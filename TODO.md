# TODO

Cluster-readiness backlog — each of these is its own effort, meant to be
tackled in a separate conversation rather than all at once. Not strictly
sequenced, but **Jake's explicit priority (2026-09-18): get the cluster
robust and smoothly operating — monitoring, alerting, log aggregation,
storage/backup gaps closed — before migrating any Compose workloads.**
"Compose workload migration" below is deliberately last for that reason;
pick among the others first.

The hardware-migration checklist that used to live in
[README.md](README.md) is now merged in below (see "Hardware migration
(SSD/Proxmox/Talos worker/HexOS VM)") — it's ~done, with its two loose ends
folded into "HexOS storage" and the new "rpi5-1 mail-alert reliability"
section.

## Hardware migration (SSD install, Proxmox, Talos worker, HexOS VM)
**Done**, merged in from README.md's original phased checklist (2026-09-18).
B2-backed up the 4TB P3 Plus, physically installed it and the 2TB T500
into the MS-A2, installed Proxmox VE 9.2-1 to the original 1TB boot SSD
(runbook: [`docs/proxmox-install.md`](docs/proxmox-install.md)), joined two
Talos worker VMs to the existing Pi control plane via Terraform
(`terraform/proxmox/talos-worker.tf`) — pivoting from BGP to Cilium L2
announcements along the way after an unresolved UCG Fiber routing bug (see
"Ingress" below) — then built the HexOS VM with both new NVMes passed
through via PCIe and a ~4TB pool (P3 Plus, with the T500 ending up as a
dedicated ZFS log device rather than striped capacity) with NFS/SMB shares
(runbook:
[`docs/hexos-install.md`](docs/hexos-install.md)). Both loose ends from
that checklist are tracked below rather than here: restoring the P3 Plus
data from B2 (see "HexOS storage") and the mail-alerting queue gap found
along the way (see "rpi5-1 mail-alert reliability").

## Ingress (Gateway API)
**Done** — decided and deployed 2026-09-13, using Gateway API (Cilium's
built-in implementation) instead of a separate ingress-nginx-style
controller; see [`talos/README.md`](talos/README.md#ingress-gateway-api-decided-and-deployed-2026-09-13).
TLS decided too: cert-manager + Let's Encrypt DNS-01 against Cloudflare, real
publicly-trusted wildcard cert for `*.jakerobb.org`, plus `external-dns`
auto-creating DNS records — see [`argocd/README.md`](argocd/README.md#dns--tls-decided-2026-09-13).
First real `HTTPRoute` is ArgoCD's own UI (`argocd.jakerobb.org`).

## etcd / control-plane backups
**Done.** Daily `talosctl etcd snapshot` via
[`scripts/etcd-snapshot-backup.sh`](scripts/etcd-snapshot-backup.sh), stored
on rpi5-1 (`~/backups/etcd`, 30-day retention) and synced to a dedicated,
scoped-key B2 bucket (added 2026-09-21). Restore procedure confirmed
working 2026-09-21 with a full live drill against production — see
[`docs/etcd-backup.md`](docs/etcd-backup.md#restore) for the runbook,
timeline, and quorum-safety mechanics. Recurring follow-up, not a one-off:
**quarterly restore drill**, next due ~2026-12-21 — worth a reminder closer
to the date rather than relying on this list alone.

## HexOS storage
**Core work done — started 2026-09-13, iSCSI path completed 2026-09-15.**
Pool (`data`, ~4TB usable — the T500 ended up as a dedicated ZFS log device
rather than striped capacity, see [`docs/hexos-install.md`](docs/hexos-install.md#6-pool--share-setup-gui-only-hexos))
created, iSCSI service enabled with a
Portal + Initiator Group configured. Both Talos workers upgraded in place
(`talosctl upgrade`) to a schematic with the `siderolabs/iscsi-tools`
extension, plus a `kubelet.extraMounts` patch for `/etc/iscsi`/`/var/lib/iscsi`
(kubelet runs in its own mount namespace on Talos and doesn't see host paths
by default, even real ones) — see
[`talos/README.md`](talos/README.md#iscsi-tools-extension-added-2026-09-15).
`democratic-csi` (TrueNAS iSCSI driver) deployed via ArgoCD against
`data/k8s-iscsi` — see
[`argocd/apps/democratic-csi/`](argocd/apps/democratic-csi/application.yaml).
Verified end-to-end with a throwaway PVC: dynamic provisioning, and clean
detach/reattach with data intact when force-moved to the other worker node.
`hexos-iscsi` is now the cluster's **default StorageClass**
(`local-path-provisioner` demoted, kept around for node-local use cases).
Authelia migrated onto it as the first real workload (clean start, not a
data migration — see `argocd/apps/authelia/application.yaml`).

Also found and fixed a real bug along the way, unrelated to HexOS itself but
uncovered by finally exercising external Gateway access post-migration: the
Cilium `CiliumL2AnnouncementPolicy` had a hardcoded `interfaces: [^eth0$]`
that never matched the Talos workers' actual `ens18` NIC, so the LB IP
silently never answered ARP — see
[`talos/README.md`](talos/README.md#ingress-gateway-api-decided-and-deployed-2026-09-13)
(gotcha entry, 2026-09-15).

**P3 Plus data restored from B2 and verified (2026-09-20).** Mounted the
`data/shared` NFS export (see [`docs/hexos-install.md`](docs/hexos-install.md#6-pool--share-setup-gui-only-hexos))
on the Intel MacBook Pro and ran `rclone copy p3plus-b2:p3plus-archive-temp`
down onto it (~14h50m for 1.33TiB/318821 files — mostly small Photos Library
files, which dominate transfer time far more than raw bandwidth). `rclone
check` afterward: 0 differences, 318821 matching files.

The earlier idea of moving InfluxDB's datastore onto `hexos-iscsi` is now
moot — the Compose observability stack (InfluxDB included) isn't being
lifted into the cluster as-is, see "Observability stack" under "Compose
workload migration" below. Separately, and later: an NFS-backed
StorageClass for genuinely ReadWriteMany workloads (media libraries, etc.),
which iSCSI/block storage can't do.

## ArgoCD-native SOPS decryption (KSOPS)
**Not started.** Every SOPS-encrypted secret under `argocd/secrets/` is
currently applied out-of-band by hand (`sops -d ... | kubectl apply -f -`)
before an Application can go healthy — ArgoCD itself has no way to decrypt
them, a gap already noted in [`argocd/README.md`](argocd/README.md) and hit
concretely setting up `democratic-csi`'s driver-config secret. KSOPS
(`viaduct-ai/kustomize-sops`) is the standard fix: an initContainer on
`repo-server` decrypts SOPS files as part of the Kustomize build. Real
tradeoffs to weigh before doing it, not just a config toggle: the age
*private* key would need to live in-cluster (currently only Jake's Mac +
1Password have it — this expands blast radius if `repo-server` is ever
compromised), and every existing secret file would need restructuring from a
standalone applied `Secret` into a Kustomize-generator reference, introducing
Kustomize into a repo that's so far been pure raw-YAML + Helm `valuesObject`.

## ArgoCD
**Base setup done** — decided and deployed 2026-09-13, installed via Helm
(app-of-apps pattern, fully automated sync) into this same repo rather than a
paired one; see [`argocd/README.md`](argocd/README.md). SSO via Authelia
added 2026-09-13 too (see below). Remaining: add real workloads under
`argocd/apps/` as other TODO items here get built out.

## Authelia SSO
**Fronting ArgoCD only — done 2026-09-13.** Single-pod Authelia (SQLite +
in-memory sessions, no Postgres/Redis) via real OIDC against ArgoCD's native
OIDC-client support; see [`argocd/README.md`](argocd/README.md#authelia-sso-decided-2026-09-13).
Also stood up `local-path-provisioner` as the cluster's first `StorageClass`
(a bridge until HexOS storage lands, below) — first PVC-backed workload
under ArgoCD's `prune: true`, so its reclaim policy was deliberately set to
`Retain`. Remaining, each its own follow-up:
- Add an `access_control` rule (and, per-app, either native OIDC or Cilium's
  `ExternalAuth` filter — see "Gateway API forward-auth" below) as each
  Compose workload below actually migrates into the cluster.

## Gateway API forward-auth (Cilium ExternalAuth filter)
**First use wired up 2026-09-15, not yet verified live.** Cilium added a
native, Gateway-API-standard way to delegate auth to an external service
(`ExternalAuth` HTTPRoute filter, GEP-1494) using the same `ext_authz`
protocol Authelia already speaks — shipped in **Cilium 1.20.0**, and the
cluster is now on **1.20.1** (upgraded 2026-09-15, see
[`talos/README.md`](talos/README.md#cilium-upgrade-119120-2026-09-15)).
Needed for any Compose workload below that doesn't have its own OIDC support
(most of them — NetworkOptimizer, change-detection, VictoriaLogs, etc.),
since Authelia's OIDC provider only directly helps apps that speak OIDC
themselves (like ArgoCD/Grafana).

The dashboard app below (`argocd/apps/homepage/`) is the pilot: its
`HTTPRoute` carries an `ExternalAuth` filter pointing at Authelia's
`/api/authz/ext-authz/` endpoint (field shape verified live against this
cluster's CRDs, see the comment in `homepage/httproute.yaml`), plus the
`access_control` rule and `ReferenceGrant` it needs
(`argocd/apps/authelia/application.yaml` and `referencegrant.yaml`). Not yet
confirmed working end-to-end post-sync — external curl `home.jakerobb.org`
after it syncs, same discipline as the Cilium upgrade itself, before trusting
it. Assumes Authelia's `ext-authz` authz endpoint works with zero explicit
`server.endpoints.authz` config (per Authelia's docs and a working reference
elsewhere) — if that assumption's wrong, that's the first thing to check.
Once confirmed, add the same filter to each other protected app's
`HTTPRoute` as it migrates. Second use added 2026-09-18 for the new
`argocd/apps/searxng/` app (same filter/`access_control`/`ReferenceGrant`
pattern) — also not yet confirmed live post-sync.

## Compose workload migration
**Not started — deliberately held until the cluster itself is robust**
(Jake's call, 2026-09-18): monitoring, alerting, log aggregation, and the
open storage/backup items above should land first, so a migrated workload
isn't the thing that finds the gaps. Move each service off the RPi5 16GB's
Docker Compose stack (`~/docker/docker-compose.yml` on rpi5-1) into the
cluster, one at a time, in separate conversations — per-item notes below on
what's known/suspected about hardware pinning going in, not a final answer.

- **NetworkOptimizer** (`optimizer` + `network-optimizer-speedtest`) — no
  hardware dependency, network-based app. Needs a persistent volume (SQLite,
  configs, license under `./data`) — `local-path-provisioner` (above) or the
  eventual HexOS storage. Already identified as an SSO candidate (only has a
  single shared `APP_PASSWORD` today) — see "Gateway API forward-auth"
  above.
- **change-detection.io** (`change-detection` + its `browserless` dependency)
  — no hardware dependency. Needs a persistent volume for the datastore.
  Same SSO story as NetworkOptimizer (basic-auth only, no OIDC).
- **Observability stack** (`influxdb`, `grafana`, `telegraf`, `unpoller`) —
  **decided (2026-09-18): not migrated as-is.** Superseded by whatever comes
  out of the "Metrics" item above instead of running two parallel
  timeseries stacks — see that section for the current direction. Where
  reasonably easy, migrate the existing InfluxDB history into the new stack
  for continuity (not required, per Jake). `unpoller` (UniFi metrics →
  InfluxDB) will need an equivalent pointed at whatever replaces it.
  Whichever tool ends up as the dashboard has native OIDC support (Grafana
  does today), so it's a clean Authelia win either way.
- **NUT UPS monitoring** (`nut-upsd`, `nut-webui`, `nut-influx-relay`) —
  `nut-upsd` needs direct USB access to the UPS and almost certainly has to
  stay Pi-pinned; `nut-webui` and `nut-influx-relay` only talk to it over the
  network, though, so those two could plausibly migrate independently even
  if `nut-upsd` doesn't.
- **Home automation stack** (`homeassistant`, `zigbee2mqtt`, `zwave-js-ui`,
  `matter-server`, `mosquitto`) — mostly hardware-pinned (Zigbee/Z-Wave USB
  dongles, Bluetooth via `dbus`, serial UART for `homeassistant`) and
  coupled to each other via MQTT. May end up staying on the Pi long-term
  rather than migrating; worth a dedicated conversation to figure out
  whether anything can split off (e.g. does `homeassistant` itself need to
  stay just because the dongles do?).
- **scrypted** — camera/NVR bridge; confirm whether it depends on
  host-level USB or hardware-accelerated transcoding before assuming it can
  move.
- **modbus-controller** — custom app talking to Modbus-over-Ethernet
  devices; likely fine to migrate (network-based, no obvious hardware pin)
  but confirm.
- **ntfy** — **done 2026-09-20**, see
  [`argocd/README.md`](argocd/README.md#ntfy-migrated-from-docker-compose-2026-09-20).
- **Not migration candidates:** `victorialogs` + `vector` are the intended
  destination for the existing "Log aggregation" TODO item below (cluster
  logs get shipped *to* them, they don't move); `watchtower` and `ofelia`
  have no direct k8s equivalent (image-update automation and cron become
  ArgoCD/`CronJob`-native concerns respectively, not lift-and-shifts) —
  `watchtower`'s half is now done, see
  [`argocd/README.md`](argocd/README.md#renovate-dependency-updates-decided-and-deployed-2026-09-16);
  `caddy` is the Pi's reverse proxy for everything above — it just shrinks
  and eventually retires as workloads move onto the Cilium Gateway, rather
  than being "migrated" itself.

## Metrics (Prometheus + timeseries DB)
**Instant metrics and querying both done, remote-write not started.**
`metrics-server`
([`argocd/README.md`](argocd/README.md#metrics-server-decided-and-deployed-2026-09-17))
covers the Kubernetes Metrics API (`kubectl top`). Turns out that alone
wasn't enough for OpenLens's own graphs/usage bars — those are Prometheus-
backed specifically, confirmed directly by OpenLens itself when it wasn't
there yet — so `kube-prometheus-stack`
([`argocd/README.md`](argocd/README.md#kube-prometheus-stack-decided-and-deployed-2026-09-17))
was added too (Grafana and Alertmanager both off — see the "Alerting" item
below for the latter). Still open: remote-writing to a proper timeseries
database rather than relying on Prometheus's own short-lived (10-day) local
storage. VictoriaMetrics is the natural pairing given VictoriaLogs is
already running on the 16GB Pi for logs (see below).

**Decided (2026-09-18):** this — not a lift-and-shift of the Compose stack's
InfluxDB/Grafana — is what replaces that stack; see "Observability stack"
under "Compose workload migration" below. Leaning toward staying in the
VictoriaMetrics family (VictoriaMetrics here + VictoriaLogs, already
running, + possibly VictoriaTraces for tracing) over Grafana's own
Mimir/Loki/Tempo ("LGTM") stack, mainly for resource footprint on this
hardware — not locked in yet. Existing InfluxDB history isn't a priority to
preserve, but a best-effort migration into whatever lands here is worth
attempting for continuity if it turns out to be reasonably easy.

## Alerting
**Done 2026-09-20.** `kube-prometheus-stack`'s Alertmanager is enabled,
routed through the `ntfy-alertmanager` bridge to `ntfy`'s `homelab-alerts`
topic — see
[`argocd/README.md`](argocd/README.md#kube-prometheus-stack-decided-and-deployed-2026-09-17).
Only `severity` is mapped to ntfy priority/tags today
([`manifests/ntfy-alertmanager/configmap.yaml`](manifests/ntfy-alertmanager/configmap.yaml)).

## rpi5-1 mail-alert reliability (msmtpq)
**Not started**, merged in from README.md's checklist (2026-09-18). The
`etcd-snapshot-backup.sh` cron job on rpi5-1 emails failures via `msmtp`
(see [`docs/email-alerts.md`](docs/email-alerts.md)), but `msmtp` sends
synchronously with no retry/queue — an ISP outage exactly when the 3:15 AM
cron fires would silently drop the alert. Fix: install `msmtpq` (bundled
with `msmtp`, a lightweight file-based queue wrapper reusing the same
config). Low priority given how narrow the overlap window is. Deliberately
**out of scope for in-cluster alerting** above — this path exists
specifically to survive a cluster outage, so it stays on rpi5-1 independent
of cluster health.

## Log aggregation
**Not started.** Ship pod and node logs off-cluster to the existing
VictoriaLogs instance already running on the 16GB Pi, rather than logs only
being reachable via `kubectl logs` per-pod. Homepage
(`argocd/apps/homepage/`) is deliberately configured `LOG_TARGETS: stdout`
(no log file) on the assumption this eventually collects it — worth
revisiting every new app's logging config once a collector (Vector, most
likely, since it's already what feeds VictoriaLogs on the Pi side per the
Compose migration notes above) is actually running in-cluster.

## Homepage dashboard widgets
**Done (2026-09-18).** Weather (Open-Meteo), Proxmox host CPU/mem, HexOS/TrueNAS
disk usage, and UniFi Controller (top-bar uptime/WAN/LAN/WLAN status) are
all wired in and confirmed working
(`argocd/apps/homepage/configmap.yaml` + `deployment.yaml`), secrets
encrypted
(`argocd/secrets/{proxmox-api-token,truenas-api-key,unifi-credentials}.homepage.sops.yaml`).
Confirmed hosts: `https://proxmox.lan:8006` (node name still the terraform
*default*, `proxmox_node_name` — unconfirmed), `http://truenas.lan` for the
widget's own API calls vs. `https://deck.hexos.com/dash` for the tile's
click-through link (two different things — see the comment in
configmap.yaml). Remember to `sops -d ... | kubectl apply -f -` each once
pushed (no KSOPS yet, applied out-of-band like every other secret here).

**Explicitly deferred:** rpi5-1 CPU/mem via Glances — would need a new
Glances service added to `docker-compose/`, reachable from the cluster over
the LAN. Skipped for now at Jake's call, revisit later.
