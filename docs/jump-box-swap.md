# Jump box swap runbook (4GB Pi replaces rpi5-1; the 16GB Pi becomes a Talos worker)

This is the execution plan for the swap described in
[`todo/HARDWARE.md`](../todo/HARDWARE.md). The idea: the 1TB SSD that holds
rpi5-1's OS and data moves to a new 4GB Raspberry Pi 5, which then *is* rpi5-1
(same hostname, same SSH host keys, same `.2` address, same cron jobs, same
secrets). The old 16GB Pi gets a fresh 256GB SSD with Talos and joins the
cluster as a worker.

Nothing is copied. The downtime is the time between shutting the old Pi down
and the new one answering on `.2`, plus the worker join, which doesn't affect
the jump box.

Names used below:

| | Hardware | Before | After |
|---|---|---|---|
| **Old Pi** | 16GB Pi 5 | rpi5-1, `192.168.102.2` | `talos-worker-3`, `<WORKER-IP>` |
| **New Pi** | 4GB Pi 5 | spare | rpi5-1, `192.168.102.2` |

`<WORKER-IP>` is a free address in `.21`–`.29` (the physical-host range; see
"MS-A2 workers" in [`talos/README.md`](../talos/README.md)). Pick it, and
check it's free, before the window. `talos-worker-3` follows the normal
decoupled `talos-worker-N` naming (`-3` is the first free number, since the
MBP worker took a hardware-identified name instead); this node is permanent,
unlike `talos-worker-mbp`. The Mac Studio's worker becomes `talos-worker-4`.

## What is unavailable during the window

Expect roughly one to two hours without any of these:

- `compose-deploy` and every Compose service: Unbound (the in-cluster copy
  keeps answering), Telegraf, Vector and `nut-upsd`.
- The GHA runner, so Terraform plans and applies.
- `talosctl`, `kubectl` and `helm` access (they live on the jump box).
- All cron jobs: etcd snapshots, the Proxmox config backup's destination,
  the UniFi GC report, upgrade checks, and the msmtpq queue flush (so alert
  email).
- UPS monitoring and clean shutdown, from the moment the old Pi powers off
  until the new Pi's `nut-upsd` is up. A power cut in that gap shuts nothing
  down cleanly.
- Host metrics and logs (Telegraf and Vector), so SigNoz will show gaps and
  may alert on missing data.

## Preconditions

Do not start the window unless every box can be ticked. If one can't, stop
and fix it, or postpone.

### Workloads

- [ ] `docker ps` on rpi5-1 shows only `unbound`, `telegraf`, `vector` and
      `nut-upsd`. Home Assistant, Zigbee2MQTT, `zwave-js-ui`, matter-server,
      Scrypted, change-detection and browserless are all in the cluster and
      verified. (As of 2026-10-01, `change-detection` and `browserless` were
      still running here, with `manifests/lan-routes/change-detection.yaml`
      routing to `.2`.)
- [ ] `manifests/lan-routes/` has no route whose backend is `192.168.102.2`.
- [ ] Every cutover branch is merged. Nothing is half-migrated, and
      `docker-compose/` matches what's running.

### No pending changes

- [ ] No open PRs touching `terraform/`, `talos/`, `argocd/` or
      `docker-compose/`. Don't merge Renovate PRs during the window either.
- [ ] `main` is what's deployed: ArgoCD shows every Application `Synced` and
      `Healthy`, and the latest Terraform plan on `main` is clean.
- [ ] No `compose-deploy` drift alert is outstanding.
- [ ] `git status` on rpi5-1's `~/dev/homelab` is clean and on `main`. (This
      is also what the next `compose-deploy` run checks.)
- [ ] No GHA run is in progress or queued.

### Cluster health

- [ ] All 6 nodes `Ready`, all on the same Talos and Kubernetes versions.
- [ ] etcd has 3 healthy members (`talosctl etcd status`).
- [ ] A fresh etcd snapshot exists, taken within the last day, and its B2
      copy is confirmed.
