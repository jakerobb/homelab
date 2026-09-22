# DONE

Completed cluster-readiness work, kept for reference — what was decided, why, and where the resulting configuration
lives. Roughly grouped by topic rather than strict chronological order.

## Hardware migration (SSD install, Proxmox, Talos worker, HexOS VM)

**Done (2026-09-18).** Originally a phased checklist in README.md (B2 backup, physical SSD install, Proxmox, Talos
worker join, HexOS VM); merged in here once complete. B2-backed up the 4TB P3 Plus, physically installed it and the 2TB
T500 into the MS-A2, installed Proxmox VE 9.2-1 to the original 1TB boot SSD (runbook: [
`../docs/proxmox-install.md`](../docs/proxmox-install.md)), joined two Talos worker VMs to the existing Pi control plane
via Terraform (`terraform/proxmox/talos-worker.tf`) — pivoting from BGP to Cilium L2 announcements along the way after
an unresolved UCG Fiber routing bug (see
"Ingress" below) — then built the HexOS VM with both new NVMes passed through via PCIe and a ~4TB pool (P3 Plus, with
the T500 ending up as a dedicated ZFS log device rather than striped capacity) with NFS/SMB shares (runbook:
[`../docs/hexos-install.md`](../docs/hexos-install.md)). Two loose ends from that checklist were tracked separately
rather than as part of this entry:
restoring the P3 Plus data from B2 (done, 2026-09-20) and the mail-alerting queue gap found along the way (still open).

## Ingress (Gateway API)

