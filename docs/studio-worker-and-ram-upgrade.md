# Mac Studio worker, MS-A2 collapse and RAM upgrade

One runbook for three connected changes, in three phases so that only the last one has an outage:

| Phase | When | Outage? | What |
|---|---|---|---|
| 1 | Now | No | Collapse the two MS-A2 workers into one (16 GiB, 8 cores); stage the Studio's config |
| 2 | Studio arrives | No | Add `talos-worker-studio` as a UTM VM on the Mac Studio; soak; later retire `talos-worker-mbp` |
| 3 | RAM in hand | **Yes, HexOS and every volume** | Swap the MS-A2's SODIMMs to 64 GB, give HexOS 24 GiB, restart |

## Why these numbers

- **The workers don't need the RAM.** In early November 2026 the MS-A2 workers used 2.1 and 2.4 GiB of 8, mbp
  6.6 of 24 and worker-3 5.1 of 16. The only documented memory problem is HexOS: SCST (the iSCSI target) sizes its
  buffer limits at 25% of the NAS's RAM (40% of that per device), and its allocation failures stalled volumes on
  2026-09-29, 10-05, 10-07 and 10-11 (see [`../todo/READY.md`](../todo/READY.md)). 24 GiB gives roughly 6 GiB and 2.4 GiB
  there, against about 2.5 GiB and 1 GiB at 10 GiB.
- **One worker per machine.** Two VMs on one host share its fate, and each Talos node costs about 1.5 GiB of fixed
  overhead (cilium-agent, envoy, otel, kubelet). The "two workers on purpose" comment in
  [`../terraform/proxmox/talos-worker.tf`](../terraform/proxmox/talos-worker.tf) was about keeping capacity while one
  worker upgrades. With the Pi and the Studio as separate workers that reasoning no longer holds.
- **Studio VM: 16 vCPUs, 40 GiB.** vCPUs are threads, not reserved cores, so 16 of the Studio's 36 costs nothing
  while the VM is idle. It's adjustable later with a VM restart. 40 of the Studio's 96 GiB leaves plenty for macOS
  and other work.
- **Capacity after mbp retires.** Requests total about 22 GiB. The Pi (16 GiB) plus a 16 GiB MS-A2 worker can hold
  that if the Studio is down, so each of the three machines is an independent failure domain. (If the MS-A2 is down,
  HexOS is down and every stateful app with it anyway.)

Final layout:

| Machine | Node | Size |
|---|---|---|
| MS-A2 (64 GB, about 62 GiB visible) | HexOS VM | 24 GiB, 6 cores |
| | `talos-worker-1` | 16 GiB, 8 cores |
| | Proxmox host + spare | about 22 GiB |
| Mac Studio | `talos-worker-studio` (`.36`) | 40 GiB, 16 vCPUs |
| Pi 5 16 GB | `talos-worker-3` (`.35`) | unchanged |

Run `kubectl`, `talosctl` and `ssh proxmox` on the jump box (`ssh jakerobb@rpi5-1.lan`) unless a step says otherwise.

---

## Phase 1: now (no outage)

### 1.1 Prepare

Do these once, ahead of the other steps.

- Connect the KVM to the MS-A2 ([`../todo/HARDWARE.md`](../todo/HARDWARE.md)), so phase 3's BIOS change doesn't also
  mean finding a monitor and keyboard.
- Check that nothing will refuse to schedule on fewer nodes. Look for `DoNotSchedule` topology spreads and required
  anti-affinity:

```bash
kubectl get deploy,sts -A -o json | jq -r '.items[] | select(.spec.template.spec.topologySpreadConstraints[]?.whenUnsatisfiable=="DoNotSchedule" or .spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution) | "\(.kind) \(.metadata.namespace)/\(.metadata.name)"'
```

- Confirm the baseline: all 7 nodes `Ready`, only `Watchdog` firing, no Argo app OutOfSync or Degraded (the
  [rolling node change](../skills/rolling-node-change/instructions.md) checklist).

### 1.2 Drain and remove `talos-worker-2`

