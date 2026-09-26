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

## Talos workload isolation (`SecurityProfileConfig`)

**Waiting on:** a Talos release that actually fixes
[siderolabs/talos#14374](https://github.com/siderolabs/talos/issues/14374) — a
startup race between CRI and `sandboxd` that causes every node to
restart-loop for 1–3 minutes on every boot with `workloadIsolation: true`
enabled. Fixed upstream 2026-09-16, one day after the currently-running
Talos version was published, so we're still on the affected release. See
[`../talos/README.md`](../talos/README.md#workload-isolation-talos-114-feature-not-enabled)
for what this feature would buy us and why it's otherwise appealing. No
target date — check the changelog of each new Talos release for #14374
specifically before assuming it's fixed.

## Authelia RBAC group/role mapping

**Waiting on:** a second real Authelia user. Right now anyone who authenticates gets whatever ArgoCD's default policy
grants, which is fine with a single user — but worth building real group/role mapping (`argocd-rbac-cm`) before that
stops being true. No target date — this depends on a new user showing up, not on elapsed time.

## UPS Tower adoption-bug stability

**Waiting on:** the 2026-09-20 fix (factory reset + re-adopt + upgrade to UniFi UPS firmware 1.6.4.432 RC) proving
durable. The UPS Tower (192.168.0.236) has repeatedly gotten stuck in the UniFi controller's "Adopting" state before —
previous resets looked fully fixed for weeks before recurring, so a clean state alone isn't enough evidence yet.
**Consider it stable on or after 2026-10-01**, assuming no recurrence before then. Todo once stable: post the
accumulated diagnostic write-up (timeline, symptoms, fix) to the UniFi community thread —
<https://community.ui.com/releases/UniFi-UPS-1-6-4/3170942e-7d0e-48b6-81c0-a8bb5d3edd78>
— since Ubiquiti's UI-Team is actively engaging there.

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

## NetworkOptimizer preview pin → back to `:latest`

**Waiting on:** the stable NetworkOptimizer **2.9.0** release
([Ozark-Connect/NetworkOptimizer releases](https://github.com/Ozark-Connect/NetworkOptimizer/releases)). On 2026-09-24
the `optimizer` service was pinned to `ghcr.io/ozark-connect/network-optimizer:2.9.0-preview2` (bumped to `-preview3`
on 2026-09-25) to try out a new feature the developer asked us to test. Watchtower won't move a pinned tag, so the pin
stays until someone changes it. Once 2.9.0 (or later) ships, change the image back to `:latest` in
`docker-compose/docker-compose.yml`. Merging deploys it to rpi5-1 automatically (see
[`../docs/compose-deploy.md`](../docs/compose-deploy.md)).

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

## Migrate `jakerobb.dev` from Hover to Cloudflare

**Waiting on:** the 15 domains transferred on 2026-09-26 all landing at Cloudflare Registrar without issue. `jakerobb.dev`
was held back on purpose because it's the one that matters. Same process as the others (runbook in
[`../terraform/cloudflare/README.md`](../terraform/cloudflare/README.md#moving-a-domain-from-hover)), plus:

- **Real records to carry over** into their own file in `terraform/cloudflare/` (not `parked.tf`): the Linode hosts
  (`@`, `beta`, `*`, `ci`, `job`, `db`, A and AAAA) and the `_acme-challenge.postgres` CNAME to `jakerobb.org`.
  Re-check Hover's DNS tab first, since the site runs on Linode and records may have changed (see "Linode workload
  migration" above). Drop the leftover SendGrid records (`23632814`, `em4126`, `em7338`, `s1`/`s2._domainkey`,
  `url3118`, `url7304`) and the broken `null _domainkey` entry.
- **Email forwarding:** Hover forwards `jake@jakerobb.dev` to Gmail, and that stops working when the nameservers move.
  Replace it with Cloudflare Email Routing (Terraform: `cloudflare_email_routing_settings`, `_address`, `_rule`, plus
  the MX/SPF records routing asks for). The token needs two more permissions for this: Zone · Email Routing Rules ·
  Edit and Account · Email Routing Addresses · Edit. The destination address needs a one-time verification click in
  Gmail. Set it up before switching nameservers so mail doesn't bounce in between. Fix the SPF record at the same time;
  it's currently malformed (`v=spf1\010v=spf1 include:_spf.google.com ~all.`), probably meant to allow sending as this
  address through Gmail.
- **Order at Hover:** change the nameservers first, then unlock it. Changing nameservers re-locked the other domains.
- **Afterwards:** turn off auto-renew on the Hover email forward (it renews separately, next on 2029-03-03), then close
  the Hover account once nothing's left in it.

## Revisit the parked domains

**Waiting on:** the next renewal cycle. The 15 domains moved to Cloudflare on 2026-09-26 are parked (no web records,
"sends no mail" records, [`../terraform/cloudflare/parked.tf`](../terraform/cloudflare/parked.tf)) and will auto-renew
at Cloudflare. **Revisit on or after 2027-11-01**, before the earliest renewal (`modyourcamaro.com`, around 2027-12-05
now that the transfer added a year). For each one, decide: keep holding it, actually build the thing, or let it lapse
(turn off auto-renew in the Cloudflare dashboard and remove it from `parked.tf`). What each one was for is in the
Hover-to-Cloudflare migration entry ([`READY.md`](READY.md) until it's done, [`DONE.md`](DONE.md) after).
`yourwebsiteisterrible.com` is the one with a live idea: a blog about terrible web UX and how to fix it, maybe with a
sister site `yourappisterrible.com` (not registered yet) for mobile apps.
