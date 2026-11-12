#!/usr/bin/env bash
# Snapshots etcd (the Talos control plane's own state — cluster resources,
# Secrets, RBAC, current resource state) and stores it locally on this host.
# Deployed manually to rpi5-1 (already holds talosctl + the cluster's
# talosconfig) and run via cron; see docs/etcd-backup.md for setup.
set -euo pipefail

# cron's default PATH (/usr/bin:/bin) doesn't include /usr/local/bin, where
# talosctl lives — without this the job fails silently every night with no
# mail transport configured to report it. Root-caused 2026-09-17: the only
# etcd snapshot that ever existed was from the initial manual test run.
PATH="/usr/local/bin:${PATH}"

TALOSCONFIG="${HOME}/talos/homelab/talosconfig"
ENDPOINTS="192.168.102.11,192.168.102.12,192.168.102.13"
NODE="192.168.102.11"
BACKUP_DIR="${HOME}/backups/etcd"
KEEP_DAYS=30

B2_BUCKET="jakerobb-homelab-etcd-backups"
B2_SECRETS="${HOME}/bin/secrets/b2-etcd-backup.sops.yaml"
B2_BIN="${HOME}/.local/bin/b2"

# Healthchecks.io heartbeat (2026-11-12): the success ping goes out at the very
# end, and any failure pings /fail, so a night that doesn't finish (cron broken,
# host down, the script dying early) alerts from outside instead of depending
# on the cron mail arriving. The ping URL is a secret: a SOPS file synced here
# by compose-deploy. No file, no heartbeat.
HC_SECRETS="${HOME}/bin/secrets/healthchecks-etcd-backup.sops.yaml"
hc_ping() {
  [ -f "$HC_SECRETS" ] || return 0
  local url
  url="$(sops --decrypt --extract '["url"]' "$HC_SECRETS" 2>/dev/null)" || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null "${url}${1:-}" || true
}

VERIFY_FILE=""
on_exit() {
  local rc=$?
  if [ -n "$VERIFY_FILE" ]; then rm -f "$VERIFY_FILE"; fi
  if [ "$rc" -ne 0 ]; then hc_ping /fail; fi
  return "$rc"
}
trap on_exit EXIT

mkdir -p "$BACKUP_DIR"

TS=$(date +%Y%m%d-%H%M%S)
SNAPSHOT="${BACKUP_DIR}/etcd-${TS}.snapshot"

talosctl --talosconfig "$TALOSCONFIG" -e "$ENDPOINTS" -n "$NODE" etcd snapshot "$SNAPSHOT"

chmod 600 "$SNAPSHOT"

find "$BACKUP_DIR" -name 'etcd-*.snapshot' -mtime "+${KEEP_DAYS}" -delete

# Off-box copy (2026-09-21): dedicated private B2 bucket, application key
# scoped to just this bucket (no access to anything else in the account).
# sops exec-env injects the key as env vars for this one command only —
# nothing decrypted ever touches disk. The bucket's own 30-day lifecycle
# rule mirrors KEEP_DAYS above, so nothing here needs to manage remote
# deletion. See docs/etcd-backup.md.
#
# --skip-newer (2026-11-01): the lifecycle rule hides a file in B2 at 30 days,
# a day before the find above deletes it locally. That hide marker is newer
# than the local file, so without this flag sync aborts with "source file is
# older than destination", and set -e then skips the verify step below.
sops exec-env "$B2_SECRETS" "${B2_BIN} sync --no-progress --skip-newer --allow-empty-source ${BACKUP_DIR} b2://${B2_BUCKET}"

# Download-and-verify (2026-09-21): confirm tonight's upload is actually
# retrievable and byte-identical from B2, not just "the sync command exited
# 0" — catches silent corruption/truncation in transit or at rest without
# waiting for the quarterly restore drill (docs/etcd-backup.md#restore) to
# find out. Only verifies tonight's fresh snapshot, not the full 30-day
# history, to keep this fast and bounded.
VERIFY_FILE="$(mktemp)"

sops exec-env "$B2_SECRETS" "${B2_BIN} file download b2://${B2_BUCKET}/$(basename "$SNAPSHOT") ${VERIFY_FILE} --no-progress"

if ! cmp -s "$SNAPSHOT" "$VERIFY_FILE"; then
  echo "ERROR: snapshot downloaded back from B2 does not match the local original ($SNAPSHOT)" >&2
  exit 1
fi

hc_ping
