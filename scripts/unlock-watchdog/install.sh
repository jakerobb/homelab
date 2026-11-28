#!/usr/bin/env bash
# Installs the FileVault unlock watchdog on rpi5-1. Run as your normal user (sudo is used where needed):
#   ./install.sh [--enable host ...]
# Installs the script, the units and every hosts/*.env, and pins each Mac's SSH host key. The timers stay off unless a
# host is named after --enable (e.g. --enable studio mbp), so you can dry-run first.
set -euo pipefail
[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root." >&2; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
LIB=/usr/local/lib/unlock-watchdog
STATE=/var/lib/unlock-watchdog
OLD_LIB=/usr/local/lib/studio-unlock-watchdog
OLD_STATE=/var/lib/studio-unlock-watchdog

ENABLE=()
if [ "${1:-}" = "--enable" ]; then shift; ENABLE=("$@"); fi

sudo install -d -m 755 "$LIB" "$LIB/hosts"
sudo install -m 755 "$DIR/unlock-watchdog.sh" "$DIR/askpass.sh" "$LIB/"
sudo install -m 644 "$DIR"/hosts/*.env "$LIB/hosts/"
sudo install -m 644 "$DIR/unlock-watchdog@.service" "$DIR/unlock-watchdog@.timer" /etc/systemd/system/
sudo install -d -m 755 -o "$USER" -g "$USER" "$STATE"

# One-time move from the Studio-only version: carry over the pinned key, and swap the running timer for the new one.
if [ -d "$OLD_LIB" ] || [ -f /etc/systemd/system/studio-unlock-watchdog.timer ]; then
  was_enabled=0
  systemctl is-enabled --quiet studio-unlock-watchdog.timer 2>/dev/null && was_enabled=1
  sudo systemctl disable --now studio-unlock-watchdog.timer 2>/dev/null || true
  install -d -m 755 "$STATE/studio"
  [ -s "$STATE/studio/known_hosts" ] || [ ! -s "$OLD_STATE/known_hosts" ] || cp "$OLD_STATE/known_hosts" "$STATE/studio/known_hosts"
  sudo rm -rf "$OLD_LIB" /etc/systemd/system/studio-unlock-watchdog.service /etc/systemd/system/studio-unlock-watchdog.timer
  echo "Removed the old studio-unlock-watchdog units and files (state left in $OLD_STATE; delete it when you like)."
  if [ "$was_enabled" = 1 ]; then
    case " ${ENABLE[*]:-} " in *" studio "*) ;; *) ENABLE+=(studio) ;; esac
    echo "The old Studio timer was enabled, so unlock-watchdog@studio.timer will be too."
  fi
fi
sudo systemctl daemon-reload

# Pin each Mac's SSH host key (the pre-boot SSH server uses the same host key as the running system, checked on the
# Studio 2026-11-06). Compare the fingerprint with the Mac's before trusting it:
#   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub     (run on the Mac)
for env in "$DIR"/hosts/*.env; do
  name="$(basename "$env" .env)"
  host="$(sed -n 's/^HOST=//p' "$env")"
  secrets="$(sed -n 's/^SECRETS_FILE=//p' "$env")"
  install -d -m 755 "$STATE/$name"
  if [ ! -s "$STATE/$name/known_hosts" ]; then
    ssh-keyscan -t ed25519 "$host" > "$STATE/$name/known_hosts" 2>/dev/null || true
    if [ -s "$STATE/$name/known_hosts" ]; then
      echo "Pinned host key for $name ($host):"
      ssh-keygen -lf "$STATE/$name/known_hosts"
      echo "Compare that fingerprint with the one on the Mac. If it differs, delete $STATE/$name/known_hosts and stop."
    else
      echo "Could not read $name's host key from $host (is it up?). Re-run install.sh later to pin it." >&2
    fi
  fi
  [ -f "$secrets" ] || echo "No $secrets yet for $name. See docs/unlock-watchdog.md (Setup)." >&2
done

for name in "${ENABLE[@]:-}"; do
  [ -n "$name" ] || continue
  sudo systemctl enable --now "unlock-watchdog@$name.timer"
  echo "Timer enabled for $name."
done
if [ "${#ENABLE[@]}" -eq 0 ]; then
  echo "Installed; no timers enabled. Dry-run first:  DRY_RUN=1 $LIB/unlock-watchdog.sh <host>"
  echo "Then enable:  sudo systemctl enable --now unlock-watchdog@<host>.timer"
fi
