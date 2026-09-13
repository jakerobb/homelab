# TODO

Cluster-readiness backlog — each of these is its own effort, meant to be
tackled in a separate conversation rather than all at once. Unlike the
hardware-migration checklist in [README.md](README.md), these aren't
sequenced — pick whichever's most useful next.

## Ingress (Gateway API)
**In progress** — decided 2026-09-13 to use Gateway API (Cilium's built-in
implementation) instead of a separate ingress-nginx-style controller; see
[`talos/README.md`](talos/README.md#ingress-gateway-api-decided-2026-09-13).
CRD install steps, `cilium/values.yaml` (`gatewayAPI.enabled: true`), and
`cilium/gateway.yaml` are drafted. Remaining: confirm it's actually applied
and working end-to-end, then add TLS (cert-manager vs. a manual cert — not
yet decided) and the first real `HTTPRoute` once an app needs one.

## etcd / control-plane backups
**Not started.** No backup story exists yet for the Talos control plane's own
state — if etcd is lost (all 3 Pi control-plane nodes, or corruption), there's
currently no path back short of rebuilding the cluster from scratch. Worth
closing given how much backup discipline went into everything else on this
project (B2 for the NVMe data, the Proxmox host-config cron job).

## HexOS storage
**Not started.** Install Proxmox VM with IOMMU passthrough for the T500 (2TB)
+ P3 Plus (4TB) NVMe drives, restore the P3 Plus data from B2, expose as
NFS/SMB, and — the actual goal, per discussion — wire it up as a Kubernetes
`StorageClass` (via an NFS CSI driver or similar) so workloads can get real
persistent volumes that survive a pod being rescheduled to a different node.

## ArgoCD
**Not started.** GitOps deployment of cluster workloads from this repo (or a
paired one) instead of manual `kubectl apply`/`helm upgrade` from rpi5-1.

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
