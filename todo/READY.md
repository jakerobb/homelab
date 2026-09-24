# READY

Cluster-readiness backlog — each of these is its own effort, meant to be tackled separately rather than all at once.
This list is in roughly priority order. "Compose workload migration" is deliberately last; we want a stable, robust,
observable cluster before we bring in critical workloads.

## CI: render and validate Kubernetes manifests

**In progress (2026-09-24).** Implemented as the `Kubernetes manifests` job in `lint.yml` plus
[`../scripts/ci/render-manifests.py`](../scripts/ci/render-manifests.py); move to DONE.md once it's green on a PR. Follow-on to the GHA work (see DONE.md). Add a job to the `lint` workflow
([`../.github/workflows/lint.yml`](../.github/workflows/lint.yml)) that `helm template`s each Helm-based ArgoCD
Application under `argocd/apps/` with its own chart/version/`valuesObject`, and runs the output plus the raw YAML under
`manifests/` through `kubeconform` (Kubernetes schemas plus CRD schemas for Gateway API, cert-manager, Cilium, etc.).
Main payoff: Renovate's chart-bump PRs currently only reveal a breaking change after merge, when ArgoCD goes unhealthy;
this would catch it on the PR. Needs a small script to pull chart repo/name/version/values out of each
`application.yaml`. GitHub-hosted runner, no secrets needed.

## Alertmanager InfoInhibitor: full inhibit_rules cascade

**Partially done.** `argocd/apps/kube-prometheus-stack/application.yaml` routes `InfoInhibitor` to the `null` receiver
(2026-09-22, stops it from notifying ntfy — see the `Watchdog`-adjacent route), but that's only half of what the alert's
own annotation says it's for: "should be routed to a null receiver **and configured to inhibit alerts with
severity=info**." The actual inhibition (an info-level alert firing alongside something more severe in the same
namespace shouldn't also notify separately) needs a real `inhibit_rules` block, which this repo doesn't have at all yet.
Standard kube-prometheus-stack pairing for this is roughly:
```yaml
inhibit_rules:
  - source_matchers: ['severity = critical']
    target_matchers: ['severity =~ warning|info']
    equal: ['namespace']
  - source_matchers: ['severity = warning']
    target_matchers: ['severity = info']
    equal: ['namespace']
  - source_matchers: ['alertname = InfoInhibitor']
    target_matchers: ['severity = info']
    equal: ['namespace']
```
Not added yet — worth confirming this doesn't unexpectedly swallow something currently useful before turning it on.

## Descheduler

**Not started.** Kubernetes never rebalances already-running pods — the scheduler only places new/pending pods, so
whatever a cordon/drain scatters stays scattered even after the drained node comes back with room to spare. Surfaced
concretely 2026-09-22: draining `talos-worker-mbp` for a Talos reinstall (see
[`talos/README.md`](../talos/README.md#additional-worker-talos-worker-mbp-added-2026-09-22)) pushed SigNoz's ClickHouse
and ZooKeeper onto the much smaller `talos-worker-1`/`talos-worker-2` (Proxmox, 4GB each), which then sat at 80-82%
memory while `-mbp` sat at 7% — fixed by hand (`kubectl delete pod`, letting the scheduler re-place them). This will
keep happening: node capacity here is heterogeneous already (tiny Pi5 control planes, small MS-A2 workers, a
temporarily-huge MBP) and gets more so once the Mac Studio arrives, and maintenance-driven drains are routine.
[`kubernetes-sigs/descheduler`](https://github.com/kubernetes-sigs/descheduler) is the standard fix — runs periodically
(typically a `CronJob`) and evicts pods that violate configured balance strategies (e.g. `LowNodeUtilization`), letting
the scheduler redo the placement. Needs a deliberately conservative policy, not defaults — aggressive eviction can
thrash stateful pods (ClickHouse is exactly the kind of workload that shouldn't be evicted repeatedly), so this pairs
with making sure the relevant `PodDisruptionBudget`s exist first.

**Why this has to be utilization-based, not just request-based** (found the same day): `kubectl describe node` showed
`talos-worker-1`/`talos-worker-2` had only 12%/38% of memory actually *requested* at the same moment `kubectl top nodes`
showed them at 78-80% real usage — most of the existing apps already on those nodes (ArgoCD components, Cilium,
cert-manager-webhook, etc.) request far less than they actually use. The scheduler only ever sees requests, so it happily
placed ClickHouse's 2Gi request believing there was ~3GB of headroom that didn't really exist. Descheduler's
`LowNodeUtilization` strategy is the right tool specifically because it looks at real utilization, not the same
request-based math the scheduler itself already got fooled by — see "Audit app memory requests against real usage"
below, a related but separate effort.

## Audit app memory requests against real usage

**Not started.** Direct fallout from the `Descheduler` finding above — worker-1/worker-2 both had real memory usage far
above what was actually requested cluster-wide (78-80% used vs. 12-38% requested), meaning most apps here are running on
guessed-low or copy-pasted chart-default requests rather than anything measured. This isn't just cosmetic: undersized
requests are exactly what let the scheduler over-pack a node past what it can really handle (see above), and it also
means Kubernetes' OOM-kill prioritization (which weighs actual usage against requests) is working off bad data
everywhere, not just for SigNoz. Go through each app under `argocd/apps/`/`manifests/`, compare `kubectl top pod`
against its committed `resources.requests`, and correct the ones that are meaningfully off — most likely candidates are
whatever's still on chart defaults rather than something set deliberately for this cluster.

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
