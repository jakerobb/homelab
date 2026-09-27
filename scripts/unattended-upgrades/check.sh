#!/usr/bin/env bash
# Daily check that unattended-upgrades is actually doing its job. Prints
# problems to stderr, so cron (MAILTO + stdout to /dev/null) mails them;
# prints nothing when all is well. Runs on rpi5-1 directly, and on the
# Proxmox host piped over SSH from rpi5-1's crontab (it has no mail setup of
# its own). See docs/rpi5-1-os-updates.md and docs/proxmox-os-updates.md.
#
# Catches the failure that went unnoticed for a year: unattended-upgrades not
# installed (or not running) while Debian security fixes pile up.
set -euo pipefail

LOG=/var/log/unattended-upgrades/unattended-upgrades.log
STATE="${XDG_CACHE_HOME:-$HOME/.cache}/pending-security-upgrades"
MAX_LOG_AGE_DAYS=3

problems=()

if ! dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
  problems+=("unattended-upgrades is not installed (run scripts/unattended-upgrades/install.sh)")
fi

for f in /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/52unattended-upgrades-local; do
  [ -f "$f" ] || problems+=("$f is missing (run scripts/unattended-upgrades/install.sh)")
done

if [ ! -f "$LOG" ]; then
  problems+=("$LOG does not exist; unattended-upgrades has never run")
elif [ -n "$(find "$LOG" -mtime "+${MAX_LOG_AGE_DAYS}")" ]; then
  problems+=("$LOG has not been written in over ${MAX_LOG_AGE_DAYS} days")
fi

# A security fix can reasonably be pending for up to a day (published after
# this morning's apt-daily-upgrade run). Only complain about packages that
# were also pending at the previous check.
mkdir -p "$(dirname "$STATE")"
touch "$STATE"
current="$(apt list --upgradable 2>/dev/null | grep -- '-security' | cut -d/ -f1 | sort || true)"
stale="$(comm -12 <(echo "$current") "$STATE" | grep -v '^$' || true)"
echo "$current" > "$STATE"

if [ -n "$stale" ]; then
  problems+=("security upgrades pending for over a day: $(echo "$stale" | wc -l | tr -d ' ') ($(echo "$stale" | head -10 | paste -sd ' ' -))")
fi

if [ ${#problems[@]} -gt 0 ]; then
  {
    echo "$(hostname) OS update check found problems:"
    printf -- '- %s\n' "${problems[@]}"
  } >&2
  exit 1
fi
