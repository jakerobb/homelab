# WATCHING

Things we fixed or changed that should stay quiet, with a check that shows whether they're staying quiet. Unlike
[`FUTURE.md`](FUTURE.md) (waiting on something to happen), these are waiting for something *not* to happen again. The
daily upgrade checker ([`../skills/upgrade-checker/instructions.md`](../skills/upgrade-checker/instructions.md)) runs every
check below on every run, so each entry has to be something it can do on its own: a command, a clear healthy result, and a
clear "this is trouble" result. When an entry has stayed healthy long enough, or the thing it watches is gone, move it to
[`DONE.md`](DONE.md) or delete it.

Entry format: a `## ` heading, then **Why**, **Check**, **Healthy**, **Trouble** and **Retire when**.

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

**Why:** on 2026-09-18 the UniFi Network app became unresponsive from a JVM garbage-collection spiral. The fix was a locked
heap (`-Xms == -Xmx = 640M` in `/etc/default/unifi` on the gateway), reapplied by hand after the UniFi OS 5.1.34 upgrade on
2026-10-27 wiped it. **UniFi OS 6.0 and Network 11.0 went on around 2026-11-06 and reset the heap to `-Xms128M -Xmx512M`
again. Decision (2026-11-09): don't restore the lock.** The new version promises better memory behavior, and the stock heap gets
a chance to prove it. So `heap 128M/512M` is expected now; don't report it, and don't suggest reapplying the lock unless the rate
below trips. The report's SSH key survived the upgrade. rpi5-1 runs the report from cron (daily digest 07:00, hourly threshold
check). See [`../docs/unifi-gc-report.md`](../docs/unifi-gc-report.md) for the background and the lock's reapply steps.

**Check:** read the report's own log on rpi5-1, which gets a line for every hourly run:
```bash
ssh jakerobb@rpi5-1.lan 'stat -c %y ~/.unifi-gc-report.log; tail -n 30 ~/.unifi-gc-report.log'
```
Lines start with `Skipped: <rate> Full GCs/hr <= threshold 150/hr` (healthy hour) or `Sent: UniFi GC report: <rate> Full GCs/hr,
heap <Xms>/<Xmx>` (the daily digest, or a tripped hour).

**Healthy:** the log was modified within the last two hours. Every `Skipped:` rate in the last 24 lines is under 150. Nothing
but `Skipped:` and `Sent:` lines. Any heap value is fine. Hourly rates were 113 to 130 on 2026-11-09 on the stock heap (45 to 90
with the lock on 2026-10-08), so judge by the 150 threshold and by change.

**Trouble:**
- A rate of 150 or more sustained over several hours (a `Sent: ... ALERT` line), or a clear upward trend toward it. That is the
  point at which to reconsider the lock, and to say so with the rates.
- A stale log, or lines that are neither `Skipped:` nor `Sent:` (errors). That usually means the gateway's `authorized_keys`
  line was wiped too, so the report can't reach it.

**Retire when:** the stock heap has stayed under the threshold for a month or two on UniFi Network 11.0, at which point the
lock can be dropped from the docs for good. Otherwise it stays as long as that gateway does.

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
