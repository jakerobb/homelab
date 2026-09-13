#!/usr/bin/env bash
# Snapshots etcd (the Talos control plane's own state — cluster resources,
# Secrets, RBAC, current resource state) and stores it locally on this host.
# Deployed manually to rpi5-1 (already holds talosctl + the cluster's
# talosconfig) and run via cron; see docs/etcd-backup.md for setup.
set -euo pipefail

TALOSCONFIG="${HOME}/talos/homelab/talosconfig"
ENDPOINTS="192.168.102.11,192.168.102.12,192.168.102.13"
NODE="192.168.102.11"
BACKUP_DIR="${HOME}/backups/etcd"
KEEP_DAYS=30

mkdir -p "$BACKUP_DIR"

TS=$(date +%Y%m%d-%H%M%S)
SNAPSHOT="${BACKUP_DIR}/etcd-${TS}.snapshot"

talosctl --talosconfig "$TALOSCONFIG" -e "$ENDPOINTS" -n "$NODE" etcd snapshot "$SNAPSHOT"

chmod 600 "$SNAPSHOT"

find "$BACKUP_DIR" -name 'etcd-*.snapshot' -mtime "+${KEEP_DAYS}" -delete
