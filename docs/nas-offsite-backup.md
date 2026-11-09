# NAS offsite backup (TrueNAS Cloud Sync to B2)

**Status: live since 2026-11-09.** TrueNAS Cloud Sync task `NAS app backups to B2` pushes `/mnt/data/k8s-nfs` to the
`jakerobb-homelab-nas-backups` B2 bucket daily at 05:30. The first run copied 72 files (843.8 MiB), the bucket count matched,
and a restored Home Assistant tarball matched its source byte for byte and listed cleanly with `tar -tzf`. Before this, the NAS had no
replication, snapshot or Cloud Sync tasks, so the app backups shared a pool with the iSCSI primaries.

## What gets copied

The `hexos-nfs` backup volumes, each its own dataset under `data/k8s-nfs`. They total about 820 MB.

| Dataset | PVC | What writes to it |
| --- | --- | --- |
| `data/k8s-nfs/pvc-ff033507-8460-43cb-b848-1294f41654db` | `homeassistant/homeassistant-backups` | `homeassistant-backup` CronJob (config tarballs, 14 days) |
| `data/k8s-nfs/pvc-3f39750a-277b-4118-bd0b-ac89338d3dca` | `scrypted/scrypted-backups` | `scrypted-backup` CronJob |
| `data/k8s-nfs/pvc-c94fd294-0532-48f3-b790-d13d4cb45bae` | `change-detection/change-detection-backups` | `change-detection-backup` CronJob |
| `data/k8s-nfs/pvc-80eed3a0-9172-45ac-bb30-f520cbe90486` | `restock-radar/restock-radar-backups` | restock-radar's own backup |

Dataset names change if a PVC is recreated, so a single task on the parent path `/mnt/data/k8s-nfs` is simpler than
one per dataset, and picks up new `hexos-nfs` volumes. That includes any non-backup volume that lands there later, so
check `zfs list -r data/k8s-nfs` before widening the schedule.

Not covered: the iSCSI zvols (`data/k8s-iscsi`, about 66 GB, block devices that Cloud Sync can't read; Prometheus and
ClickHouse are the big ones and are accepted losses), and `data/shared` (1.5 TB, the restored P3 Plus archive; copying
it is a separate cost decision).

## How it was set up (manual, needs your B2 and TrueNAS logins)

1. **Create a bucket and a key scoped to it**, same pattern as the etcd bucket
   ([`etcd-backup.md`](etcd-backup.md)). Run this somewhere you've done `b2 account authorize`:

    ```bash
    b2 bucket create jakerobb-homelab-nas-backups allPrivate
    b2 key create --bucket jakerobb-homelab-nas-backups jakerobb-homelab-nas-backups-key \
      listAllBucketNames,listBuckets,listFiles,readFiles,writeFiles,deleteFiles
    ```

    `deleteFiles` is needed because a SYNC task removes files the CronJobs have pruned. `listAllBucketNames` is needed
    because TrueNAS lists buckets over the S3 API (to verify the credential and to fill the bucket dropdown), and
    B2 answers a bucket-restricted key's `ListBuckets` with `403 AccessDenied: not entitled` without it. Set the bucket's lifecycle
    rule to "keep only the last version" after 30 days, so a bad sync can still be undone within a month. Put the
    key ID and key in 1Password.
2. **TrueNAS: Credentials, Backup Credentials, Cloud Credentials, Add** an **Amazon S3** credential (not the Backblaze B2
   provider) pointed at B2's S3-compatible endpoint:
    - Access Key ID: the key's `keyId`. Secret Access Key: the key's `key`.
    - Endpoint URL: `https://s3.us-east-005.backblazeb2.com` (the `s3endpoint` that `b2 account authorize` reports).
    - Region: `us-east-005`.

    The native B2 provider doesn't work here: TrueNAS 25.10.7's rclone (v1.70.2) authorizes with B2's v1 API, and
    Backblaze answers that with `400 bad_request: This request is not currently supported on API version number 1` for
    this account's keys (checked 2026-11-09; v4 and the `b2` CLI accept the same key). The S3 endpoint avoids the
    native API. Revisit if a later TrueNAS ships an rclone that uses a newer B2 API.
3. **Data Protection, Cloud Sync Tasks, Add:**
    - Direction `PUSH`, transfer mode `SYNC`, directory `/mnt/data/k8s-nfs`, bucket
      `jakerobb-homelab-nas-backups`, folder `k8s-nfs`.
    - Schedule: daily at 05:30, after the CronJobs finish (they run at 03:17 to 03:27 America/Detroit).
    - Leave the other options at their defaults. Client-side encryption is optional; if you turn it on, store the
      password in 1Password, because without it the data is unrecoverable.
4. **Dry run, then run it once** and compare file counts: `b2 ls --recursive jakerobb-homelab-nas-backups` against
   `find /mnt/data/k8s-nfs -type f | wc -l` on the NAS.
5. **Prove a restore** by downloading one Home Assistant tarball from B2 and checking it with `tar -tzf`.
6. Add the key to the secrets-rotation inventory in [`../todo/READY.md`](../todo/READY.md) (done 2026-11-09).

## Checking it later

`ssh truenas-ops 'sudo midclt call cloudsync.query'` shows the task and its last run state. There's no alert on a
failed Cloud Sync yet (tracked in [`../todo/READY.md`](../todo/READY.md)).

The TrueNAS credential is named `Backblaze B2` but is an Amazon S3 credential on B2's endpoint; the key lives in the
`b2-nas-backups` item in the `homelab-k8s` vault.
