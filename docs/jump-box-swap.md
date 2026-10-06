# Jump box swap runbook (4GB Pi replaces rpi5-1; the 16GB Pi becomes a Talos worker)

**Status: done 2026-10-06** (shut down 11:38, worker joined 15:08; see [`todo/DONE.md`](../todo/DONE.md) for the
summary). This page is kept as the record and as a template for any future jump box or Pi worker swap. The notes
added while doing it (the temporary-address swap, the MAC filter, the HAT swap, the SD card's size) are folded into the
steps below.

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
| **Old Pi** | 16GB Pi 5 | rpi5-1, `192.168.102.2` | `talos-worker-3`, `192.168.102.35` |
| **New Pi** | 4GB Pi 5 | spare | rpi5-1, `192.168.102.2` |

The worker's address is `192.168.102.35`: workers live in the `.3x` range (`.31`/`.32`
the MS-A2 VMs, `.34` the MBP). `.33` is TrueNAS, so it's skipped. Confirm
`.35` has no static device or DHCP reservation in UniFi before the window.
`talos-worker-3` follows the normal
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
      verified. (change-detection and browserless moved on 2026-10-05.)
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
- [x] IPv6 DNS: **decided 2026-10-06 to accept the risk, and leave RA
      alone.** The Server and Trusted VLANs advertise only
      `fd3d:b17d:9f8e:102::2`, and the cluster Unbound has no IPv6, so during
      the window any dual-stack client that prefers the IPv6 resolver may see
      slow lookups (a timeout, then fallback to IPv4 DNS). The evidence for
      accepting: none of the 447,487 queries in the previous 72 hours of
      Unbound's query log came from an IPv6 client address. Giving the
      cluster Unbound an IPv6 address is a separate future item (see
      [`todo/READY.md`](../todo/READY.md)).
- [ ] A rehearsal succeeded: at a quiet time, `docker stop unbound` on
      rpi5-1 for three minutes, confirm clients and the cluster keep
      resolving, then `docker start unbound`. Keep it under five minutes and
      start it just after a `compose-deploy` run (minutes ending in 0 or 5):
      `compose-deploy` runs `docker compose up -d` every five minutes, which
      restarts anything stopped by hand. Done 2026-10-06: no DNS problems.

### Hardware

- [ ] The SD card boots the new Pi and you can SSH in (step 1 below), and its
      EEPROM is set, so none of its setup happens in the window.
- [ ] The new Pi has a proper 5V/5A supply and cooling. The two Pis have
      **different NVMe HATs**: the new Pi's takes only up to a 2242 SSD (the
      256GB is a 2230), and rpi5-1's takes the 1TB 2280. So in the window each
      SSD travels on its own HAT (see "Swap the hardware"). Check that each
      HAT's cable, standoffs and cooler fit the Pi it's moving to.
- [ ] The 256GB SSD is flashed, checksum-verified and test-booted (step 2 below).
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

The new Pi's setup (EEPROM, and writing the worker's image) happens from a
Raspberry Pi OS SD card, not from the SSD.

**First, check the SD card has a working OS.** It may be left over from
bootstrapping the control-plane Pis, but nothing in this repo records that,
so don't assume. Put it in the new Pi with no SSD installed and power it on
(the Ethernet cable on the Server VLAN). Give it a couple of minutes, then
find its address in UniFi's client list. Don't use `rpi5-1.lan`, which is
still the old Pi.

```bash
ssh <user>@<new-pi-address> 'uname -a; cat /etc/os-release | head -2; lsblk -o NAME,SIZE,MODEL'
```

If you can SSH in, the card is fine and you can skip the rest of this
paragraph. If it doesn't appear in UniFi or won't accept SSH, write a fresh
card on a machine that's allowed to mount it (the MBP, say) with Raspberry Pi
Imager: device "Raspberry Pi 5", OS "Raspberry Pi OS Lite (64-bit)", and in
the customisation settings set a hostname that **isn't `rpi5-1`** (for
example `rpi5-new`), a username (`jakerobb`), your SSH public key with
password login off, and enable SSH. Skip Wi-Fi; use the Ethernet cable. Then
boot it and run the check above. Any current Pi OS release is fine; this card
is a scratch environment, not the jump box.

