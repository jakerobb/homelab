#!/bin/sh
set -eu
PART=/dev/nvme0n1p1
MNT=/mnt/esp
NEW_HASH="9aa3c44ab42d181dd3ecf1aa2759f2ee702e019d590110fd41c4a415de311265"
BACKUP_NAME="u-boot.bin.orig-backup-20260918"

echo "=== u-boot write installer (not a real Talos installer) ==="
mkdir -p "$MNT"
mount -t vfat -o rw "$PART" "$MNT"

if [ ! -f "$MNT/config.txt" ] || [ ! -f "$MNT/u-boot.bin" ]; then
  echo "ERROR: sanity check failed (missing config.txt/u-boot.bin) -- aborting without writing anything" >&2
  umount "$MNT"
  exit 1
fi

echo "current u-boot.bin:"
sha256sum "$MNT/u-boot.bin"

if [ -f "$MNT/$BACKUP_NAME" ]; then
  echo "ERROR: backup file $BACKUP_NAME already exists -- refusing to overwrite, aborting" >&2
  umount "$MNT"
  exit 1
fi

echo "staging new u-boot.bin"
cp /payload/u-boot.bin "$MNT/u-boot.bin.new"
ACTUAL=$(sha256sum "$MNT/u-boot.bin.new" | awk '{print $1}')
if [ "$ACTUAL" != "$NEW_HASH" ]; then
  echo "ERROR: staged payload hash mismatch ($ACTUAL != $NEW_HASH) -- aborting, removing staged file" >&2
  rm -f "$MNT/u-boot.bin.new"
  umount "$MNT"
  exit 1
fi
echo "staged payload verified: $ACTUAL"

echo "backing up current u-boot.bin to $BACKUP_NAME"
cp "$MNT/u-boot.bin" "$MNT/$BACKUP_NAME"

echo "swapping in new u-boot.bin"
mv "$MNT/u-boot.bin.new" "$MNT/u-boot.bin"
sync

FINAL=$(sha256sum "$MNT/u-boot.bin" | awk '{print $1}')
umount "$MNT"

if [ "$FINAL" != "$NEW_HASH" ]; then
  echo "ERROR: post-write verification failed! final=$FINAL expected=$NEW_HASH" >&2
  exit 1
fi

echo "=== u-boot.bin replaced and verified: $FINAL ==="
echo "=== backup of original saved on-disk as $BACKUP_NAME ==="
exit 0
