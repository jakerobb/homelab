#!/usr/bin/env bash
# One-time cutover helper: copies matter-server's storage from the old Compose install on rpi5-1
# into the cluster's PVC. Run on rpi5-1 AFTER the migration PR is merged, once compose-deploy
# has removed the old container and the new pod is waiting at Init:0/1.
# Runbook: argocd/README.md, "matter-server (migrated from Docker Compose, 2026-10-01)".
#
# It refuses to continue unless the old container is stopped (two controllers on one fabric
# would both answer devices) and the pod is waiting. The marker that releases the pod is
# created last. Leaves the old data directory untouched, which is the rollback.
#
#   restore.sh            do it
#   restore.sh --check    run the checks only, copy nothing
set -euo pipefail

OLD="${OLD:-$HOME/docker/matter-server/data}"
NS="${NS:-matter-server}"
KUBECTL="${KUBECTL:-kubectl}"
SUDO="${SUDO-sudo}"
CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

die() { echo "ABORT: $*" >&2; exit 1; }

if [ -z "${SKIP_DOCKER_CHECK:-}" ] && docker ps --format '{{.Names}}' | grep -qx matter-server; then
  die "the Compose matter-server container is still running. Wait for compose-deploy to remove it (it runs every 5 minutes)."
fi

$SUDO test -d "$OLD" || die "no $OLD"
$SUDO sh -c "ls '$OLD'/*.json >/dev/null 2>&1" || die "no fabric JSON in $OLD"
$SUDO test -f "$OLD/chip_factory.ini" || die "no $OLD/chip_factory.ini"

state=$($KUBECTL -n "$NS" get pod -l app.kubernetes.io/name=matter-server \
  -o jsonpath='{.items[0].status.initContainerStatuses[0].state.running.startedAt}' 2>/dev/null || true)
[ -n "$state" ] || die "no matter-server pod with a running restore init container in namespace $NS (expected Init:0/1)."
$KUBECTL -n "$NS" exec deploy/matter-server -c restore -- test ! -e /store/.restored \
  || die "/store/.restored already exists. The PVC was already restored. Not touching it."

if $CHECK_ONLY; then
  echo "checks passed; nothing copied (--check)"
  exit 0
fi

echo "copying matter-server storage..."
$SUDO tar -C "$OLD" -cf - . \
  | $KUBECTL -n "$NS" exec -i deploy/matter-server -c restore -- tar -C /store -xof -

$KUBECTL -n "$NS" exec deploy/matter-server -c restore -- touch /store/.restored
echo "done: marker created, the pod will start. Watch: $KUBECTL -n $NS logs -f deploy/matter-server"
