# READY

Cluster-readiness backlog — each of these is its own effort, meant to be tackled separately rather than all at once.
This list is in roughly priority order. "Compose workload migration" is deliberately last; we want a stable, robust,
observable cluster before we bring in critical workloads.

## Compose workload migration

**In progress (since 2026-09-28).** Migrated services move to [`DONE.md`](DONE.md) as they land.
Move each service off the RPi5 16GB's Docker Compose stack into the cluster, one at a time, in separate sessions. For
each, consider whether a more K8s-appropriate or K8s-native alternative exists. Each application should be a separate
ArgoCD Application resource. Put each application behind Authelia -- using OIDC if possible; ExternalAuth filtering
otherwise. Persistent storage moves from the Pi to democratic-csi PVC.

### Do not migrate

- **Observability stack** (`telegraf`, `vector`) - Stay on rpi5-1 as collectors only: both ship to SigNoz, and
  `influxdb`, `grafana` and `victorialogs` were retired on 2026-10-01 (see [`DONE.md`](DONE.md)). History was not
  migrated. NetworkOptimizer's buckets moved to the app's own in-cluster InfluxDB on 2026-09-29.
- **`nut-upsd`** — needs USB access to the CyberPower UPS, so it stays on rpi5-1 until the hardware plan in
  [`HARDWARE.md`](HARDWARE.md) moves that Pi into the cluster. Its relay and web UI were replaced by nut-exporter
  (see [`DONE.md`](DONE.md)).

### To be migrated

