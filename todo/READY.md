# READY

Cluster-readiness backlog — each of these is its own effort, meant to be tackled separately rather than all at once.
This list is in roughly priority order.

## Dual-stack cluster (IPv4 + IPv6)

The cluster is IPv4-only: pods (`10.244.0.0/16`), Services and the Cilium LB pool (`192.168.102.128/26`) have no
IPv6, and the nodes have no IPv6 addresses. That was fine until the in-cluster Unbound
([`../argocd/README.md`](../argocd/README.md#unbound-in-cluster-copy-deployed-2026-09-29)) needed an IPv6 address to
hand out. Its VIP is IPv4 only (`192.168.102.130`), so for now DHCPv6/RA on the Server and Trusted VLANs should keep
advertising only the jump box's `fd3d:b17d:9f8e:102::2` as an IPv6 resolver.

Dual-stack is a project of its own, not a side effect of Unbound: it touches every workload and needs a maintenance
window. Rough steps:

- Add an IPv6 pod CIDR and service CIDR (from the `fd3d:b17d:9f8e::/48` ULA space) to the control-plane config, and
  enable IPv6 in Cilium (`talos/cilium/values.yaml`). Cilium's pod CIDR allocation has to match the Talos
  `podSubnets`, same as for IPv4.
- Give every node a stable IPv6 address (SLAAC or a reservation), including the MBP's UTM VM.
- Add an IPv6 block to the `homelab-pool` LB pool, and set `ipFamilyPolicy: PreferDualStack` on the Gateway's and the
  Unbound Service, with a pinned IPv6 address for Unbound.
- **Check first:** whether Cilium's L2 announcements answer IPv6 neighbor discovery (NDP) on the version we run. If
  they don't, an IPv6 LB IP can't be announced on the LAN, and the alternatives (BGP, a different approach) change the
  plan.
- Check every workload that hard-codes an address family or a `0.0.0.0` bind, and the UniFi firewall rules between
  VLANs, which need IPv6 equivalents for anything the cluster serves.
- On the UniFi side, DHCPv6 only hands out DNS servers to clients that speak DHCPv6. SLAAC with RDNSS reaches more
  devices (Android in particular ignores DHCPv6), so switch the Server and Trusted VLANs to SLAAC when adding the
  Unbound IPv6 address, as some of the other dual-stack VLANs already are.

Then add the IPv6 VIP to the Server and Trusted VLANs' IPv6 DNS servers next to the jump box's.

## Secrets rotation (external systems)

The goal is peace of mind and following best practice, not a compliance regime. Nothing has ever been rotated, and
there's no inventory. The scope is deliberately narrow: credentials issued by an *external* system (a provider's API
token, a service account), because those are the ones that grant access beyond this cluster and that a leak would
make worst. Out of scope: Authelia's internal keys and OIDC client secrets, the SOPS age key, the Talos secrets
bundle, and the Zigbee and Z-Wave network keys. Rotating those is invasive (re-pairing devices, re-encrypting the
Authelia database, re-keying every SOPS file) for little gain at this scale.

Rotating one of these is mostly small: create a new credential at the provider, put it in the `homelab-k8s` vault (or
re-encrypt the SOPS file), force-sync and restart the consumer (see "Adding or rotating a secret" in
[`../argocd/README.md`](../argocd/README.md#adding-or-rotating-a-secret)), confirm it works, then revoke the old one.
The old credential should be revoked last, so nothing breaks in between.

Rough inventory, to be checked against the repo, 1Password and each provider before trusting it:

- **Cloudflare:** the cluster's API token (cert-manager and external-dns, from the `homelab-k8s` vault) and Terraform's
  separate token (`terraform/cloudflare/secrets/`).
- **TrueNAS:** API keys for democratic-csi (two drivers), and `truenas-exporter`. democratic-csi's key is
  already due for replacement with a least-privilege user; see [`FUTURE.md`](FUTURE.md#democratic-csi-on-truenass-json-rpc-api-hold-hexostruenas-below-26x),
  and rotate it as part of that.
- **UniFi:** Unpoller's login, and `UNIFI_TOKEN` in the Compose `.env`.
- **Proxmox:** Terraform's token (`terraform/proxmox/secrets/`).
- **Home Assistant:** the `claude-ops-token` long-lived access token on the non-admin `claude` user (created 2026-10-19,
  stored in the `home-assistant-claude` item in the `homelab-k8s` vault). It can read every entity and call services, so
  treat it like an admin-adjacent credential; Claude only reads state with it.
- **GitHub:** the Renovate token, and the self-hosted runner's registration.
- **Backblaze B2:** the Terraform state key, the etcd-backup key, and the P3 Plus backup key. All three should already
  be scoped to one bucket each; confirm that, and that none is the master key.
- **Brevo:** the SMTP login in `scripts/secrets/msmtprc.sops.yaml`.
- **1Password:** the `homelab-external-secrets` service account token, which can be replaced as documented under
  [ESO bootstrap](../argocd/README.md#eso-bootstrap-one-time-manual). It's the least risky one to practice on.
- **Not in the repo:** account logins (Cloudflare, B2, GitHub, UniFi, HexOS/TrueNAS admin, Hover). Passwords and 2FA are
  1Password's job; just check each account for long-lived API tokens nobody remembers creating.

Suggested approach:

1. The Compose migration is finished (only Unbound, Telegraf, Vector and `nut-upsd` remain), so the list is as short as it will get; check whether `UNIFI_TOKEN` and the NUT passwords are still needed.
2. Write a runbook under `docs/` (and add it to `docs-site/mkdocs.yml`'s `nav:`): for each credential, which provider
   issued it, its scopes, where it's stored, and how to rotate it. Note any that are over-privileged and replace them
   with narrower or per-consumer credentials as you go, which is the bigger win than the rotation itself.
3. Do one rotation of everything as a dry run, noting where it hurt.
4. Set an expiry wherever the provider allows one, and otherwise a yearly calendar reminder to rotate. Rotate
   immediately if a credential might have leaked (pasted somewhere, a laptop lost).

## Security hardening (from the 2026-10-04 review)

A read-only review of the repo, the cluster and rpi5-1 found a solid baseline (Authelia default-deny with two-factor,
pinned image tags, key-only SSH, protected `main`) and the gaps below. Each is its own small effort. What the review
did *not* cover (UniFi's inter-VLAN firewall and any WAN port forwards, what Cloudflare exposes to the internet,
Proxmox and TrueNAS/HexOS API exposure, and 2FA on the GitHub, 1Password, Cloudflare and UniFi accounts) still needs a
separate look.

### Switch the rpi5-1 host firewall to enforcing

The firewall is installed and has been in log-only mode since 2026-10-22 (see
[`../docs/rpi5-1-firewall.md`](../docs/rpi5-1-firewall.md)). After about a week, read `journalctl -k | grep homelab-fw`,
add rules for anything legitimate it shows, and run `sudo ./install.sh enforce`. Then decide whether to narrow NUT (`:3493`)
from the whole Server VLAN to the worker nodes, which is all that uses it. Jump-box OS upgrade (Debian 12 to 13) is
tracked in `FUTURE.md`.

### Pin container images by digest

Images are pinned by tag, which a registry can repoint (only restock-radar is pinned by digest today, by hand; the
GitHub "require SHA pinning" setting covers Actions, not container images). Add `docker:pinDigests` to Renovate's `extends` so it adds
`@sha256:` digests and updates them with the tag. Expect a one-time PR touching most manifests, and review it as you
would a bulk change; the `# renovate:` annotated pins in custom managers may need their regexes widened to cope with a
digest after the tag.

### Gate the jump-box Terraform jobs with an Environment

Deferred 2026-10-04. The Terraform plan and apply jobs run on rpi5-1, which holds Terraform's SOPS age key, for any PR
from a branch in this repo. Renovate's token now has the Workflows permission, so a stolen token could push a branch
that changes a workflow and runs on that runner. Putting those jobs behind a GitHub Environment with you as a required
reviewer closes that, at the cost of approving each Terraform PR (including Renovate's provider bumps) before it runs.
Revisit if the token's scope widens, a second person gets write access, or the jump box gains more access.

## Go apps: loose ends from the 2026-10-09 CI and Renovate work

The four Go apps (`restock-radar`, `nut-relay`, `truenas-exporter`, `modbus-eth-controller`) now share the same `ci.yml`
and `docker-publish.yml`, have required PR checks and signed commits, and are covered by this repo's Renovate CronJob
(see [`DONE.md`](DONE.md#go-apps-shared-ci-required-checks-and-renovate-coverage)). Each item below is small and
independent.

### Prove modbus's signed Swagger commit

The publish workflow regenerates Swagger docs and commits them back to `main` with the `jakerobb-apps-bot` GitHub App's
token, through the GraphQL `createCommitOnBranch` call, so GitHub signs it. The app bypasses `main pr` and not
`main integrity`. Every publish so far found no docs changes, so that path has never actually pushed. Next time a PR
changes the API annotations, check the publish run after merge: "Commit and push changes" should succeed, and a new
`chore: auto-update swagger docs` commit should appear on `main` as verified, authored by the app. If it's rejected, the
error names the rule that blocked it.

### Make the four repos' rulesets agree

They drifted while being set up. restock-radar, nut-relay and truenas-exporter each have one `main` ruleset (deletion,
force-push, signatures, PR and checks, no bypass). modbus has two: `main integrity` (no bypass) and `main pr` (the app
can bypass). "Require branches to be up to date" is on for nut-relay and truenas-exporter and off for restock-radar and
modbus. restock-radar also requires `ui`, which the others don't have. Pick the settings you want, apply them everywhere
and write them down. Only modbus needs the split form, because it's the only one with a bot that pushes to `main`.

### A read-only Docker Hub token for CI

CI's `docker` job logs in with the same `DOCKERHUB_TOKEN` that publishes images, and any branch in these repos can read
it during a CI run. Create a second, read-only (public repositories) token, store it as a separate secret, and use that
one in `ci.yml`. Leave the write token to `docker-publish.yml`.

### Let Renovate read vulnerability alerts

Renovate logs "Cannot access vulnerability alerts" for homelab and restock-radar. Add **Dependabot alerts: Read-only**
to its token, so security-driven updates can be flagged as such. Optional.

### Stop copying the workflows

`ci.yml` and `docker-publish.yml` are now copies in four repos, kept in sync by hand, and the last round showed how easily
they drift. A reusable workflow in one repo (called with the image name and whether there's a UI) would turn the
next change into one PR. The catch is that every repo then depends on one repo, and modbus's Swagger step is a special
case. Worth it if a fifth Go app turns up, or the next shared change is as big as this one was.

## VolumeSnapshots for the iSCSI volumes

Nothing here can take a VolumeSnapshot today. The external-snapshotter CRDs are installed
([`../manifests/external-snapshotter/`](../manifests/external-snapshotter)) but not the snapshot-controller or its
validating webhook (`../argocd/README.md`, "external-snapshotter CRDs"), there's no `VolumeSnapshotClass`, and
democratic-csi has `volumeSnapshotClasses: []` in
[`../argocd/apps/democratic-csi/application.yaml`](../argocd/apps/democratic-csi/application.yaml). Turning them on
means installing the controller, defining a class for the driver (which makes ZFS snapshots on HexOS through the
TrueNAS API), proving a snapshot and a restore on a throwaway PVC, and adding something to take them on a schedule
and prune them. That touches the storage path every PVC shares, so it's a project of its own. Services that need a
backup today do it themselves onto `hexos-nfs` (Home Assistant, Scrypted and restock-radar all do), which keeps
working whatever happens to snapshots. Worth doing if a service turns up that can't copy its own data, or for
Prometheus and ClickHouse, whose volumes are too big to copy.

## Move the remaining hand-applied CRDs under ArgoCD

kube-prometheus-stack's CRDs have been ArgoCD-managed since 2026-10-02, using `ServerSideApply=true` plus the
`argocd.argoproj.io/compare-options: ServerSideDiff=true` annotation on the Application (no `Replace`). See the
`crds.enabled` bullet in [`argocd/README.md`](../argocd/README.md) for why both settings matter and the retest that proved
it. Three CRD sets are still applied by hand and drift on every chart bump (the Prometheus ones had fallen a patch
release behind before the move):

- **External Secrets Operator** (`clustersecretstores`/`secretstores` are ~724KB as rendered; chart CRDs are installed
  with `installCRDs: false`, see `argocd/apps/external-secrets/application.yaml`).
- **external-snapshotter** (the "external-snapshotter CRDs" section of `argocd/README.md`).
- **SigNoz's clickhouse-operator** (3 CRDs shipped in the chart's `crds/`, see the SigNoz section of `argocd/README.md`).

The same recipe should work for each, but it's untested on these charts. For each one: render the chart's CRDs and run
`kubectl diff --server-side --force-conflicts` against the cluster first (the dry run is what showed the Prometheus
version drift), then flip the chart to ship CRDs (or add a small Application for the raw manifests), add the SSA and
ServerSideDiff settings, and confirm `argocd-controller/Apply` shows up in the live CRDs' managed fields. Weigh the
prune risk before enabling: with `prune: true`, removing a CRD from the source deletes every custom resource of that
kind. Adding `argocd.argoproj.io/sync-options: Prune=false` to each CRD, where the chart lets you, is the safeguard.
When a set moves, delete its manual-apply section from the README in the same PR.

## Watch the first Renovate auto-merges, then widen the rules

The tier-1 `AUTO-MERGE` rules in [`../renovate.json`](../renovate.json) (our own app images, GitHub Actions patch/digest, the
`renovate/renovate` image, patch bumps of Glance/Headlamp/Radar) are merged by the CronJob's new 11:30am weekday run
([`../manifests/renovate/cronjob.yaml`](../manifests/renovate/cronjob.yaml)). After the first weekday or two, check:

- A PR opened by the 4:30am run is merged by the 11:30am run (`kubectl logs -n renovate job/<latest>` shows the merge), and
  nothing is merged outside 11am to 1pm on a weekday, or on a weekend. If PRs just sit, the likely causes are the `automergeSchedule` syntax, `lint` not
  reporting as the required check, or the token lacking permission to merge.
- The `automerge` label appears on eligible PRs, and `internalChecksFilter: strict` isn't hiding updates that should be
  open (a package without a release timestamp and a `minimumReleaseAge` is held back; check the Dependency Dashboard).
- A merge of one of our own images deploys cleanly: ArgoCD syncs it, no `ArgoApp*` or `PodCantStart` alert fires.

Then consider widening, one slice at a time, with the reasoning in [`../argocd/README.md`](../argocd/README.md#renovate-dependency-updates-decided-and-deployed-2026-09-16):
Helm charts without CRDs, patch bumps of other apps, and charts with CRDs only after the remaining hand-applied CRDs are
under ArgoCD (the item above) and the rendered diff covers them. Server-side dry-run in CI would be the extra gate for the
riskier slices. The runner image and tool pins need a check that tests the new runner, not the old one.

## Watch the new rollout deadlines

The readiness probes, the cluster-wide 180s deadline policy and the tightened startup budgets are all live (see
[`DONE.md`](DONE.md)). What's left is watching them on real rollouts:

- Watch for an unexpected `ArgoAppDegraded` on a slow rollout: the cluster default is 180s, and an app that legitimately needs
  longer wants an explicit value (startup budget + 2 minutes) or the annotation (see `docs/adding-an-app.md`).
- After the next Home Assistant upgrade that migrates its recorder database, check it stayed Ready within its 5 minute startup
  budget; if it restarted during the migration, raise `failureThreshold` (see the comment on its `startupProbe`). The same goes
  for InfluxDB after an unclean stop, which would replay its WAL, and for zigbee2mqtt if its coordinator handshake runs long.
- Still without a readiness probe, by choice or because the chart has no setting: see the "Not done" list in
  [`../argocd/README.md`](../argocd/README.md#readiness-probes-and-a-cluster-wide-progress-deadline-added-2026-10-18).

## Resilience follow-ups from the 2026-10-18 audit

Found while checking what the alerts and the cluster's history show. The alerts bundle that came out of it is in
[`DONE.md`](DONE.md); these are what's left.

- **SigNoz's ClickHouse volume should plateau near 19 GiB, not fill** (checked 2026-10-19). It grew a steady 0.58 GiB/day
  (17.5 of 29.4 GiB used), and a straight-line projection of that said "full in about 21 days". That ignored the TTLs: every table
  expires its data after 30 days (SigNoz logs after 15), and all of it dates from SigNoz's install on 2026-09-22, so nothing had
  expired yet. The logs table, old enough for its TTL to have acted, has already flattened. The metrics (51% of the volume) and
  ClickHouse's own `system` logs (37%: `query_log`, `part_log` and three more) should level off between 2026-10-22 and 2026-10-25;
  the check is in [`FUTURE.md`](FUTURE.md#signoz-clickhouse-volume-confirm-it-plateaus). Optional: the system logs cost more than
  all of SigNoz's logs, and shortening their TTL or the volume of what they record would free 3 to 4 GiB.
- **`zigbee2mqtt-data` looks like it's filling** (about 45 days to full at its 7-day trend, at only 11.5% used), which is odd for a
  Zigbee config. That is also a straight-line projection, so first check whether it's real growth or a log or backup that rotates,
  then find what's growing.
- **ntfy delivery isn't verified.** The Healthchecks heartbeat covers Prometheus and Alertmanager but skips ntfy-alertmanager and
  ntfy. A small CronJob could publish a message, poll to confirm ntfy stored it, and ping a second Healthchecks check.
- **Are the app backups copied offsite?** The Home Assistant, Scrypted and change-detection backups go to a `hexos-nfs` volume,
  which lives on the same NAS as the iSCSI primaries. If they aren't copied elsewhere, a NAS failure takes both.

## Alertmanager label-based routing

Alertmanager has been live for a month (as of 2026-10-20), so there's now a track record to design against. Only `severity`
maps to ntfy priority/tags today ([`../manifests/ntfy-alertmanager/configmap.yaml`](../manifests/ntfy-alertmanager/configmap.yaml)).
Review the month's alerts (what fired, what was noise, what you wished went elsewhere) and decide whether per-namespace
topics or other label-based routing are worth building.

## SigNoz alerting -> ntfy-alertmanager direct integration

SigNoz went live on 2026-09-22, and a month in it's time for an opinion on whether it's staying. If it is, SigNoz's own
alert rules (evaluated against its ClickHouse-backed data, not Prometheus) can notify a generic Webhook channel. That
webhook's payload shape looks like the "Alertmanager outbound notification" format `ntfy-alertmanager`
([`../manifests/ntfy-alertmanager/`](../manifests/ntfy-alertmanager/)) already parses, so SigNoz-native alerts could point
straight at it and reuse the existing ntfy pipeline, skipping Alertmanager for that path. Not verified live; found via
docs comparison, not a real test POST. Start with a test POST. See
[`../argocd/README.md`](../argocd/README.md#signoz-decided-and-deployed-2026-09-22) for the SigNoz deployment itself.

## Watch the HexOS iSCSI target logs after the memory bump

**Unblocked 2026-10-24 (moved from FUTURE.md by the upgrade checker):** the last SCST allocation failure was 2026-10-15 05:00 EDT, and the `max_sectors_kb` cap has been on all four workers since 2026-10-16, so there has been a clean week. Decide: retire this item and its [`WATCHING.md`](WATCHING.md) entry, or pick a fix. Originally waiting on: a week of normal use after the HexOS VM went from 8GB to 10GB (applied and restarted 2026-10-08). This is
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

## Trim over-sized memory requests

**Unblocked 2026-10-25** (a clean month of usage history has accrued since the 2026-09-24 restarts). The 2026-09-24 audit set memory
requests just above each workload's 7-day *peak*; p95 is the usual basis. Biggest overshoots, summed across
replicas/nodes: cilium-agent (~1.8GiB over p95), otel-agent (~1.5GiB; 384Mi on every node, sized for mbp, while the
Pis use ~65Mi), kube-apiserver (~0.9GiB; 1536Mi each on three control planes), cilium-envoy (~0.6GiB). Together
about 2-3GiB of requested memory. Waiting because Cilium and every pod on mbp restarted on 2026-09-24, so the recent
history understates their steady state. Re-run the same Prometheus comparison (per-container 7d/30d p95 and max vs
`kube_pod_container_resource_requests`) and size to about p95. The apiserver lives in
[`../talos/patches/control-plane/control-plane-resources.yaml`](../talos/patches/control-plane/control-plane-resources.yaml)
(needs a `talosctl patch` per control plane); the rest are Helm values in `argocd/apps/` and `talos/cilium/values.yaml`
(Cilium needs a manual ArgoCD sync).
