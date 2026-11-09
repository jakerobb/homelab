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

`ssh truenas-ops 'sudo midclt call cloudsync.query'` shows the task and its last run state. Add `| jq '.[].job.state'` to see only the state.

## Failure alert (Healthchecks.io)

The task's post-script pings a [Healthchecks.io](https://healthchecks.io) check, the same service that watches
Alertmanager (see "Watchdog" in [`../argocd/README.md`](../argocd/README.md)). TrueNAS runs a Cloud Sync post-script only
after rclone exits 0 (`middlewared/plugins/cloud_sync.py` raises before it on any failure), so the ping means "last run
succeeded". That makes it a dead-man's switch, which catches both kinds of failure:

- a run that fails (bad credential, B2 outage, full bucket): no ping;
- a run that never happens (task disabled, TrueNAS down, the NAS can't reach the internet): no ping.

Setup (manual, needs your Healthchecks.io login and TrueNAS UI):

1. In Healthchecks.io, add a check named `NAS Cloud Sync to B2`: period 1 day, grace time 4 hours (the task starts at
   05:30 and takes minutes, so a ping is due by about 06:00). Description for the alert email:

    > NAS Cloud Sync to B2 did not report success. The TrueNAS task "NAS app backups to B2" (daily, 05:30) pings this
    > check only when it finishes without error, so either the last run failed or it didn't run. Check the task's last
    > run in the TrueNAS UI (Data Protection, Cloud Sync Tasks), or from the jump box:
    > `ssh truenas-ops 'sudo midclt call cloudsync.query' | jq '.[].job'`.
    > See docs/nas-offsite-backup.md.

2. Put the ping URL in 1Password (`homelab-k8s` vault, item `healthchecks-nas-cloudsync`, field `url`). It's a secret in
   the same sense as the Watchdog's: anyone holding it can send a false "alive". Nothing in the cluster reads this one;
   the item is just the record.
3. In TrueNAS, edit the Cloud Sync task and set **Post-script** to:

    ```bash
    curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/<uuid>"
    ```

    A failed `curl` fails the job's post-script step, so the task shows as failed in the UI too, but the data has
    already been copied by then.
4. Use **Run Now** once and confirm the check turns green in Healthchecks.io.
5. Test the alarm by temporarily changing the post-script's URL to one ending in `/fail`, running the task, and
   confirming the email arrives. Then put the right URL back.

What this doesn't cover: a sync that succeeds but copies nothing useful (for example, the CronJobs stopped writing
backups, so there is nothing new to copy). The per-app backup CronJobs have their own alerts for that. A B2-side
"newest object is under 36 hours old" check would also catch it; it's optional and not built.

The TrueNAS credential is named `Backblaze B2` but is an Amazon S3 credential on B2's endpoint; the key lives in the
`b2-nas-backups` item in the `homelab-k8s` vault.
