#!/usr/bin/env bash
# Backs up Proxmox host config that isn't reproducible from this repo's
# Terraform/docs — the web UI TLS cert, user/token database, storage.cfg —
# to rpi5-1. Deployed manually to /usr/local/sbin on the Proxmox host and run
# via cron; see docs/proxmox-config-backup.md for setup.
#
# Deliberately NOT committed to git as live state: /etc/pve mixes secrets
# (hashed tokens/passwords, TLS private key) with config, and mutates
# continuously. VM configs under /etc/pve/qemu-server are derived state once
# Terraform manages them — the source of truth for those is already in git.
set -euo pipefail

BACKUP_USER="pve-backup"
BACKUP_HOST="rpi5-1.lan"
BACKUP_KEY="/root/.ssh/pve-backup-ed25519"
REMOTE_DIR="backups/proxmox"
KEEP_DAYS=14

TS=$(date +%Y%m%d-%H%M%S)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
ARCHIVE="${WORKDIR}/proxmox-config-${TS}.tar.gz"

tar czf "$ARCHIVE" \
  /etc/pve \
  /etc/network/interfaces \
  /etc/apt/sources.list.d \
  /etc/hosts \
  /etc/resolv.conf \
  /etc/chrony \
  2>/dev/null || true # tolerate paths that may not exist on this install

chmod 600 "$ARCHIVE"

scp -i "$BACKUP_KEY" -o StrictHostKeyChecking=accept-new \
  "$ARCHIVE" "${BACKUP_USER}@${BACKUP_HOST}:${REMOTE_DIR}/"

ssh -i "$BACKUP_KEY" -o StrictHostKeyChecking=accept-new "${BACKUP_USER}@${BACKUP_HOST}" \
  "find ${REMOTE_DIR} -name 'proxmox-config-*.tar.gz' -mtime +${KEEP_DAYS} -delete"