- [ ] No firing alerts in SigNoz, and no pods in `CrashLoopBackOff` or
      `Pending`.
- [ ] No PVC is read-only. Headlamp's "ReadOnly" is the access mode, not the
      failure we care about: that one is the *filesystem* remounting
      read-only inside the node after an iSCSI hiccup, which Kubernetes
      doesn't surface. Check the node kernel logs instead; zero matches on
      every node is a pass (see [troubleshooting](troubleshooting.md)):

      ```bash
      for n in 11 12 13 31 32 34; do echo -n "$n: "; talosctl -n 192.168.102.$n dmesg | grep -cE "EXT4-fs.*(aborted journal|read-only|Remounting)"; done
      ```
- [ ] The MBP host has disk headroom (see
      [`utm-talos-worker.md`](utm-talos-worker.md)).
- [ ] [`talos/cilium/validate.sh`](../talos/cilium/validate.sh) passes.

### DNS

- [ ] The cluster Unbound (`192.168.102.130`) is in the DHCP DNS list of every
      VLAN that used `.2`, **ahead of** `.2` or alongside it.
- [ ] At least the longest DHCP lease time has passed since that change. Check
      with a short query-log window on rpi5-1 (Unbound doesn't log queries by
      default). Turn it on without a restart, let it run a few minutes, count
      queries per client, and turn it off again:

      ```bash
      docker exec unbound unbound-control -s /var/unbound/unbound.ctl set_option log-queries: yes
      docker logs --since 10m unbound 2>&1 | grep -E 'info: [0-9a-f:.]+ .* IN$' | awk '{print $4}' | sort | uniq -c | sort -rn
      docker exec unbound unbound-control -s /var/unbound/unbound.ctl set_option log-queries: no
      ```

      Any client still querying `.2` is a client that hasn't renewed, or one
      with a hardcoded DNS server. The Talos nodes are expected: they pin
      `.2` (then `1.1.1.1`) in
      [`nameservers.yaml`](../talos/patches/nameservers.yaml).
- [ ] Hardcoded-DNS devices are accounted for (UniFi gateway's own settings,
      Proxmox, TrueNAS, the MBP host, any static-IP gear). Either they're
      changed, or you've accepted they'll fall back to their secondary or
      lose DNS for the window.
- [ ] Both Unbounds give identical answers. Compare a handful of `*.lan`
      names with `dig @192.168.102.2` and `dig @192.168.102.130`, and diff
      the config the pods and the Compose container actually load.
- [ ] Decide what IPv6 DNS does. The Server and Trusted VLANs advertise only
      `fd3d:b17d:9f8e:102::2`, and the cluster Unbound has no IPv6. Either
      remove it from RA for the window (and put it back after), or accept
      slow lookups on dual-stack clients.
- [ ] A rehearsal succeeded: at a quiet time, `docker stop unbound` on
      rpi5-1 for five minutes, confirm clients and the cluster keep
      resolving, then `docker start unbound`.

### Hardware

- [ ] New Pi passed the SD-card test below, so none of its setup happens in
      the window.
- [ ] The new Pi has the same kind of NVMe HAT as the old one, a proper 5V/5A
      supply, and cooling.
- [ ] The 256GB SSD is flashed and verified (below).
- [ ] You know which switch port and cable each Pi uses, and that the new
      Pi's port is on the Server VLAN.
- [ ] Both Pis' EEPROMs have `BOOT_ORDER=0xf641` (SD, USB, NVMe) and neither
      has an SD card or USB stick in it, so each falls through to its SSD.
      You have a keyboard-free way to power-cycle each Pi.
- [ ] Both Pis' Ethernet MACs are written down.

### Timing

- [ ] The window avoids the cron times that matter. Check `crontab -l` on
      rpi5-1 for the etcd snapshot, and remember the Proxmox config backup
      pushes to rpi5-1 at 03:00 and the upgrade check runs at 09:00. A
      missed run is harmless, but then you'll wonder about it later.
