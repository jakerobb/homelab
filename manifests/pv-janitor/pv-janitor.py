#!/usr/bin/env python3
"""Deletes PersistentVolumes left Released for too long, with notice first.

Every StorageClass here uses reclaimPolicy: Retain, so deleting a PVC (or an
ArgoCD prune doing it by accident) leaves the PV and its backing storage
behind: a zvol on HexOS for hexos-iscsi/hexos-nfs, a directory on the node for
local-path. That's the safety net. This job turns it into a time window: once
a PV has been Released for GRACE_DAYS, it switches the PV to
reclaimPolicy: Delete, and the provisioner that created it deletes the backing
storage and then the PV object. Deleting the PV object directly would free
nothing, since the provisioner only cleans up Released PVs whose policy is
Delete.

Rules, per run (daily):
- A PV annotated homelab.jakerobb.org/pv-janitor-keep=true is never touched.
- Released for GRACE_DAYS - WARN_DAYS: send a warning to ntfy and record when
  on the PV (WARNED_ANNOTATION).
- Released for GRACE_DAYS *and* warned at least WARN_DAYS ago, during this
  release: delete. So nothing is ever deleted without a full WARN_DAYS of
  notice, even after missed runs or on first deploy.
- A PV in phase Failed (e.g. its deletion failed) gets one notification.

Stdlib only, talking to the API server with the pod's service account, so the
image is plain python. See manifests/pv-janitor/README.md.
"""
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

GRACE_DAYS = int(os.environ.get("GRACE_DAYS", "30"))
WARN_DAYS = int(os.environ.get("WARN_DAYS", "7"))
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
NTFY_URL = os.environ["NTFY_URL"]

PREFIX = "homelab.jakerobb.org/pv-janitor"
KEEP_ANNOTATION = f"{PREFIX}-keep"
WARNED_ANNOTATION = f"{PREFIX}-warned-at"
FAILED_ANNOTATION = f"{PREFIX}-failed-notified"

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
API = "https://kubernetes.default.svc"
SSL_CTX = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
with open(f"{SA_DIR}/token") as f:
    TOKEN = f.read().strip()

NOW = datetime.now(timezone.utc)


def api(method, path, body=None):
    headers = {"Authorization": f"Bearer {TOKEN}", "Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/merge-patch+json"
    req = urllib.request.Request(f"{API}{path}", data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, context=SSL_CTX, timeout=30) as resp:
        return json.load(resp)


def patch_pv(name, body):
    if DRY_RUN:
        print(f"  [dry run] would patch {name}: {json.dumps(body)}")
        return
    api("PATCH", f"/api/v1/persistentvolumes/{name}", body)


def notify(title, message, priority="default", tags=""):
    if DRY_RUN:
        print(f"  [dry run] would notify: {title}")
        return
    req = urllib.request.Request(
        NTFY_URL,
        data=message.encode(),
        method="POST",
        headers={"Title": title, "Priority": priority, "Tags": tags},
    )
    urllib.request.urlopen(req, timeout=15).close()


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def describe(pv):
    spec = pv["spec"]
    claim = spec.get("claimRef") or {}
    return (
        f"Was claimed by: {claim.get('namespace', '?')}/{claim.get('name', '?')}\n"
        f"StorageClass: {spec.get('storageClassName', '?')}, "
        f"size: {spec.get('capacity', {}).get('storage', '?')}"
    )


def keep_hint(name):
    return f"To keep it: kubectl annotate pv {name} {KEEP_ANNOTATION}=true"


def handle_released(pv):
    name = pv["metadata"]["name"]
    annotations = pv["metadata"].get("annotations") or {}
    released_at = parse_time(pv["status"].get("lastPhaseTransitionTime"))
    if released_at is None:
        # Only possible for PVs that last changed phase before the API server
        # started recording this. Can't age them, so never delete them.
        print(f"{name}: Released, no lastPhaseTransitionTime; skipping")
        return

    age = NOW - released_at
    delete_after = released_at + timedelta(days=GRACE_DAYS)
    warned_at = parse_time(annotations.get(WARNED_ANNOTATION))
    # A warning only counts for the current release: if the PV was re-bound
    # and released again since, lastPhaseTransitionTime is newer than it.
    if warned_at and warned_at < released_at:
        warned_at = None
    warned = f"warned {warned_at:%Y-%m-%d %H:%M} UTC" if warned_at else "not warned"
    print(f"{name}: Released {age.days}d ago ({released_at:%Y-%m-%d}), {warned}")

    if warned_at is None:
        if age >= timedelta(days=GRACE_DAYS - WARN_DAYS):
            when = max(delete_after, NOW + timedelta(days=WARN_DAYS))
            notify(
                f"PV {name} will be deleted on or after {when:%Y-%m-%d}",
                f"It has been unclaimed (Released) since {released_at:%Y-%m-%d}.\n"
                f"{describe(pv)}\n"
                f"Its backing storage will be deleted too.\n{keep_hint(name)}",
                priority="default",
                tags="wastebasket,warning",
            )
            patch_pv(name, {"metadata": {"annotations": {WARNED_ANNOTATION: NOW.strftime("%Y-%m-%dT%H:%M:%SZ")}}})
            print("  -> warned")
        return

    if age >= timedelta(days=GRACE_DAYS) and NOW - warned_at >= timedelta(days=WARN_DAYS):
        patch_pv(name, {"spec": {"persistentVolumeReclaimPolicy": "Delete"}})
        notify(
            f"Deleting PV {name}",
            f"Unclaimed since {released_at:%Y-%m-%d}; warned {warned_at:%Y-%m-%d}.\n"
            f"{describe(pv)}\n"
            f"Switched to reclaimPolicy: Delete; its provisioner now deletes the "
            f"backing storage and the PV.",
            priority="low",
            tags="wastebasket",
        )
        print("  -> reclaimPolicy set to Delete")


def handle_failed(pv):
    name = pv["metadata"]["name"]
    annotations = pv["metadata"].get("annotations") or {}
    print(f"{name}: Failed ({pv['status'].get('message', 'no message')})")
    if FAILED_ANNOTATION in annotations:
        return
    notify(
        f"PV {name} is in phase Failed",
        f"{pv['status'].get('message', 'No message.')}\n{describe(pv)}\n"
        f"Usually its provisioner couldn't delete the backing storage. Check its "
        f"logs and delete the storage and PV by hand.",
        priority="high",
        tags="warning",
    )
    patch_pv(name, {"metadata": {"annotations": {FAILED_ANNOTATION: NOW.strftime("%Y-%m-%dT%H:%M:%SZ")}}})


def main():
    print(f"pv-janitor: grace {GRACE_DAYS}d, warn {WARN_DAYS}d ahead{', DRY RUN' if DRY_RUN else ''}")
    pvs = api("GET", "/api/v1/persistentvolumes")["items"]
    for pv in sorted(pvs, key=lambda p: p["metadata"]["name"]):
        annotations = pv["metadata"].get("annotations") or {}
        phase = pv.get("status", {}).get("phase")
        if annotations.get(KEEP_ANNOTATION) == "true":
            if phase in ("Released", "Failed"):
                print(f"{pv['metadata']['name']}: {phase}, kept by annotation")
            continue
        if phase == "Released":
            handle_released(pv)
        elif phase == "Failed":
            handle_failed(pv)
    print("done")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} from {e.url}: {e.read().decode(errors='replace')}", file=sys.stderr)
        sys.exit(1)
