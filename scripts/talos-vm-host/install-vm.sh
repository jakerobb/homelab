#!/bin/sh
# Installs a Talos worker VM as a root LaunchDaemon on a Mac. Not run directly: the per-host wrappers
# (studio-worker/install.sh, mbp-worker/install.sh) call it with their directory and worker name.
#   install-vm.sh <dir holding com.jakerobb.talos-worker-<name>.plist> <name, e.g. studio>
# Run as your normal user (sudo is used where needed). Needs ~/talos-vm/disk.qcow2 already in place.
set -eu
[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root." >&2; exit 1; }
[ $# -eq 2 ] || { echo "usage: install-vm.sh <host dir> <name>" >&2; exit 64; }
HOSTDIR="$1"; NAME="talos-worker-$2"
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.jakerobb.$NAME"
SRC_PLIST="$HOSTDIR/$LABEL.plist"
RUN="/usr/local/sbin/$NAME-run"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
[ -f "$HOME/talos-vm/disk.qcow2" ] || { echo "Missing $HOME/talos-vm/disk.qcow2" >&2; exit 1; }
plutil -lint "$SRC_PLIST"
# Restarting the daemon powers the VM off (gracefully), so only do it when something it runs has changed, or it isn't
# loaded. Drain the node before running this when it will restart.
if cmp -s "$DIR/run-vm.sh" "$RUN" && cmp -s "$SRC_PLIST" "$PLIST" && sudo launchctl print "system/$LABEL" >/dev/null 2>&1; then
  echo "Installed files already match and the daemon is loaded; leaving the VM running."
  exit 0
fi
sudo install -d -m 755 /usr/local/sbin
sudo install -m 755 -o root -g wheel "$DIR/run-vm.sh" "$RUN"
sudo install -m 644 -o root -g wheel "$SRC_PLIST" /Library/LaunchDaemons/
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
# A graceful stop (ACPI power-down, then Talos shutting down) takes up to the plist's ExitTimeOut (120s); bootstrapping
# earlier fails with "Input/output error". Wait for launchd to forget the service, up to 150s.
for _ in $(seq 1 300); do sudo launchctl print "system/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
sudo launchctl bootstrap system "$PLIST"
echo "Started. Console: $HOME/talos-vm/console.log; daemon log: /var/log/$NAME.log"
