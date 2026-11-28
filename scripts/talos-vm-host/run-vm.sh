#!/bin/sh
# Runs a Talos worker VM under QEMU with Apple's Hypervisor.framework (HVF). Started by the host's
# com.jakerobb.talos-worker-* LaunchDaemon, as root, because vmnet-bridged needs root. One script for every Mac that
# hosts a worker: the per-host settings come from the daemon's plist (EnvironmentVariables), so the Mac Studio (arm64)
# and the MacBook Pro (x86_64) run identical logic. See ../../docs/studio-worker-and-ram-upgrade.md and
# ../../docs/mbp-worker-qemu.md.
#
# Required (plist): VM_ARCH (aarch64 or x86_64), VM_MAC, VM_CPUS, VM_MEM_MB, BRIDGE_IF.
# Optional: VM_DIR (default /Users/jakerobb/talos-vm), QEMU, VM_CPU, VM_NIC_OPTS (extra virtio-net-pci options), NET (a
# full -netdev argument, for testing), CDROM (the ISO to attach).
set -eu

: "${VM_ARCH:?VM_ARCH is not set}" "${VM_MAC:?VM_MAC is not set}" "${VM_CPUS:?VM_CPUS is not set}"
: "${VM_MEM_MB:?VM_MEM_MB is not set}" "${BRIDGE_IF:?BRIDGE_IF is not set}"
VM_DIR="${VM_DIR:-/Users/jakerobb/talos-vm}"
VM_NIC_OPTS="${VM_NIC_OPTS:+,$VM_NIC_OPTS}"
case "$VM_ARCH" in
  aarch64) QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}"; ISO=metal-arm64.iso ;;
  x86_64)  QEMU="${QEMU:-/Users/jakerobb/.local/qemu/bin/qemu-system-x86_64}"; ISO=metal-amd64.iso ;;
  *) echo "VM_ARCH must be aarch64 or x86_64, not $VM_ARCH" >&2; exit 64 ;;
esac
SHARE="$(cd "$(dirname "$QEMU")/../share/qemu" && pwd)"
# rx_queue_size=1024 on the Studio (plist VM_NIC_OPTS; the maximum, default 256) is a throughput experiment: QEMU's
# vmnet backend moves packets on one thread, which saturated at ~6 Gbit/s sending / ~7.5 receiving with ~1,000
# retransmits per 10s run (2026-11-06). Result: sending improved a few percent (6.1 to 6.65 Gbit/s on one stream),
# receiving didn't (7.1-7.5 either way), and retransmits were mixed. Kept, since it costs nothing, but it isn't the
# fix: the single thread is the limit.
NET="${NET:-vmnet-bridged,id=net0,ifname=${BRIDGE_IF}}"

if [ "$VM_ARCH" = aarch64 ]; then
  [ -f "$VM_DIR/vars.fd" ] || dd if=/dev/zero of="$VM_DIR/vars.fd" bs=1m count=64 2>/dev/null
  set -- \
    -machine virt,highmem=on -accel hvf -cpu "${VM_CPU:-host}" \
    -no-reboot \
    -smp "$VM_CPUS" -m "$VM_MEM_MB" \
    -drive if=pflash,format=raw,file="$SHARE/edk2-aarch64-code.fd",readonly=on \
    -drive if=pflash,format=raw,file="$VM_DIR/vars.fd" \
    -drive if=none,id=disk0,file="$VM_DIR/disk.qcow2",format=qcow2,cache=writeback,discard=unmap \
    -device virtio-blk-pci,drive=disk0,bootindex=1 \
    -netdev "$NET" -device virtio-net-pci,netdev=net0,mac="$VM_MAC""$VM_NIC_OPTS" \
    -device virtio-rng-pci \
    -display none -serial "file:$VM_DIR/console.log" \
    -monitor "unix:$VM_DIR/monitor.sock,server,nowait"
