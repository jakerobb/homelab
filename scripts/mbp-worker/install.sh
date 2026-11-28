#!/bin/sh
# Installs the talos-worker-mbp VM as a root LaunchDaemon on the MacBook Pro.
# Run as your normal user (sudo is used where needed): ./install.sh
# Needs ~/talos-vm/disk.qcow2 in place and QEMU built into ~/.local/qemu; see ../../docs/mbp-worker-qemu.md. The launcher
# is shared with the Mac Studio: ../talos-vm-host/run-vm.sh.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -x "$HOME/.local/qemu/bin/qemu-system-x86_64" ] || { echo "Missing $HOME/.local/qemu/bin/qemu-system-x86_64 (../talos-vm-host/build-qemu-macos-x86.sh)" >&2; exit 1; }
exec "$HERE/../talos-vm-host/install-vm.sh" "$HERE" mbp