Draining is graceful, so iSCSI volumes detach cleanly. worker-1 can't absorb all of worker-2's requests (7.3 GiB
against 7.26 GiB allocatable), so some pods will land on mbp and worker-3; the descheduler evens that out later.

```bash
kubectl drain talos-worker-2 --ignore-daemonsets --delete-emptydir-data --timeout=300s
```

Shut the VM down (VM 100) before deleting the node object, or the kubelet re-registers it. Shutting it down also
frees its 8 GiB on the host, which step 1.3 needs.

```bash
ssh proxmox "qm shutdown 100 --timeout 180"
```

```bash
kubectl delete node talos-worker-2
```

### 1.3 Grow `talos-worker-1` to 16 GiB and 8 cores

`talos-worker.tf` has `reboot_after_update = false`, so set the values live first so the merge is a no-op for them,
then roll the worker as in
[Resizing the Talos worker VMs](proxmox-os-updates.md#resizing-the-talos-worker-vms) (VM 101):

```bash
kubectl drain talos-worker-1 --ignore-daemonsets --delete-emptydir-data --timeout=300s
```

```bash
ssh proxmox "qm set 101 --memory 16384 --cores 8 && qm shutdown 101 --timeout 180 && qm start 101"
```

Wait for `Ready`. Confirm a cold start and the new capacity (the 2026-09-27 lesson: a responding API is not proof of
a reboot):

```bash
talosctl -n 192.168.102.31 read /proc/uptime
```

```bash
kubectl get node talos-worker-1 -o jsonpath='{.status.capacity.memory} {.status.capacity.cpu}{"\n"}'
```

```bash
kubectl uncordon talos-worker-1
```

Then rebalance with the descheduler as in the rolling-node-change skill's "Finish" section, and check an iSCSI pod
on worker-1 can write.

### 1.4 Terraform and repo changes (one PR)

The merge applies [`talos-worker.tf`](../terraform/proxmox/talos-worker.tf) via
[GHA](gha-terraform.md), so do it only after 1.2 and 1.3.

- Remove the `talos-worker-2` entry (VM 100 and its disk get destroyed). Set `cores = 8`, `dedicated = 16384`.
  Rewrite the header comment (one worker per physical machine now) and the memory comment (the old "24 of 29 GiB"
  arithmetic).
- Remove `.32` from `nut_v4` in `scripts/rpi5-1-firewall/homelab-fw.nft`, then on rpi5-1 run `sudo ./install.sh`
  ([`rpi5-1-firewall.md`](rpi5-1-firewall.md#adding-a-node)).
- Remove `talos/patches/workers/worker-2.yaml`, the `.32` DHCP reservation in the UCG, and every doc that lists two
  MS-A2 workers (root `README.md` lines 42 and 376, `terraform/proxmox/README.md`, `docs/overview.md`,
  `talos/README.md`).
- Check the PR plan shows only the VM 100 destroy and no change to VM 101.

### 1.5 Pre-stage the Studio's side

Nothing here needs the Mac.

- Add a DHCP reservation in the UCG for MAC `02:00:00:00:00:36` to `192.168.102.36`.
- Add `.36` to `nut_v4` in the firewall file (and re-run `install.sh`), so `nut-exporter` works if it lands there.
- `talos/patches/workers/worker-studio.yaml` is written in phase 2 (step 2.2), not now: its interface name and
  `install.disk` are only known once the VM is up, and a file full of placeholders isn't worth committing. Model it on
  [`worker-mbp.yaml`](../talos/patches/workers/worker-mbp.yaml): hostname `talos-worker-studio`, `nic-speed-mbps: "10000"`
  (use the real link speed), static ULA `fd3d:b17d:9f8e:102::36/64` with the `::/0` route via
  `fe80::1e0b:8bff:fe14:a5d5` (metric 2048), `accept_ra_rt_info_max_plen`, the `/etc/iscsi` and `/var/lib/iscsi`
  extraMounts, and `kernel.modules: [iscsi_tcp]`. `install.image` is the same schematic as worker-1
  (`85824046c9070c5b1dbcd4c6673157d7cd6d78785c10c3dc03a1b0f2a50c1615`) at the current Talos version, **without**
  `tsc=reliable`. That workaround is for the x86 TSC clocksource and has no arm64 equivalent. Watch for
  `NodeClockNotSynchronising` once the node is up. Also add `"192.168.102.36": "talos-worker-studio"` to the node map in
  `docker-compose/vector/vector.yaml`, so its kernel logs get a node name.
- Prepare, but **do not merge**, the phase 3 change: `hexos.tf` `dedicated = 24576` with the comment rewritten (see
  3.9). It would fail to start on 29 GiB, which is why it waits for the RAM.

---

## Phase 2: Studio is ready (no outage)

The generic recipe is [`utm-talos-worker.md`](utm-talos-worker.md). The differences for an Apple Silicon host:

- Use the **arm64** images from the Image Factory with the schematic above: `nocloud-arm64.qcow2` and
  `metal-arm64.iso`. The `metal` ISO is still needed for maintenance mode, for the reason the runbook gives.
- UTM: Virtualize, Linux, "Use Apple Virtualization" **off** (QEMU backend, as on the MBP). 16 CPU cores, 40960 MiB RAM,
  64 GiB disk, bridged to the wired interface on the Server VLAN, `virtio-net-pci`, MAC `02:00:00:00:00:36`.

### 2.0 Address allowlists (before the node takes pods)

Anything that allows traffic by node IP has to learn `192.168.102.36`, and forget `.32`. In the repo that's already
done (rpi5-1's `nut_v4`; Vector's map is a phase 2 edit, see 1.5). The rest lives outside the repo:

- **UniFi firewall rules.** The IoT VLAN rule that lets cluster nodes reach `kvm`, `rack-led` and `modbus-relay`
  allows node IPs, not just rpi5-1 (see [IoT VLAN firewall](../argocd/README.md)). It's documented as
  `.11`-`.13`, `.31`, `.32`, `.34`, without `.35`, so check whether it's an IP group and what's actually in it. Add `.36`,
  remove `.32`. Check any other rule that names node IPs: Home Assistant, Matter and Scrypted run with `hostNetwork` and
  float to any worker, so they reach cameras and IoT devices from the node's own address.
- **Device-side allowlists** that name the old nodes' IPs, if any (a camera, the KVM, the Z-Wave or Zigbee gateways).
- **DHCP reservation** for `02:00:00:00:00:36` to `192.168.102.36` (1.5). Remove `.32`'s (1.4).
- **After the node is up**, repeat the reachability test that found the IoT rule problem: a test pod pinned to
  `talos-worker-studio` that reaches an IoT-VLAN host, and a `hostNetwork` pod (blackbox-exporter, Home Assistant) landing on it.

Nothing to change on HexOS: NFS exports are limited to the Server VLAN (`192.168.102.0/24`), and iSCSI uses
democratic-csi's credentials rather than per-initiator addresses, so a new node on that VLAN is already allowed. The
Cilium L2 announcement policies select nodes by label, not by name or interface, so the Studio takes part as soon as it
has `nic-speed-mbps`. Decide that label's value on the VM's measured throughput rather than the Mac's port speed.
`"10000"` makes it a candidate to announce the `nic-10g` Services (NetworkOptimizer's), and a UTM bridge is unlikely to
reach 10 Gbit/s.

### 2.1 Mac host setup

Do this before the VM, on the Studio:

- Enable Remote Login with key auth (the 1Password SSH-agent gotcha in `utm-talos-worker.md` applies).
- Stop it sleeping: System Settings, Energy, "Prevent automatic sleeping when the display is off", and "Start up
  automatically after a power failure". Check with `pmset -g` that `sleep` is 0.
- Decide how the VM comes back after a reboot or power cut. UTM doesn't start VMs on its own, so add UTM as a login
  item with auto-login (if you accept that) or a launch agent running `utmctl start talos-worker-studio`. Without it, a
  macOS update leaves the node dead until you log in. Note that decision in this runbook.
- Disk headroom. The 2018 MBP's host disk filling froze its VM and corrupted its image store
  ([`utm-talos-worker.md`](utm-talos-worker.md#recovering-from-a-corrupted-image-store)). Install Telegraf per
  [`mac-host-metrics.md`](mac-host-metrics.md) with a disk alert, and keep the qcow2 on the internal SSD with room.

### 2.2 Bring up the node

Follow `utm-talos-worker.md` steps 3 to 6 with these specifics. Before generating the config, read the real interface
and disk names from the maintenance API (don't assume `enp0s1` or `/dev/sda`):

```bash
talosctl -n 192.168.102.36 --insecure get links
```

```bash
talosctl -n 192.168.102.36 --insecure get disks
```

Fill the placeholders in `worker-studio.yaml`, then (on rpi5-1):

```bash
talosctl machineconfig patch ~/talos/homelab/worker.yaml -p @worker-studio.yaml -o worker-studio.yaml
```

```bash
talosctl apply-config --insecure -n 192.168.102.36 -f worker-studio.yaml
```

Check the shared `worker.yaml` template's `install.image` isn't stale first (it has drifted before, see the MBP
section of [`talos/README.md`](../talos/README.md)). Eject the ISO once it's installed.

### 2.3 Verify before trusting it

- `talosctl -n 192.168.102.36 get extensions` lists `iscsi-tools` and `util-linux-tools`; `kubectl get nodes` shows
  it `Ready`.
- `talosctl -n 192.168.102.36 get machineconfig -o yaml` shows the schematic image in `install.image` (no drift).
- A throwaway `hexos-iscsi` PVC and pod, pinned to the node with `nodeSelector: kubernetes.io/hostname:
  talos-worker-studio`, mount and write. Delete both afterwards.
- `max_sectors_kb` is capped (the [`iscsi-max-sectors.yaml`](../talos/patches/iscsi-max-sectors.yaml) patch is in the
  template): `talosctl -n 192.168.102.36 read /sys/block/sdb/queue/max_sectors_kb` shows 1024 on the TrueNAS disks.
- `talosctl -n 192.168.102.36 get addresses` shows the static ULA, and `read /proc/net/ipv6_route` shows the static
  default route. Check where `matter-server` (hostNetwork) lands, since it depends on those.
- The 10G L2 announcement policy picks the node up (label `nic-speed-mbps: 10000`) and a `nic-10g` Service still answers.
- Host disk and temperature metrics arrive from the Mac.

### 2.4 Soak, then retire `talos-worker-mbp`

Run the cluster as is for a week or two. Nothing moves to the Studio on its own; the descheduler rebalances over
time, or drain a heavy workload to it deliberately. Consider steering Prometheus and ClickHouse there with
`nodeAffinity`.

Retiring mbp is a cordon and drain (its storage is all on `hexos-iscsi`, so there's no data migration):

```bash
kubectl drain talos-worker-mbp --ignore-daemonsets --delete-emptydir-data --timeout=300s
```

Power the VM off but **keep it** for a week as a rollback. Then:

- `kubectl delete node talos-worker-mbp`; delete the VM and the Mac's `192.168.102.9` Telegraf setup if unwanted.
- Remove `.34` from `nut_v4` (and re-run `install.sh`), delete `talos/patches/workers/worker-mbp.yaml` and the `.34`
  DHCP reservation.
- Update the read-only-volume checks in [`troubleshooting.md`](troubleshooting.md) and
  [`proxmox-os-updates.md`](proxmox-os-updates.md), which loop over `for n in 34 35`, to `36 35`. Update the node
  counts and tables in `talos/README.md` (including the NIC-speed table), `overview.md`, the rolling-node-change
  skill's "All 7 nodes" and the `HARDWARE.md` entry.

---

## Phase 3: RAM in hand (the outage)

The MS-A2 has two SODIMM slots, so this is a swap, not an addition. Keep the old sticks as a fallback.

HexOS goes down, and with it every PVC and `/mnt/data/shared`. Control planes, DNS and non-PVC pods stay up. Plan for
roughly one to two hours, plus the memory test.

### 3.0 Beforehand

- **Test the used SODIMMs** before they go anywhere near the NAS: memtest86+ from a USB stick, at least two full
  passes. Ideally do this in another machine. Otherwise it's the first thing to do in step 3.5, which extends the
  outage.
- Check they match the MS-A2's supported type (DDR5 SODIMM, same speed class as the old ones).
- Have ready: a USB stick with memtest86+, the KVM connected, a small screwdriver.
- Pick a quiet window. Consider an Alertmanager silence so the outage doesn't flood email and ntfy.
- Merge nothing for phase 3 yet.

### 3.1 Snapshot and back up

Take a ZFS snapshot via the scoped NAS account (`claude-ops` may snapshot but never destroy; see
[`truenas-ops-access.md`](truenas-ops-access.md)). Find the datasets first:

```bash
ssh truenas-ops 'sudo zfs list'
```

```bash
ssh truenas-ops 'sudo zfs snapshot -r <pool>@pre-ram-upgrade'
```

Run a Proxmox config backup (`/usr/local/sbin/proxmox-config-backup.sh` if that's where
[`proxmox-config-backup.md`](proxmox-config-backup.md) put it; otherwise wait for the 03:00 cron run and confirm it).
Take an etcd snapshot too (`~/bin/etcd-snapshot-backup.sh`).

### 3.2 Stop everything that writes to HexOS

ArgoCD's self-heal and the Prometheus and ClickHouse operators scale PVC workloads straight back up, which is why
[`proxmox-os-updates.md`](proxmox-os-updates.md#after-a-reboot-read-only-iscsi-volumes) says deleting pods afterwards
is simpler. Doing it properly prevents the silently read-only volumes entirely, but the order matters. Leave
**External Secrets running**: restarting it bursts through the 1Password quota.

Stop the controller first (confirm its name with `kubectl -n argocd get sts`):

```bash
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
```

Scale deployments to zero first, which includes the operators, and wait a minute so they can't recreate anything:

```bash
for ns in $(kubectl get pvc -A --no-headers | awk '{print $1}' | sort -u); do kubectl -n "$ns" scale deploy --all --replicas=0; done
```

Then the StatefulSets (Prometheus, ClickHouse, zookeeper, signoz and the rest), and suspend the CronJobs in those
namespaces:

```bash
for ns in $(kubectl get pvc -A --no-headers | awk '{print $1}' | sort -u); do kubectl -n "$ns" scale sts --all --replicas=0; kubectl -n "$ns" get cronjob -o name | xargs -r -I{} kubectl -n "$ns" patch {} -p '{"spec":{"suspend":true}}'; done
```

Verify that no pod still mounts a PVC, and that the PVC list matches what was scaled (21 PVCs across about 17
namespaces on 2026-11-03):

```bash
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim) | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"'
```

### 3.3 Drain the MS-A2 worker

```bash
kubectl drain talos-worker-1 --ignore-daemonsets --delete-emptydir-data --timeout=300s
```

### 3.4 Power down, cleanly and in order

HexOS first, so ZFS exports. Find its VM ID, shut it down with ACPI, and wait until it has stopped before touching
the others:

```bash
ssh proxmox "qm list"
```

```bash
ssh proxmox "qm shutdown <hexos-vmid> --timeout 300"
```

```bash
ssh proxmox "qm shutdown 101 --timeout 180"
```

```bash
ssh proxmox "shutdown -h now"
```

### 3.5 Swap the RAM and set the BIOS (at the machine)

- Unplug the power, swap the two SODIMMs, reassemble.
- Boot to the BIOS. Confirm 64 GB is detected, then apply the UMA change from
  [`HARDWARE.md`](../todo/HARDWARE.md) (AMD CBS, NBIO Common Options, GFX Configuration, UMA Frame Buffer Size, 512M or
  the smallest option; do **not** disable the iGPU, the HDMI console is the break-glass).
- If the sticks weren't tested elsewhere, boot memtest86+ now and let at least two passes finish.
- Boot Proxmox. If you want the kernel update now, take it in this boot and follow the post-reboot checks in
  [`proxmox-os-updates.md`](proxmox-os-updates.md).

Check the host sees the memory (expect roughly 62 to 63 GiB):

```bash
ssh proxmox "free -m"
```

### 3.6 Give HexOS the memory and start it

Staged Terraform changes don't apply to a stopped VM until the next start, and `hexos.tf` also has
`reboot_after_update = false`. Set it live so the merge is a no-op for it:

```bash
ssh proxmox "qm set <hexos-vmid> --memory 24576 && qm start <hexos-vmid>"
```

Then merge the staged `hexos.tf` PR (3.9).

### 3.7 Verify HexOS is healthy before anything depends on it

- Cold start: `ssh truenas-ops uptime` shows minutes, not days.
- The pool is online and the datasets are there: `ssh truenas-ops 'sudo zfs list'`.
- The VM sees 24 GiB: `ssh truenas-ops 'grep MemTotal /proc/meminfo'`.
- SCST's limits scaled with it: `ssh truenas-ops 'cat /sys/module/scst/parameters/scst_max_cmd_mem
  /sys/module/scst/parameters/scst_max_dev_cmd_mem'` (expect about 6144 and 2458 MB).
- The iSCSI and NFS services are running (HexOS UI, or `showmount -e truenas.lan` from rpi5-1).
- No error spam in `ssh truenas-ops 'sudo /usr/bin/cat /var/log/scst.log' | tail`.

Start `talos-worker-1` and uncordon it:

```bash
ssh proxmox "qm start 101"
```

```bash
talosctl -n 192.168.102.31 read /proc/uptime
```

```bash
kubectl uncordon talos-worker-1
```

### 3.8 Restore the workloads

Start the Argo controller. Its self-heal restores replicas, StatefulSets and CronJob `suspend` from git, so there's
nothing to scale back by hand. Because the controller was off, refresh the root app first and confirm its revision is
current before trusting the child apps (an out-of-date root once gave a false all-Synced).

```bash
kubectl -n argocd scale statefulset argocd-application-controller --replicas=1
```

The volumes all reattach at once, and Prometheus and ClickHouse can take several minutes. Then:

- No `Failed` or `Pending` pods; every app Synced and Healthy; only `Watchdog` firing; silence removed.
- Nothing left at zero replicas or suspended that shouldn't be:
  `kubectl get deploy,sts -A | grep ' 0/'` and `kubectl get cronjob -A | grep True`.
- No read-only volumes (should be none, since nothing was mounted, but it's cheap to check):

```bash
for n in 31 35 36; do echo "$n:"; talosctl -n 192.168.102.$n dmesg | grep -E "EXT4-fs.*(aborted journal|read-only)"; done
```

- Prometheus is scraping, SigNoz is ingesting, Home Assistant is responding, the ntfy test notification arrives.

### 3.9 Finish

- `hexos.tf`: `dedicated = 24576` with a rewritten comment (the old text says the host has 32 GB and fits no more than
  10 GiB; now say 64 GB, 24 GiB, why 24 and what the SCST numbers became).
- `todo/HARDWARE.md`: delete the done UMA, RAM and Studio items. Add a completion note to `todo/DONE.md`.
- `todo/DONE.md`: the retired "HexOS iSCSI target out of command memory" entry mentions "another RAM increase" only as
  a fallback; note that SCST's limits are now the 24 GiB ones.
- Update `docs/overview.md`, `docs/proxmox-os-updates.md` (the "29.1 GiB usable" arithmetic) and `talos/README.md`
  with what is true now.

### Rollback

- A bad stick: put the old pair back and boot; nothing else changed except the BIOS UMA setting, which is harmless.
- HexOS won't start at 24 GiB: `qm set <hexos-vmid> --memory 10240` and start; the workers can stay as they are.
- A volume turned read-only after the restore: delete the affected pod, one at a time
  ([procedure](proxmox-os-updates.md#after-a-reboot-read-only-iscsi-volumes)).
- The ZFS snapshot from 3.1 is the last resort. Remember `claude-ops` can't destroy snapshots.
