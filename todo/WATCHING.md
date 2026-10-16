# WATCHING

Things we fixed or changed that should stay quiet, with a check that shows whether they're staying quiet. Unlike
[`FUTURE.md`](FUTURE.md) (waiting on something to happen), these are waiting for something *not* to happen again. The
daily upgrade checker ([`../skills/upgrade-checker/instructions.md`](../skills/upgrade-checker/instructions.md)) runs every
check below on every run, so each entry has to be something it can do on its own: a command, a clear healthy result, and a
clear "this is trouble" result. When an entry has stayed healthy long enough, or the thing it watches is gone, move it to
[`DONE.md`](DONE.md) or delete it.

Entry format: a `## ` heading, then **Why**, **Check**, **Healthy**, **Trouble** and **Retire when**.

## HexOS iSCSI target out of command memory (SCST allocation failures)

**Why:** the Prometheus volume stalls of 2026-09-29, 10-05 and 10-07 were the iSCSI target (SCST) on the HexOS VM failing to
allocate 8 MiB command buffers. It answered BUSY/QUEUE FULL, and the worker's write timed out after 180s and failed with
EIO. Before the VM went from 8GB to 10GB RAM (restarted 2026-10-08 13:17 EDT) there were bursts of thousands of failures
a minute on most days. After the bump the failures stopped for about three days, then came back in small bursts: 13 at
2026-10-11 13:00 EDT and 2 at 19:00 (both odd UTC hours, which fits Prometheus's two-hourly head compaction, but that is
a guess). There was no initiator-visible impact. Separately, at 2026-10-08 17:15:36 EDT every iSCSI connection on all
four workers logged `detected conn error (1020)` at once and stayed down for about 94 seconds; Prometheus failed
its liveness probe and restarted, and SigNoz's ClickHouse restarted too. The NAS's SCST log has no lines at all for that
window, and the cause is unknown. The follow-up in [`FUTURE.md`](FUTURE.md) ("Watch the HexOS iSCSI target logs after the
memory bump") is the planned review; this entry is the daily tripwire.
On 2026-10-11 at 23:26 EDT a burst of about 10,400 failures stalled the SigNoz ClickHouse volume, which went
read-only and silently dropped eight hours of telemetry. Two alerts were added for that case in
`argocd/apps/kube-prometheus-stack/application.yaml`: `ISCSIVolumeWritesStopped` and `ContainerOOMKilledRepeatedly`.
If either fires, treat it as this entry being in trouble.

**Check:** two parts. First, count the allocation failures in the NAS's SCST log, from the last 24 hours only. `scst.log`
is rotated around 23:00, so read both files and filter on the timestamp prefix (`Mon  D HH:MM:SS`, local time EDT/EST):
```bash
ssh truenas-ops 'sudo /usr/bin/cat /var/log/scst.log.1; sudo /usr/bin/cat /var/log/scst.log' \
  | grep 'Allocation of sgv_pool_obj failed' | awk '{print $1, $2, substr($3,1,5)}' | sort | uniq -c
```
Count only the lines dated within the last 24 hours **and after the 2026-10-08 13:17 EDT restart** (the failures logged
earlier that day, including 2,046 at 09:00, predate the bump), and group by minute to see bursts. Also read the NAS's
memory and uptime (a reboot resets the log's story):
```bash
ssh truenas-ops 'grep -E "MemTotal|MemFree|MemAvailable|SUnreclaim" /proc/meminfo; grep -E "^(size|c_max) " /proc/spl/kstat/zfs/arcstats; uptime'
```
Second, look for iSCSI connection drops on the initiators, which the target's log can miss (2026-10-08 17:15). Timestamps
are UTC:
```bash
ssh jakerobb@rpi5-1.lan 'for ip in 31 32 35 34; do echo "== .$ip"; talosctl -n 192.168.102.$ip dmesg | grep "detected conn error" | awk "{print substr(\$4,2,13)}" | sort | uniq -c | tail -5; done'
```
(`.31` and `.32` are workers 1 and 2, `.35` is worker-3, `.34` is the MacBook Pro worker.) Count only the entries in the
last 24 hours. A node that was rebooted in that window logs some at boot; check `talosctl -n <ip> read /proc/uptime`
before calling those trouble.

**Healthy:** zero allocation failures in the last 24 hours, and zero `detected conn error` lines on any worker. `MemTotal`
about 10GB. Don't judge `MemAvailable` against a fixed number: ZFS's ARC (about 5.5GB of a 9.3GB `c_max`) isn't counted
in it, so it reads 1 to 1.5GB when things are fine. Report `MemFree`, `SUnreclaim` and ARC `size` for context, and flag
a clear fall in `MemFree` (below roughly 200MB) or growth in `SUnreclaim` (over about 2GB) versus the previous run.

**Trouble:** any allocation failure, or any `detected conn error` outside a node's boot. Report the count, the minutes it
happened, and whether a "Kernel storage error" ntfy alert or a Prometheus restart (`kubectl -n monitoring get pod
prometheus-... `, restart count) lines up with it. A burst of hundreds in a minute means a stall happened or nearly did.
Connection errors on several workers in the same second mean the target or the path to it went away, whatever its log
says. Next steps if it keeps coming back: shrink the initiators' maximum write size (see the FUTURE.md item), or raise
`scst_max_cmd_mem` and `scst_max_dev_cmd_mem` (2486 and 994 MB at 10GB of RAM; they scale to 25% of RAM, and
need a module reload to change). The `max_sectors_kb` cap of 1024 is on all four workers (mbp since 2026-10-12, the rest since 2026-10-16); see FUTURE.md.

**Retire when:** the FUTURE.md review on or after 2026-10-19 finds a clean week and Jake agrees; then delete this entry along
with that one. A clean day or two doesn't count, since the failures came back after three quiet days.

## ESO 1Password wedged client (eso-restarter)

**Why:** the `onepasswordSDK` provider can wedge after a transient network error, and every ExternalSecret then fails with
`wasm error: out of bounds memory access` until the ESO pod restarts (it hit on 2026-09-30). The cause is upstream, tracked
in [`FUTURE.md`](FUTURE.md) ("ESO 1Password wedged-client fix"). Until it's fixed, `manifests/eso-restarter/` restarts ESO
automatically when it sees the signature (added 2026-10-07). It hasn't fired for real yet, so the first real wedge is also
the first test of its detection and its "ESO is back" ntfy update.

**Check:**
```bash
ssh jakerobb@rpi5-1.lan 'kubectl -n eso-restarter logs "$(kubectl -n eso-restarter get pods --sort-by=.metadata.creationTimestamp -o name | tail -1)"; kubectl get externalsecret,clustersecretstore -A --no-headers | grep -v True; kubectl -n external-secrets get pods --no-headers'
```
The log's last line says whether any wedge events were seen since the current ESO pod started. Also compare the
`external-secrets` pod's age and restarts against the previous run: a pod younger than a day, or a restart count that went
up, means ESO was restarted (by the restarter, a rollout or a node move).

**Healthy:** the log says "none (no wedge events since the current pod started)", every ExternalSecret and the
ClusterSecretStore are Ready (the `grep -v True` prints nothing), and the ESO pods have no unexplained restarts.

**Trouble:** a wedge event in the log, or any ExternalSecret not Ready. Report when it happened, whether ESO recovered on its
own, and what the ntfy messages said (the restarter posts a "restarting" notice and an "ESO is back" update to
`homelab-alerts`). Then do the review the FUTURE.md item asks for: did the detection and the notices behave, and record the
outcome in [`DONE.md`](DONE.md). If the restarter itself failed (its Jobs show `Failed`), that is worse than the wedge.

**Retire when:** the upstream fix is in the running ESO version and `manifests/eso-restarter/` is removed (the FUTURE.md
item says how).

## UniFi Network app GC thrash on the CGFiber (47Net.lan)

**Why:** on 2026-09-18 the UniFi Network app became unresponsive from a JVM garbage-collection spiral. The fix is a locked
heap (`-Xms == -Xmx = 640M` in `/etc/default/unifi` on the gateway). Both that file and the report's SSH key live on the
gateway's overlay and survive normal reboots and app upgrades, but a full **UniFi OS** upgrade wipes them, after which the
heap silently reverts. rpi5-1 runs the report from cron (daily digest 07:00, hourly threshold check). See
[`../docs/unifi-gc-report.md`](../docs/unifi-gc-report.md) for the background and the reapply steps.

**Check:** read the report's own log on rpi5-1, which gets a line for every hourly run:
```bash
ssh jakerobb@rpi5-1.lan 'stat -c %y ~/.unifi-gc-report.log; tail -n 30 ~/.unifi-gc-report.log'
```
Lines start with `Skipped: <rate> Full GCs/hr <= threshold 150/hr` (healthy hour) or `Sent: UniFi GC report: <rate> Full GCs/hr,
heap <Xms>/<Xmx>` (the daily digest, or a tripped hour).

**Healthy:** the log was modified within the last two hours. Every `Skipped:` rate in the last 24 lines is under 150. Any
`Sent:` line shows `heap 640M/640M`. Nothing but `Skipped:` and `Sent:` lines. Rates were 45 to 90 per hour on 2026-10-08;
the docs' "healthy" range of 24 to 42 predates that, so judge by the 150 threshold and by change.

**Trouble:**
- A rate of 150 or more, or a `Sent:` line with a heap other than `640M/640M` (the lock is gone: probably a UniFi OS
  upgrade).
- A stale log, or lines that are neither `Skipped:` nor `Sent:` (errors). That usually means the gateway's `authorized_keys`
  line was wiped too, so the report can't reach it.
- A UniFi OS upgrade on the gateway since the last check. If you can see one (for example from the UniFi UI's update
  history), say so, because it means both pieces need reapplying even if the numbers still look fine.

**Retire when:** never, really. This one stays as long as that gateway does, so only retire it if the box is replaced.

## UPS Tower stuck "Adopting" in UniFi

**Why:** the UniFi UPS Tower (shown as "Office UPS" in unpoller, `192.168.0.9`, MAC `1c:0b:8b:3a:6b:ff`) periodically got stuck
in the controller's "Adopting" state, a known UniFi UPS firmware bug. It keeps powering the outlets the whole time; only
management is lost, so nothing visibly breaks. It was fixed on 2026-09-20 by a factory reset, re-adopt and an upgrade to
firmware 1.6.4.432 (an early-access release), and was stable through at least 2026-10-01. Earlier fixes held for weeks
before it recurred, so this one isn't proven. See
[`../docs/troubleshooting.md`](../docs/troubleshooting.md#the-ups-tower-is-stuck-adopting-in-unifi).

**Check:** ask Prometheus about the unpoller series for the device. The service proxy on the API server needs no
port-forward:
```bash
ssh jakerobb@rpi5-1.lan 'for q in "unpoller_device_info%7Bname%3D%22Office%20UPS%22%7D" "increase(unpoller_device_uptime_seconds%7Bname%3D%22Office%20UPS%22%7D%5B1h%5D)" "max(resets(unpoller_device_uptime_seconds%7Bname%3D%22Office%20UPS%22%7D%5B24h%5D))"; do kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$q"; echo; done'
```
These are, in order: the device's info series (its `version` label is the firmware), its uptime growth over the last hour, and
the number of uptime resets (reboots) in the last 24 hours.

**Healthy:** the info series exists with `version` `1.6.4.432` (or newer), the uptime grew by about 3,600 seconds in an
hour, and there were 0 resets.

**Trouble:** the info series is missing, the uptime didn't grow (it stops advancing when the controller loses the device),
any reset in 24 hours, or a changed firmware version. Also look for a `UPS Tower is offline` notice on the
`network-optimizer-alerts` ntfy topic. If it recurs: check the device's state in the UniFi API before assuming a new problem
(`state` 7 with `adopted` true is this bug), and post a follow-up in the 1.6.4 community thread, since Ubiquiti's UI team
is engaging there.

**Retire when:** about three months with no recurrence on 1.6.4 or a newer release.
