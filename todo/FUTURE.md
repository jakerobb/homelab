# FUTURE

Things we can't act on yet because they're waiting on something outside our control — an upstream release, a
stability/time window, or a precondition that hasn't happened. Check back here periodically; once an item's dependency
clears, move it into the active backlog as regular actionable work.

## HexOS B2 backup bucket deletion

**Waiting on:** local *redundant* storage for that data. The HexOS pool (`data`) is a single 4TB SSD (the P3 Plus) with the 2TB T500 as a
separate ZFS log device, so there is no redundancy: the B2 bucket is currently the only second copy of the restored P3
Plus data, and losing that one SSD would otherwise lose it. The restore itself is done and `rclone check`-verified (0 differences, 318821 files) as of 2026-09-20. Elapsed
time doesn't change this: a month of the pool staying healthy (reached 2026-10-20) doesn't make a single-disk pool safe.
**Delete the bucket only once the data also lives on redundant local storage** (for example, the replacement NAS
hardware with a mirrored or RAID-Z layout), and re-run `rclone check` against the new copy first. No target date.

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

## Remove restock-radar's `npm <12` Renovate constraint

**Waiting on:** a fixed npm 12 release. npm 12 defaults `allow-remote` to `none`, and `npm install --package-lock-only`
(what Renovate runs for lockfile updates) wrongly refuses registry tarballs of packages that declare
`bundleDependencies`, such as Tailwind 4's `@tailwindcss/oxide-wasm32-wasi`, with `EALLOWREMOTE`. It's tracked in
[npm/cli#9800](https://github.com/npm/cli/issues/9800); the candidate fixes are
[#9818](https://github.com/npm/cli/pull/9818) and [#9819](https://github.com/npm/cli/pull/9819), both open and
unreviewed as of 2026-10-21. It still reproduced on npm 12.2.1, the latest release then. Until it's fixed,
`restock-radar`'s `renovate.json` caps Renovate's npm at `<12` (`constraints.npm`), with a package rule so Renovate
doesn't open a PR to raise that cap. Real installs and CI are unaffected (they skip the package, and Node 24 ships
npm 11).

**To check:** whether #9800 is closed and which npm release has the fix. Then verify it in a scratch directory:
`echo '{"name":"repro","version":"1.0.0","dependencies":{"@tailwindcss/oxide":"4.3.3"}}' > package.json`, then
`npx -p node@24 -p npm@<fixed version> -- npm install --package-lock-only`. If it succeeds, remove the `constraints`
block and the `renovate-config` package rule from `restock-radar`'s `renovate.json`, and delete this item. No target
date; this depends on upstream.

## Doorbell relay PoE auto-recovery: confirm it stays off

**Waiting on:** time. UniFi's "device auto-recovery" on USW Pro HD 24 PoE Port 18 (the modbus eth relay) re-enabled
itself once already: the relay carries zero traffic except when the doorbell rings, so UniFi reads the silence as a dead
device and power-cycles the port, visible as "power-cycled Port 18" in the UniFi logs about every 35 minutes
(first confirmed 2026-10-08, still happening 2026-10-22). Turned back off by hand on 2026-10-22 at 10:51pm.
**Check on or after 2026-11-01** that the setting is still off, and that the cycling has stopped:

```bash
# On rpi5-1: any "power-cycled Port 18" in the last day? Expect none.
kubectl -n signoz exec chi-signoz-clickhouse-cluster-0-0-0 -c clickhouse -- clickhouse-client -q "select count() from signoz_logs.distributed_logs_v2 where ts_bucket_start >= toUnixTimestamp(now())-86400 and timestamp > (toUnixTimestamp(now())-86400)*1000000000 and body like '%power-cycled Port 18%' settings max_memory_usage=1500000000"
```

If it came back, find what re-enabled it (a UniFi Network update or a re-adoption of the switch are the likely suspects)
and consider an alert on the log line.
