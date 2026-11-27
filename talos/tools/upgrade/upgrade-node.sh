#!/bin/bash
# Upgrade one Talos node and verify the result. Run on the jump box.
# Usage: upgrade-node.sh <node-name> <node-ip> <installer-image> <target-version> [--no-drain] [-- <extra talosctl upgrade args>]
#   e.g. upgrade-node.sh talos-worker-studio 192.168.102.36 factory.talos.dev/installer/<schematic>:v1.14.7 v1.14.7 -- --reboot-mode powercycle
#
# Steps: ESP size preflight, drain, upgrade, then wait until the node reports the target version, has a fresh boot and
# is Ready. Prints ALLDONE only if all of that is true; any failure prints a line ending in FAILED and exits non-zero.
# Run nodes one at a time and stop on the first non-zero exit. Never loop over nodes ignoring failures.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 4 ] || { sed -n '2,8p' "$0" >&2; exit 64; }
NAME=$1 IP=$2 IMAGE=$3 TARGET=$4; shift 4
DRAIN=yes
[ "${1:-}" = "--no-drain" ] && { DRAIN=no; shift; }
[ "${1:-}" = "--" ] && shift
EXTRA=("$@")
fail() { echo "$1: FAILED"; exit 1; }

"$HERE/check-esp.sh" "$IP" || fail "PREFLIGHT"
if [ "$DRAIN" = yes ]; then
  kubectl drain "$NAME" --ignore-daemonsets --delete-emptydir-data --timeout=300s || fail "DRAIN"
fi
BEFORE=$(talosctl -n "$IP" read /proc/uptime 2>/dev/null | awk '{print int($1)}')
talosctl -n "$IP" upgrade --image "$IMAGE" --wait --timeout 15m "${EXTRA[@]}" || fail "UPGRADE"

# talosctl returning is not proof the node came back: re-check everything independently.
for _ in $(seq 1 60); do   # up to 10 minutes
  TAG=$(talosctl -n "$IP" version 2>/dev/null | awk '/Tag:/ {t=$2} END {print t}')
  UP=$(talosctl -n "$IP" read /proc/uptime 2>/dev/null | awk '{print int($1)}')
  READY=$(kubectl get node "$NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [ "$TAG" = "$TARGET" ] && [ -n "$UP" ] && [ "$READY" = True ] && break
  sleep 10
done
[ "$TAG" = "$TARGET" ]  || fail "VERIFY version is '${TAG:-unreachable}', wanted $TARGET"
[ -n "$UP" ] && [ -n "$BEFORE" ] && [ "$UP" -lt "$BEFORE" ] || fail "VERIFY no fresh boot (uptime ${UP:-?}s, before ${BEFORE:-?}s)"
[ "$READY" = True ]     || fail "VERIFY node not Ready"
talosctl -n "$IP" get extensions | grep -E "iscsi|util-linux" || fail "VERIFY storage extensions missing"
kubectl get node "$NAME" --no-headers
echo ALLDONE
