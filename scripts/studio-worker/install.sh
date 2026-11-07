#!/bin/sh
# Installs the talos-worker-studio VM as a root LaunchDaemon on the Mac Studio.
# Run as your normal user (sudo is used where needed): ./install.sh
# Needs ~/talos-vm/disk.qcow2 already in place; see ../../docs/studio-worker-and-ram-upgrade.md.
set -eu
[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root." >&2; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HOME/talos-vm/disk.qcow2" ] || { echo "Missing $HOME/talos-vm/disk.qcow2" >&2; exit 1; }
sudo install -d -m 755 /usr/local/sbin
sudo install -m 755 -o root -g wheel "$DIR/run-vm.sh" /usr/local/sbin/talos-worker-studio-run
plutil -lint "$DIR/com.jakerobb.talos-worker-studio.plist"
sudo install -m 644 -o root -g wheel "$DIR/com.jakerobb.talos-worker-studio.plist" /Library/LaunchDaemons/
sudo launchctl bootout system/com.jakerobb.talos-worker-studio 2>/dev/null || true
# A graceful stop (ACPI power-down, then Talos shutting down) takes up to the plist's ExitTimeOut (120s); bootstrapping
# earlier fails with "Input/output error". Wait for launchd to forget the service, up to 150s.
for _ in $(seq 1 300); do sudo launchctl print system/com.jakerobb.talos-worker-studio >/dev/null 2>&1 || break; sleep 0.5; done
sudo launchctl bootstrap system /Library/LaunchDaemons/com.jakerobb.talos-worker-studio.plist
echo "Started. Console: $HOME/talos-vm/console.log; daemon log: /var/log/talos-worker-studio.log"