- [ ] You have a way into the cluster if the jump box doesn't come back:
      Talos config and secrets are on the SSD, and `secrets.sops.yaml` plus
      the age key in 1Password is the fallback (see
      [`talos/README.md`](../talos/README.md)). Also optional but cheap: copy
      `~/talos/homelab` and `~/bin/secrets` to your Mac before you start, in
      case the SSD is damaged in transit.

## Before the window

Everything here is done with the old Pi still running, so none of it is
downtime.

### 1. Prepare the new Pi from an SD card

Boot the new Pi from a Raspberry Pi OS Lite SD card, not from the SSD.

Update the EEPROM and set the boot order to SD, USB, NVMe:

```bash
sudo rpi-eeprom-update -a
```

```bash
sudo rpi-eeprom-config --edit
```

In the editor, use this (the old Pi's config, with `BOOT_ORDER` changed):

```ini
[all]
BOOT_UART=1
BOOT_ORDER=0xf641
NET_INSTALL_AT_POWER_ON=1
PCIE_PROBE=1
```

`BOOT_ORDER` digits are read right to left: `1` is SD, `4` is USB, `6` is
NVMe, `f` repeats. So `0xf641` tries SD, then USB, then NVMe, which means a
bootable SD card or USB stick always wins over the SSD and you can override a
Pi's boot without touching its config. The flip side: **an SD card left in a
Pi will boot instead of the SSD**, so take it out before the window. rpi5-1's
EEPROM (the old Pi, which becomes the worker) was set to this order on
2026-10-02, replacing `0xf146`. It's written to flash but only shows in
`sudo rpi-eeprom-config` after its next boot. Confirm then that it reads
`0xf641`.
Reboot, then check `lsblk` sees an NVMe device if you've temporarily put any
SSD in its HAT. Then shut down and take the SD card out, but keep it for
rollback.

Also confirm here that the new Pi's Ethernet link comes up at 1Gb/s on the
cable it will use.

### 2. Prepare the 256GB SSD for the worker

Work out how the three control-plane Pis got their disks. That isn't
recorded in [`talos/README.md`](../talos/README.md), which only covers
upgrades. The `yama6a/talos-raspberry-pi5` project documents how to produce
a bootable image for a Pi 5 with NVMe boot; use the same release as the
control planes (currently `v1.14.2-1`).

Write that image to the 256GB SSD from your Mac with a USB-to-NVMe
enclosure. A fresh disk install doesn't hit the EFI-variable bug from the
[U-Boot fix](../talos/tools/uboot-fix/README.md) (that bug blocks
*upgrades*), but this node will have the same unpatched `u-boot.bin` as a
plain `v1.14.2-1` and will be un-upgradable the same way. Plan to apply the
U-Boot fix to it before its first Talos upgrade, or build the image with the
patched `u-boot.bin` swapped in from the start (the "combined image" pattern
in that README).

### 3. Write the worker's Talos config

Following "Talos config: fully reproducible from committed inputs" in
[`talos/README.md`](../talos/README.md), render `worker.yaml` for the new
node with:

- the shared patches: `kubelet-log-limits.yaml`,
  `kubelet-parallel-image-pulls.yaml`, `nameservers.yaml`
  (`discovery-registry-fix.yaml` is control-plane-only; check the
  README section if unsure)
- a new `talos/patches/workers/worker-3.yaml` with:
    - `machine.network.hostname: talos-worker-3`
    - `machine.nodeLabels` `homelab.jakerobb.org/nic-speed-mbps: "1000"`
    - `machine.install.image`: the **Pi 5 installer**, not the Factory amd64
      schematic that the shared `worker.yaml` template now points at. This
      is the same trap that caught `talos-worker-mbp` in reverse.
    - `install.disk` stays `/dev/nvme0n1`, the same as the template.
    - **Kernel logs.** The other workers send theirs to Vector on `.2` with the
      `talos.logging.kernel=udp://192.168.102.2:5140/` kernel arg, baked into
      their Image Factory schematics (see "Talos kernel logs" in
      [`talos/README.md`](../talos/README.md)). This node boots the Pi 5
      installer, not a Factory schematic, and `machine.install.extraKernelArgs`
      is ignored under SDBoot, so there is no obvious way to add the arg. Work
      out one before the window (patching the custom installer image, or an
      alternative like a DaemonSet that tails `/dev/kmsg`), or decide to run
      without it. The control planes have the same gap and were left out on
      purpose. Whatever you pick, the new rpi5-1 must keep `.2` and Vector's
      `5140/udp` mapping, or the workers' arg needs another upgrade each.
    - the iSCSI kernel module and kubelet `extraMounts`, *if* this node will
      run workloads with iSCSI volumes (democratic-csi). That also needs the
      `iscsi-tools` and `util-linux-tools` extensions. Look at how the
      control-plane Pis got them (`talosctl -n 192.168.102.11 get extensions`
      and their machine config) before deciding. If the node won't host
      PVC-backed pods, skip it and keep it cordoned off from them with a
      taint.

Commit `worker-3.yaml` in a PR and merge it before the window, so nothing
needs committing while the jump box is off. Only the rendered `worker.yaml`
stays on the jump box.

### 4. Audit images for arm64

Every Pod that could land on the new node has to have an arm64 image. The
three Pi control planes are tainted, so very little arm64 scheduling has
been tested.

**Done 2026-10-01:** all 68 distinct images across the cluster's Pods,
DaemonSets, Deployments, StatefulSets, CronJobs and Jobs (including init
containers) have a `linux/arm64` manifest (`docker buildx imagetools
inspect`), and no workload pins `kubernetes.io/arch`. Re-run the audit if
workloads were added since:

```bash
kubectl get pods,ds,deploy,sts,cronjob,job -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.jobTemplate.spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u | while read -r img; do docker buildx imagetools inspect "$img" 2>&1 | grep -q 'Platform:.*linux/arm64' && echo "OK    $img" || echo "NOARM $img"; done | grep -v '^OK'
```

Empty output means every image has an arm64 build.

### 5. NIC watchdog DaemonSet

[`nic-watchdog-mitigation.yaml`](../talos/patches/control-plane/nic-watchdog-mitigation.yaml)
now selects `kubernetes.io/arch: arm64` rather than the control-plane label,
so the new worker (same Pi 5 NIC) picks it up automatically. It isn't
ArgoCD-managed, so after the PR merges, apply it once from rpi5-1 (no change
to the three control planes):

```bash
kubectl apply -f ~/dev/homelab/talos/patches/control-plane/nic-watchdog-mitigation.yaml
```

### 6. DHCP and DNS prep

- Lower DHCP lease times a day or two ahead if you haven't already, so any
  straggler renews soon after.
- Open UniFi on a second device and have the reservation edits ready: new Pi
  MAC → `.2` (and `fd3d:b17d:9f8e:102::2` if that's a reservation rather than
  a static address on the Pi), old Pi MAC → `<WORKER-IP>`.

### 7. Tell yourself what you've paused

- Renovate PRs: don't merge any.
- If anything else on a schedule matters (the CGFiber heap monitoring email,
  the UniFi GC report), expect it to skip a run.

## The window

Machine for each step is in bold. Start by writing down the time; note the
elapsed time at each step.

### 1. Final checks on the old Pi

**On rpi5-1:**

```bash
uptime && docker ps --format '{{.Names}}\t{{.Status}}'
```

```bash
cd ~/dev/homelab && git status --short && git rev-parse --abbrev-ref HEAD
```

```bash
~/bin/etcd-snapshot-backup.sh
```

Confirm the snapshot's email arrives (or its log shows success), that no GHA
job is running (`gh run list --status in_progress`), and that you've done
the "copy to Mac" insurance if you wanted it.

### 2. Shut down the old Pi

**On rpi5-1:**

```bash
sudo shutdown -h now
```

Don't `docker compose stop` first: containers stopped by hand don't come back
on boot under `unless-stopped`. A normal shutdown stops them in a way that
lets them restart automatically (and `compose-deploy` runs `up -d` every
five minutes regardless).

Wait for the green LED to go dark, then unplug its power. DNS now depends
entirely on the cluster Unbound and whatever the clients cached.

### 3. Swap the hardware

1. Move the **1TB SSD** from the old Pi to the new Pi.
2. Fit the **256GB SSD** into the old Pi.
3. Move the **UPS USB cable** from the old Pi to the new Pi. The UPS keeps
   running; only monitoring stops until `nut-upsd` is back up on the new Pi.
4. Put each Pi's Ethernet cable where it should be. Don't power either on
   yet.

The UPS stays with the *jump box* for now, with Compose's `nut-upsd` still
doing the job, so there's no monitoring gap beyond the swap itself. That's a
deliberate change from `todo/HARDWARE.md`, which moves the UPS to the worker
and runs `nut-upsd` in the cluster. Do that later as its own change, once the
worker has been stable for a while (see "After the swap").

### 4. Move the DHCP reservations

**In UniFi**, in this order, so the two Pis never hold `.2` at once:

1. Old Pi's MAC → `<WORKER-IP>`.
2. New Pi's MAC → `192.168.102.2` (and the IPv6 address, if reserved).

### 5. Power on the new Pi and verify it is rpi5-1

Power it on and wait a minute or two.

**On your Mac:**

```bash
ssh jakerobb@rpi5-1.lan 'hostname && uptime && ip -br a'
```

The SSH host key is the same one as before, since it's on the SSD, so
`known_hosts` shouldn't complain. If it does, stop and find out why before
trusting the machine. `uptime` should show a fresh boot, and `ip -br a`
should show `192.168.102.2` on the wired interface. (`wlan0` will have a new
MAC and no reservation; that's fine, the interface is on the list to remove
later.)

Then, **on rpi5-1**, go through the "After the swap" verification table
below. UPS, Unbound and the runner matter most; do those first.

### 6. Join the worker

Do this only once the jump box checks out.

**On the old Pi:** just power it on. It boots Talos from the 256GB SSD, takes
`<WORKER-IP>` from DHCP and sits in maintenance mode.

**On rpi5-1:**

```bash
talosctl -n <WORKER-IP> get disks --insecure
```

If that shows the NVMe disk, apply the config:

```bash
cd ~/talos/homelab && talosctl apply-config --insecure -n <WORKER-IP> --file worker.yaml
```

Use the per-node rendered file you made in step 3 of "Before the window".
The node should reboot into a configured state and register.

```bash
kubectl get nodes -o wide
```

As soon as `talos-worker-3` appears:

```bash
kubectl cordon talos-worker-3
```

Cordoning stops ordinary pods from landing on it before you've audited it.
DaemonSet pods still schedule.

### 7. Check the worker

**On rpi5-1:**

```bash
kubectl get pods -A -o wide --field-selector spec.nodeName=talos-worker-3
```

Expect the Cilium agent, node-exporter, the NIC watchdog and democratic-csi's
node plugin (if you gave it iSCSI) all `Running`. Then:

```bash
talosctl -n <WORKER-IP> get machinestatus,extensions,resolvers
```

```bash
~/dev/homelab/talos/cilium/validate.sh
```

Check that Cilium's L2 announcements are behaving. Workers announce LB IPs
(the Gateway, Unbound's VIP), so this node may take over some from the
others; confirm those addresses still answer from another machine, and that
the `nic-10g` Services are still announced only by 10GbE nodes.

Leave it cordoned until the arm64 audit from "Before the window" is done
and you're happy. Then `kubectl uncordon talos-worker-3`.

### 8. Put DHCP and RA back

Restore normal lease times, and re-add the IPv6 resolver to RA if you removed
it. Note the end time.

## After the swap: verify the new rpi5-1

**On rpi5-1** unless noted.

| Check | How | Pass looks like |
|---|---|---|
| Rebooted fresh | `uptime` | uptime of minutes, not days |
| Right address | `ip -br a` | `192.168.102.2` on the wired NIC |
| Compose is back | `docker ps` | `unbound`, `telegraf`, `vector`, `nut-upsd` all `Up` |
| Unbound answers | from your Mac: `dig @192.168.102.2 <a *.lan name>` | same answer as `@192.168.102.130` |
| UPS visible | `upsc <ups-name>@localhost` and from another host: `upsc <ups-name>@rpi5-1.lan` | live values; nut-exporter alert clears |
| `compose-deploy` | `crontab -l`, then wait for the next run or run it by hand | no drift alert, no errors |
| GHA runner | `systemctl status 'actions.runner.*'`, and GitHub → Settings → Actions → Runners | service active, runner **Idle** |
| Terraform | push a trivial change on a branch, or re-run the latest plan job | plan job runs on the runner and succeeds |
| Talos access | `talosctl -n 192.168.102.11 version`, `kubectl get nodes` | all 7 nodes `Ready` (cordoned worker shows `SchedulingDisabled`) |
| etcd backup | `~/bin/etcd-snapshot-backup.sh` | success, B2 copy appears |
| Email relay | send a test through `msmtpq`, and check `~/.msmtp.queue/` is empty | mail arrives, queue empty |
| Telegraf and Vector | SigNoz | host metrics and logs flowing again, no more "no data" |
| Talos kernel logs | SigNoz logs, filter `source_type = 'talos-kernel'` | new lines from every worker after Vector is back (nodes buffer nothing: logs sent during the window are lost) |
| Proxmox backup | next 03:00 run, or run `proxmox-config-backup.sh` on the Proxmox host | files land under `~pve-backup/backups/proxmox/` |
| Hubble CLI, helm, kubeconfig | `hubble status`, `helm list -A`, `kubectl get ns` | all work, no new credentials needed |

Also check what you can't see from here: that the Brevo relay and the
Cloudflare Access allowlist are still fine (same WAN, so nothing to change
unless egress routing differs), and that the SigNoz and Telegraf alerts that
fired during the window resolve themselves.

## Rollback

The old SSD is never written to by anything except normal use, so rolling
back is a swap in reverse.

**If the new Pi won't come up as rpi5-1** (at step 5): power it off, put the
1TB SSD back in the old Pi, move the UPS cable and reservation back (old
Pi's MAC → `.2`), and power on. The old Pi comes back exactly as it was. Move
the Talos SSD out of it afterwards if you want to try again.

**If the worker won't join** (at step 6): nothing about the cluster or the
jump box depends on it, so you can just power the old Pi off and leave it.
The cluster has worked without it so far; retry later.

**If the cluster misbehaves after the worker joins** (unexpected churn,
Cilium trouble): `kubectl drain` and `kubectl delete node talos-worker-3`,
then power the Pi off.

## After the swap: follow-ups

- Update the docs that name the old arrangement: the rpi5-1 sections of
  [`todo/HARDWARE.md`](../todo/HARDWARE.md) (delete the finished checklist
  items), `README.md`, `talos/README.md` (a new "talos-worker-3" section and
  the node counts), [`talos/patches/nameservers.yaml`](../talos/patches/nameservers.yaml)'s
  comment, the overview, and [`todo/DONE.md`](../todo/DONE.md).
- Host cleanup on the new rpi5-1, from `todo/HARDWARE.md`: drop `wlan0` (`.3`)
  and `wlan0-watchdog.{service,timer}`, remove Bluetooth and avahi packages,
  and clear the ~31G of one-off files in `~`.
- Remove the `compose-deploy` cron entry only if no Compose services remain
  (Unbound is still there, so it stays for now).
- Uncordon `talos-worker-3` once the arm64 audit is done, then watch it for a
  few days before moving the UPS.
- Move the UPS to the worker as its own change: deploy `nut-upsd` in the
  cluster pinned to that node with USB access, add the NUT client extension
  for the worker's own clean shutdown, and point the jump box's
  `nut-monitor.service` at it.
- Apply the U-Boot fix to `talos-worker-3` before its first Talos upgrade, if
  you didn't build it in from the start.
