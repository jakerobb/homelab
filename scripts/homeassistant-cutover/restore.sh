#!/usr/bin/env bash
# One-time cutover helper: copies Home Assistant's /config from the old Compose install on rpi5-1
# into the cluster's PVC. Run on rpi5-1 AFTER the migration PR is merged, once the new pod is
# waiting at Init:0/1. Runbook: argocd/README.md, "homeassistant (migrated from Docker Compose,
# 2026-10-01)".
#
# It refuses to continue unless the old container is stopped (two instances would fight over the
# HomeKit ports, and a running one holds the SQLite database open, so the copy wouldn't be
# consistent) and the pod is waiting. The marker that releases the pod is created last. Leaves
# the old directory untouched, which is the rollback.
#
# Not copied: `core` (a 590Mi crash dump), logs, the lock file, deps/ tts/ .cache/ (re-created
# on start). The recorder database IS copied, together with its -wal/-shm files, which is why
# the container must be down.
#
# .storage/http is patched in transit: Envoy now reaches Home Assistant from a pod address
# (10.244.0.0/16), not a node address, and Home Assistant answers 400 to X-Forwarded-For from
# a proxy it doesn't trust.
#
#   restore.sh            do it
#   restore.sh --check    run the checks only, copy nothing
#   restore.sh --wait     as above, but first wait (up to 10 minutes) for compose-deploy to
#                         remove the old container and for the pod to be waiting
set -euo pipefail

OLD="${OLD:-$HOME/docker/homeassistant}"
NS="${NS:-homeassistant}"
KUBECTL="${KUBECTL:-kubectl}"
SUDO="${SUDO-sudo}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CHECK_ONLY=false
WAIT=false
case "${1:-}" in
  --check) CHECK_ONLY=true ;;
  --wait) WAIT=true ;;
  "") ;;
  *) echo "usage: $0 [--check|--wait]" >&2; exit 2 ;;
esac

die() { echo "ABORT: $*" >&2; exit 1; }

old_running() { [ -z "${SKIP_DOCKER_CHECK:-}" ] && docker ps --format '{{.Names}}' | grep -qx homeassistant; }
pod_waiting() {
  [ -n "$($KUBECTL -n "$NS" get pod -l app.kubernetes.io/name=homeassistant \
    -o jsonpath='{.items[0].status.initContainerStatuses[0].state.running.startedAt}' 2>/dev/null || true)" ]
}

if $WAIT; then
  for _ in $(seq 120); do
    if ! old_running && pod_waiting; then break; fi
    sleep 5
  done
fi

if old_running; then
  die "the Compose homeassistant container is still running. Wait for compose-deploy to remove it (it runs every 5 minutes), or use --wait."
fi

$SUDO test -f "$OLD/configuration.yaml" || die "no $OLD/configuration.yaml"
$SUDO test -f "$OLD/home-assistant_v2.db" || die "no $OLD/home-assistant_v2.db"
$SUDO test -f "$OLD/.storage/core.config_entries" || die "no $OLD/.storage/core.config_entries"
$SUDO test -f "$OLD/.storage/http" || die "no $OLD/.storage/http"

pod_waiting || die "no homeassistant pod with a running restore init container in namespace $NS (expected Init:0/1)."
$KUBECTL -n "$NS" exec deploy/homeassistant -c restore -- test ! -e /config/.restored \
  || die "/config/.restored already exists. The PVC was already restored. Not touching it."

# Make sure the .storage/http patch will work before copying anything.
$SUDO cat "$OLD/.storage/http" | POD_CIDR="$POD_CIDR" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
d["data"]["stable"]["trusted_proxies"]
print("http: trusted_proxies present; will add", os.environ["POD_CIDR"])
' || die ".storage/http isn't in the expected shape."

if $CHECK_ONLY; then
  echo "checks passed; nothing copied (--check)"
  exit 0
fi

echo "copying /config (this includes the ~225Mi database)..."
$SUDO tar -C "$OLD" \
  --exclude=./core --exclude='./home-assistant.log*' --exclude=./.ha_run.lock \
  --exclude=./deps --exclude=./tts --exclude=./.cache \
  -cf - . \
  | $KUBECTL -n "$NS" exec -i deploy/homeassistant -c restore -- tar -C /config -xof -

echo "patching .storage/http (trusted_proxies += $POD_CIDR)..."
$SUDO cat "$OLD/.storage/http" | POD_CIDR="$POD_CIDR" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
tp = d["data"]["stable"]["trusted_proxies"]
if os.environ["POD_CIDR"] not in tp:
    tp.append(os.environ["POD_CIDR"])
json.dump(d, sys.stdout, indent=2)
' | $KUBECTL -n "$NS" exec -i deploy/homeassistant -c restore -- sh -c 'cat > /config/.storage/http'

$KUBECTL -n "$NS" exec deploy/homeassistant -c restore -- touch /config/.restored
echo "done: marker created, the pod will start. Watch: $KUBECTL -n $NS logs -f deploy/homeassistant"
