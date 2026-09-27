# pv-janitor

A daily CronJob that deletes PersistentVolumes left unclaimed for 30 days,
after warning about each one 7 days ahead through ntfy (`homelab-alerts`).
Added 2026-09-27.

## Why

Every StorageClass here (`hexos-iscsi`, `hexos-nfs`, `local-path`) uses
`reclaimPolicy: Retain`, on purpose: an accidental ArgoCD prune that deletes
a PVC leaves the data behind instead of destroying it. The cost is that
nothing ever cleans up PVs whose PVC was deleted deliberately. They sit in
phase `Released`, and so does their backing storage: a zvol on HexOS, or a
directory on a node. This job turns the safety net into a 30-day window.

## What it does

Each run (04:45 America/Detroit), for every PV:

- **Annotated `homelab.jakerobb.org/pv-janitor-keep=true`:** skipped, always.
- **Released for 23+ days, not yet warned:** sends a warning to ntfy with the
  date it'll be deleted and the command to keep it, and records the time on
  the PV (`homelab.jakerobb.org/pv-janitor-warned-at`).
- **Released for 30+ days and warned at least 7 days ago:** switches the PV to
  `reclaimPolicy: Delete` and sends a notice. The provisioner that created it
  (democratic-csi or local-path-provisioner) then deletes the backing storage
  and the PV object. The job itself never deletes a PV; its RBAC is only
  get/list/patch on PVs.
- **Phase `Failed`** (usually a delete the provisioner couldn't finish): one
  high-priority notification, then it's left for a human.

A warning only counts for the current release. If a PV is re-bound and
released again, its release time resets, and it gets a fresh warning. Nothing
is deleted without a full 7 days' notice, even after missed runs or on first
deploy. A failed run fires kube-prometheus-stack's `KubeJobFailed` alert.

`GRACE_DAYS`, `WARN_DAYS` and `DRY_RUN` are env vars in
[`cronjob.yaml`](cronjob.yaml).

## Keeping a PV

On rpi5-1:

```bash
kubectl annotate pv <pv-name> homelab.jakerobb.org/pv-janitor-keep=true
```

## Getting the data back before it's deleted

A Released PV can be bound to a new PVC. Clear its old claim, then create a
PVC with `volumeName: <pv-name>` and the same StorageClass, access mode and
size:

```bash
kubectl patch pv <pv-name> --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'
```

Once it's Bound, the job ignores it. If it's released again later, the
30 days start over.

## Tested (2026-09-27)

Before writing the job, the mechanism was checked by hand on both
provisioners: a Released test PV switched to `Delete` had its PV, its zvol on
HexOS, and its local-path directory on the node all gone within about 10
seconds. Then the job itself: a dry run against the real PVs (the three
orphans at the time, released 4 and 11 days earlier, correctly left alone),
and a full warn-then-delete cycle with `GRACE_DAYS=0`/`WARN_DAYS=0` on a
throwaway volume. The real orphans were annotated `keep` during that test,
and the annotation was removed afterwards.

At deploy time there were three orphans: an old 200Mi Authelia volume on
worker-1's local disk (released 2026-09-15), and two test volumes on HexOS,
`mbp-iscsi-test` (1Gi) and `hexos-iscsi-fio-bench` (5Gi), released
2026-09-22. They get warnings around 2026-10-08 and 2026-10-15, and are
deleted a week after that unless kept.
