#!/usr/bin/env bash
# Runs Terraform against Proxmox with the API token injected from
# secrets/proxmox-api-token.sops.yaml for the duration of this one command —
# same sops-exec-env pattern as scripts/etcd-snapshot-backup.sh's B2
# credentials. Nothing decrypted ever touches disk or shell history.
#
# Usage: ./tf.sh plan
#        ./tf.sh apply
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="${SCRIPT_DIR}/secrets/proxmox-api-token.sops.yaml"

if [ ! -f "$SECRETS_FILE" ]; then
  echo "Missing $SECRETS_FILE — see secrets/proxmox-api-token.yaml.example" >&2
  exit 1
fi

cmd="terraform -chdir=${SCRIPT_DIR}"
for arg in "$@"; do
  cmd+=" $(printf '%q' "$arg")"
done

exec sops exec-env "$SECRETS_FILE" "$cmd"
