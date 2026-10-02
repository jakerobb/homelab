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

- **Home automation stack** (`homeassistant`) — not hardware-pinned. The Zigbee and Z-Wave coordinators are on Ethernet, not USB.
  Home Assistant doesn't use Bluetooth, so the `/run/dbus` mount can go. Its `/dev/ttyAMA0` / `/dev/serial0` devices
  (the Pi's GPIO UART) were for an integration that never worked and isn't in use, so drop them and `privileged: true`
  rather than carrying them over.
  `mosquitto`, `zwave-js-ui`, `zigbee2mqtt` and `matter-server` already moved; see [`DONE.md`](DONE.md).
  **Decide config ownership per service before moving each one.** `change-detection` rewrites its own config files,
  and a ConfigMap/Secret mount is read-only, so it can't save UI changes there. Pick one: seed the file into the PVC
  once (the app owns it afterward, so UI edits survive but git isn't authoritative), or overwrite it on every start (git
  wins, UI edits are lost). `zwave-js-ui` and `zigbee2mqtt` both took the seed-once route (Zigbee2MQTT's config comes from
  the old data directory rather than a ConfigMap, since it holds device names). Both keep their secrets in an
  ExternalSecret, as env vars (Z-Wave) or a `!secret` file (Zigbee2MQTT, whose `write()` would otherwise copy env
  overrides into the PVC).
- **change-detection.io** (`change-detection` + its `browserless` dependency) — **deliberately last; don't suggest it
  as the next migration.** browserless (headless Chromium) is heavy, and Jake has ideas for relying on it less, so it
  waits until everything else has moved. No hardware dependency. Needs a persistent volume for the datastore.

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
4. Expect to need `ignoreDifferences` or sync options for the chart's CRDs, `argocd-initial-admin-secret` and the redis
   secret-init job, so Argo doesn't fight them.
5. Update "Upgrading ArgoCD itself" and the "Bootstrap pattern" section of `argocd/README.md` (the "manual permanently"
   claim), and move the Renovate comment off the `helm install` block.