Also confirm here that the new Pi's Ethernet link comes up at 1Gb/s on the
cable it will use (`ethtool eth0 | grep Speed`; the interface may be `end0`
on some images).

Then update the EEPROM package and set the boot order to SD, USB, NVMe.
Upgrade the `rpi-eeprom` package first: on an older Pi OS card its packaged
bootloader can be *older* than what's already flashed, and applying a config
would flash that older one.

```bash
sudo apt update && sudo apt install --only-upgrade -y rpi-eeprom
```

```bash
sudo rpi-eeprom-config --edit
```

(Non-interactively: write the config below to a file and run
`sudo rpi-eeprom-config --apply <file>`. When booted from SD it only *stages*
the update, and the next reboot flashes it. Done this way on 2026-10-06; the
Pi came back with `BOOT_ORDER=0xf641` and bootloader `2026-09-25`.)
The new Pi's EEPROM, checked 2026-10-06, had `BOOT_ORDER=0xf461` (SD, NVMe,
USB) and no `PCIE_PROBE`; the bootloader is already newer than the packaged
release, so `rpi-eeprom-update -a` is a no-op there. In the editor, use this
(the old Pi's config, with `BOOT_ORDER` changed):

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

Reboot the new Pi, SSH back in, and confirm with `sudo rpi-eeprom-config`
that `BOOT_ORDER` reads `0xf641`. Leave it running for step 2.

### 2. Prepare the 256GB SSD for the worker

The patched image is already built and written on your Mac (`~/talos-worker-3-image/`).
The Mac you're working from blocks external storage, so write the image from
the new Pi, booted from the SD card, with the 256GB SSD in its HAT. (The
Imager, the MBP with a TB3 enclosure, or the MS-A2 would all need the same
file copy plus extra hardware, and the MS-A2 is the Proxmox host.)

**Built 2026-10-05:** `metal-arm64-rpi5-uboot-patched.raw`
(sha256 `3727a1ef07c1cac25a75606c83754052106eded143d085c38a0d484738f06370`, also in the
`.sha256` file beside it). It is the `yama6a/talos-raspberry-pi5` `v1.14.2-1`
`metal-arm64-rpi5.raw.xz` release asset (sha256 `c1d39f6e…2120399`, verified
against the release's `sha256sums.txt`) with `/u-boot.bin` on the EFI
partition replaced by the `hive.2` build (`9aa3c44a…de311265`, verified against the
upstream `SHA256SUMS`), so this node has the same fixed U-Boot as the combined
image in the [U-Boot fix](../talos/tools/uboot-fix/README.md) and can be
upgraded. Re-verify the file on your Mac first:

```bash
shasum -a 256 -c ~/talos-worker-3-image/metal-arm64-rpi5-uboot-patched.raw.sha256
```

1. Power the new Pi off, install the **256GB** SSD in its HAT (the 1TB SSD
   stays out of this Pi until the window), and boot from the SD card again.
   Confirm there's exactly one NVMe device, `nvme0n1`, before writing
   anything. **The SD card is also ~238G** (`mmcblk0`), so size alone won't
   tell them apart: the target is `/dev/nvme0n1`, never `/dev/mmcblk0`, which
   is the OS you're running from.

   **On the new Pi:**

```bash
lsblk -o NAME,SIZE,MODEL
```

2. **From your Mac**, stream the image to the SSD, with no intermediate file
   (the image is mostly zeros and compresses to ~110MB). This assumes the Pi's
   user has passwordless sudo, the Raspberry Pi OS default:

```bash
xz -T0 -c ~/talos-worker-3-image/metal-arm64-rpi5-uboot-patched.raw | ssh <user>@<new-pi-address> 'xz -dc | sudo dd of=/dev/nvme0n1 bs=4M conv=fsync status=progress'
```

   If sudo asks for a password, the pipe fails. Instead `scp` the file
   `xz -T0 -k ~/talos-worker-3-image/metal-arm64-rpi5-uboot-patched.raw` to the Pi, and on the Pi run
   `xz -dc <file>.xz | sudo dd of=/dev/nvme0n1 bs=4M conv=fsync status=progress`.

3. Verify the write. **On the new Pi** the output should be the checksum from
   the `.sha256` file (`3727a1ef…8f06370`):

```bash
sudo head -c 2355101696 /dev/nvme0n1 | sha256sum
```

4. Optional but recommended: **test-boot the image on real Pi 5 hardware**
   before the window. Run `sudo shutdown -h now` on the new Pi, take the SD
   card **out**, and power it on. With no SD card it falls through to the
   NVMe and Talos should come up in maintenance mode on a DHCP address (find
   it in UniFi). From rpi5-1:

```bash
talosctl -n <its-address> get disks --insecure
```

   **Don't apply a config.** Maintenance mode writes nothing to the disk, so
   the SSD stays ready; reflash it if you want a pristine disk.
5. Power the Pi off and take the 256GB SSD out, along with its HAT; it goes
   into the old Pi during the window. Keep the SD card for the new Pi's rollback, but make
   sure it's out of the Pi before the window (see the boot-order note above).

If you ever rebuild the image for a newer release: download the release's
`metal-arm64-rpi5.raw.xz`, `xz -d` it, attach it with
`hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount`, mount the
first (EFI) partition, copy the verified `u-boot.bin` over `u-boot.bin`, then
delete the `._u-boot.bin` file macOS leaves behind before detaching.

The image has the `iscsi-tools` and `util-linux-tools` extensions built in,
like the control planes. This node's `machine.install.image` is the plain
`v1.14.2-1` tag only so the config applies; every future `talosctl upgrade`
of it needs `--image` with a combined image, per the
[U-Boot fix](../talos/tools/uboot-fix/README.md) "Full sequence per node".

### 3. Write the worker's Talos config

`talos/patches/workers/worker-3.yaml` (committed) holds this node's
hostname, NIC-speed label, install image and the iSCSI `extraMounts`; see its
comments. Render the per-node config **on rpi5-1**, before the window:

```bash
cd ~/talos/homelab && talosctl machineconfig patch worker.yaml -p @$HOME/dev/homelab/talos/patches/workers/worker-3.yaml -o worker-3.yaml && talosctl validate -c worker-3.yaml -m metal
```

Don't re-apply the shared patches here: `worker.yaml` already has
`kubelet-log-limits`, `kubelet-parallel-image-pulls`, `nameservers` and the
security profile folded in, and the JSON6902 ones can't be applied to a
multi-document config anyway. (Rendered and validated 2026-10-05: hostname,
label, Pi 5 install image, iSCSI mounts, nameservers and the security
profile all present.) Two choices worth knowing about:

- **iSCSI:** the patch has no `kernel.modules: iscsi_tcp`, unlike the other
  workers, because the yama6a kernel builds it in (`CONFIG_ISCSI_TCP=y`) and
  the control planes run the same image without it. After the node joins,
  check `talosctl -n 192.168.102.35 get extensions` shows both extensions; if
  a PVC-backed pod can't attach, add the module entry.
- **Kernel logs.** The other workers send theirs to Vector on `.2` with the
  `talos.logging.kernel=udp://192.168.102.2:5140/` kernel arg, baked into
  their Image Factory schematics (see "Talos kernel logs" in
  [`talos/README.md`](../talos/README.md)). This node boots the Pi 5
  installer, not a Factory schematic, and `machine.install.extraKernelArgs`
  is ignored under SDBoot, so there is no obvious way to add the arg. The
  control planes have the same gap and were left out on purpose; leave this
  node out too unless you decide otherwise. If you do add it later, the new
  rpi5-1 must keep `.2` and Vector's `5140/udp` mapping.

`worker-3.yaml` (the patch) is committed in the same PR as these runbook
changes, so nothing needs committing while the jump box is off. Only the
rendered per-node `worker-3.yaml` in `~/talos/homelab` stays on the jump box.

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
  a static address on the Pi), old Pi MAC → `192.168.102.35`.

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

1. Move the **1TB SSD, on its 2280-capable HAT**, from the old Pi to the new
   Pi.
2. Fit the **256GB SSD, on the new Pi's 2230/2242 HAT**, into the old Pi.
   (Each SSD stays on its HAT; the HAT is what moves.)
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

MACs: old Pi `88:a2:9e:2b:0c:2d`, new Pi `98:fe:54:51:5e:4a`.

UniFi refuses to assign an IP that another client is using, and a Pi keeps its
lease until it renews. Free `.2` and `.35` ahead of time by moving the old
Pi's reservation to a temporary spare address (done 2026-10-06: `.5`),
rebooting it so it renews onto that address, and then shutting it down. Note
that a reservation's name goes with its address, so `rpi5-1.lan` follows it
(it resolved to `.5` for a while); use IPs until both Pis are on their final
ones.

**In UniFi**, first remove any temporary reservation on the new Pi's MAC (it
was given `.35` during preparation, which is the worker's address and would
block step 1). Then, in this order, so the two Pis never hold `.2` at once:

