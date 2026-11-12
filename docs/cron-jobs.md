# rpi5-1 cron jobs

Every cron job on rpi5-1 is one file under [`../scripts/rpi5-cron/`](../scripts/rpi5-cron/), named `homelab-<job>`, installed
to `/etc/cron.d/` by [`install.sh`](../scripts/rpi5-cron/install.sh). The old per-user crontab is retired (the installer saves
a copy as `~/crontab.backup-<timestamp>` and removes it).

| File | Schedule | What |
|---|---|---|
| `homelab-compose-deploy` | every 5 min | [Compose auto-deploy](compose-deploy.md) |
| `homelab-etcd-snapshot-backup` | 03:15 | [etcd snapshot + B2 upload](etcd-backup.md) |
| `homelab-unifi-gc-report-daily` / `-hourly` | 07:00 / hourly | [UniFi GC report](unifi-gc-report.md) |
| `homelab-msmtpq-flush` | every 15 min | retry queued mail ([email alerts](email-alerts.md)) |
| `homelab-unattended-upgrades-check-rpi5-1` / `-proxmox` | 09:00 / 09:05 | [OS update checks](rpi5-1-os-updates.md) |
| `homelab-docker-image-prune` | 05:00 | removes images unused for a week |

## Changing a job

1. Edit or add the file in `scripts/rpi5-cron/` and merge it.
2. The compose-deploy cron compares each installed file with the repo and sends an ntfy alert naming the installer if one
   differs or is missing. On rpi5-1: `cd ~/dev/homelab && ./scripts/rpi5-cron/install.sh`. The alert clears itself.
3. Removing a file from the repo and re-running the installer removes it from `/etc/cron.d/`.

cron.d is picky: the files must be root-owned and mode 0644, and the file name can only contain letters, digits, `_` and `-`
(a dot, as in `foo.sh`, makes cron silently ignore it). There's a user column after the schedule, and `MAILTO` and `PATH` are
set per file. Jobs mail their stderr to `MAILTO` through the msmtpq relay ([email alerts](email-alerts.md)), so keep stdout
redirected to `/dev/null` for jobs that are quiet on success.

## Heartbeats

Two jobs ping Healthchecks.io, so that a job that silently stops alerts from outside: compose-deploy (below) and the
[etcd backup](etcd-backup.md#heartbeat).

## Is compose-deploy itself running?

If the compose-deploy cron stopped (cron broken, host down, the script crashing on startup), nothing would alert, since it
is also what raises the other alerts. So each completed run pings a [Healthchecks.io](https://healthchecks.io) check, and a
crash pings its `/fail` URL. The check's period is 5 minutes with a 15-minute grace period, and it emails when pings stop.

The ping URL is a secret, kept in `scripts/secrets/healthchecks-compose-deploy.sops.yaml` (template:
`healthchecks-compose-deploy.example.yaml`, one `url:` key). The script decrypts it each run. Without the file there is no
heartbeat, and nothing else changes. A paused deploy (dirty checkout) still pings: that's alerted on ntfy, and the heartbeat
only means the job ran.
