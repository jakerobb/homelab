#!/bin/sh
# Installs the talos-worker-studio VM as a root LaunchDaemon on the Mac Studio.
# Run as your normal user (sudo is used where needed): ./install.sh
# Needs ~/talos-vm/disk.qcow2 already in place; see ../../docs/studio-worker-and-ram-upgrade.md. The launcher
# is shared with the MacBook Pro: ../talos-vm-host/run-vm.sh.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$HERE/../talos-vm-host/install-vm.sh" "$HERE" studio
