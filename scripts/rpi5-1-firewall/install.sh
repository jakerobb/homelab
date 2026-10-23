#!/bin/bash
# Installs or updates the rpi5-1 host firewall. Run as root on rpi5-1:
#   sudo ./install.sh log       # log what would be dropped, drop nothing (default)
#   sudo ./install.sh enforce   # drop whatever the rules don't allow
# Safe to rerun; switching modes reloads the ruleset atomically.
set -euo pipefail
mode="${1:-log}"
case "$mode" in
  log)     rule="# log-only: the final chain stays empty" ;;
  enforce) rule="add rule inet homelab_fw final drop" ;;
  *) echo "usage: $0 [log|enforce]" >&2; exit 2 ;;
esac
here="$(cd "$(dirname "$0")" && pwd)"
install -d -m 0755 /etc/homelab-fw
install -m 0644 "$here/homelab-fw.nft" /etc/homelab-fw/homelab-fw.nft
echo "$rule" > /etc/homelab-fw/mode.nft
nft -c -f /etc/homelab-fw/homelab-fw.nft
install -m 0644 "$here/homelab-fw.service" /etc/systemd/system/homelab-fw.service
systemctl daemon-reload
systemctl enable homelab-fw.service
systemctl reload-or-restart homelab-fw.service
echo "homelab-fw is in $mode mode"
