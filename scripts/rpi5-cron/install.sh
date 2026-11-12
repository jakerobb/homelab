#!/usr/bin/env bash
# Installs rpi5-1's cron jobs as one file per job under /etc/cron.d/ (names
# homelab-*), removes homelab-* files that are no longer in this directory, and
# retires the old per-user crontab (backed up first). Idempotent. Run on rpi5-1
# from this directory; the compose-deploy cron alerts on ntfy when an installed
# file differs from the repo. See docs/cron-jobs.md.
#
# cron.d rules: root-owned, mode 0644, file names without dots.
set -euo pipefail

cd "$(dirname "$0")"

for f in homelab-*; do
  sudo install -m 0644 -o root -g root "$f" "/etc/cron.d/$f"
done

for f in /etc/cron.d/homelab-*; do
  [ -e "$f" ] || continue
  [ -e "$(basename "$f")" ] || { echo "removing stale $f"; sudo rm -- "$f"; }
done

# The same jobs also in the user crontab would run twice.
if crontab -l >/dev/null 2>&1; then
  backup="$HOME/crontab.backup-$(date +%Y%m%d-%H%M%S)"
  crontab -l > "$backup"
  echo "old user crontab saved to $backup"
  crontab -r
fi

ls -l /etc/cron.d/homelab-*