1. Old Pi's MAC → `192.168.102.35`.
2. New Pi's MAC → `192.168.102.2` (and the IPv6 address, if reserved).

### 5. Power on the new Pi and verify it is rpi5-1

Power it on and wait a minute or two. If it doesn't answer on `.2`, check the
switch port for a MAC address filter (the new Pi's MAC differs from the old
Pi's); that cost 2026-10-06's window an extra while.

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
`192.168.102.35` from DHCP and sits in maintenance mode.

**On rpi5-1:**

```bash
talosctl -n 192.168.102.35 get disks --insecure
```

If that shows the NVMe disk, apply the config:

```bash
cd ~/talos/homelab && talosctl apply-config --insecure -n 192.168.102.35 --file worker-3.yaml
```

`worker-3.yaml` is the per-node file you rendered in step 3 of "Before the window".
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
talosctl -n 192.168.102.35 get machinestatus,extensions,resolvers
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

### 8. Put DHCP back

Restore normal lease times. RA wasn't changed (see the IPv6 precondition).
Note the end time.

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
| Hubble CLI, helm, kubeconfig | `hubble status -P` (needs the port-forward flag), `helm list -A`, `kubectl get ns` | all work, no new credentials needed |

Also check what you can't see from here: that the Brevo relay and the
Cloudflare Access allowlist are still fine (same WAN, so nothing to change
unless egress routing differs), and that the SigNoz and Telegraf alerts that
fired during the window resolve themselves.

## Rollback

The old SSD is never written to by anything except normal use, so rolling
back is a swap in reverse.

**If the new Pi won't come up as rpi5-1** (at step 5): power it off, put the
1TB SSD (with its HAT) back in the old Pi, move the UPS cable and reservation back (old
Pi's MAC → `.2`), and power on. The old Pi comes back exactly as it was. Move
the Talos SSD out of it afterwards if you want to try again.

**If the worker won't join** (at step 6): nothing about the cluster or the
jump box depends on it, so you can just power the old Pi off and leave it.
The cluster has worked without it so far; retry later.

**If the cluster misbehaves after the worker joins** (unexpected churn,
Cilium trouble): `kubectl drain` and `kubectl delete node talos-worker-3`,
then power the Pi off.

## After the swap: follow-ups

Done 2026-10-06: the docs that named the old arrangement, the host cleanup on rpi5-1 (`wlan0` and its watchdog,
Bluetooth and avahi, and about 31G of old files moved to TrueNAS or deleted), the SigNoz packet-loss alert and Telegraf no longer pinging `.3`, and uncordoning
`talos-worker-3` after the arm64 audit.

Still open:

- Descheduler: run by hand 2026-10-06 after the uncordon; it moved 10 pods in two runs and the third run evicted
  nothing (see "After a rolling node change" in [`talos/README.md`](../talos/README.md)).
- The U-Boot fix is already built into `talos-worker-3`'s disk image. Its first Talos upgrade still needs `--image` with
  a combined image, not the plain tag.
