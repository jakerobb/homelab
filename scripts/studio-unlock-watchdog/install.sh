#!/usr/bin/env bash
# Installs the Studio unlock watchdog on rpi5-1. Run as your normal user (sudo is used where needed):
#   ./install.sh [--enable]
# Without --enable it installs the files and the units but leaves the timer off, so you can dry-run first.
set -euo pipefail
[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root." >&2; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
LIB=/usr/local/lib/studio-unlock-watchdog
STATE=/var/lib/studio-unlock-watchdog
HOST="${STUDIO_HOST:-192.168.102.22}"
SECRETS="$HOME/bin/secrets/studio-unlock.sops.yaml"

sudo install -d -m 755 "$LIB"
sudo install -m 755 "$DIR/studio-unlock-watchdog.sh" "$DIR/askpass.sh" "$LIB/"
sudo install -m 644 "$DIR/studio-unlock-watchdog.service" "$DIR/studio-unlock-watchdog.timer" /etc/systemd/system/
sudo install -d -m 755 -o "$USER" -g "$USER" "$STATE"

# Pin the Studio's SSH host key. The pre-boot SSH server uses the same host key as the running system (checked
# 2026-11-06), so one entry covers both. Compare the fingerprint with the Studio's before trusting it:
#   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub     (run on the Studio)
if [ ! -s "$STATE/known_hosts" ]; then
  ssh-keyscan -t ed25519 "$HOST" > "$STATE/known_hosts" 2>/dev/null
  echo "Pinned host key for $HOST:"
  ssh-keygen -lf "$STATE/known_hosts"
  echo "Compare that fingerprint with the one on the Studio. If it differs, delete $STATE/known_hosts and stop."
fi

sudo systemctl daemon-reload
if [ ! -f "$SECRETS" ]; then
  echo "No $SECRETS yet. Create it from scripts/secrets/studio-unlock.example.yaml (docs/studio-unlock-watchdog.md)." >&2
fi
if [ "${1:-}" = "--enable" ]; then
  sudo systemctl enable --now studio-unlock-watchdog.timer
  echo "Timer enabled."
else
  echo "Installed; timer NOT enabled. Dry-run first:  DRY_RUN=1 $LIB/studio-unlock-watchdog.sh"
  echo "Then enable:  sudo systemctl enable --now studio-unlock-watchdog.timer"
fi
