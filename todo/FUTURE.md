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

## Re-enable `KubeMemoryOvercommit` alert notifications

**Waiting on:** the Mac Studio being onboarded as a Talos worker. On 2026-09-25 this alert was routed to Alertmanager's
`null` receiver in
[`../argocd/apps/kube-prometheus-stack/application.yaml`](../argocd/apps/kube-prometheus-stack/application.yaml) (search
for `KubeMemoryOvercommit`). It fires when total memory requests exceed what the cluster could still hand out after
losing its largest node. That's accurate, not a false positive: `talos-worker-mbp` holds ~58% of cluster memory, so no
realistic set of requests passes (see [`DONE.md`](DONE.md#audit-app-memory-requests-against-real-usage)). It fired
daily, with nothing to act on until a second large node exists. Once the Studio is a worker, delete that route and
check the alert in the Prometheus UI: it should be inactive. If it's still firing, revisit requests (see the next item)
before re-enabling notifications.

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

**Waiting on:** the new 4GB Raspberry Pi 5 jump box ([`HARDWARE.md`](HARDWARE.md)). rpi5-1 runs Raspberry Pi OS on
bookworm, which is now `oldstable`. That's fine for now: unattended-upgrades applies Debian security fixes, and
bookworm LTS keeps publishing them until mid-2028 (see [`../docs/rpi5-1-os-updates.md`](../docs/rpi5-1-os-updates.md)).
rpi5-1 itself is being converted to a Talos worker once the Compose workloads are off it, so upgrading it in place
isn't worth the effort. The current plan is to move rpi5-1's SSD into the new Pi, which would carry bookworm over, so
decide then: a fresh trixie image plus restoring the jump-box tooling (Raspberry Pi's supported path, and a chance to
confirm the setup is reproducible from this repo), or keep bookworm until closer to LTS end. No target date.

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

## Add the in-cluster Unbound to the Server VLAN's DHCP

**Waiting on:** time to trust the in-cluster Unbound ([`../argocd/README.md`](../argocd/README.md#unbound-in-cluster-copy-deployed-2026-09-29))
on the Trusted VLAN, where `192.168.102.130` was added to DHCP on 2026-09-30 (alongside the Pi's `.2`). **On or after
2026-10-07**, if nothing has gone wrong there, add `192.168.102.130` as a DNS server on the Server VLAN too, next to
`.2`. Things to check first: no name-resolution problems or firewall gaps seen from the Trusted VLAN's clients (a Mac
and an iPhone), and both replicas Ready on different workers. Don't touch the Talos nodes' resolvers; they're pinned to
`.2` and `1.1.1.1` by [`../talos/patches/nameservers.yaml`](../talos/patches/nameservers.yaml), so they ignore what
DHCP hands out. The IPv6 side is separate; see "Dual-stack cluster" in [`READY.md`](READY.md).

## Prometheus PVC steady-state usage

**Waiting on:** the 10-day retention window to fill. The PVC was expanded from 10Gi to 20Gi on 2026-09-30 after it hit
~85% (8.8 GB) while still growing ~0.4 GB per 12 hours, so its steady-state size is unknown. **Check on or after
2026-10-03**: look at `kubelet_volume_stats_used_bytes` for the `prometheus-...-db` PVC. If growth has flattened well
under 20Gi, nothing to do; if it's still climbing toward the limit, set `retentionSize` (a bit under the PVC size) on
the Prometheus spec in `argocd/apps/kube-prometheus-stack/application.yaml`, and/or cut series cardinality (~240k
series at last count).

## ESO 1Password wedged-client fix

**Waiting on:** an upstream fix for [external-secrets/external-secrets#6941](https://github.com/external-secrets/external-secrets/issues/6941)
(the `onepasswordSDK` provider never recreates its cached client after a transient network error wedges the WASM
instance, so every ExternalSecret fails with `wasm error: out of bounds memory access` until the pod restarts), which
in turn depends on the SDK bug 1Password/onepassword-sdk-go#288. It hit us on 2026-09-30 after a DNS blip. Renovate will
eventually bump the chart, but won't flag that the fix is in it, so check the issue's status. Once it's closed and the
running ESO version contains the fix, remove the `wasm error` restart hint from the `ExternalSecretNotSynced` alert in
`manifests/external-secrets-config/prometheusrule.yaml`. No target date; this depends on upstream, not elapsed time.

## Delete the old Z-Wave JS UI store on rpi5-1

**Waiting on:** a stretch of the in-cluster zwave-js-ui behaving, since `~/docker/zwave-js-ui/` on rpi5-1 is the
rollback (revert the migration PR and restore the Compose service). Cut over 2026-10-01; Home Assistant toggling a
Z-Wave outlet through the new server is confirmed. **Consider it safe to delete on or after 2026-10-08.** Then, on
rpi5-1, `sudo rm -rf ~/docker/zwave-js-ui` (root-owned). Besides the node cache, it still holds the old
`settings.json` with the Z-Wave security keys in plaintext, and `users.json`, so don't leave it around indefinitely.
Runbook: [`../argocd/README.md`](../argocd/README.md#zwave-js-ui-migrated-from-docker-compose-2026-10-01), step 6.

## Delete the old Zigbee2MQTT data on rpi5-1

**Waiting on:** the in-cluster Zigbee2MQTT behaving for a stretch, since `~/docker/zigbee2mqtt/` on rpi5-1 is the rollback
(revert the migration PR and restore the Compose service). **Consider it safe to delete on or after 2026-10-08** (one week after the 2026-10-01 cutover).
Then, on rpi5-1, `sudo rm -rf ~/docker/zigbee2mqtt` (partly root-owned). It holds the device database, the coordinator
backup, and `configuration.yaml` with the Zigbee network key in plaintext, so don't leave it around indefinitely. Make
sure the in-cluster copy is the one you want to keep first: it's now the only live copy of the device names.
Runbook: [`../argocd/README.md`](../argocd/README.md#zigbee2mqtt-migrated-from-docker-compose-2026-10-01), step 5.

## Delete the old matter-server data on rpi5-1

**Waiting on:** the in-cluster matter-server behaving for a stretch, since `~/docker/matter-server/` on rpi5-1 is the
rollback (revert the migration PR and restore the Compose service). **Consider it safe to delete on or after 2026-10-08**
(one week after the 2026-10-01 cutover). Then, on rpi5-1, `sudo rm -rf ~/docker/matter-server` (root-owned). It holds the
Matter fabric and its signing keys, so don't leave it around indefinitely. The in-cluster PVC is now the only live copy.
Also delete `~/docker/homeassistant/.storage/core.config_entries.pre-matter-url`, which still points Home Assistant at
the old `ws://localhost:5580/ws`.
Runbook: [`../argocd/README.md`](../argocd/README.md#matter-server-migrated-from-docker-compose-2026-10-01), step 5.
