#!/bin/bash
# Preflight for a Talos upgrade: is the node's EFI system partition (ESP) big enough to take the new boot image?
# Usage: check-esp.sh <node-ip> [min-MiB]     (run on the jump box; read-only, nothing on the node changes)
#
# A Talos upgrade writes the new UKI (~100 MiB for a Pi 5 build, plus u-boot.bin, overlays and systemd-boot) to the ESP
# and removes the old one. Nodes that were dd'd from a raw image (talos-worker-3) have a ~100 MiB ESP that can't hold
# the image at all, and the upgrade then leaves the node without a kernel. Nodes provisioned by the installer have a
# 2.2 GB ESP. Default minimum is 400 MiB (about 3x the UKI). This checks the partition's size, not its free space;
# the installer's own contents are small next to that margin.
set -euo pipefail
IP=${1:?usage: check-esp.sh <node-ip> [min-MiB]}
MIN_MIB=${2:-400}
VOLS=$(talosctl -n "$IP" get discoveredvolumes -o json 2>/dev/null | jq -s '[.[] | select(.spec.label == "EFI" and .spec.type == "partition")]') \
  || { echo "ESP CHECK FAILED: can't read disk layout from $IP" >&2; exit 2; }
if [ "$(jq length <<<"$VOLS")" -ne 1 ]; then
  echo "ESP CHECK FAILED: expected exactly one EFI partition on $IP, found $(jq length <<<"$VOLS")" >&2; exit 2
fi
SIZE=$(jq -r '.[0].spec.size' <<<"$VOLS")
SIZE_MIB=$((SIZE / 1048576))
DEV=$(jq -r '.[0].spec.dev_path' <<<"$VOLS")
if [ "$SIZE_MIB" -lt "$MIN_MIB" ]; then
  echo "ESP CHECK FAILED: $IP $DEV is ${SIZE_MIB} MiB, need at least ${MIN_MIB} MiB. Don't upgrade this node: re-provision it with the installer first (see talos/README.md, 'ESP size')." >&2
  exit 1
fi
echo "ESP ok: $IP $DEV is ${SIZE_MIB} MiB (minimum ${MIN_MIB} MiB)"
