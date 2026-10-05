#!/usr/bin/env bash
# One-time cutover helper: copies changedetection.io's datastore from the old Compose install
# on rpi5-1 into the cluster's PVC. Run on rpi5-1 AFTER the migration PR is merged, once the
# new pod is waiting at Init:0/1. Runbook: argocd/README.md, "change-detection (migrated from
# Docker Compose, 2026-10-05)".
#
# What it copies: changedetection.json (settings: UI password, API key, notification URL),
# secret.txt, and the directory of every watch that is NOT a store.ui.com page, with its snapshot
# history and screenshots. The UniFi store watches are left behind on purpose (restock-radar
# replaced them). Also left behind: url-watches*.json, a legacy file changedetection.io would
# re-import watches from, and the old before-update-*.tar.gz and changedetection-*.json backups.
# The notification URL is repointed from https://ntfy.jakerobb.org to the in-cluster ntfy
# Service, which is where the pod's network policy allows it to go.
#
# It refuses to continue unless the old container is stopped (it rewrites its own files, so a
# live copy wouldn't be consistent, and two instances would both fetch every page) and the pod
# is waiting. The marker that releases the pod is created last. Leaves the old directory
# untouched, which is the rollback.
#
#   restore.sh            do it
#   restore.sh --check    run the checks only, copy nothing
#   restore.sh --wait     as above, but first wait (up to 10 minutes) for compose-deploy to
#                         remove the old container and for the pod to be waiting
set -euo pipefail

OLD="${OLD:-$HOME/docker/change-detection}"
NS="${NS:-change-detection}"
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

old_running() { [ -z "${SKIP_DOCKER_CHECK:-}" ] && docker ps --format '{{.Names}}' | grep -qx change-detection; }
pod_waiting() {
  [ -n "$($KUBECTL -n "$NS" get pod -l app.kubernetes.io/name=change-detection \
    -o jsonpath='{.items[0].status.initContainerStatuses[0].state.running.startedAt}' 2>/dev/null || true)" ]
}

if $WAIT; then
  for _ in $(seq 120); do
    if ! old_running && pod_waiting; then break; fi
    sleep 5
  done
fi

if old_running; then
  die "the Compose change-detection container is still running. Wait for compose-deploy to remove it (it runs every 5 minutes), or use --wait."
fi

$SUDO test -f "$OLD/changedetection.json" || die "no $OLD/changedetection.json"
$SUDO test -f "$OLD/secret.txt" || die "no $OLD/secret.txt"

pod_waiting || die "no change-detection pod with a running restore init container in namespace $NS (expected Init:0/1)."
$KUBECTL -n "$NS" exec deploy/change-detection -c restore -- test ! -e /datastore/.restored \
  || die "/datastore/.restored already exists. The PVC was already restored. Not touching it."

# The watches to bring over: every directory whose watch.json isn't a store.ui.com page.
KEEP=$($SUDO python3 - "$OLD" <<'PY'
import glob, json, os, sys
old = sys.argv[1]
for f in sorted(glob.glob(os.path.join(old, "*", "watch.json"))):
    url = json.load(open(f)).get("url", "")
    if "store.ui.com" not in url:
        print(os.path.basename(os.path.dirname(f)), url, file=sys.stderr)
        print(os.path.basename(os.path.dirname(f)))
PY
)
[ -n "$KEEP" ] || die "found no watches to copy"
mapfile -t KEEP_DIRS <<<"$KEEP"
echo "watches to copy: ${#KEEP_DIRS[@]} (expected 3: the changedetection.io changelog, ui.com whats-new, smarthomeshop.io UltimateSensor)"

if $CHECK_ONLY; then
  echo "checks passed; nothing copied (--check)"
  exit 0
fi

STAGE=$(mktemp -d)
trap '$SUDO rm -rf "$STAGE"' EXIT
$SUDO tar -C "$OLD" -cf - changedetection.json secret.txt "${KEEP_DIRS[@]}" | $SUDO tar -C "$STAGE" -xf -

# Repoint the global notification URL at the in-cluster ntfy (http, port 8080). The ntfy
# Service has no auth, like restock-radar's use of it.
$SUDO python3 - "$STAGE/changedetection.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
app = d["settings"]["application"]
app["notification_urls"] = [
    u.replace("ntfy://ntfy.jakerobb.org/", "ntfy://ntfy.ntfy.svc:8080/")
    for u in app.get("notification_urls", [])
]
json.dump(d, open(p, "w"), indent=4)
PY

echo "copying /datastore..."
$SUDO tar -C "$STAGE" -cf - . \
  | $KUBECTL -n "$NS" exec -i deploy/change-detection -c restore -- tar -C /datastore -xof -

$KUBECTL -n "$NS" exec deploy/change-detection -c restore -- touch /datastore/.restored
echo "done: marker created, the pod will start. Watch: $KUBECTL -n $NS logs -f deploy/change-detection"