- **Decide config ownership per service before moving each one.** `change-detection` rewrites its own config files,
  and a ConfigMap/Secret mount is read-only, so it can't save UI changes there. Pick one: seed the file into the PVC
  once (the app owns it afterward, so UI edits survive but git isn't authoritative), or overwrite it on every start (git
  wins, UI edits are lost). `zwave-js-ui`, `zigbee2mqtt` and `homeassistant` all took the seed-once route (Zigbee2MQTT's
  and Home Assistant's config come from the old data directory rather than a ConfigMap). Secrets go in an ExternalSecret,
  as env vars (Z-Wave) or a `!secret` file (Zigbee2MQTT, whose `write()` would otherwise copy env overrides into the PVC).
- **change-detection.io** (`change-detection` + its `browserless` dependency) — **ready to migrate.** It was held back
  because browserless (headless Chromium) is heavy and Jake wanted to rely on it less. The UniFi store watches were
  what drove that, and [restock-radar](https://github.com/jakerobb/restock-radar) replaced them on 2026-10-05
  (`argocd/README.md`'s restock-radar section), so **retire the 26 UniFi store entries instead of migrating them.**
  The rest are three non-store pages (the changedetection.io changelog, `smarthomeshop.io`'s UltimateSensor, and
  `ui.com/us/en/whats-new`). Check whether those need a browser at all; if plain HTTP fetches work, drop browserless
  rather than moving it, and close "Secure browserless" below with it. No hardware dependency. Needs a persistent
  volume for the datastore.

When a service migrates, delete its file from `manifests/lan-routes/` in the same PR.

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
- **TrueNAS:** API keys for democratic-csi (two drivers), `truenas-exporter` and Homepage. democratic-csi's key is
  already due for replacement with a least-privilege user; see [`FUTURE.md`](FUTURE.md#democratic-csi-on-truenass-json-rpc-api-hold-hexostruenas-below-26x),
  and rotate it as part of that.
- **UniFi:** Homepage's API key, Unpoller's login, and `UNIFI_TOKEN` in the Compose `.env`.
- **Proxmox:** the token Homepage uses and Terraform's token (`terraform/proxmox/secrets/`).
- **GitHub:** the Renovate token, and the self-hosted runner's registration.
- **Backblaze B2:** the Terraform state key, the etcd-backup key, and the P3 Plus backup key. All three should already
  be scoped to one bucket each; confirm that, and that none is the master key.
- **Brevo:** the SMTP login in `scripts/secrets/msmtprc.sops.yaml`.
- **1Password:** the `homelab-external-secrets` service account token, which can be replaced as documented under
  [ESO bootstrap](../argocd/README.md#eso-bootstrap-one-time-manual). It's the least risky one to practice on.
- **Not in the repo:** account logins (Cloudflare, B2, GitHub, UniFi, HexOS/TrueNAS admin, Hover). Passwords and 2FA are
  1Password's job; just check each account for long-lived API tokens nobody remembers creating.

Suggested approach:

1. Finish the Compose migration first, so the list shrinks (e.g. `UNIFI_TOKEN` and the NUT passwords may go with it).
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

### Secure browserless

`browserless` (Compose, `network_mode: host`) listens on `0.0.0.0:3000` with **no `TOKEN`**, so anything that can reach
`192.168.102.2:3000` can drive a remote Chromium: run arbitrary pages and scripts from the Pi's network position, and
reach whatever the Pi can. `change-detection` also connects to it with `--disable-web-security`
(`PLAYWRIGHT_DRIVER_URL` in `docker-compose/docker-compose.yml`). Both containers run on the same host, so the usual fix
is to stop exposing it. Check browserless v2's docs for a bind-address setting (`HOST`) to put it on `127.0.0.1` and
change `PLAYWRIGHT_DRIVER_URL` to `ws://127.0.0.1:3000/...`. If that doesn't work, set a `TOKEN` (from 1Password, like the
other secrets) and add `?token=` to the URL. Verify from another machine that `:3000` is closed. This is a stopgap:
when browserless moves into the cluster (see "Compose workload migration"), it should get a ClusterIP Service that
only `change-detection` can reach.

### Secure ChangeDetection

`change-detection` listens on `0.0.0.0:5000` on rpi5-1 (host networking, so the compose `ports: 9898:5000` mapping
doesn't apply). Authelia's two-factor rule only covers `changedetection.jakerobb.org`; hitting `rpi5-1:5000` directly
skips it and reaches an unauthenticated UI that can fetch arbitrary URLs. It can't bind to loopback, since the
Gateway's Envoy proxies to it from the cluster nodes. Instead, restrict the port with a host firewall rule on rpi5-1
that allows `:5000` only from the node IPs (`.11`-`.13`, `.31`, `.32`, `.34`; Envoy's upstream connections leave
through the node's IP, see the "LAN routes" section of `argocd/README.md`). Host-network container ports are ordinary
host sockets, so a normal INPUT rule applies, unlike Docker-published ports. Also set a password in ChangeDetection's
own settings as a second layer. Like browserless, this is a stopgap until the workload moves into the cluster.

### Scope Headlamp's ServiceAccount

The `headlamp` ClusterRoleBinding gives Headlamp's own ServiceAccount `cluster-admin`
([`manifests/headlamp/clusterrolebinding.yaml`](../manifests/headlamp/clusterrolebinding.yaml)), so a compromised
Headlamp pod would own the cluster. That was a deliberate 2026-09-21 call, because Headlamp ran in `-in-cluster` mode and
used the SA's token for every request. Since then kube-apiserver was wired to Authelia's OIDC
([`talos/patches/control-plane/oidc.yaml`](../talos/patches/control-plane/oidc.yaml)) with an `oidc-admin` binding for
`jakerobb@gmail.com`, and the comment on that binding says the SA is for Headlamp's backend only, not for requests that
carry a user's token. **Find out which is true now** before changing anything: bind the SA to `view` (or a narrower
role) and check that Headlamp still works for you, including writes, since those should then be authorized by your own
`oidc-admin` identity. If writes break, Headlamp is still using the SA's token, and the answer is a smaller custom role
instead of `view`. Update the "RBAC" bullet in the Headlamp section of `argocd/README.md` either way.

### Harden SSH and the host firewall on rpi5-1

`sshd` is already key-only. Still to do: `PermitRootLogin` is `without-password`, so set it to `no`, and set
`X11Forwarding no`. `3493` (the NUT data port for the UPS) is reachable from the LAN without authentication; it's
read-only data, but consider limiting it to the hosts that need it. A first look at the nftables ruleset showed only
Docker's NAT chains, so confirm what, if anything, filters INPUT, and settle on a default-deny baseline (SSH from the
LAN, DNS on `:53`, `:3493` from where it's needed, and whatever the two entries above leave open) so that new
host-network containers aren't exposed by default. Jump-box OS upgrade (Debian 12 to 13) is tracked in `FUTURE.md`.

### Turn on the remaining free GitHub security features

Code scanning's default setup with the `actions` language (CodeQL looks for script injection in workflow files, which
matters with self-hosted runners on a public repo; Settings, Advanced Security). Dependabot malware alerts (Dependabot
alerts are already on). A `SECURITY.md`, plus private vulnerability reporting if you ever want outside reports.

### Pin container images by digest

Images are pinned by tag, which a registry can repoint. Add `docker:pinDigests` to Renovate's `extends` so it adds
`@sha256:` digests and updates them with the tag. Expect a one-time PR touching most manifests, and review it as you
would a bulk change; the `# renovate:` annotated pins in custom managers may need their regexes widened to cope with a
digest after the tag.

### Gate the jump-box Terraform jobs with an Environment

Deferred 2026-10-04. The Terraform plan and apply jobs run on rpi5-1, which holds Terraform's SOPS age key, for any PR
from a branch in this repo. Renovate's token now has the Workflows permission, so a stolen token could push a branch
that changes a workflow and runs on that runner. Putting those jobs behind a GitHub Environment with you as a required
reviewer closes that, at the cost of approving each Terraform PR (including Renovate's provider bumps) before it runs.
Revisit if the token's scope widens, a second person gets write access, or the jump box gains more access.

## Unique image tags for the Go apps

The Go apps' images are tagged with the UTC date (`YYYYMMDD`), so a second publish on the same day moves the tag.
restock-radar hit this on 2026-10-05: the re-published image kept the tag the running pod already used, so a tag bump
would have changed nothing in git or on the node, and the Deployment is pinned by digest as a workaround. Change each
workflow's tag step to include the time: `date -u +%Y%m%d%H%M%S` (`YYYYMMDDHHMMSS`). That's still one integer, so
Renovate's docker versioning sorts it, and it's greater than every existing 8-digit tag, so the first bump PR after
the switch is an ordinary update. Don't use a separator (`20261005-021530`): Renovate reads what follows a dash as a
variant suffix and only proposes tags with the same one, so it would never see a newer image. That's from Renovate's
docs, not tested here, so check that the first bump PR appears. Leave `latest` as it is.

Apps (each repo's `.github/workflows/docker-publish.y*ml`; the `date` step differs slightly between them):
`restock-radar`, `nut-relay`, `truenas-exporter` and `modbus-eth-controller`, whose pins are in
`manifests/restock-radar/`, `nut-exporter/`, `truenas-exporter/` and `modbus-controller/`. Once restock-radar has a
unique tag, its digest pin is optional; keep it if "Pin container images by digest" below goes ahead.

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

## Prometheus PVC steady-state usage

**Was waiting on:** the 10-day retention window to fill. The PVC was expanded from 10Gi to 20Gi on 2026-09-30 after it hit
~85% (8.8 GB) while still growing ~0.4 GB per 12 hours, so its steady-state size is unknown. **Check on or after
2026-10-03**: look at `kubelet_volume_stats_used_bytes` for the `prometheus-...-db` PVC. If growth has flattened well
under 20Gi, nothing to do; if it's still climbing toward the limit, set `retentionSize` (a bit under the PVC size) on
the Prometheus spec in `argocd/apps/kube-prometheus-stack/application.yaml`, and/or cut series cardinality (~240k
series at last count).

**Update 2026-10-03:** window has elapsed. PVC is at ~10.1 GB of 21 GB (48%), up from 8.8 GB on 09-30, so growth has slowed but is worth one more look before deciding on `retentionSize`.

## Let ArgoCD manage its own Helm chart

ArgoCD's own chart is the one recurring manual `helm upgrade`
([`argocd/README.md`](../argocd/README.md#upgrading-argocd-itself)). Everything else, Cilium included, is an
Application. Make ArgoCD adopt itself so a merged Renovate PR is the whole deploy, with no cron job or runner. (A cron on
rpi5-1 like [compose-deploy](../docs/compose-deploy.md) would work but means parsing the version out of a README code
block. A GitHub Actions deploy is out: the only runner is on rpi5-1, which holds the Talos secrets.)

1. Add an `argocd` Application for `argo/argo-cd` with the values from
   [`argocd/install/values.yaml`](../argocd/install/values.yaml) (multi-source with a `$values` ref, or `valuesObject`).
   Renovate tracks its `targetRevision`.
2. Start with manual sync, like Cilium, and flip to automated after watching a couple of upgrades. A bad version can break
   the controller that's applying it; recovery is `helm install` against the same values from rpi5-1.
3. One-time adoption: sync the Application over the live resources, then delete the stale Helm release Secrets
   (`sh.helm.release.v1.argocd.*` in the `argocd` namespace) without uninstalling, so nobody runs `helm upgrade` against
   stale state.
4. Expect to need `ignoreDifferences` or sync options for `argocd-initial-admin-secret` and the redis secret-init job, so
   Argo doesn't fight them. The chart's CRDs need the same treatment as kube-prometheus-stack's: the `applicationsets`
   CRD is ~377KB, over the client-side-apply annotation cap, so the Application needs `ServerSideApply=true` plus the
   `argocd.argoproj.io/compare-options: ServerSideDiff=true` annotation (see the CRD item below). Also protect the CRDs
   from `prune` (`Prune=false`): ArgoCD's own CRDs vanishing would take every Application with them.
5. Update "Upgrading ArgoCD itself" and the "Bootstrap pattern" section of `argocd/README.md` (the "manual permanently"
   claim), and move the Renovate comment off the `helm install` block.

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
