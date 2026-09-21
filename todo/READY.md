# READY

Cluster-readiness backlog — each of these is its own effort, meant to be tackled separately rather than all at once.
This list is in roughly priority order. "Compose workload migration" is deliberately last; we want a stable, robust,
observable cluster before we bring in critical workloads.

## GHA Terraform automation

Pull requests should trigger a `terraform plan`; merges to `main` should trigger `terraform apply`. 

## Log and Metrics aggregation

Ship pod and node logs to a long-term log aggregator rather than logs only being reachable via `kubectl logs` per-pod.
`metrics-server` and `kube-prometheus-stack` are already deployed and covering instant metrics/querying, but Prometheus
only has its own short-lived (10-day) local storage — remote-writing to a proper timeseries database is still open. This
will replace the observability stack running on the Pi. Re-evaluate what solutions make the most sense in K8s.

## ArgoCD-native SOPS decryption (KSOPS)

Every SOPS-encrypted secret under `argocd/secrets/` is currently applied out-of-band by hand
(`sops -d ... | kubectl apply -f -`) before an Application can go healthy — ArgoCD itself has no way to decrypt them, a
gap already noted in [`../argocd/README.md`](../argocd/README.md) and hit concretely setting up `democratic-csi`'s
driver-config secret. KSOPS (`viaduct-ai/kustomize-sops`) is the standard fix: an initContainer on `repo-server`
decrypts SOPS files as part of the Kustomize build. Real tradeoffs to weigh before doing it, not just a config toggle:
the age *private* key would need to live in-cluster (currently only Jake's Mac + 1Password have it — this expands blast
radius if `repo-server` is ever compromised), and every existing secret file would need restructuring from a standalone
applied `Secret` into a Kustomize-generator reference, introducing Kustomize into a repo that's so far been pure
raw-YAML + Helm `valuesObject`.

## rpi5-1 mail-alert reliability (msmtpq)

**Not started**, merged in from README.md's original hardware-migration checklist (2026-09-18). The
`etcd-snapshot-backup.sh` cron job on rpi5-1 emails failures via `msmtp` (see [
`../docs/email-alerts.md`](../docs/email-alerts.md)), but `msmtp` sends synchronously with no retry/queue — an ISP
outage exactly when the 3:15 AM cron fires would silently drop the alert. Fix: install `msmtpq` (bundled with `msmtp`, a
lightweight file-based queue wrapper reusing the same config). Low priority given how narrow the overlap window is.
Deliberately **out of scope for in-cluster alerting** — this path exists specifically to survive a cluster outage, so it
stays on rpi5-1 independent of cluster health.

## HexOS storage

**Not started.** An NFS-backed `StorageClass` for genuinely ReadWriteMany workloads (media libraries, etc.) — the
`hexos-iscsi` `StorageClass` already in place is iSCSI/block storage, which can't do RWX. HexOS's `data/shared` NFS
export already exists and is usable manually; this is about wiring a real dynamically-provisioned `StorageClass` for it.

## Compose workload migration

**Not started — deliberately held until the cluster itself is robust**
Move each service off the RPi5 16GB's Docker Compose stack into the cluster, one at a time, in separate sessions. For
each, consider whether a more K8s-appropriate or K8s-native alternative exists. Each application should be a separate
ArgoCD Application resource. Put each application behind Authelia -- using OIDC if possible; ExternalAuth filtering
otherwise. Persistent storage moves from the Pi to democratic-csi PVC.

### Do not migrate

- **Observability stack** (`influxdb`, `grafana`, `telegraf`, `victorialogs`, `vector`) - Superseded by whatever comes
  out of the "Log and Metrics aggregation" item instead of running two parallel timeseries stacks — see that section for
  the current direction. Where reasonably easy, migrate the existing InfluxDB history into the new stack for continuity
  (not required, per Jake).
- **Watchtower** — obviated by Renovate
- **Ofelia** — replaced by K8s CronJobs
- **Caddy** — obviated by Cilium Gateway

### To be migrated

- **Unpoller** (UniFi metrics aggregation) — probably switching from InfluxDB as a target to Prometheus
- **NetworkOptimizer** (`optimizer` + `network-optimizer-speedtest`) — no hardware dependency, network-based app. Needs
  a persistent volume (SQLite, configs, license under `./data`)
- **change-detection.io** (`change-detection` + its `browserless` dependency) — no hardware dependency. Needs a
  persistent volume for the datastore.
- **NUT UPS monitoring** (`nut-upsd`, `nut-webui`, `nut-influx-relay`) —
  `nut-upsd` needs direct USB access to the CyberPower UPS and almost certainly has to stay Pi-pinned; `nut-webui` and
  `nut-influx-relay` only talk to it over the network, though, so those two could plausibly migrate independently even
  if `nut-upsd` doesn't.
- **Home automation stack** (`homeassistant`, `zigbee2mqtt`, `zwave-js-ui`,
  `matter-server`, `mosquitto`) — none hardware-pinned; ZWave and Zigbee integrations are all network-based.
- **scrypted** — camera/NVR bridge
- **modbus-controller** — custom app talking to a Modbus-over-Ethernet device
