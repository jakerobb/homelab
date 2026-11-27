# PoE switch firmware upgrade

How to upgrade the firmware on the core PoE switch without the storage trouble an outage causes. Written 2026-11-26 from
the cluster's own failure notes; nothing here has been rehearsed yet, so the first run is also the test.

## What the switch carries

Everything. The three control planes (`talos-cp-*`, standalone Pi 5s on PoE), `talos-worker-3` (Pi 5, PoE), the MS-A2
(Proxmox, with the HexOS VM that provides every PV and `talos-worker-1`), the MacBook Pro (`talos-worker-mbp`) and the
uplink to the Pro XG 8 PoE, which carries the Mac Studio (`talos-worker-studio`). rpi5-1, the jump box, is on it too, so
**your SSH session dies during the outage**: do everything before and after from a session that doesn't need to survive
it, and start nothing long-running on the jump box in between.

## What the outage does

A firmware upgrade reboots the switch, which is a few minutes with no network and no power loss for the nodes, except
possibly the PoE-powered ones. Per component:

- **etcd and Kubernetes:** survives. The control planes lose each other at once, and quorum comes back when the network
  does. Running pods keep running without the API server.
- **PoE nodes (three control planes, worker-3):** assume the switch drops PoE during the reboot (not confirmed for this
  model). They then lose power and cold-boot when it returns: no graceful etcd stop, which etcd tolerates, but it's the
  untidy part. That's why a snapshot comes first.
- **Storage:** the real risk. Every PVC is on HexOS, over iSCSI or NFS. If the outage outlasts the iSCSI session
  timeout, a mounted volume that gets written to aborts its ext4 journal and turns read-only, and it stays that way
  after the network returns. Some pods crash-loop; others (ClickHouse, SigNoz) stay `Running` and silently fail every
  write. See [After a reboot: read-only iSCSI volumes](proxmox-os-updates.md#after-a-reboot-read-only-iscsi-volumes).
  The timeout isn't set anywhere in this repo, so it's the open-iscsi default; I expect about two minutes, but that's
  unverified. A switch reboot usually takes longer.
  `talos-worker-1` and HexOS are VMs on one host, so their traffic may stay on Proxmox's bridge; the other three
  workers can't count on that.
- **Mac Studio:** loses the network, not power, so its FileVault state doesn't matter and the VM keeps running.

## Why not shut the cluster down

A graceful shutdown buys nothing the steps below don't, and it costs a manual restart. Powered-off Pis don't start
themselves, so each one needs a PoE port cycle from the UniFi controller, and the controller has to be reachable first.
It also doesn't remove the PoE power loss for the control planes. Stopping the writers is the only part that matters.

## Before

Pick a quiet window, and have the switch's rollback ready (the previous firmware version, and a way to reach the UniFi
controller if the network is down).

1. Every node `Ready`, only `Watchdog` firing, no Argo app OutOfSync or Degraded. Pause the Healthchecks.io check (the
   dead-man's-switch; see "Dead-man's-switch" in [`../argocd/README.md`](../argocd/README.md)), or it emails 10 to 20
   minutes into the outage.
2. Snapshot etcd on the jump box: `~/bin/etcd-snapshot-backup.sh`.
3. Stop everything that writes to HexOS. This is the same procedure as step 3.2 of
   [the RAM upgrade](studio-worker-and-ram-upgrade.md#32-stop-everything-that-writes-to-hexos) with one difference, and
   the order matters (ArgoCD's self-heal and the Prometheus and ClickHouse operators scale workloads straight back up).
   Leave **External Secrets** running: restarting it bursts through the 1Password quota. The difference: **do not skip
   `restock-radar` and `ntfy`, and don't run `nas-outage.sh`.** Its stand-ins run on the Studio, which loses the network
   with everything else, so they'd protect nothing.

   ```bash
   kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
   # deployments first (this includes the operators); wait a minute so nothing is recreated
   for ns in $(kubectl get pvc -A --no-headers | awk '{print $1}' | sort -u); do kubectl -n "$ns" scale deploy --all --replicas=0; done
   # then the StatefulSets, and suspend the CronJobs in those namespaces
   for ns in $(kubectl get pvc -A --no-headers | awk '{print $1}' | sort -u); do kubectl -n "$ns" scale sts --all --replicas=0; kubectl -n "$ns" get cronjob -o name | xargs -r -I{} kubectl -n "$ns" patch {} -p '{"spec":{"suspend":true}}'; done
   ```

4. Check that no pod still mounts a PVC. The result should be empty (21 PVCs in 15 namespaces on 2026-11-26):

   ```bash
   kubectl get pods -A -o json | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim) | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"'
   ```

   Pods from finished Jobs may still be listed as `Completed`; they don't hold a mount.

## The upgrade

Upgrade the switch from the UniFi controller. Don't touch anything else while it's down, and don't power-cycle a Pi by
hand: if the switch doesn't bring PoE back by itself, cycle the port from the controller once the switch is up.

## After

1. Wait for the switch, then for the Pis: `talosctl -n 192.168.102.11,192.168.102.12,192.168.102.13 read /proc/uptime`
   should show a fresh boot if PoE was dropped. `talosctl etcd status` shows all three members healthy.
2. All seven nodes `Ready` (`kubectl get nodes`). The Studio's VM and `talos-worker-1` should never have gone down.
3. Start the Argo controller. Its self-heal restores replicas, StatefulSets and CronJob `suspend` from git, so there's
   nothing to scale back by hand. Refresh the root app and confirm its revision is current first (an out-of-date root
   once gave a false all-Synced):

   ```bash
   kubectl -n argocd scale statefulset argocd-application-controller --replicas=1
   ```

   The volumes all reattach at once; Prometheus and ClickHouse can take several minutes.
4. Check nothing is left at zero or suspended, and that no volume came back read-only (it shouldn't, since nothing was
   mounted, but it's cheap):

   ```bash
   kubectl get deploy,sts -A | grep ' 0/'; kubectl get cronjob -A | grep True
   for n in 31 34 35 36; do echo "$n:"; talosctl -n 192.168.102.$n dmesg | grep -E "EXT4-fs.*(aborted journal|read-only)"; done
   ```

   Anything read-only is fixed by deleting the affected pod; see the procedure linked above.
5. Prometheus is scraping, SigNoz is ingesting, Home Assistant responds, an external `curl` of an ingress or
   LoadBalancer IP works, and only `Watchdog` is firing. Resume the Healthchecks.io check and confirm it goes green
   within about 10 minutes.

## If only the Pro XG 8 needs upgrading

That affects the Mac Studio alone. Follow [Rebooting the Studio](studio-worker-and-ram-upgrade.md#rebooting-the-studio)
instead: drain `talos-worker-studio` first, and expect it to rejoin once the network is back.
