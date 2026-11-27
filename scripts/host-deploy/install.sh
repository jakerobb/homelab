#!/bin/sh
# One-time setup of host-deploy on a Mac VM host: clones the repo into a dedicated deploy checkout and installs the
# launchd job that runs host-deploy.py from it every 5 minutes. Run as your normal user: ./install.sh. Safe to re-run.
# The checkout is separate from your working copy on purpose: host-deploy pauses (and alerts) if its clone is dirty or
# off main, and you shouldn't have to keep your dev checkout on main for it.
set -eu
[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root." >&2; exit 1; }
[ "$HOME" = /Users/jakerobb ] || { echo "The plist hard-codes /Users/jakerobb; edit it for $HOME first." >&2; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
CLONE="$HOME/.local/share/host-deploy/homelab"

mkdir -p "$(dirname "$CLONE")" "$HOME/.local/state/host-deploy"
chmod 700 "$HOME/.local/state/host-deploy"
if [ -d "$CLONE/.git" ]; then
  git -C "$CLONE" pull --ff-only --quiet
else
  # The repo is public, so this needs no credentials (and no ssh agent, which a daemon can't use).
  git clone --quiet https://github.com/jakerobb/homelab.git "$CLONE"
fi

plutil -lint "$DIR/com.jakerobb.host-deploy.plist"
sudo install -m 644 -o root -g wheel "$DIR/com.jakerobb.host-deploy.plist" /Library/LaunchDaemons/
sudo launchctl bootout system/com.jakerobb.host-deploy 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.jakerobb.host-deploy.plist
echo "Installed. First run: /usr/bin/python3 $CLONE/scripts/host-deploy/host-deploy.py -v --dry-run"
echo "Log: ~/.local/state/host-deploy/deploy.log (launchd's own output: launchd.log there)"
