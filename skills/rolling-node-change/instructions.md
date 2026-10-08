# Rolling node change

How to change nodes one at a time without losing the cluster: a Talos OS upgrade, a Kubernetes or kubelet bump, a
schematic change, or a reboot of a host that carries nodes (Proxmox, the MacBook Pro). Invoke by hand; it is not
scheduled. This file is written to Claude as instructions and is also the human runbook. Node-type specifics live in
[`../../talos/README.md`](../../talos/README.md), linked below; don't copy them here.

Run `kubectl`/`talosctl` on the jump box (`ssh jakerobb@rpi5-1.lan`). Cluster state changes (drain, patch, upgrade) are
what the user asked for when they invoke this skill, but confirm the target version and node order first, and stop on
any unexpected result instead of pressing on.

## Before touching anything

1. All 7 nodes `Ready`, no unexpected firing alerts, no Argo app OutOfSync or Degraded.
2. Control-plane work: take an etcd snapshot first (`~/bin/etcd-snapshot-backup.sh`). Never take two control planes
   down at once; quorum is 2 of 3.
3. MacBook Pro worker involved: check host disk first (`ssh jakerobb@192.168.102.9 df -h /`). A full host disk has
   frozen the VM before (see [`../../docs/utm-talos-worker.md`](../../docs/utm-talos-worker.md)).
4. Pick the order: workers before control planes is fine; control planes strictly one at a time.

## Change types

**Kubernetes version (whole cluster).** `talosctl upgrade-k8s --to <version>` from the jump box. It rewrites the live
nodes, not the machine-config files on disk, so afterwards bump `machine.kubelet.image` (and any other pinned version)
in `~/talos/homelab/controlplane.yaml`, `worker.yaml` and `worker-3.yaml`, keeping dated `.bak-` copies, and run
`talosctl validate --config <file> --mode metal`.

**Kubelet on one node.** Cordon, drain (`kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`), then patch
with a strategic-merge file (`machine: {kubelet: {image: ghcr.io/siderolabs/kubelet:<version>}}`) using
`talosctl -n <ip> patch machineconfig --mode=no-reboot -p @file.yaml`. JSON6902 patches are rejected on these
multi-document configs. Wait for the node to report the new `kubeletVersion` and `Ready`, then uncordon.

**Talos OS upgrade, workers.** Drain, then `talosctl -n <ip> upgrade --image factory.talos.dev/installer/<schematic>:<version>`.
Use the node's own schematic (the standard one on worker-1/2/3, the `tsc=reliable` one on worker-mbp). Afterwards patch
`.machine.install.image` to the same value (no reboot). Uncordon once it is back.

**Talos OS upgrade, Pi control planes.** Never use the fork's plain tag: the combined-image recipe and U-Boot patch in
[`../../talos/README.md`](../../talos/README.md#full-sequence-per-node) is required until upstream carries the fix. Do not
patch `.machine.install.image` on these nodes (explained in that README).

**Host reboot (Proxmox, MBP).** Drain the nodes it carries first; afterwards check for silently read-only iSCSI volumes
(see [`../../docs/troubleshooting.md`](../../docs/troubleshooting.md)).

## Verify each node before starting the next

- `talosctl -n <ip> version` shows the new version, and `uptime` shows a fresh boot if one was expected. A responding
  API is not proof of a reboot.
- `talosctl -n <ip> get extensions` still lists `iscsi-tools` and `util-linux-tools`.
- `kubectl get nodes`: the node is `Ready` at the expected kubelet version. Control planes: `talosctl etcd status`
  shows all members healthy.
- A pod with an iSCSI volume on the node mounts and can write. Prometheus and SigNoz's ClickHouse can take several
  minutes to reattach after a reboot.
- An external `curl` of an ingress or LoadBalancer IP works. Cilium has failed silently before while reporting
  Healthy.
- Expect brief pod churn. A `cilium-operator` standby replica may crash-loop once; delete the pod if it doesn't recover.

## Finish

1. Uncordon every cordoned node.
2. Rebalance: `kubectl create job -n descheduler --from=cronjob/descheduler descheduler-manual-$(date +%s)` and read its
   logs. Each run evicts at most 5 pods, so repeat until the workers are roughly level, then delete the manual Jobs.
3. Confirm only `Watchdog` is firing and every pod is Running or Completed.
4. Update the version facts in `talos/README.md`'s "Current state" section, and anything else that states the old
   version. Describe what is true now, not the history; git has the history.
5. Report: what changed, which nodes, anything that needed a retry, and which manual follow-ups remain.
