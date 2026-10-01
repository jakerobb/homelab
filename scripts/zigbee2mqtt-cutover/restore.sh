#!/usr/bin/env bash
# One-time cutover helper: copies Zigbee2MQTT's data from the old Compose install on rpi5-1
# into the cluster's PVC. Run on rpi5-1 AFTER the migration PR is merged, once compose-deploy
# has removed the old container and the new pod is waiting at Init:0/1.
# Runbook: argocd/README.md, "zigbee2mqtt (migrated from Docker Compose, 2026-10-01)".
#
# Why a script and not a one-liner: this is the step that can orphan every paired Zigbee
# device (a wrong network key, or Zigbee2MQTT starting on an empty data dir, forms a new
# network on the coordinator). So it refuses to continue unless:
#   - the old container is stopped (the coordinator takes one TCP client at a time),
#   - the network key in the cluster Secret is identical to the key in the old config,
#   - and it only creates the marker that releases the pod after everything has copied.
# It never prints the key. It only reports MATCH or MISMATCH.
#
# Leaves the old data directory untouched, which is the rollback.
#
#   restore.sh            do it
#   restore.sh --check    run the checks only, copy nothing
set -euo pipefail

OLD="${OLD:-$HOME/docker/zigbee2mqtt/data}"
NS="${NS:-zigbee2mqtt}"
KUBECTL="${KUBECTL:-kubectl}"
SUDO="${SUDO-sudo}"
MQTT_SERVER="mqtt://mosquitto.mosquitto.svc.cluster.local:1883"
CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

die() { echo "ABORT: $*" >&2; exit 1; }

# The Compose container must be gone, or it still holds the coordinator connection.
if [ -z "${SKIP_DOCKER_CHECK:-}" ] && docker ps --format '{{.Names}}' | grep -qx zigbee2mqtt; then
  die "the Compose zigbee2mqtt container is still running. Wait for compose-deploy to remove it (it runs every 5 minutes)."
fi

$SUDO test -f "$OLD/configuration.yaml" || die "no $OLD/configuration.yaml"
for f in database.db state.json coordinator_backup.json; do
  $SUDO test -f "$OLD/$f" || die "no $OLD/$f"
done

# The pod has to be waiting in the restore init container, or there's nothing to copy into.
state=$($KUBECTL -n "$NS" get pod -l app.kubernetes.io/name=zigbee2mqtt \
  -o jsonpath='{.items[0].status.initContainerStatuses[0].state.running.startedAt}' 2>/dev/null || true)
[ -n "$state" ] || die "no zigbee2mqtt pod with a running restore init container in namespace $NS (expected Init:0/1)."
$KUBECTL -n "$NS" exec deploy/zigbee2mqtt -c restore -- test ! -e /store/.restored \
  || die "/store/.restored already exists. The PVC was already restored. Not touching it."

# Compare the old config's network key with the one the cluster will hand the app.
secret_yaml=$($KUBECTL -n "$NS" get secret zigbee2mqtt-network-key -o jsonpath='{.data.secret\.yaml}' | base64 -d) \
  || die "the zigbee2mqtt-network-key Secret doesn't exist yet. Is the 1Password item in place and the ExternalSecret synced?"
$SUDO cat "$OLD/configuration.yaml" | SECRET_YAML="$secret_yaml" python3 -c '
import os, sys, yaml
old = yaml.safe_load(sys.stdin)["advanced"]["network_key"]
new = yaml.safe_load(os.environ["SECRET_YAML"])["network_key"]
if not (isinstance(old, list) and len(old) == 16):
    sys.exit("ABORT: the old config does not hold a literal 16-number network_key")
if old != new:
    print("network key: MISMATCH (old config vs cluster Secret)")
    sys.exit(1)
print("network key: MATCH")
' || die "fix the 1Password item (zigbee2mqtt-network-key/network_key), force-sync the ExternalSecret, and rerun."

if $CHECK_ONLY; then
  echo "checks passed; nothing copied (--check)"
  exit 0
fi

echo "copying device database, state and coordinator backup..."
$SUDO tar -C "$OLD" -cf - database.db state.json coordinator_backup.json \
  | $KUBECTL -n "$NS" exec -i deploy/zigbee2mqtt -c restore -- tar -C /store -xof -

echo "writing configuration.yaml (network key -> !secret reference, MQTT -> in-cluster broker)..."
$SUDO cat "$OLD/configuration.yaml" | python3 -c '
import sys, yaml
c = yaml.safe_load(sys.stdin)
c["advanced"]["network_key"] = "!secret network_key"
c["mqtt"]["server"] = sys.argv[1]
out = yaml.safe_dump(c, default_flow_style=False, sort_keys=False)
assert "network_key: '"'"'!secret network_key'"'"'" in out, "reference not written"
sys.stdout.write(out)
' "$MQTT_SERVER" \
  | $KUBECTL -n "$NS" exec -i deploy/zigbee2mqtt -c restore -- sh -c 'cat > /store/configuration.yaml'

$KUBECTL -n "$NS" exec deploy/zigbee2mqtt -c restore -- touch /store/.restored
echo "done: marker created, the pod will start. Watch: $KUBECTL -n $NS logs -f deploy/zigbee2mqtt"