**Done** — decided and deployed 2026-09-13, using Gateway API (Cilium's built-in implementation) instead of a separate
ingress-nginx-style controller; see [
`../talos/README.md`](../talos/README.md#ingress-gateway-api-decided-and-deployed-2026-09-13). TLS decided too:
cert-manager + Let's Encrypt DNS-01 against Cloudflare, real publicly-trusted wildcard cert for `*.jakerobb.org`, plus
`external-dns`
auto-creating DNS records — see [`../argocd/README.md`](../argocd/README.md#dns--tls-decided-2026-09-13). First real
`HTTPRoute` is ArgoCD's own UI (`argocd.jakerobb.org`).

## ArgoCD

**Base setup done** — decided and deployed 2026-09-13, installed via Helm (app-of-apps pattern, fully automated sync)
into this same repo rather than a paired one; see [`../argocd/README.md`](../argocd/README.md). SSO via Authelia added
2026-09-13 too (see "Authelia SSO" below). Ongoing by nature:
real workloads keep getting added under `argocd/apps/` as other backlog items get built out.

## Authelia SSO

**Fronting ArgoCD only — done 2026-09-13.** Single-pod Authelia (SQLite + in-memory sessions, no Postgres/Redis) via
real OIDC against ArgoCD's native OIDC-client support; see [
`../argocd/README.md`](../argocd/README.md#authelia-sso-decided-2026-09-13). Also stood up `local-path-provisioner` as
the cluster's first `StorageClass`
— first PVC-backed workload under ArgoCD's `prune: true`, so its reclaim policy was deliberately set to `Retain`. It was
a deliberate bridge until real HexOS-backed storage landed (see "HexOS storage" below); `hexos-iscsi`
has since superseded it as the cluster's default `StorageClass`, and Authelia itself was migrated onto `hexos-iscsi`.
Remaining, not covered by this entry: adding an `access_control` rule (and per-app OIDC/forward-auth)
as each Compose workload actually migrates into the cluster — tracked as an open item.

## Metrics: instant metrics (metrics-server + kube-prometheus-stack)

**Done.** `metrics-server`
([`../argocd/README.md`](../argocd/README.md#metrics-server-decided-and-deployed-2026-09-17))
covers the Kubernetes Metrics API (`kubectl top`). Turns out that alone wasn't enough for OpenLens's own graphs/usage
bars — those are Prometheus- backed specifically, confirmed directly by OpenLens itself when it wasn't there yet — so
`kube-prometheus-stack`
([`../argocd/README.md`](../argocd/README.md#kube-prometheus-stack-decided-and-deployed-2026-09-17))
was added too (Grafana still off; Alertmanager was off initially but has since been enabled — see "Alerting" below).
Remote-writing to a proper timeseries database instead of relying on Prometheus's own short-lived (10-day) local storage
is still open, tracked separately.

## Log and Metrics aggregation (SigNoz)

**Done (2026-09-22).** Replaces the "re-evaluate what solutions make sense"
placeholder — landed on [SigNoz](https://signoz.io) (logs/metrics/traces in
one stack), running on a new third worker,
[`talos-worker-mbp`](../talos/README.md#additional-worker-talos-worker-mbp-added-2026-09-22)
(a temporary UTM VM on an idle MacBook Pro, deliberately disposable — every
stateful piece is on `hexos-iscsi`). Full writeup, every gotcha found, and
the corrected metrics-ingestion approach (federation, not remote_write — the
original assumption didn't hold up) are in
[`../argocd/README.md`](../argocd/README.md#signoz-decided-and-deployed-2026-09-22).
Ship-pod-and-node-logs and remote-write-to-a-proper-timeseries-database are
both closed: `signoz/k8s-infra`'s DaemonSet tails container logs
cluster-wide, and `kube-prometheus-stack`'s Prometheus is federated into
SigNoz's ClickHouse-backed store rather than relying on its own 10-day local
retention. `kube-prometheus-stack` itself stays in place — Alertmanager and
its ntfy routing are untouched, and Headlamp's Prometheus plugin (confirmed
viable against SigNoz's real Prometheus-API-compatible endpoint, not yet
switched over) is the only path that could eventually make it removable.
Storage validated with a real `fio` benchmark before trusting
`hexos-iscsi` for ClickHouse's latency-sensitive workload (~3000 IOPS/
direction, ~1.3ms average latency — see the linked writeup for full
numbers). Not done: piping rpi5-1's own Compose-host logs (Vector) into the
same collector — explicit follow-up, not started.

## Proxmox host config backup

**Done — deployed and running since 2026-09-11.** Daily cron on the Proxmox host itself tars up `/etc/pve`, network
config, apt sources, and chrony config, and ships it to rpi5-1 over a restricted SSH key (file transfer only, no
shell). See [`../docs/proxmox-config-backup.md`](../docs/proxmox-config-backup.md).

## etcd / control-plane backups

**Done.** Daily `talosctl etcd snapshot` via
[`../scripts/etcd-snapshot-backup.sh`](../scripts/etcd-snapshot-backup.sh), stored on rpi5-1 (`~/backups/etcd`, 30-day
retention) and synced to a dedicated, scoped-key B2 bucket (added 2026-09-21). Restore procedure confirmed working
2026-09-21 with a full live drill against production — see
[`../docs/etcd-backup.md`](../docs/etcd-backup.md#restore) for the runbook, timeline, and quorum-safety mechanics.
Ongoing: a quarterly restore drill runs automatically (scheduled Claude task), next due ~2026-12-21.

## HexOS storage

**Done — started 2026-09-13, iSCSI path completed 2026-09-15.**
Pool (`data`, ~4TB usable — the T500 ended up as a dedicated ZFS log device rather than striped capacity, see [
`../docs/hexos-install.md`](../docs/hexos-install.md#6-pool--share-setup-gui-only-hexos))
created, iSCSI service enabled with a Portal + Initiator Group configured. Both Talos workers upgraded in place
(`talosctl upgrade`) to a schematic with the `siderolabs/iscsi-tools`
extension, plus a `kubelet.extraMounts` patch for `/etc/iscsi`/`/var/lib/iscsi`
(kubelet runs in its own mount namespace on Talos and doesn't see host paths by default, even real ones) — see
[`../talos/README.md`](../talos/README.md#iscsi-tools-extension-added-2026-09-15).
`democratic-csi` (TrueNAS iSCSI driver) deployed via ArgoCD against
`data/k8s-iscsi` — see
[`../argocd/apps/democratic-csi/`](../argocd/apps/democratic-csi/application.yaml). Verified end-to-end with a throwaway
PVC: dynamic provisioning, and clean detach/reattach with data intact when force-moved to the other worker node.
`hexos-iscsi` is now the cluster's **default StorageClass**
(`local-path-provisioner` demoted, kept around for node-local use cases). Authelia migrated onto it as the first real
workload (clean start, not a data migration — see `argocd/apps/authelia/application.yaml`).

Also found and fixed a real bug along the way, unrelated to HexOS itself but uncovered by finally exercising external
Gateway access post-migration: the Cilium `CiliumL2AnnouncementPolicy` had a hardcoded `interfaces: [^eth0$]`
that never matched the Talos workers' actual `ens18` NIC, so the LB IP silently never answered ARP — see
[`../talos/README.md`](../talos/README.md#ingress-gateway-api-decided-and-deployed-2026-09-13)
(gotcha entry, 2026-09-15).

**P3 Plus data restored from B2 and verified (2026-09-20).** Mounted the
`data/shared` NFS export (see [`../docs/hexos-install.md`](../docs/hexos-install.md#6-pool--share-setup-gui-only-hexos))
on the Intel MacBook Pro and ran `rclone copy p3plus-b2:p3plus-archive-temp`
down onto it (~14h50m for 1.33TiB/318821 files — mostly small Photos Library files, which dominate transfer time far
more than raw bandwidth). `rclone
check` afterward: 0 differences, 318821 matching files.

The earlier idea of moving InfluxDB's datastore onto `hexos-iscsi` is now moot — the Compose observability stack
(InfluxDB included) isn't being lifted into the cluster as-is; it's superseded by the in-cluster metrics stack instead.

## Talos control-plane installer & firmware fix

**Done.** Control-plane installer switched from the now-inactive `talos-rpi5/installer` to the maintained
`yama6a/talos-raspberry-pi5` fork (2026-09-17), then all 3 Pi5 control planes were upgraded past a Pi5-specific
U-Boot EFI-variable bug that blocked every normal `talosctl upgrade`, fixed with a custom `/bin/installer` image
that swaps the patched `u-boot.bin` directly rather than going through Talos's own (blocked) EFI-variable write
path. Full rationale, the dead ends ruled out first, and the reusable tooling for the next Talos bump are in
[`../talos/README.md`](../talos/README.md#talos-v1141-upgrade-blocked-by-pi5-efi-variable-firmware-bug-2026-09-18) and
[`../talos/tools/uboot-fix/`](../talos/tools/uboot-fix/).

## Talos cluster reliability fixes

**Done.** A handful of silent (Healthy-looking but actually broken) issues found and fixed on the existing cluster,
each with its root cause and rationale written up in [`../talos/README.md`](../talos/README.md):

- **Kubernetes discovery registry** — two control planes had cluster discovery entirely broken (Kubernetes 1.32+
  tightened node RBAC in a way that broke Talos's legacy discovery mechanism); fixed by disabling it in favor of
  the `service` registry.
- **kube-scheduler / kube-controller-manager metrics** — both bound to `127.0.0.1` by Talos's own default, so
  Prometheus couldn't scrape either one; fixed by explicitly binding `0.0.0.0` (still TLS/auth-protected, so this
  doesn't remove any auth).
- **Control-plane VIP** (`192.168.102.10`) — floats across all 3 control planes via Talos's built-in VIP feature,
  so `kubectl`/OpenLens no longer drop their connection when a single control-plane node restarts.
- **Container log size limits** — made kubelet's previously-implicit `containerLogMaxSize`/`containerLogMaxFiles`
  explicit rather than relying on defaults.
- **Machine-config `install.image` drift** — found stale on all 5 nodes (harmless day-to-day); fixed on both
  workers, deliberately left stale on control planes rather than papered over with a value that would be a
  landmine if it were ever actually used to reinstall one — see talos/README.md for why.

## Alerting

**Done 2026-09-20.** `kube-prometheus-stack`'s Alertmanager is enabled, routed through the `ntfy-alertmanager` bridge to
`ntfy`'s `homelab-alerts`
topic — see
[`../argocd/README.md`](../argocd/README.md#kube-prometheus-stack-decided-and-deployed-2026-09-17). Only `severity` is
mapped to ntfy priority/tags today ([
`../manifests/ntfy-alertmanager/configmap.yaml`](../manifests/ntfy-alertmanager/configmap.yaml)).

## ntfy (Compose workload migration)

**Done 2026-09-20.** Migrated off the RPi5 16GB's Docker Compose stack into the cluster — see
[`../argocd/README.md`](../argocd/README.md#ntfy-migrated-from-docker-compose-2026-09-20).

## Homepage dashboard widgets

**Done (2026-09-18).** Weather (Open-Meteo), Proxmox host CPU/mem, HexOS/TrueNAS disk usage, and UniFi Controller
(top-bar uptime/WAN/LAN/WLAN status) are all wired in and confirmed working (`argocd/apps/homepage/configmap.yaml` +
`deployment.yaml`), secrets encrypted
(`argocd/secrets/{proxmox-api-token,truenas-api-key,unifi-credentials}.homepage.sops.yaml`). Confirmed hosts:
`https://proxmox.lan:8006` (node name still the terraform *default*, `proxmox_node_name` — unconfirmed),
`http://truenas.lan` for the widget's own API calls vs. `https://deck.hexos.com/dash` for the tile's click-through link
(two different things — see the comment in configmap.yaml). Remember to `sops -d ... | kubectl apply -f -` each once
pushed (no KSOPS yet, applied out-of-band like every other secret here).

The rpi5-1 CPU/mem widget (Glances) was deliberately deferred rather than shipped with the rest of this.

## Gateway API forward-auth (Cilium ExternalAuth filter)

**Done — wired up 2026-09-15, confirmed working live.** Cilium added a native, Gateway-API-standard way to delegate
auth to an external service (`ExternalAuth` HTTPRoute filter, GEP-1494) using the same `ext_authz` protocol Authelia
already speaks — shipped in **Cilium 1.20.0**; see [
`../talos/README.md`](../talos/README.md#cilium-version-management) for how the cluster's Cilium version is tracked
and upgraded. Needed for any Compose workload that
doesn't have its own OIDC support (most of them — NetworkOptimizer, change-detection, VictoriaLogs, etc.), since
Authelia's OIDC provider only directly helps apps that speak OIDC themselves (like ArgoCD/Grafana).

The dashboard app (`argocd/apps/homepage/`) was the pilot: its `HTTPRoute` carries an `ExternalAuth` filter
pointing at Authelia's `/api/authz/ext-authz/` endpoint (field shape verified live against this cluster's CRDs, see the
comment in `homepage/httproute.yaml`), plus the `access_control` rule and `ReferenceGrant` it needs
(`argocd/apps/authelia/application.yaml` and `referencegrant.yaml`). Confirmed working end-to-end post-sync (external
curl against `home.jakerobb.org`), and has been running well for days since. Authelia's `ext-authz` authz endpoint
works with zero explicit `server.endpoints.authz` config, as assumed going in. Second use added 2026-09-18 for
`argocd/apps/searxng/` (same filter/`access_control`/`ReferenceGrant` pattern), also confirmed live. Add the same
filter to each other protected app's `HTTPRoute` as it migrates.
