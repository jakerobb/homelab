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
**Core work done — started 2026-09-13, iSCSI path completed 2026-09-15.**
Pool (`data`, striped, ~6TB usable) created, iSCSI service enabled with a
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

**Remaining, deliberately deferred to its own conversation (2026-09-15):**
moving InfluxDB's datastore onto `hexos-iscsi` — the original motivating
case (NFS isn't safe for its embedded bbolt store) — is a big enough lift
(likely its own data-migration dance, unlike Authelia's clean-start path)
to warrant fresh context rather than folding into this one. Also still
open: restore the P3 Plus data from B2, and a separate, later addition of
an NFS-backed StorageClass for genuinely ReadWriteMany workloads (media
libraries, etc.), which iSCSI/block storage can't do.

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
- Currently only local admin + Authelia; no group/role mapping into ArgoCD
  RBAC (`argocd-rbac-cm`) — anyone who authenticates via Authelia gets
  whatever ArgoCD's default policy grants. Worth revisiting once there's
  more than one Authelia user.

## Cilium: drop the upgradeCompatibility flag
**Not started.** `talos/cilium/values.yaml` sets `upgradeCompatibility: "1.19"`,
added 2026-09-16 so ArgoCD's render of the `cilium` Application matched the
one-time `--set upgradeCompatibility=1.19` flag used on the manual 1.19→1.20
`helm upgrade` the day before (2026-09-15, see
[`talos/README.md`](talos/README.md#cilium-upgrade-119120-2026-09-15)). Keeps
`envoy-xds-mode` unset (agent's legacy-safe default) instead of the chart's
new 1.20+ default of `"ads"`. Once 1.20.1 has been running stable for a
while, remove the key from `cilium/values.yaml` and Sync (see
[`argocd/apps/cilium/`](argocd/apps/cilium/application.yaml)) — plain
no-op-except-for-that-one-key change. Verify with
[`talos/cilium/validate.sh`](talos/cilium/validate.sh) afterward, same as
any other Cilium sync.

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
`HTTPRoute` as it migrates.

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
  ArgoCD/`CronJob`-native concerns respectively, not lift-and-shifts) —
  `watchtower`'s half is now done, see
  [`argocd/README.md`](argocd/README.md#renovate-dependency-updates-decided-and-deployed-2026-09-16);
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
being reachable via `kubectl logs` per-pod. Homepage
(`argocd/apps/homepage/`) is deliberately configured `LOG_TARGETS: stdout`
(no log file) on the assumption this eventually collects it — worth
revisiting every new app's logging config once a collector (Vector, most
likely, since it's already what feeds VictoriaLogs on the Pi side per the
Compose migration notes above) is actually running in-cluster.

## Homepage dashboard widgets
**Requested 2026-09-16, nearly done.** Weather (Open-Meteo), Proxmox host
CPU/mem, and HexOS/TrueNAS disk usage are fully wired in
(`argocd/apps/homepage/configmap.yaml` + `deployment.yaml`), secrets
encrypted and staged (`argocd/secrets/{proxmox-api-token,truenas-api-key}.homepage.sops.yaml`).
Confirmed hosts: `https://proxmox.lan:8006` (node name still the terraform
*default*, `proxmox_node_name` — unconfirmed), `http://truenas.lan` for the
widget's own API calls vs. `https://deck.hexos.com/dash` for the tile's
click-through link (two different things — see the comment in
configmap.yaml). Remember to `sops -d ... | kubectl apply -f -` both once
pushed (no KSOPS yet, applied out-of-band like every other secret here).

Still open:
- **UniFi Controller** (top-bar info widget: uptime/WAN/LAN/WLAN status) —
  wiring is done (`argocd/apps/homepage/configmap.yaml`'s `unifi_console`
  block + `deployment.yaml`), waiting on Jake to generate an API key in the
  UniFi Network application and fill in
  `argocd/secrets/unifi-credentials.homepage.sops.yaml` (still an unencrypted
  placeholder template — encrypt with `sops -e -i` once filled in, same as
  the other two were).

**Explicitly deferred:** rpi5-1 CPU/mem via Glances — would need a new
Glances service added to `docker-compose/`, reachable from the cluster over
the LAN. Skipped for now at Jake's call, revisit later.
