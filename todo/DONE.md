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
restoring the P3 Plus data from B2 (done, 2026-09-20) and the mail-alerting queue gap found along the way (done, 2026-09-25; see below).

## rpi5-1 mail-alert reliability (msmtpq)

**Done (2026-09-25).** rpi5-1's `sendmail` is now a thin wrapper around Debian's bundled `msmtpq`
([`../scripts/msmtpq/`](../scripts/msmtpq/)), installed with `dpkg-divert` so `msmtp-mta` upgrades can't undo it. When
the relay is unreachable, cron `MAILTO` alerts (such as the etcd-backup failure alert) are queued instead of dropped,
and a `*/15` cron job flushes the queue. Kept deliberately on rpi5-1, independent of the cluster. Verified by queueing
a send through a stub that always fails, then flushing it, and by sending end-to-end through cron's real `MAILTO` path.
Details: [`../docs/email-alerts.md`](../docs/email-alerts.md#queuing-when-the-relay-is-unreachable-msmtpq).

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

**NFS / ReadWriteMany path completed (2026-09-25).** `hexos-nfs` `StorageClass` from a second democratic-csi release
([`../argocd/apps/democratic-csi-nfs/`](../argocd/apps/democratic-csi-nfs/application.yaml), `freenas-api-nfs` driver):
one dataset + export per PVC under `data/k8s-nfs`, `maproot=root` + `0777`, Server-VLAN-only exports, `Retain`, NFSv4.2,
same SELinux `context=` label and standalone registrar as the iSCSI release. Existing data (`data/shared`) is reached via
a static PV through the same driver instead. Usage, caveats, and the verification procedure are in
[`../docs/nfs-storage.md`](../docs/nfs-storage.md). Verified end-to-end on deploy: two pods on different workers (one
non-root with `fsGroup`, one root) reading each other's files, root `chown` working, refquota enforced at the PVC size
(`Disk quota exceeded` with incompressible data — zeros compress away and don't hit it), dataset/share comments set to
`<namespace>/<pvc>`, a read-only static PV on `data/shared` from the third worker with `supplementalGroups: [3003]`, no
AVC denials on any worker, and the driver's `DeleteVolume` removing its dataset and export cleanly.

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

## Homepage TrueNAS widget: JSON-RPC API

**Done (confirmed 2026-09-23).** Was parked in FUTURE waiting for Homepage support for HexOS/TrueNAS's JSON-RPC 2.0 /
WebSocket API, because the REST API is removed in HexOS v26.04. Homepage added that support in January 2026
([gethomepage/homepage#6161](https://github.com/gethomepage/homepage/pull/6161), widget `version: 2`). It ships in
v2.4.0, which is what's deployed, and [`../manifests/homepage/configmap.yaml`](../manifests/homepage/configmap.yaml)
already sets `version: 2` on the `truenas` widget. Homepage's logs showed no TrueNAS errors over 24h, so the widget is
already on the new API and a HexOS upgrade past 26.04 won't break it.

## GHA Terraform automation

**Done (2026-09-24).** `terraform/proxmox` is planned on every PR that touches it and applied on merge to `main`, by
[`../.github/workflows/terraform-proxmox.yml`](../.github/workflows/terraform-proxmox.yml), with plan/apply output in
the job summary. It runs on a self-hosted runner on the jump box, not in-cluster via ARC, because this Terraform
manages the VMs the cluster's workers run on. The runner runs as an unprivileged `gha-runner` user with its own age key,
which can decrypt only `terraform/**/secrets`. State moved from local disk on rpi5-1 to the B2 bucket
`jakerobb-homelab-tfstate`. B2 can't do Terraform's native state locking, so `tf.sh` takes a host-level `flock`
instead, and all runs happen on the jump box. The public repo is protected by running the plan job only for same-repo
PRs and requiring approval for all outside contributors' workflow runs. The first CI applies were no-ops, as expected.
Runbook: [`../docs/gha-terraform.md`](../docs/gha-terraform.md).

The same effort added a `lint` workflow ([`../.github/workflows/lint.yml`](../.github/workflows/lint.yml),
GitHub-hosted, no secrets) with four checks: every `*.sops.*` file is really encrypted
([`../scripts/ci/check-sops-encrypted.py`](../scripts/ci/check-sops-encrypted.py)), the Renovate config is valid in
strict mode, and `shellcheck` and `actionlint` pass.

## CI: render and validate Kubernetes manifests

**Done (2026-09-24).** The `Kubernetes manifests` job in [`../.github/workflows/lint.yml`](../.github/workflows/lint.yml)
runs [`../scripts/ci/render-manifests.py`](../scripts/ci/render-manifests.py) to render everything ArgoCD would apply,
then validates the output with `kubeconform` against Kubernetes and CRD schemas (Gateway API, cert-manager, Cilium, and
so on). The script runs `helm template` on each Helm-based Application under `argocd/apps/` with its own
chart/version/values, and includes the raw YAML under `manifests/` as well. The payoff is that a breaking Renovate chart
bump now fails on its PR instead of showing up after merge as an unhealthy ArgoCD app. The job passed on the PR that
added it ([#17](https://github.com/jakerobb/homelab/pull/17)) and on the merge to `main`. It runs on a GitHub-hosted
runner and needs no secrets.

## Alertmanager inhibit_rules cascade

**Done (2026-09-24). It turned out to be live all along.** The todo item assumed the repo had no `inhibit_rules`, but
the live Alertmanager config already had all four of the chart's default rules. `alertmanager.config` in
`kube-prometheus-stack`'s values is a map that Helm deep-merges, and this repo's `config:` never set `inhibit_rules`,
so the chart's defaults stayed in effect. The rules are now written out explicitly in
[`../argocd/apps/kube-prometheus-stack/application.yaml`](../argocd/apps/kube-prometheus-stack/application.yaml),
identical to the defaults (confirmed by rendering the chart), so a future chart bump can't change them without showing up
in a diff. The comment there explains what each rule does. The main difference from the version sketched in the old todo
item: the critical→warning and warning→info rules match on `alertname` as well as `namespace`, so an unrelated critical
alert doesn't hide a different warning. Info alerts only notify when a warning or critical alert is firing in the same
namespace, which is how the `InfoInhibitor` rule is designed to work.

## Descheduler

**Done (2026-09-24). Goes live when merged.** [`kubernetes-sigs/descheduler`](https://github.com/kubernetes-sigs/descheduler)
chart 0.36.0, in [`../argocd/apps/descheduler/application.yaml`](../argocd/apps/descheduler/application.yaml). It exists
because Kubernetes never rebalances pods that are already running. On 2026-09-22, draining `talos-worker-mbp` for a Talos
reinstall pushed SigNoz's ClickHouse and ZooKeeper onto `talos-worker-1` and `talos-worker-2`. Those two sat at 80-82%
memory while `-mbp` sat at 7%, and the fix was deleting the pods by hand. The comment in the Application covers the full
reasoning. The main decisions:

- **Real usage, not requests.** `LowNodeUtilization` looks at requests unless you tell it otherwise. That is the same
  math the scheduler uses, and it's what caused the problem: the workers were 12-38% *requested* but 78-80% *used*.
  Here it reads real usage from metrics-server instead (`metricsUtilization.source: KubernetesMetrics`).
- **Conservative settings.** It runs as a CronJob at 03:30 America/Detroit, only against worker nodes, with only
  `LowNodeUtilization` and `RemoveDuplicates`. Each run evicts at most 2 pods per node and 3 in total. A node counts as
  underused below 35% on both CPU and memory, and as overloaded above 70% on either one.
- **Stateful pods can be evicted.** All PVCs are on `hexos-iscsi`, so a pod with a volume can move to another node. The
  single-replica ones (ClickHouse, ZooKeeper, Prometheus, Authelia, ntfy) have a short outage while the volume
  re-attaches, which is acceptable at 3:30am. The chart's default protection for local storage is turned off because
  it treats emptyDir as local storage, and ClickHouse, `signoz-0`, Prometheus and most of ArgoCD mount one. Left on, it
  would protect exactly the pods this exists to move. System-critical and DaemonSet pods are still protected.
- **No new PDBs.** For a single replica, `minAvailable: 1` would block both descheduler and `kubectl drain`. The existing
  ClickHouse PDB (`maxUnavailable: 1` on one replica) never blocks anything and was left as is.
- **No ServiceMonitor.** The Job only runs for a few seconds, so Prometheus would never scrape it. To see what it did,
  look for Events with reason `Descheduled`, or read the pod logs from the last few Jobs in the `descheduler` namespace.

Checked before merge by building v0.36.0 and running it with `--dry-run` from rpi5-1 against the live cluster, using
the exact policy. With today's usage (workers ~57%, `-mbp` ~25%) it correctly decided there was nothing to do. With
the overload threshold lowered to 50% in a scratch copy, it picked evictions from both small workers and stopped at the
per-node and per-run caps. One behaviour to know about: within a node, pods are evicted in order of lowest priority,
then QoS class (BestEffort first), not largest first. After a big imbalance it can take a few nights to settle, and the
largest pod isn't guaranteed to be the one that moves. The real fix for that is accurate requests, done in "Audit app
memory requests against real usage" below.

## Audit app memory requests against real usage

**Done and live (2026-09-24).** Merged in [#21](https://github.com/jakerobb/homelab/pull/21); the manual steps
(Cilium sync, ArgoCD `helm upgrade`, Talos patch on all three control planes) were applied the same day. The rollout
was interrupted when `talos-worker-mbp` froze partway through (see "Mac host disk alert" below) and finished after it
recovered. Requests were compared against 7 days of
Prometheus history per workload (`container_memory_working_set_bytes` and CPU usage against
`kube_pod_container_resource_requests`), not a single `kubectl top` reading. Before: about 40 containers had no requests
at all, and the cluster requested 7.4Gi total while using far more. The rule used: memory request just above the 7-day
peak, memory limit (where one exists) about 1.5-2x the request, CPU request about p95. No limits were added to
cluster-critical components (Cilium, kube-apiserver), because an OOM kill there is an outage.

What changed:

- **Real problems fixed.** SigNoz's otel-collector was OOM-killed at its 1Gi limit (now 768Mi request / 2Gi limit).
  ZooKeeper sat at ~475Mi against a 512Mi limit (now 512Mi / 1Gi).
- **Big unrequested workloads.** Cilium agent/envoy/operator (`talos/cilium/values.yaml`), Prometheus (2Gi), all of
  ArgoCD (`argocd/install/values.yaml`), SigNoz's k8s-infra otel agent (was the chart's 100Mi, real 65-386Mi by node),
  democratic-csi, cert-manager, external-dns, kube-state-metrics, node-exporter, the prometheus-operator and its
  config-reloader sidecars, local-path-provisioner.
- **Control-plane static pods.** New Talos patch
  [`../talos/patches/control-plane/control-plane-resources.yaml`](../talos/patches/control-plane/control-plane-resources.yaml):
  kube-apiserver 512Mi -> 1536Mi (real 1.3-1.4Gi), controller-manager 256Mi -> 192Mi, scheduler 64Mi -> 96Mi.
- **Small corrections.** Up: authelia, homepage, searxng, ntfy, renovate. Down: headlamp, metrics-server.
- **Left alone.** ClickHouse: its 7-day numbers (CPU throttled, 2.5Gi peak) were from before the 2026-09-23 CPU tuning;
  since then it peaks at 1.35Gi and ~0.2 cores, well inside 2Gi / 500m. The ClickHouse operator's two containers
  (~100Mi together) still have no requests, because the signoz chart has no values key for them. One-shot hook Jobs too.

Consequences worth knowing:

- Projected memory requests with today's placement: control planes 86-90%, worker-1 86%, worker-2 ~97%, mbp 22%. The
  biggest waste on the Pis is the otel agent's 384Mi (sized for mbp's pod count; it uses ~65Mi on a Pi), since a
  DaemonSet can't have per-node requests. If a new DaemonSet ever won't fit on the control planes, look there first.
- With honest requests the scheduler now knows worker-1/-2 are nearly full, so restarted pods will land on mbp. That is
  the intended outcome, but it also means removing `talos-worker-mbp` before the Mac Studio arrives would leave pods
  Pending, where before it would have silently over-packed the small workers.
- The descheduler's `nodeFit: true` checks requests, so its eviction decisions are more accurate now too.
- `KubeMemoryOvercommit` started firing (and did daily): total requests (21.9GiB) exceed what's left if the largest
  node is lost (39.4 - 23.0 = 16.4GiB). That's true, not a bad rule: mbp holds ~58% of cluster memory, and even
  perfectly sized requests (~13.8GiB real usage) would sit just under the line. Routed to Alertmanager's `null`
  receiver on 2026-09-25 until the Mac Studio joins (see `FUTURE.md`).
- In hindsight, sizing requests at the 7-day *peak* overshot. p95 is the usual basis, with limits or headroom
  covering spikes. The biggest overshoots are per-node DaemonSets sized for mbp (otel-agent 384Mi and cilium-envoy
  128Mi on every node) and the apiserver at 1536Mi. Trimming them is deferred (see `FUTURE.md`).

## Mac host disk alert

**Done and live (2026-09-24).** Merged in [#22](https://github.com/jakerobb/homelab/pull/22) (plus
[#24](https://github.com/jakerobb/homelab/pull/24) for a Telegraf warning), and the MacBook re-bootstrapped;
Prometheus shows the `mac-hosts` target up and both rules loaded. Prompted by
`talos-worker-mbp` going NotReady mid-rollout the same day. The UTM VM's disk file only grows on the Mac as the VM
writes to it. A burst of ~15 image pulls grew it until the MacBook Pro's disk filled, and QEMU paused the VM ("No
space left on device"). Kubelet's image cleanup can't catch this, because it measures the VM's 66GB virtual disk, not
the Mac's free space. Recovery added a second problem: the Talos install ISO had never been detached from the VM
([`../docs/utm-talos-worker.md`](../docs/utm-talos-worker.md) step 7) and was still first in boot order, so deleting
it to free space and then re-attaching it booted the VM into Talos's `haltIfInstalled` guard. Removing the CD drive
fixed that.

The Mac's Telegraf was already reporting the problem to SigNoz: 99.6-99.9% used, under 1GB free, from at least 10:30
that morning. Nothing alerted on it, because SigNoz has no alerting wired up. The fix sends the same metrics to
Prometheus as well:

- Telegraf ([`../scripts/mac-host-metrics/telegraf.conf`](../scripts/mac-host-metrics/telegraf.conf)) gets an
  `outputs.prometheus_client` on `:9273`, alongside its existing OTLP output.
- kube-prometheus-stack scrapes it as the `mac-hosts` job, a static target at the Mac's new DHCP reservation
  `192.168.102.9` (it had been on a `.203` lease).
- `MacHostDiskSpaceLow` fires through Alertmanager → ntfy: warning below 40GiB free for 15 minutes, critical below
  15GiB for 5. Both share an alertname, so the critical one inhibits the warning. A failed scrape shows up as the
  chart's existing `TargetDown` alert.

Runbook: [`../docs/mac-host-metrics.md`](../docs/mac-host-metrics.md) ("Where the data goes", plus a new verification
step for the endpoint and the macOS firewall).

## Cluster secrets via 1Password + External Secrets Operator

**Done and live (2026-09-25).** Merged in [#27](https://github.com/jakerobb/homelab/pull/27). Replaced the old KSOPS
item. Every SOPS file under `argocd/secrets/` used to be applied by hand (`sops -d ... | kubectl apply -f -`) because
ArgoCD couldn't decrypt it. External Secrets Operator now syncs every cluster Secret from a dedicated `homelab-k8s`
1Password vault, using a read-only service account. We chose that over KSOPS, which would have needed the age
private key in-cluster plus Kustomize. Design and runbooks: [`../argocd/README.md`](../argocd/README.md#external-secrets-operator-decided-and-deployed-2026-09-24).

- A one-shot script copied the 16 SOPS files into 13 1Password items, straight from `sops -d` into `op item create`,
  then read every field back to confirm it matched. The two Cloudflare copies were the same token, so they became one
  item. `truenas-api-key.sops.yaml` was never applied and was dead, because democratic-csi embeds the key in its
  driver config. That config is now an ESO template in git, with only the key coming from 1Password. The SigNoz admin
  login went to Jake's Private vault, since nothing in the cluster reads it.
- At cutover, all 14 ExternalSecrets adopted their existing Secrets in place. Every value was checked against its
  SOPS source, and all matched. The `kubectl.kubernetes.io/last-applied-configuration` annotations, which held
  plaintext copies from `kubectl apply`, were stripped afterwards.
- First-sync gotcha: the ExternalSecrets reconciled a few seconds before the `ClusterSecretStore` turned Valid, so
  they all failed and went into retry backoff. A `force-sync` annotation on each fixed it at once.
- ArgoCD's OIDC client secret is now a `$argocd-oidc-authelia:clientSecret` reference, so ArgoCD `helm upgrade`s no
  longer need the SOPS values fragment.
- `argocd/secrets/` now holds only `onepassword-service-account.sops.yaml`, the ESO token that has to be bootstrapped
  by hand.
