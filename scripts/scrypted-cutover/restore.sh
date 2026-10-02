#!/usr/bin/env bash
# One-time cutover helper: copies Scrypted's /server/volume from the old Compose install on
# rpi5-1 into the cluster's PVC. Run on rpi5-1 AFTER the migration PR is merged, once the new
# pod is waiting at Init:0/1. Runbook: argocd/README.md, "scrypted (migrated from Docker
# Compose, 2026-10-01)".
#
# It refuses to continue unless the old container is stopped (two instances would fight over
# the HomeKit identities, and a running one holds scrypted.db open, so the copy wouldn't be
# consistent) and the pod is waiting. The marker that releases the pod is created last. Leaves
# the old directory untouched, which is the rollback.
#
#   restore.sh            do it
#   restore.sh --check    run the checks only, copy nothing
#   restore.sh --wait     as above, but first wait (up to 10 minutes) for compose-deploy to
#                         remove the old container and for the pod to be waiting
set -euo pipefail

OLD="${OLD:-$HOME/docker/scrypted}"
NS="${NS:-scrypted}"
KUBECTL="${KUBECTL:-kubectl}"
SUDO="${SUDO-sudo}"
CHECK_ONLY=false
WAIT=false
case "${1:-}" in
  --check) CHECK_ONLY=true ;;
  --wait) WAIT=true ;;
  "") ;;
  *) echo "usage: $0 [--check|--wait]" >&2; exit 2 ;;
esac

die() { echo "ABORT: $*" >&2; exit 1; }

old_running() { [ -z "${SKIP_DOCKER_CHECK:-}" ] && docker ps --format '{{.Names}}' | grep -qx scrypted; }
pod_waiting() {
  [ -n "$($KUBECTL -n "$NS" get pod -l app.kubernetes.io/name=scrypted \
    -o jsonpath='{.items[0].status.initContainerStatuses[0].state.running.startedAt}' 2>/dev/null || true)" ]
}

if $WAIT; then
  for _ in $(seq 120); do
    if ! old_running && pod_waiting; then break; fi
    sleep 5
  done
fi

if old_running; then
  die "the Compose scrypted container is still running. Wait for compose-deploy to remove it (it runs every 5 minutes), or use --wait."
fi

$SUDO test -f "$OLD/scrypted.db/CURRENT" || die "no $OLD/scrypted.db/CURRENT"
$SUDO test -d "$OLD/plugins" || die "no $OLD/plugins"

pod_waiting || die "no scrypted pod with a running restore init container in namespace $NS (expected Init:0/1)."
$KUBECTL -n "$NS" exec deploy/scrypted -c restore -- test ! -e /server/volume/.restored \
  || die "/server/volume/.restored already exists. The PVC was already restored. Not touching it."

if $CHECK_ONLY; then
  echo "checks passed; nothing copied (--check)"
  exit 0
fi

echo "copying /server/volume..."
$SUDO tar -C "$OLD" -cf - . \
  | $KUBECTL -n "$NS" exec -i deploy/scrypted -c restore -- tar -C /server/volume -xof -

$KUBECTL -n "$NS" exec deploy/scrypted -c restore -- touch /server/volume/.restored
echo "done: marker created, the pod will start. Watch: $KUBECTL -n $NS logs -f deploy/scrypted"
