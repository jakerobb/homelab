#!/bin/sh
set -eu
PART=/dev/nvme0n1p1
MNT=/mnt/esp

echo "=== dry-run u-boot inspector (not a real Talos installer) ==="
mkdir -p "$MNT"
echo "mounting $PART read-only at $MNT"
mount -t vfat -o ro "$PART" "$MNT"

echo "--- directory listing of $MNT ---"
ls -la "$MNT"

if [ ! -f "$MNT/config.txt" ] || [ ! -f "$MNT/u-boot.bin" ]; then
  echo "ERROR: expected config.txt and u-boot.bin not both found at $MNT -- wrong partition or layout?" >&2
  umount "$MNT"
  exit 1
fi

echo "--- u-boot.bin sha256 ---"
sha256sum "$MNT/u-boot.bin"

echo "--- config.txt contents ---"
cat "$MNT/config.txt"

umount "$MNT"
echo "=== DRY RUN OK -- exiting 1 deliberately so no reboot is ever triggered ==="
exit 1
