# READY

Cluster-readiness backlog — each of these is its own effort, meant to be tackled separately rather than all at once.
This list is in roughly priority order. "Compose workload migration" is deliberately last; we want a stable, robust,
observable cluster before we bring in critical workloads.

## Cluster secrets via 1Password + External Secrets Operator

**In progress (branch `external-secrets-1password`, 2026-09-24).** Replaces the old KSOPS item. Every SOPS file under
`argocd/secrets/` had to be applied by hand (`sops -d ... | kubectl apply -f -`) because ArgoCD couldn't decrypt it.
We chose External Secrets Operator reading a dedicated `homelab-k8s` 1Password vault over KSOPS. KSOPS would have
needed the age private key in-cluster and Kustomize. See
[`../argocd/README.md`](../argocd/README.md#external-secrets-operator-decided-and-deployed-2026-09-24) for the design.

Done on the branch: ESO Application (chart 2.11.0) plus `ClusterSecretStore`, 15 `ExternalSecret`s and an
`ExternalSecretNotSynced` alert in `manifests/external-secrets-config/`. ArgoCD's OIDC secret moved to a
`$secret:key` reference. democratic-csi's driver config is now a template. Docs are updated, and
`scripts/migrate-to-1password.py` is ready to run.

Remaining:
1. Run `scripts/migrate-to-1password.py`. It creates the vault, items and service account, and writes the
   encrypted token file.
2. Install ESO's CRDs and apply the token Secret (argocd/README.md, "ESO bootstrap").
3. Merge. Confirm every `ExternalSecret` is `SecretSynced` and adopted its existing Secret.
4. `helm upgrade` ArgoCD with plain `-f argocd/install/values.yaml` (drops the old SOPS values fragment). Then check
   SSO login.
5. Strip the stale `kubectl.kubernetes.io/last-applied-configuration` annotation from the adopted Secrets. `kubectl
   apply` stored every plaintext value there, and ESO doesn't remove it, so rotated values would linger in it.
6. `git rm` the 16 migrated `argocd/secrets/*.sops.yaml` files, keeping only `onepassword-service-account.sops.yaml`.
   Then move this item to DONE.md.

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

## Migrate domain names Hover -> CloudFlare

I have several domain names registered at Hover:
* jakerobb.dev -- my personal website
* soleman.ski -- Squarespace site for my father-in-law's business. I never finished it. 
* commaspacebitch.com -- a joke domain I registered twenty years ago, never used, and should stop paying for.

Just grabbed these because I could; completely unused; some forwarded to jakerobb.dev
* jakerobb.me
* robb.online
* robb.software

Reserved business opportunities:
* indigoapps.dev -- Indigo because it's the color Apple left out of its original rainbow logo; the idea was that I'd build apps Apple neglected. No specific ideas.
* fastodon.dev, fastodon.me - I was into Mastodon for a while and thought I wanted to build and host an ActivityPub server in Go rather than Ruby; it would be super performant, hence the name. 
* camaroev.net, camaro-ev.com, camaroev.org, camaroquestions.com, firebirdquestions.com, transamquestions.com, fbodyquestions.com, modyourcamaro.com -- I love Camaros and wanted to build something here. 

## Make a Documentation app/site -- docs.jakerobb.org

Serves a hyperlinked view of all the docs. What everything is, how it works, how it's connected, how to fix common 
issues, how to get access, etc. This should be behind Authelia, linked from Homepage, and deployed as an ArgoCD
application just like everything else.

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
