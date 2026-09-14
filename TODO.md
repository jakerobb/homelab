# TODO

Cluster-readiness backlog — each of these is its own effort, meant to be
tackled in a separate conversation rather than all at once. Unlike the
hardware-migration checklist in [README.md](README.md), these aren't
sequenced — pick whichever's most useful next.

## Ingress (Gateway API)
**Done** — decided and deployed 2026-09-13, using Gateway API (Cilium's
built-in implementation) instead of a separate ingress-nginx-style
controller; see [`talos/README.md`](talos/README.md#ingress-gateway-api-decided-and-deployed-2026-09-13).
TLS decided too: cert-manager + Let's Encrypt DNS-01 against Cloudflare, real
publicly-trusted wildcard cert for `*.jakerobb.org`, plus `external-dns`
auto-creating DNS records — see [`argocd/README.md`](argocd/README.md#dns--tls-decided-2026-09-13).
First real `HTTPRoute` is ArgoCD's own UI (`argocd.jakerobb.org`).

## etcd / control-plane backups
**Local backup done (2026-09-13).** Daily `talosctl etcd snapshot` via
[`scripts/etcd-snapshot-backup.sh`](scripts/etcd-snapshot-backup.sh), stored
on rpi5-1 (`~/backups/etcd`, 30-day retention) — see
[`docs/etcd-backup.md`](docs/etcd-backup.md). Deliberately local-only for
now; shipping a copy off-box (e.g. B2, matching the P3 Plus backup pattern)
is a deferred follow-up. Restore procedure also not yet exercised — worth
testing before relying on it in a real incident.

## HexOS storage
**In progress — started 2026-09-13.** IOMMU enabled and confirmed on the
Proxmox host, both NVMe drives isolated cleanly in their own IOMMU groups,
Terraform written for the HexOS VM with passthrough — see
[`docs/hexos-install.md`](docs/hexos-install.md) and root
[README.md](README.md#5-hexos-vm-with-t500--p3-plus) step 5. Remaining: apply
the Terraform, install HexOS, set up the pool/share, restore the P3 Plus data
from B2, and — the actual goal, per discussion — wire it up as a Kubernetes
`StorageClass` (via an NFS CSI driver or similar) so workloads can get real
persistent volumes that survive a pod being rescheduled to a different node.

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
- Currently only local admin + Authelia; no group/role mapping into ArgoCD
  RBAC (`argocd-rbac-cm`) — anyone who authenticates via Authelia gets
  whatever ArgoCD's default policy grants. Worth revisiting once there's
  more than one Authelia user.

## Gateway API forward-auth (Cilium ExternalAuth filter)
**Not started — blocked on a Cilium upgrade.** Cilium added a native,
Gateway-API-standard way to delegate auth to an external service
(`ExternalAuth` HTTPRoute filter, GEP-1494) using the same `ext_authz`
protocol Authelia already speaks — but it only shipped in **Cilium 1.20.0**;
the cluster is still on **1.19.5**. Needed for any Compose workload below
that doesn't have its own OIDC support (most of them — NetworkOptimizer,
change-detection, VictoriaLogs, etc.), since Authelia's OIDC provider only
directly helps apps that speak OIDC themselves (like ArgoCD/Grafana). Two
pieces: (1) upgrade Cilium — its own tested change given the cluster's past
BGP/routing issues, not something to fold silently into an app migration;
(2) once upgraded, add an `ExternalAuth` filter to each protected app's
`HTTPRoute` pointing at Authelia's `/api/authz/ext-authz/` endpoint.

## Compose workload migration
**Not started.** Move each service off the RPi5 16GB's Docker Compose stack
(`~/docker/docker-compose.yml` on rpi5-1) into the cluster, one at a time, in
separate conversations — per-item notes below on what's known/suspected
about hardware pinning going in, not a final answer.

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
  likely superseded rather than lifted-and-shifted: the "Metrics" TODO below
  already plans VictoriaMetrics for in-cluster metrics. Worth deciding
  whether to migrate this stack as-is or fold it into that effort instead of
  running two parallel timeseries stacks. Grafana itself has native OIDC
  support, so it's a clean Authelia win whichever way storage goes.
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
- **ntfy** — push notification server; straightforward migration candidate,
  no obvious hardware dependency.
- **Not migration candidates:** `victorialogs` + `vector` are the intended
  destination for the existing "Log aggregation" TODO item below (cluster
  logs get shipped *to* them, they don't move); `watchtower` and `ofelia`
  have no direct k8s equivalent (image-update automation and cron become
  ArgoCD/`CronJob`-native concerns respectively, not lift-and-shifts);
  `caddy` is the Pi's reverse proxy for everything above — it just shrinks
  and eventually retires as workloads move onto the Cilium Gateway, rather
  than being "migrated" itself.

## Metrics (Prometheus + timeseries DB)
**Not started.** Cluster/node/pod metrics — specifically so OpenLens's
graphs and stats actually populate — plus remote-writing them to a proper
timeseries database rather than relying on Prometheus's own short-lived
local storage. VictoriaMetrics is the natural pairing given VictoriaLogs is
already running on the 16GB Pi for logs (see below).

## Log aggregation
**Not started.** Ship pod and node logs off-cluster to the existing
VictoriaLogs instance already running on the 16GB Pi, rather than logs only
being reachable via `kubectl logs` per-pod.
