# FUTURE

Things we can't act on yet because they're waiting on something outside our control — an upstream release, a
stability/time window, or a precondition that hasn't happened. Check back here periodically; once an item's dependency
clears, move it into the active backlog as regular actionable work.

## HexOS B2 backup bucket deletion

**Waiting on:** enough elapsed time to trust the new non-redundant (striped, no AnyRaid) HexOS pool before deleting the
B2 safety copy of the restored P3 Plus data. The restore itself is done and `rclone check`-verified (0 differences,
318821 files) as of 2026-09-20 — this is pure insurance against early pool failure, not active work. **Consider the pool
stable, and the bucket safe to delete, on or after 2026-10-20** (one month from the verified restore), assuming no
issues surface before then.

## SigNoz ClickHouse volume: confirm it plateaus

**Waiting on:** the 30-day TTL starting to expire the oldest SigNoz metrics and ClickHouse system-log data. Everything in that
volume dates from SigNoz's install on 2026-09-22, so nothing has expired yet and the volume has been growing a steady 0.58 GiB/day
(17.5 of 29.4 GiB used on 2026-10-19). The straight-line "full in about 21 days" ignores the TTLs; the expectation is a plateau
near 19 GiB (about 65%), up to 22 GiB if ClickHouse needs merge headroom. SigNoz logs, on a 15-day TTL, already flattened.
**Check on or after 2026-10-25.** If it's still climbing by about 0.5 GiB/day then, the model is wrong and the volume does need
retention changes or a bigger volume (see the ClickHouse item in [`READY.md`](READY.md)).

Usage on the volume itself:

```bash
kubectl -n signoz exec chi-signoz-clickhouse-cluster-0-0-0 -c clickhouse -- df -h /var/lib/clickhouse
```

And whether expiry is really dropping the old metrics. The oldest daily partition should now be around 30 days old, not
2026-09-22:

```bash
kubectl -n signoz exec chi-signoz-clickhouse-cluster-0-0-0 -c clickhouse -- clickhouse-client -q \
  "SELECT min(partition) FROM system.parts WHERE active AND database='signoz_metrics' AND table='samples_v4'"
```

If both look right, delete this item and the ClickHouse volume bullet in `READY.md`.

## Authelia RBAC group/role mapping

**Waiting on:** a second real Authelia user. Right now anyone who authenticates gets whatever ArgoCD's default policy
grants, which is fine with a single user — but worth building real group/role mapping (`argocd-rbac-cm`) before that
stops being true. No target date — this depends on a new user showing up, not on elapsed time.

## ArgoCD automated sync for its own chart

**Waiting on:** a few ArgoCD upgrades going cleanly through the manual sync (adopted 2026-10-18; see "Upgrading ArgoCD
itself" in [`../argocd/README.md`](../argocd/README.md#upgrading-argocd-itself)). Then consider `syncPolicy.automated` on
[`../argocd/apps/argocd/application.yaml`](../argocd/apps/argocd/application.yaml) so a merged Renovate bump is the whole
deploy. The case for it is a smaller blast radius than Cilium's (a broken Argo stops deploys, it doesn't take the network
down); the case against is that auto-sync keeps re-applying a bad version to a controller that can't revert it. Cilium stays
manual either way. Also rehearse the `helm install` recovery path first (noted in the README as untested since adoption).

## Alertmanager label-based routing

**Waiting on:** enough real alert volume/noise to know what routing is actually worth building. Only `severity` maps to
ntfy priority/tags today ([
`../manifests/ntfy-alertmanager/configmap.yaml`](../manifests/ntfy-alertmanager/configmap.yaml)); per-namespace topics
or similar are premature until there's a track record to design against. **Consider there to be enough of a track record
to design against on or after 2026-10-20** (one month from Alertmanager going live), assuming no issues surface before
then.

## SigNoz alerting -> ntfy-alertmanager direct integration

