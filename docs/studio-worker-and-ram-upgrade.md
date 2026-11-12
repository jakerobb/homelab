# Mac Studio worker, MS-A2 collapse and RAM upgrade

One runbook for three connected changes, in three phases so that only the last one has an outage:

| Phase | When | Outage? | What |
|---|---|---|---|
| 1 | Now | No | Collapse the two MS-A2 workers into one (16 GiB, 8 cores); stage the Studio's config |
| 2 | Studio arrives | No | Add `talos-worker-studio` as a QEMU VM on the Mac Studio (done 2026-11-06); soak; later retire `talos-worker-mbp` |
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
[Resizing the Talos worker VM](proxmox-os-updates.md#resizing-the-talos-worker-vm) (VM 101):

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
- Remove `.32` from `nut_v4` in `scripts/rpi5-1-firewall/homelab-fw.nft`, then on rpi5-1 run `sudo ./install.sh enforce`
  (plain `./install.sh` defaults to log-only mode and would quietly stop enforcing;
  [`rpi5-1-firewall.md`](rpi5-1-firewall.md#adding-a-node)).
- Remove `talos/patches/workers/worker-2.yaml`, the `.32` DHCP reservation in the UCG, and every doc that lists two
  MS-A2 workers (root `README.md` lines 42 and 376, `terraform/proxmox/README.md`, `docs/overview.md`,
  `talos/README.md`).
- Check the PR plan shows only the VM 100 destroy and no change to VM 101.

### 1.5 Pre-stage the Studio's side

Nothing here needs the Mac.

- Add a DHCP reservation in the UCG for MAC `02:00:00:00:00:36` to `192.168.102.36`.
- Add `.36` to `nut_v4` in the firewall file (and re-run `sudo ./install.sh enforce`), so `nut-exporter` works if it lands there.
- Write `talos/patches/workers/worker-studio.yaml`, modelled on [`worker-mbp.yaml`](../talos/patches/workers/worker-mbp.yaml)
  (the file as built is the reference): hostname `talos-worker-studio`, static ULA `fd3d:b17d:9f8e:102::36/64` with
  the `::/0` route via `fe80::1e0b:8bff:fe14:a5d5` (metric 2048), `accept_ra_rt_info_max_plen`, the `/etc/iscsi` and
  `/var/lib/iscsi` extraMounts, and `kernel.modules: [iscsi_tcp]`. Take the interface name and `install.disk` from the
  maintenance API, not by analogy (they came out as `enp0s2` and `/dev/vda`). `install.image` is the same schematic
  as worker-1 (`85824046c9070c5b1dbcd4c6673157d7cd6d78785c10c3dc03a1b0f2a50c1615`) at the **current** Talos version
  (the shared template's image is stale), **without** `tsc=reliable`, which is an x86 clocksource workaround. The
  `nic-speed-mbps` label is the measured VM speed, not the host NIC's; see 2.3.
- Prepare, but **do not merge**, the phase 3 change: `hexos.tf` `dedicated = 24576` with the comment rewritten (see
  3.9). It would fail to start on 29 GiB, which is why it waits for the RAM.

---

## Phase 2: Studio is ready (no outage)

Done 2026-11-06. The VM runs under **QEMU with Hypervisor.framework (HVF) as a root LaunchDaemon**, not under UTM.
The reason is FileVault: after a remote unlock the Mac sits at the login window with no GUI session, so LaunchDaemons
start but a GUI app like UTM does not. The files are in [`../scripts/studio-worker/`](../scripts/studio-worker/):
`run-vm.sh` (the QEMU command line), `com.jakerobb.talos-worker-studio.plist` and `install.sh`. The generic UTM recipe
([`utm-talos-worker.md`](utm-talos-worker.md)) still applies to the 2018 MBP.

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

- Remote Login with key auth, and the Studio's key in rpi5-1's `authorized_keys` (the Pi's host firewall also needs the
  Studio's IP in `ssh_v4`, see [`rpi5-1-firewall.md`](rpi5-1-firewall.md)). The 1Password SSH-agent gotcha in
  `utm-talos-worker.md` applies: don't route automation through the agent.
- Stop it sleeping (`pmset -g` shows `sleep 0`) and set it to start up after a power failure.
- **FileVault stays on.** A cold boot or power loss therefore waits at the unlock screen, and the VM only comes back
  once someone unlocks it. Pre-login SSH accepts the account password, so `ssh jakerobb@192.168.102.22` from a
  terminal unlocks it remotely (tested 2026-11-06: key auth refused at 17:27:02, working by 17:28:56). The Mac then
  reaches the login window, LaunchDaemons start (Telegraf and the VM daemon both do), and the node rejoins. The
  Apple-menu Restart does an *authenticated restart* that skips the unlock, so only a shutdown or power loss needs it.
  An automatic unlock watchdog on the jump box is built but not yet enabled; see
  [`studio-unlock-watchdog.md`](studio-unlock-watchdog.md) for the tradeoff and the test it still needs.
- Disk headroom. The 2018 MBP's host disk filling froze its VM and corrupted its image store. Install Telegraf per
  [`mac-host-metrics.md`](mac-host-metrics.md) (with its disk alert, and the Cilium egress rule for `:9273`), and keep
  the qcow2 on the internal SSD with room.
- `brew install qemu` (as the normal user).

### 2.2 Bring up the node

1. In `~/talos-vm/` on the Studio: download `metal-arm64.iso` for the schematic at the current Talos version from the
   Image Factory, and create a **blank** disk: `qemu-img create -f qcow2 disk.qcow2 64G`. (The `nocloud` disk image
   never opens the maintenance API, as the UTM runbook explains. A blank disk falls through to the ISO on first boot,
   and after the install the disk boots first. The ISO stays attached as a recovery boot.)
2. Add a DHCP reservation for MAC `02:00:00:00:00:36` to `192.168.102.36` in the UCG.
3. Copy `scripts/studio-worker/` to `~/talos-vm/` (or use the repo checkout) and run `./install.sh`. It installs
   `run-vm.sh` as `/usr/local/sbin/talos-worker-studio-run` and loads the daemon. The VM is 16 vCPUs, 40960 MiB,
   `vmnet-bridged` on `en0`, virtio-net with `rx_queue_size=1024`, virtio-blk disk. A SIGTERM (host shutdown, a
   `launchctl bootout`) sends an ACPI power-down, so Talos shuts down cleanly; the plist's `ExitTimeOut` is 120 s.
   **Re-running `install.sh` restarts the VM**: cordon and drain the node first.
4. Read the real names from the maintenance API on rpi5-1 (`--insecure` goes after the subcommand):

   ```bash
   talosctl get links --insecure -n 192.168.102.36
   ```

   ```bash
   talosctl get disks --insecure -n 192.168.102.36
   ```

5. Fill in `worker-studio.yaml`, render it against the shared template on rpi5-1 and apply it:

   ```bash
   talosctl machineconfig patch ~/talos/homelab/worker.yaml -p @worker-studio.yaml -o worker-studio-full.yaml
   ```

   ```bash
   talosctl apply-config --insecure -n 192.168.102.36 -f worker-studio-full.yaml
   ```

   It installs to the blank disk, reboots and joins; expect a few minutes to `Ready`.

### 2.3 Verify before trusting it

- `talosctl -n 192.168.102.36 get extensions` lists `iscsi-tools` and `util-linux-tools`; `kubectl get nodes` shows
  it `Ready`.
- `talosctl -n 192.168.102.36 get machineconfig -o yaml` shows the schematic image in `install.image` (no drift).
- A throwaway `hexos-iscsi` PVC and pod, pinned to the node with `nodeSelector: kubernetes.io/hostname:
  talos-worker-studio`, mount and write. Delete both afterwards. *(Done 2026-11-06: attached, mounted and wrote.
  `hexos-iscsi` is `Retain`, so the PV goes `Released` and the zvol stays on the NAS: delete the PV, then
  `zfs destroy` the zvol under `data/k8s-iscsi/` by hand.)*
- `max_sectors_kb` is capped (the [`iscsi-max-sectors.yaml`](../talos/patches/iscsi-max-sectors.yaml) patch is in the
  template): `talosctl -n 192.168.102.36 read /sys/block/sdb/queue/max_sectors_kb` shows 1024 on the TrueNAS disks.
  *(Done 2026-11-06: 1024 on `sda`. With no other disk attached the TrueNAS LUN was `sda`, not `sdb`.)*
- `talosctl -n 192.168.102.36 get addresses` shows the static ULA, and `read /proc/net/ipv6_route` shows the static
  default route. Check where `matter-server` (hostNetwork) lands, since it depends on those. *(Done 2026-11-06: the
  static ULA `::36` and both default routes, RA-learned at metric 1024 and static at 2048, are present, and the
  sysctl reads 64. Still to check: `matter-server`'s placement. The node also picked up SLAAC addresses and on-link
  routes for the `:42`, `:55`, `:62` and `:92` prefixes about 4.5 minutes after boot; the Pi worker has none, but
  its SLAAC addresses expired long ago, so this is not yet known to be Studio-specific.)*
- **Measure the network, then set the label.** The host's native 10GbE measures 9.37 Gbit/s, but the VM's pod-to-pod
  speed is lower: about 6.0-6.7 Gbit/s sending and 7.1-7.5 receiving (2026-11-06; `iperf3` against
  `network-optimizer-lb` from a pod pinned to the node, in the `network-optimizer` namespace because that namespace's
  policy blocks other clients). QEMU's vmnet backend moves packets on one thread, which pegs at ~100% (the vCPUs
  idle), so more cores won't help; `rx_queue_size=1024` bought a few percent on sending. The label is
  `nic-speed-mbps: "6000"`, the weaker direction. NetworkOptimizer's `Gt 9999` preference then still favours the
  MS-A2, and the `In ["10000"]` 10G L2 policy keeps `nic-10g` Services off the Studio. That policy is a hard
  requirement, not a preference: with `talos-worker-1` down (phase 3), `network-optimizer-lb` has no announcer and
  is unreachable. Accepted, since such outages are rare.
- Host disk, temperature and fan metrics arrive from the Mac (`macmon_*`, see `mac-host-metrics.md`), and the node's
  kernel logs reach SigNoz (it needs its IP in Vector's `nodes` map).

### 2.4 Soak, then retire `talos-worker-mbp`

Run the cluster as is for a week or two. Nothing moves to the Studio on its own; the descheduler rebalances over
time, or drain a heavy workload to it deliberately. Consider steering Prometheus and ClickHouse there with
`nodeAffinity`.

Retiring mbp is a cordon and drain (its storage is all on `hexos-iscsi`, so there's no data migration):

```bash
kubectl drain talos-worker-mbp --ignore-daemonsets --delete-emptydir-data --timeout=300s
```

Power the VM off but **keep it** for a week as a rollback. Then:

- `kubectl delete node talos-worker-mbp`; delete the VM and the Mac's `192.168.102.9` Telegraf setup if unwanted
  (and its entry in the `prometheus-scrape` policy in `manifests/network-policies/monitoring.yaml`).
- Remove `.34` from `nut_v4` (and re-run `sudo ./install.sh enforce`), delete `talos/patches/workers/worker-mbp.yaml`
  and the `.34` DHCP reservation, and take `.34` out of Vector's `nodes` map.
- Update the read-only-volume checks in [`troubleshooting.md`](troubleshooting.md) and
  [`proxmox-os-updates.md`](proxmox-os-updates.md), which loop over `for n in 34 35`, to `36 35`. Update the node
  counts and tables in `talos/README.md` (including the NIC-speed table), `overview.md`, the rolling-node-change
  skill's "All 7 nodes" and the `HARDWARE.md` entry.

### Rebooting the Studio

A shutdown or power loss needs the FileVault unlock above before anything starts. To restart it deliberately, cordon
and drain `talos-worker-studio`, then use the Apple-menu **Restart** (authenticated restart, no unlock needed): launchd
sends SIGTERM, the VM powers down gracefully and the daemon restarts it at boot. For a full shutdown, expect to unlock
by SSH afterwards. A graceful stop can take a minute or two, so `launchctl bootout` followed immediately by `bootstrap`
fails with an I/O error unless you wait (`install.sh` waits up to 150 s).

---

## Phase 3: RAM in hand (the outage)

The MS-A2 has two SODIMM slots, so this is a swap, not an addition. Keep the old sticks as a fallback.

HexOS goes down, and with it every PVC and `/mnt/data/shared`. Control planes, DNS and non-PVC pods stay up. Plan for
roughly one to two hours, plus the memory test.

**Two things stay running through the outage: restock-radar and ntfy**, so stock alerts keep arriving on phones. They
run as temporary stand-ins on throwaway `emptyDir` storage, pinned to the Studio; see
[The restock-radar and ntfy carve-out](#the-restock-radar-and-ntfy-carve-out) below. Everything else stops, and the
rest of the cluster is silent for the whole window: Prometheus and Alertmanager have PVCs, so nothing will alert about
the cluster itself until 3.8 (ntfy is up, but nothing is publishing to it except restock-radar). The restock-radar web UI
is unreachable too, because Authelia keeps its 2FA registrations on a PVC and stays off. `network-optimizer-lb` (the
10G-only Service) has no announcer while `talos-worker-1` is down, which is accepted: nearly everything else is off
then too. The Studio and the Pi worker keep running the non-PVC pods.

### The restock-radar and ntfy carve-out

[`../scripts/nas-outage/nas-outage.sh`](../scripts/nas-outage/nas-outage.sh) does the whole thing, in three commands:
`plan` (read-only checks and a server-side dry run), `start` (3.2) and `finish --nas-up` (3.8). It runs on the jump box.

- **What it creates.** `restock-radar-standby` and `ntfy-standby`, generated from the live Deployments when the script
  runs (so they always carry the current image digest, config and probes) with every PVC swapped for an `emptyDir`,
  pinned to `talos-worker-studio` (never `talos-worker-1`: the drain in 3.3 would evict them and their data). The real
  Deployments are only scaled to 0 and back; git is never touched. That is also why ArgoCD must be stopped first: its
  self-heal would otherwise scale the real ones straight back up, so `start` and `finish` refuse to run while the
  controller is up.
- **What's lost.** ntfy's message cache (12 hours of recent messages, for clients that were offline) is recreated
  empty. restock-radar keeps its database, which is a few MB: 0.6 MB, plus a write-ahead log that was 4 MB on
  2026-11-12, so the script always copies the `-wal` file along with the `.db`. Anything the stand-in learns during the
  outage is copied back by `finish`.
- **What it deliberately leaves out.** Authelia: it holds the 2FA registrations, which aren't worth putting on a
  throwaway volume (they were lost once, in the 2026-09-15 migration), and the stock alerts don't go through it. The
  Home Assistant stack and everything else stay off.
- **No skipped poll interval.** restock-radar sleeps for its poll interval plus or minus jitter *after* each cycle
  finishes: 5 minutes plus or minus 1, so the gap between one cycle ending and the next starting is at least 4 minutes.
  Both hand-overs (in `start`, and back in `finish`) wait for `restock_radar_last_cycle_timestamp_seconds` to change,
  then stop one copy and start the other inside that gap. The stand-in pod is created ahead of time with an init
  container that blocks until the database arrives, and its image is already pulled, so the hand-over itself is only:
  scale the old one to 0 and wait for it to exit cleanly (SIGTERM checkpoints the WAL), stream the database through
  `kubectl exec`, compare checksums, release the init container. It prints how long that took and warns past 150 seconds.
  Tested on 2026-11-12 against the live cluster without a hand-over (pod admission, pinning, image pull on the Studio,
  `exec` into the init container, the copy and the checksum comparison all work; the copy took under a second).
- **If a stand-in's pod is lost** (the Studio VM restarts, say) it comes back blocked in its init container, not with an
  empty database, so it can't silently re-baseline. `nas-outage.sh reseed` pushes the copy that `start` saved in
  `~/nas-outage/seed.tar` into it, which restores the state as of the hand-over.

Backups need no thought: the stand-in's `/backups` is a throwaway `emptyDir`, the nightly NFS copies on the NAS simply
stop for the window, and `finish` puts the newest database back on the real volume. The pre-outage database is kept
next to it in `/data/.pre-outage` on the `restock-radar-data` volume, in case the copy back needs undoing.

### 3.0 Beforehand

- **Test the used SODIMMs** before they go anywhere near the NAS: memtest86+ from a USB stick, at least two full
  passes. Ideally do this in another machine. Otherwise it's the first thing to do in step 3.5, which extends the
  outage.
- Check they match the MS-A2's supported type (DDR5 SODIMM, same speed class as the old ones).
- Have ready: a USB stick with memtest86+, the KVM connected, a small screwdriver.
- **The phase 1 Terraform change must already be merged and applied.** Until it lands, `terraform/proxmox` still
  declares two 4-core, 8 GiB workers while the real VMs are collapsed (VM 101 at 16 GiB and 8 cores, set live; VM 100
  stopped). Any apply from the HexOS PR would then try to put VM 101 back to 8 GiB and could start VM 100, and the
  next restart of VM 101 would boot with the wrong size. Check before the window: `ssh proxmox "qm list"` shows no
  VM 100, and the `proxmox` plan on a PR is empty.
- **Pause the Healthchecks.io check** (the dead-man's-switch; see "Dead-man's-switch" in
  [`../argocd/README.md`](../argocd/README.md)) when you scale things down in 3.2. Alertmanager is a StatefulSet, so
  it goes to zero with the rest and the pings stop; the check emails 10 to 20 minutes later. Resume it in 3.8.
- **Put the carve-out script on the jump box and rehearse it.** The repo isn't checked out there, so copy the script
  over (the same way as `~/bin/etcd-snapshot-backup.sh`):

  ```bash
  scp scripts/nas-outage/nas-outage.sh jakerobb@rpi5-1.lan:bin/
  ```

  Run `~/bin/nas-outage.sh plan` on the jump box: it checks that `talos-worker-studio` is Ready and schedulable, builds
  both stand-ins and server-side dry-runs them, and prints where the real pods are. Then do one full rehearsal while the
  NAS is up (about 15 minutes, with ArgoCD stopped for that time): scale the Argo controller to 0 as in 3.2,
  `~/bin/nas-outage.sh start`, check `status` and that a restock-radar alert would arrive, then
  `~/bin/nas-outage.sh finish --nas-up` and scale Argo back to 1. A rehearsal is the only way to see a real hand-over
  time, and it leaves `~/nas-outage/{seed,final}.tar` as proof that both copies work.
- The Studio must be healthy for the whole window, since it holds the only copy of restock-radar's live data: check
  `talos-worker-studio` is Ready, the Telegraf disk alert is quiet, and nothing else is about to reboot it
  ([Rebooting the Studio](#rebooting-the-studio)).
- Pick a quiet window. An Alertmanager silence is pointless here, since Alertmanager is off. Avoid the Studio's own
  maintenance and the scheduled backups, which the stand-ins don't cover.
- Hold the staged `hexos.tf` PR (3.9) until after the RAM is in and HexOS is up.
- Facts checked 2026-11-07: HexOS is VM **102** (`hexos`, 10240 MiB), the worker is VM **101** (16384 MiB), the ZFS
  pool is `data`, and there are 21 PVCs in 14 namespaces. The host reports 29,769 MB total with about 1.5 GB
  available, so it is genuinely full today.

### 3.1 Snapshot and back up

Take a ZFS snapshot via the scoped NAS account (`claude-ops` may snapshot but never destroy; see
[`truenas-ops-access.md`](truenas-ops-access.md)). Find the datasets first:

```bash
ssh truenas-ops 'sudo zfs list'
```

```bash
ssh truenas-ops 'sudo zfs snapshot -r data@pre-ram-upgrade'
```

Run a Proxmox config backup (the script is on the Proxmox host, see
[`proxmox-config-backup.md`](proxmox-config-backup.md); the 03:00 cron run also does it):

```bash
ssh proxmox "/usr/local/sbin/proxmox-config-backup.sh"
```

Take an etcd snapshot too, on rpi5-1:

```bash
~/bin/etcd-snapshot-backup.sh
```

### 3.2 Stop everything that writes to HexOS

ArgoCD's self-heal and the Prometheus and ClickHouse operators scale PVC workloads straight back up, which is why
[`proxmox-os-updates.md`](proxmox-os-updates.md#after-a-reboot-read-only-iscsi-volumes) says deleting pods afterwards
is simpler. Doing it properly prevents the silently read-only volumes entirely, but the order matters. Leave
**External Secrets running**: restarting it bursts through the 1Password quota.

Pause the Healthchecks.io check now (see 3.0). Then stop the controller first (confirm its name with
`kubectl -n argocd get sts`):

```bash
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
```

Scale deployments to zero first, which includes the operators, and wait a minute so they can't recreate anything.
**Skip `restock-radar` and `ntfy`**: those two are handed over by the carve-out script below, and a blanket scale-down
would also kill their stand-ins.

```bash
for ns in $(kubectl get pvc -A --no-headers | awk '{print $1}' | sort -u | grep -vxE 'restock-radar|ntfy'); do kubectl -n "$ns" scale deploy --all --replicas=0; done
```

Then the StatefulSets (Prometheus, ClickHouse, zookeeper, signoz and the rest), and suspend the CronJobs in those
namespaces (the same two are skipped; neither has a StatefulSet, and restock-radar's nightly backup is in the app):

```bash
for ns in $(kubectl get pvc -A --no-headers | awk '{print $1}' | sort -u | grep -vxE 'restock-radar|ntfy'); do kubectl -n "$ns" scale sts --all --replicas=0; kubectl -n "$ns" get cronjob -o name | xargs -r -I{} kubectl -n "$ns" patch {} -p '{"spec":{"suspend":true}}'; done
```

Last, hand restock-radar and ntfy over to their stand-ins (Argo is already stopped, which the script requires). It
restarts ntfy on the Studio first, then waits for restock-radar's next poll cycle to finish, which takes up to six
minutes, and stops the real pod right then. It prints the before and after state; expect no warnings. If it fails it
rolls both apps back onto their real volumes, which is safe because the NAS is still up.

```bash
~/bin/nas-outage.sh start
```

Verify that no pod still mounts a PVC (the script also checks this for its two namespaces), and that the PVC list
matches what was scaled (21 PVCs across 14 namespaces on 2026-11-07; the PVCs of restock-radar and ntfy are now unused):

```bash
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim) | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"'
```

### 3.3 Drain the MS-A2 worker

```bash
kubectl drain talos-worker-1 --ignore-daemonsets --delete-emptydir-data --timeout=300s
```

The stand-ins are pinned to `talos-worker-studio` and aren't on this node. Confirm with
`kubectl get pods -A -o wide | grep standby`: if either is on `talos-worker-1`, stop and don't drain, because
`--delete-emptydir-data` would discard restock-radar's live database.

### 3.4 Power down, cleanly and in order

HexOS first, so ZFS exports. Its VM ID is 102 (confirm with `qm list`); shut it down with ACPI and wait until it has stopped before touching
the others:

```bash
ssh proxmox "qm list"
```

```bash
ssh proxmox "qm shutdown 102 --timeout 300"
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
ssh proxmox "qm set 102 --memory 24576 && qm start 102"
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

**First, hand restock-radar and ntfy back, while ArgoCD is still stopped.** The order matters: once Argo is up its
self-heal scales the real Deployments to 1 by itself, and a real restock-radar starting on the stale NAS database
would alert again on every change the stand-in already reported. This needs HexOS verified (3.7) and
`talos-worker-1` uncordoned, since the real pods need their iSCSI volumes. The script restarts the real ntfy and only
then removes its stand-in; mounts the NAS volume in a helper pod; waits for the stand-in's next poll cycle to finish;
copies the database back (the old one is kept in `/data/.pre-outage`, and the copy is undone if the checksums
differ); stops the stand-in; and starts the real restock-radar, all inside the four-minute gap. It compares the item
and variant counts before and after, and warns past 150 seconds:

```bash
~/bin/nas-outage.sh finish --nas-up
```

If it can't mount the NAS volume or the real ntfy won't start, it stops before touching restock-radar, and the
stand-ins keep serving. Fix the cause (usually a volume that came back read-only, see
[the procedure](proxmox-os-updates.md#after-a-reboot-read-only-iscsi-volumes)) and run it again.

Then start the Argo controller. Its self-heal restores replicas, StatefulSets and CronJob `suspend` from git, so there's
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
for n in 31 34 35 36; do echo "$n:"; talosctl -n 192.168.102.$n dmesg | grep -E "EXT4-fs.*(aborted journal|read-only)"; done
```

- Prometheus is scraping, SigNoz is ingesting, Home Assistant is responding, the ntfy test notification arrives.
- **Resume the Healthchecks.io check** and confirm it turns green within about 10 minutes (Alertmanager's `Watchdog`
  pings it every 5).

### 3.9 Finish

- `hexos.tf`: `dedicated = 24576` with a rewritten comment. The current one (lines 90 to 99) says the host has 32 GB and
  fits no more than 10 GiB. Replace it with something like: "24 GiB, up from 10 GiB (the host went from 32 GB to
  64 GB on <date>). SCST (the iSCSI target) sizes its command-memory limits at 25% of RAM, so 24 GiB gives about
  6144 MB total and 2458 MB per device, against about 2.5 GB and 1 GB at 10 GiB. The earlier bump from 8 GiB
  (2026-10-08) was for the 8 MiB-buffer allocation failures behind the Prometheus volume stalls; this adds margin.
  The host has 64 GB: this VM, the 16 GiB worker, and about 22 GiB left for Proxmox and future VMs." Keep the "no
  `floating`" note about ballooning. It's a no-op apply, since 3.6 already set the value live.
- `todo/HARDWARE.md`: delete the done UMA, RAM and Studio items. Add a completion note to `todo/DONE.md`.
- `todo/DONE.md`: the retired "HexOS iSCSI target out of command memory" entry mentions "another RAM increase" only as
  a fallback; note that SCST's limits are now the 24 GiB ones.
- Update `docs/overview.md`, `docs/proxmox-os-updates.md` (the "29.1 GiB usable" arithmetic) and `talos/README.md`
  with what is true now.

### Rollback

- A bad stick: put the old pair back and boot; nothing else changed except the BIOS UMA setting, which is harmless.
- HexOS won't start at 24 GiB: `qm set 102 --memory 10240` and start; the workers can stay as they are.
- A volume turned read-only after the restore: delete the affected pod, one at a time
  ([procedure](proxmox-os-updates.md#after-a-reboot-read-only-iscsi-volumes)).
- The carve-out went wrong. `~/bin/nas-outage.sh status` shows what's running and how long ago restock-radar last
  finished a cycle. A stand-in pod that was lost is `reseed`'s job (above). If `start` fails, it rolls both apps back
  onto their real volumes by itself. If `finish` can't be used at all, the stand-in's database is in
  `~/nas-outage/final.tar` (taken at the last hand-over) and the pre-outage one is in `~/nas-outage/seed.tar`;
  restock-radar's own README has the restore procedure for a database file. Losing the carve-out isn't fatal: with an
  empty database the next start re-baselines silently, and UI-added products are the only thing not in git.
- The ZFS snapshot from 3.1 is the last resort. Remember `claude-ops` can't destroy snapshots.
