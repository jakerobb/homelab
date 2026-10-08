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

## Cilium `upgradeCompatibility` flag removal

**Waiting on:** the Cilium 1.20 line (1.20.1 upgraded 2026-09-15, patch- bumped to the currently-running **1.20.2** on
2026-09-16) running stable for a meaningful stretch before removing the `upgradeCompatibility: "1.19"` key from
`talos/cilium/values.yaml` and syncing. That key currently keeps `envoy-xds-mode` on its legacy-safe default instead of
1.20+'s new `"ads"` default — a low-risk, one-key change once the wait's over. See [
`../talos/README.md`](../talos/README.md#cilium-version-management). **Consider 1.20.x stable, and the flag safe
to remove, on or after 2026-10-15** (one month from the 1.20.1 upgrade — the 1.20.2 patch bump the next day doesn't
reset this clock), assuming no issues surface before then.

## Authelia RBAC group/role mapping

**Waiting on:** a second real Authelia user. Right now anyone who authenticates gets whatever ArgoCD's default policy
grants, which is fine with a single user — but worth building real group/role mapping (`argocd-rbac-cm`) before that
stops being true. No target date — this depends on a new user showing up, not on elapsed time.

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

## Delete the old change-detection datastore on rpi5-1

**Waiting on:** the in-cluster change-detection behaving for a stretch, since `~/docker/change-detection/` on rpi5-1 is the
rollback (revert the migration PR and restore the Compose services). **Consider it safe to delete on or after 2026-10-12**
(one week after the 2026-10-05 cutover). Then, on rpi5-1, `sudo rm -rf ~/docker/change-detection` (partly root-owned). It
holds the old snapshot history (including the dropped UniFi store watches), the app's API key, and a
stale notification URL carrying a Home Assistant access token; revoke that token in Home Assistant too if it still exists.
Make sure the in-cluster copy is the one you want to keep first (and that a nightly backup has landed in the
`change-detection-backups` PVC). Runbook: [`../argocd/README.md`](../argocd/README.md#change-detection-migrated-from-docker-compose-2026-10-05), step 4.

## Drop the matter-server and zwave-js-ui-ws LoadBalancer VIPs

**Waiting on:** Home Assistant behaving on the in-cluster addresses for a couple of days. It was repointed on 2026-10-08
(MQTT to `mosquitto.mosquitto.svc.cluster.local:1883`, Z-Wave JS to `ws://zwave-js-ui-ws.zwave-js-ui.svc.cluster.local:3000`,
Matter to `ws://matter-server.matter-server.svc.cluster.local:5580/ws`), and Matter, Z-Wave and Zigbee devices all checked
out. **Consider it safe on or after 2026-10-10.** Then change `manifests/matter-server/service.yaml` and
`manifests/zwave-js-ui/service-ws.yaml` to `type: ClusterIP`, removing the `lbipam.cilium.io/ips` (`192.168.102.133` and
`.132`) and `external-dns` annotations, and check that external-dns drops the `matter` and `zwave-ws` records. The comments
at the top of both files describe the VIPs, so update them too, plus the matching notes in `argocd/README.md`. Rollback
is the saved `.storage/core.config_entries.pre-matter-svc` on the `homeassistant-config` volume, or reverting the Service
edits. Keep the MQTT VIP (`192.168.102.131`) unless you've confirmed nothing on the LAN uses `mqtt.jakerobb.org`.


## Drop the kubeconform external-secrets.io schema pin

**Waiting on:** the community CRD catalog fixing `external-secrets.io/clustersecretstore_v1.json`. Its 2026-10-08 update
([datreeio/CRDs-catalog#988](https://github.com/datreeio/CRDs-catalog/pull/988)) made kubeconform fail with "could not find
schema for ClusterSecretStore", so [`../.github/workflows/lint.yml`](../.github/workflows/lint.yml) pins that group to the
previous commit (`f3e4382`). Check now and then by running kubeconform against
`manifests/external-secrets-config/clustersecretstore.yaml` with only the `main` catalog location; once it validates,
remove the pinned `-schema-location` line and its comment. No target date: this depends on upstream.

## Watch the HexOS iSCSI target logs after the memory bump

**Waiting on:** a week of normal use after the HexOS VM went from 8GB to 10GB (applied and restarted 2026-10-08). The
Prometheus volume stalls of 2026-09-29, 10-05 and 10-07 were SCST (the iSCSI target) failing to allocate 8 MiB command
buffers: `Allocation of sgv_pool_obj failed (size 8388608)` in `/var/log/scst.log`, answered BUSY/QUEUE FULL, until the
worker's write timed out after 180s. **Check on or after 2026-10-15:**
- `ssh truenas-ops 'sudo /usr/bin/cat /var/log/scst.log' | grep -c 'Allocation of sgv_pool_obj failed'` (plus
  `scst.log.1`; the older `.gz` files need `zcat` entries in `claude-ops`'s sudo list). Before the bump there were bursts of
  thousands a minute on most days.
- No "Kernel storage error" ntfy alert from SigNoz, and no Prometheus restart with `persist head block ... input/output error`.
- `MemTotal` on the NAS is about 10GB, and `/proc/meminfo` shows how much is free and in slab.

If the failures continue: shrink the initiators' maximum write size (Talos nodes' `max_sectors_kb`, from 8 MiB down to about
1 MiB, matching the negotiated `MaxBurstLength`; it needs a persistent udev or machine-config setting and some research), or
raise `scst_max_cmd_mem` / `scst_max_dev_cmd_mem` (currently 1985 and 794 MB). The Proxmox host has about 1GB left after
this bump, so another RAM increase means shrinking a worker first. If it's quiet, delete this item and the SCST notes can
stay in `DONE.md`.