else
  # Mirrors what UTM ran for the MacBook Pro's VM (read from its process arguments), so the guest sees the same
  # hardware: the NIC at PCI slot 1 (Talos names it enp0s1, which worker-mbp.yaml's static config depends on), and the
  # disk on the q35 AHCI controller (/dev/sda, which its install.disk names). Don't "improve" either to virtio without
  # changing that machine config in the same step. The CPU model is UTM's too, for the same reason.
  [ -f "$VM_DIR/vars.fd" ] || cp "$SHARE/edk2-i386-vars.fd" "$VM_DIR/vars.fd"
  set -- \
    -machine q35,vmport=off,i8042=off,hpet=off -accel hvf -cpu "${VM_CPU:-Skylake-Client}" \
    -no-reboot -nodefaults \
    -smp "cpus=$VM_CPUS,sockets=1,cores=$VM_CPUS,threads=1" -m "$VM_MEM_MB" \
    -global PIIX4_PM.disable_s3=1 -global ICH9-LPC.disable_s3=1 \
    -drive if=pflash,format=raw,unit=0,file="$SHARE/edk2-x86_64-code.fd",readonly=on \
    -drive if=pflash,format=raw,unit=1,file="$VM_DIR/vars.fd" \
    -netdev "$NET" -device virtio-net-pci,netdev=net0,mac="$VM_MAC",bus=pcie.0,addr=0x1"$VM_NIC_OPTS" \
    -drive if=none,media=disk,id=disk0,file="$VM_DIR/disk.qcow2",format=qcow2,discard=unmap,detect-zeroes=unmap \
    -device ide-hd,bus=ide.0,drive=disk0,bootindex=0 \
    -device virtio-rng-pci \
    -display none -serial "file:$VM_DIR/console.log" \
    -monitor "unix:$VM_DIR/monitor.sock,server,nowait"
fi
# The Talos metal ISO stays attached as the second boot device. A blank disk falls through to it on first boot,
# which gives the interactive maintenance API (the nocloud disk image never opens one; see utm-talos-worker.md).
# Once Talos is installed the disk boots first and the ISO is ignored, but it is still there as a recovery boot.
CDROM="${CDROM:-$VM_DIR/$ISO}"
if [ -f "$CDROM" ]; then
  if [ "$VM_ARCH" = aarch64 ]; then
    set -- "$@" -drive if=none,id=cd0,file="$CDROM",media=cdrom,readonly=on -device usb-ehci -device usb-storage,drive=cd0,bootindex=2
  else
    set -- "$@" -drive if=none,id=cd0,file="$CDROM",media=cdrom,readonly=on -device ide-cd,bus=ide.1,drive=cd0,bootindex=1
  fi
fi

# -no-reboot: a guest reboot makes QEMU exit, and launchd (KeepAlive) starts a fresh process, which is a cold boot of the
# VM. Without it QEMU resets the vCPUs in place, which is a risk under HVF. (The wedge seen during the 2026-11-25 Talos
# upgrade on the Studio was Talos's kexec reboot, which hangs under HVF; the Studio's machine config sets
# kernel.kexec_load_disabled to avoid it. See ../../docs/studio-worker-and-ram-upgrade.md.)
#
# Even so, QEMU's stderr goes through `uniq_log` below, which collapses runs of identical lines, so a storm like that
# can't fill the disk.
#
# Not `exec`: launchd stops the daemon with SIGTERM (host shutdown, restart, bootout), which would kill the VM
# like a power cut. Instead ask the guest to power down over the QEMU monitor (Talos treats the ACPI power
# button as a graceful shutdown) and wait for it, up to the plist's ExitTimeOut.
uniq_log() {
  /usr/bin/awk '
    $0 == prev { n++; next }
    { if (n > 1) print "(previous line repeated " n " times)"; print; prev = $0; n = 1; fflush() }
    END { if (n > 1) print "(previous line repeated " n " times)" }'
}
LOGFIFO="$VM_DIR/qemu-log.fifo"
rm -f "$LOGFIFO"; mkfifo "$LOGFIFO"
uniq_log < "$LOGFIFO" &
"$QEMU" "$@" > "$LOGFIFO" 2>&1 &
QPID=$!
trap 'echo system_powerdown | /usr/bin/nc -U "$VM_DIR/monitor.sock" >/dev/null 2>&1 || kill "$QPID"' TERM INT
# `wait` returns early when a trapped signal arrives; keep waiting until QEMU itself has exited.
while kill -0 "$QPID" 2>/dev/null; do wait "$QPID" || true; done
