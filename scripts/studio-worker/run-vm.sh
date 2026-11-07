#!/bin/sh
# Runs the talos-worker-studio VM under QEMU with Apple's Hypervisor.framework
# (HVF). Started by the com.jakerobb.talos-worker-studio LaunchDaemon, as root,
# because vmnet-bridged needs root. See ../../docs/studio-worker-and-ram-upgrade.md.
#
# Env overrides, mostly for testing: VM_DIR, NET (a full -netdev argument), CDROM (the ISO to attach).
set -eu

VM_DIR="${VM_DIR:-/Users/jakerobb/talos-vm}"
QEMU=/opt/homebrew/bin/qemu-system-aarch64
FW=/opt/homebrew/share/qemu/edk2-aarch64-code.fd
BRIDGE_IF="${BRIDGE_IF:-en0}"
MAC="02:00:00:00:00:36"
# rx_queue_size=1024 (the maximum; default 256) is a throughput experiment: QEMU's vmnet backend moves packets on one
# thread, which saturated at ~6 Gbit/s sending / ~7.5 receiving with ~1,000 retransmits per 10s run (2026-11-06).
# Result: sending improved a few percent (6.1 to 6.65 Gbit/s on one stream), receiving didn't (7.1-7.5 either way),
# and retransmits were mixed. Kept, since it costs nothing, but it isn't the fix: the single thread is the limit.
NET="${NET:-vmnet-bridged,id=net0,ifname=${BRIDGE_IF}}"

[ -f "$VM_DIR/vars.fd" ] || dd if=/dev/zero of="$VM_DIR/vars.fd" bs=1m count=64 2>/dev/null

set -- \
  -machine virt,highmem=on -accel hvf -cpu host \
  -smp 16 -m 40960 \
  -drive if=pflash,format=raw,file="$FW",readonly=on \
  -drive if=pflash,format=raw,file="$VM_DIR/vars.fd" \
  -drive if=none,id=disk0,file="$VM_DIR/disk.qcow2",format=qcow2,cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=disk0,bootindex=1 \
  -netdev "$NET" -device virtio-net-pci,netdev=net0,mac="$MAC",rx_queue_size=1024 \
  -device virtio-rng-pci \
  -display none -serial "file:$VM_DIR/console.log" \
  -monitor "unix:$VM_DIR/monitor.sock,server,nowait"
# The Talos metal ISO stays attached as the second boot device. A blank disk falls through to it on first boot,
# which gives the interactive maintenance API (the nocloud disk image never opens one; see utm-talos-worker.md).
# Once Talos is installed the disk boots first and the ISO is ignored, but it is still there as a recovery boot.
CDROM="${CDROM:-$VM_DIR/metal-arm64.iso}"
if [ -f "$CDROM" ]; then
  set -- "$@" -drive if=none,id=cd0,file="$CDROM",media=cdrom,readonly=on -device usb-ehci -device usb-storage,drive=cd0,bootindex=2
fi

# Not `exec`: launchd stops the daemon with SIGTERM (host shutdown, restart, bootout), which would kill the VM
# like a power cut. Instead ask the guest to power down over the QEMU monitor (Talos treats the ACPI power
# button as a graceful shutdown) and wait for it, up to the plist's ExitTimeOut.
"$QEMU" "$@" &
QPID=$!
trap 'echo system_powerdown | /usr/bin/nc -U "$VM_DIR/monitor.sock" >/dev/null 2>&1 || kill "$QPID"' TERM INT
# `wait` returns early when a trapped signal arrives; keep waiting until QEMU itself has exited.
while kill -0 "$QPID" 2>/dev/null; do wait "$QPID" || true; done
