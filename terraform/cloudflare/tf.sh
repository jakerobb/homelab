#!/usr/bin/env bash
# Runs Terraform against Cloudflare with the API token (secrets/cloudflare-api-token.sops.yaml)
# and the B2 state-backend key (shared with terraform/proxmox) injected for the duration
# of this one command. Same pattern as ../proxmox/tf.sh — see there for the details.
# Used both by hand on the jump box and by .github/workflows/terraform-cloudflare.yml.
#
# Usage: ./tf.sh plan
#        ./tf.sh apply
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="${SCRIPT_DIR}/secrets/cloudflare-api-token.sops.yaml"
STATE_SECRETS_FILE="${SCRIPT_DIR}/../proxmox/secrets/b2-state-backend.sops.yaml"

for f in "$SECRETS_FILE" "$STATE_SECRETS_FILE"; do
  if [ ! -f "$f" ]; then
    echo "Missing $f — see ${f%.sops.yaml}.yaml.example" >&2
    exit 1
  fi
done

# B2 can't do Terraform's native state locking (see backend.tf), so serialize runs
# on this host instead — CI and manual runs both happen on the jump box, and the
# lock file is shared across users (world-writable /run/lock). Held until
# Terraform exits, since the fd is inherited through the exec below. Skipped where
# flock doesn't exist (macOS), which isn't somewhere this should run anyway.
if command -v flock >/dev/null 2>&1; then
  LOCK_DIR=/run/lock
  [ -d "$LOCK_DIR" ] && [ -w "$LOCK_DIR" ] || LOCK_DIR=/tmp
  LOCK_FILE="${LOCK_DIR}/homelab-terraform-cloudflare.lock"
  [ -e "$LOCK_FILE" ] || (umask 000 && : >"$LOCK_FILE")
  exec 9<"$LOCK_FILE"
  if ! flock -n 9; then
    echo "Another tf.sh run holds $LOCK_FILE — waiting up to 15 minutes..." >&2
    flock -w 900 9 || { echo "Timed out waiting for $LOCK_FILE" >&2; exit 1; }
  fi
fi

cmd="terraform -chdir=${SCRIPT_DIR}"
for arg in "$@"; do
  cmd+=" $(printf '%q' "$arg")"
done

exec sops exec-env "$STATE_SECRETS_FILE" \
  "sops exec-env $(printf '%q' "$SECRETS_FILE") $(printf '%q' "$cmd")"