**Waiting on:** enough time actually using SigNoz to know whether it's staying. SigNoz's own alert rules (evaluated
against its ClickHouse-backed data, not Prometheus) can notify a generic Webhook channel, and that webhook's payload
shape turned out to be the same "Alertmanager outbound notification" format `ntfy-alertmanager`
([`../manifests/ntfy-alertmanager/`](../manifests/ntfy-alertmanager/)) already parses (built to consume real
Alertmanager's webhook) — meaning SigNoz-native alerts could plausibly point straight at it, skipping Alertmanager
entirely for that path, reusing the existing ntfy pipeline. Not verified live; found via docs comparison, not a real
test POST. Deliberately not investigated further yet — see
[`../argocd/README.md`](../argocd/README.md#signoz-decided-and-deployed-2026-09-22) for the SigNoz deployment itself.
**Revisit on or after 2026-10-22** (one month from SigNoz going live), once there's a real opinion on whether SigNoz is
worth keeping — no point building integration plumbing for a tool that might get replaced.

## Linode workload migration
**Waiting on:** the Mac Studio being online and all home workloads being moved. 

I have a Kubernetes cluster running in Linode (LKE). It runs my personal website and some apps I built. It's massive
overkill and costs way too much money. When all of the home workloads have been moved and the Mac Studio is online, 
there will be enough resources in-house to move almost all of that off the cloud. My intention is to serve the static 
content from their smallest static instance (used to be called a Nanode, $5/month) and serve APIs from the house. This 
is not normally something I'd recommend, but I have like four users and no uptime guarantees, so I feel good about it.
That $85/month saved will go a long way toward paying for the Mac Studio!

Also, this setup is constantly emailing me about high CPU usage and container restarts. I have not had time to 
investigate, but my plan is to eliminate most of it anyway. Every time I check the website itself, it seems fine. 

## InfluxDB 2.x pin → 3.x

**Waiting on:** NetworkOptimizer no longer depending on Flux
([Ozark-Connect/NetworkOptimizer](https://github.com/Ozark-Connect/NetworkOptimizer)). Its InfluxDB
([`../manifests/network-optimizer/influxdb-deployment.yaml`](../manifests/network-optimizer/influxdb-deployment.yaml))
is held below 3.0 by an `allowedVersions: "<3"` rule in [`../renovate.json`](../renovate.json), because every query the
app makes is Flux (all in `MonitoringInfluxClient.cs`), and InfluxDB 3 dropped Flux for SQL and InfluxQL. When upstream
moves to SQL or InfluxQL, remove that rule and plan the 2.x → 3.x data migration; 3.x doesn't read 2.x's storage
directly.

## Trim over-sized memory requests

**Waiting on:** a clean month of usage history. **Revisit on or after 2026-10-25.** The 2026-09-24 audit set memory
requests just above each workload's 7-day *peak*; p95 is the usual basis. Biggest overshoots, summed across
replicas/nodes: cilium-agent (~1.8GiB over p95), otel-agent (~1.5GiB; 384Mi on every node, sized for mbp, while the
Pis use ~65Mi), kube-apiserver (~0.9GiB; 1536Mi each on three control planes), cilium-envoy (~0.6GiB). Together
about 2-3GiB of requested memory. Waiting because Cilium and every pod on mbp restarted on 2026-09-24, so the recent
history understates their steady state. Re-run the same Prometheus comparison (per-container 7d/30d p95 and max vs
`kube_pod_container_resource_requests`) and size to about p95. The apiserver lives in
[`../talos/patches/control-plane/control-plane-resources.yaml`](../talos/patches/control-plane/control-plane-resources.yaml)
(needs a `talosctl patch` per control plane); the rest are Helm values in `argocd/apps/` and `talos/cilium/values.yaml`
(Cilium needs a manual ArgoCD sync).

## Memory requests for SigNoz's ClickHouse operator

**Waiting on:** the upstream `signoz` Helm chart exposing resources for its bundled clickhouse-operator. As of chart
0.143.0 there's no values key for the `operator` and `metrics-exporter` containers of `signoz-clickhouse-operator`, so
they're the only long-running containers in the cluster without memory requests (~100Mi together). Not worth a
post-render patch for that little. When Renovate bumps the chart, check `helm show values signoz/signoz` under
`clickhouse.clickhouseOperator` for a `resources` key, and set requests from real usage if it's there.

## democratic-csi on TrueNAS's JSON-RPC API (hold HexOS/TrueNAS below 26.x)

**Waiting on:** a democratic-csi release that talks to TrueNAS over the JSON-RPC 2.0 WebSocket API
([democratic-csi/democratic-csi#509](https://github.com/democratic-csi/democratic-csi/issues/509)). Both drivers
(`freenas-api-iscsi` and `freenas-api-nfs`, v1.9.5) use the REST API, which TrueNAS 26.04 removes. Until then,
**don't let HexOS move TrueNAS past 25.10**: every `hexos-iscsi` and NFS volume would stop provisioning, attaching and
resizing. TrueNAS's "deprecated REST API was used" alert comes from democratic-csi. As of 2026-09-29, TrueNAS's
audit log showed its API key as the only REST caller (`midclt call audit.query` as `jake`, filtering on
`service_data.protocol == LEGACY_REST`). The IP in the alert is whichever worker runs the controller pods. The
maintainer said on 2026-09-14 that work was starting, and plans to drop REST and require TrueNAS 26.x, so the
driver upgrade and the TrueNAS upgrade will likely have to happen together. If it stalls, alternatives are
[truenas/truenas-csi](https://github.com/truenas/truenas-csi) (official) and
[fenio/tns-csi](https://github.com/fenio/tns-csi). While doing this, also replace the `democratic-csi` API key. It
belongs to `truenas_admin`, so it has full admin rights; give it a dedicated user with only the roles the driver
needs. The key goes into
[`../manifests/external-secrets-config/democratic-csi.yaml`](../manifests/external-secrets-config/democratic-csi.yaml)
and `democratic-csi-nfs.yaml` from 1Password.

## Revisit the parked domains

**Waiting on:** the next renewal cycle. The 15 domains moved to Cloudflare on 2026-09-26 are parked (no web records,
"sends no mail" records, [`../terraform/cloudflare/parked.tf`](../terraform/cloudflare/parked.tf)) and will auto-renew
at Cloudflare. **Revisit on or after 2027-11-01**, before the earliest renewal (`modyourcamaro.com`, around 2027-12-05
now that the transfer added a year). For each one, decide: keep holding it, actually build the thing, or let it lapse
(turn off auto-renew in the Cloudflare dashboard and remove it from `parked.tf`). What each one was for is in
[`DONE.md`](DONE.md#domains-hover---cloudflare).
`yourwebsiteisterrible.com` is the one with a live idea: a blog about terrible web UX and how to fix it, maybe with a
sister site `yourappisterrible.com` (not registered yet) for mobile apps.

## Jump box OS: Debian 12 (bookworm) -> 13 (trixie)

**Waiting on:** bookworm LTS getting closer to its end (mid-2028), or a reason to move sooner. rpi5-1 runs Raspberry
Pi OS on bookworm, which is now `oldstable`. That's fine for now: unattended-upgrades applies Debian security fixes, and
bookworm LTS keeps publishing them until mid-2028 (see [`../docs/rpi5-1-os-updates.md`](../docs/rpi5-1-os-updates.md)).
The 2026-10-06 jump box swap moved the existing SSD onto the new 4GB Pi, so bookworm carried over unchanged. Decide
between a fresh trixie image plus restoring the jump-box tooling (Raspberry Pi's supported path, and a chance to confirm
the setup is reproducible from this repo), or staying on bookworm until closer to LTS end. No target date.

## Close the Hover account

**Waiting on:** the two dropped domains lapsing at Hover (auto-renew is off): `commaspacebitch.com` on 2026-12-18 and
`soleman.ski` on 2027-09-23. Everything else has moved to Cloudflare (see [`DONE.md`](DONE.md#domains-hover---cloudflare)).
**Close it on or after 2027-09-24**, or sooner if leftover domains don't matter. The `jake@jakerobb.dev` forward still
listed there is unused (mail goes through Cloudflare now) and can just be deleted.

## Mac Studio on the Temperatures dashboard

**Waiting on:** the Mac Studio arriving (expected November). Setting it up with
[`../docs/mac-host-metrics.md`](../docs/mac-host-metrics.md) gets it onto SigNoz's Temperatures dashboard
([`../terraform/signoz/dashboard-temperatures.tf`](../terraform/signoz/dashboard-temperatures.tf)) with no dashboard
changes: the Mac panels group by `host.name`. The likely snag is temperatures. `collect-smc.sh` reads them from
`powermetrics --samplers smc`, which was only verified on the Intel MacBook Pro, and Apple Silicon may not report die
temperatures that way (step 5 of the runbook already warns about this). If it prints nothing there, pick another source
for Apple Silicon's temperature sensors, and keep the metric name `smc_temperature_value` with `sensor=cpu_die` /
`gpu_die` so the dashboard picks it up.

## ESO 1Password wedged-client fix

**Waiting on:** an upstream fix for [external-secrets/external-secrets#6941](https://github.com/external-secrets/external-secrets/issues/6941)
(the `onepasswordSDK` provider never recreates its cached client after a transient network error wedges the WASM
instance, so every ExternalSecret fails with `wasm error: out of bounds memory access` until the pod restarts), which
in turn depends on the SDK bug 1Password/onepassword-sdk-go#288. It hit us on 2026-09-30 after a DNS blip. Renovate will
eventually bump the chart, but won't flag that the fix is in it, so check the issue's status. Once it's closed and the
running ESO version contains the fix, remove `manifests/eso-restarter/` (and its Application, and its entry in
`manifests/ntfy/networkpolicy.yaml` and `docs-site/mkdocs.yml`) and the `wasm error` text from the
`ExternalSecretNotSynced` alert in `manifests/external-secrets-config/prometheusrule.yaml`. No target date; this depends
on upstream, not elapsed time.

## Follow up on the 1Password SDK stack-leak reports

**Waiting on:** maintainer feedback, from either repo. No target date. We found the root cause of the ESO wedge above
(2026-10-06) and reported it twice:
[1Password/onepassword-sdk-go#288](https://github.com/1Password/onepassword-sdk-go/issues/288) (a comment with a repro
and the cause, plus a follow-up pointing at go-sdk) and
[extism/go-sdk#102](https://github.com/extism/go-sdk/issues/102) (the root fix). In short: when a request fails inside
Extism go-sdk's `http_request` host function (a network error, or a context deadline or cancellation), it calls
`panic(err)`, and the guest's wasm stack pointer is never restored. Each failure leaks ~51KiB of the core's 1MiB shadow
stack, so after 20 failures every call on that process-wide instance fails with `wasm error: out of bounds memory
access`, permanently. Not a heap leak: guest memory, Go heap and RSS stay flat, and our own ESO's memory stayed flat
through an 8-hour wedge. The `dyegoe` memory growth reported in #288 is unexplained. A four-line experiment (return an
empty response with status 0 instead of panicking) fixed it, including the deadline and cancellation path.

When either repo answers:
- **extism/go-sdk#102:** if the maintainers pick a direction, write the PR with a regression test. Surface the real
  error to the guest (the experiment discards it), and check what other PDKs do with a status-0 response. go-sdk's last
  commit and release were spring 2025, so don't expect a quick merge.
- **onepassword-sdk-go#288:** if they'd take it, propose treating a wasm trap as fatal for the instance (rebuild the
  plugin and re-init live clients from their saved configs). The `runtime.SetFinalizer` release of a client ID needs a
  generation counter, or a finalizer firing after a rebuild would release another client's ID. Weaker case now that the
  panic fix also covers deadlines; it's belt and braces for traps we haven't seen.
- **Either lands in a release:** then do what the ESO item above says (confirm the running ESO version has it, then
  remove `manifests/eso-restarter/` and the alert text), and delete this item.
- **Meanwhile:** `manifests/eso-restarter/` restarts ESO automatically on the wedge signature, and the daily check in
  [`WATCHING.md`](WATCHING.md) tells us when it fires. After the first real wedge, review how the detection and notices behaved and
  note the outcome in [`DONE.md`](DONE.md).
- **Nothing by 2026-12-01:** revisit forking go-sdk and the 1Password SDK. Weigh it against the restart job covering it.

## Drop the kubeconform external-secrets.io schema pin

**Waiting on:** the community CRD catalog fixing `external-secrets.io/clustersecretstore_v1.json`. Its 2026-10-08 update
([datreeio/CRDs-catalog#988](https://github.com/datreeio/CRDs-catalog/pull/988)) made kubeconform fail with "could not find
schema for ClusterSecretStore", so [`../.github/workflows/lint.yml`](../.github/workflows/lint.yml) pins that group to the
previous commit (`f3e4382`). The cause is tracked upstream in
[datreeio/CRDs-catalog#991](https://github.com/datreeio/CRDs-catalog/issues/991): ESO added a field named `properties`
under `spec.provider.crd.whitelist.rules[]`, and the catalog's converter wrongly adds a stray `additionalProperties: false`
entry inside that field map, which kubeconform can't load. The converter fix is
[datreeio/CRDs-catalog#964](https://github.com/datreeio/CRDs-catalog/pull/964) (open since 2026-08-31, awaiting review);
the catalog's schemas also need regenerating after it merges. Check now and then (start with whether #964 has merged) by
running kubeconform against `manifests/external-secrets-config/clustersecretstore.yaml` with only the `main` catalog
location; once it validates, remove the pinned `-schema-location` line and its comment. No target date: this depends on
upstream.

## Watch the HexOS iSCSI target logs after the memory bump

**Waiting on:** a week of normal use after the HexOS VM went from 8GB to 10GB (applied and restarted 2026-10-08). This is
**not** clean: the failures came back in small bursts on 2026-10-11 (13 at 13:00 EDT, 2 at 19:00), and an unexplained
94-second iSCSI outage hit all four workers at 2026-10-08 17:15 (see [`WATCHING.md`](WATCHING.md)). Then, at 23:26 to
23:28 EDT on 2026-10-11, about 10,400 allocation failures in three minutes stalled the SigNoz ClickHouse volume for 180s;
ext4 aborted its journal and remounted it read-only, and SigNoz stored nothing from about 23:25 to 07:05 EDT until the
pod was deleted on 2026-10-12. So the review on or after 2026-10-19 should not retire this item unless there has been a
clean week since the last failure, and it should decide on a fix (shrinking `max_sectors_kb` or raising the SCST limits)
rather than just keep watching.
The Prometheus volume stalls of 2026-09-29, 10-05 and 10-07 were SCST (the iSCSI target) failing to allocate 8 MiB command
buffers: `Allocation of sgv_pool_obj failed (size 8388608)` in `/var/log/scst.log`, answered BUSY/QUEUE FULL, until the
worker's write timed out after 180s. **Check on or after 2026-10-19:**
- `ssh truenas-ops 'sudo /usr/bin/cat /var/log/scst.log' | grep -c 'Allocation of sgv_pool_obj failed'` (plus
  `scst.log.1`; the older `.gz` files need `zcat` entries in `claude-ops`'s sudo list). Before the bump there were bursts of
  thousands a minute on most days.
- No "Kernel storage error" ntfy alert from SigNoz, and no Prometheus restart with `persist head block ... input/output error`.
- No `detected conn error` lines in the workers' `talosctl dmesg` (the 2026-10-08 17:15 outage left nothing in the NAS's log).
- `MemTotal` on the NAS is about 10GB, and `/proc/meminfo` shows how much is free and in slab.

**Rolled out to all four workers (2026-10-16 ~08:11 EDT); trial began 2026-10-12 ~08:08 EDT on `talos-worker-mbp`.** The initiators' `max_sectors_kb` is capped at 1024, via [`../talos/patches/iscsi-max-sectors.yaml`](../talos/patches/iscsi-max-sectors.yaml)
(a `UdevRulesConfig` document, applied with `--mode=no-reboot`; Talos re-triggered udev live). The target advertises an
optimal transfer length of 8 MiB, which is why every `TrueNAS` disk sat at `max_sectors_kb=8192`; the session's
negotiated `MaxBurstLength` is only 1 MiB. Workers 1, 2 and 3 got it live on 2026-10-16 (`--mode=no-reboot`), after the 2026-10-13 13:15 EDT burst (~8,300 failures) gave worker-1 `Buffer I/O error`s on `sdc` while the capped mbp logged nothing. The `worker.yaml` template on rpi5-1 has the document
(appended 2026-10-12, backup `worker.yaml.bak-20261012`), so a rebuilt node gets it by default. What to look at:
- **First 48 hours:** no regression in ClickHouse or scrypted-backup throughput or in write latency on the mbp
  (`node_disk_io_time_seconds_total`).
- **Persistence:** after the next iSCSI reconnect or reboot of the mbp, confirm its iSCSI disks come back at 1024
  (`talosctl -n 192.168.102.34 read /sys/block/sdb/queue/max_sectors_kb`, and the other TrueNAS disks).
- **A burst:** the verdict. If SCST logs a burst (hundreds of allocation failures a minute or more) and the mbp's
  `talosctl dmesg` shows no `timing out command` or ext4 errors, the trial passed. Compare against the other workers:
  SCST's failures are global to the target, so one node's change shouldn't lower the NAS-side count much; judge it by
  the node's own volumes.
- **Stalls despite 1024:** the trial failed; fall back to raising the SCST limits.
- **7 to 14 days with no burst:** inconclusive, so roll it out to all four workers anyway (low risk, easy to revert)
  (the template already has it).
  If the trial fails, remove the document from the template too.

**If the failures continue after a rollout:** raise `scst_max_cmd_mem` / `scst_max_dev_cmd_mem`. They are auto-scaled
to 25% of the NAS's RAM (and the per-device limit to 40% of that), so they are **2486 and 994 MB** at 10GB, not the
1985 and 794 of the 8GB VM. They are read-only module parameters (`/sys/module/scst/parameters/`), so changing them
means setting a module option and reloading SCST or rebooting the NAS, and a hand-edited modprobe file may not survive
a TrueNAS update. The Proxmox host has about 1GB left, so another RAM increase means shrinking a worker first. Another
possible lever is lowering the optimal transfer length at the target, so every initiator gets it for free; unchecked
whether TrueNAS exposes that. If it's quiet, delete this item and the SCST notes can stay in `DONE.md`.
