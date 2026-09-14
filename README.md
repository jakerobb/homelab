# homelab
This repo contains IaC and related stuff for my homelab.

## Current architecture

- **Network:** Ubiquiti, Server VLAN `192.168.102.0/24`. Talos jump box (`rpi5-1`,
  `.2`, holds `talosctl` + cluster secrets) · 3-node Talos control plane (`.11`-`.13`,
  Raspberry Pi 5 4GB) · MS-A2 (`.21`) running Proxmox VE, hosting two Talos worker
  VMs — `talos-worker-1` (`.31`) and `talos-worker-2` (`.32`) — joined to the cluster.
- **Existing cluster:** Talos v1.11.5, Kubernetes v1.34.1, Cilium CNI with
  `kubeProxyReplacement`, full eBPF host routing, and L2 announcements for
  LoadBalancer IPs (`192.168.102.128/26`) — BGP was the original design but hit
  an unresolved UCG Fiber routing bug, see `talos/README.md` for the writeup.
  Control-plane nodes use a **custom Pi5 installer image** — any amd64 node must use
  the stock Talos installer instead. Details and gotchas live in
  [`talos/README.md`](talos/README.md).
- **Outside the cluster:** the original RPi5 16GB stays on Docker Compose duty for
  hardware-pinned things (e.g. NUT client for the UPS) until/unless that changes later.
- **IaC layout:**
  - [`talos/`](talos/) — non-secret Cilium config and per-node Talos patches
    applied to the existing cluster.
  - [`terraform/proxmox/`](terraform/proxmox/) — Proxmox VM definitions; the two
    Talos worker VMs are provisioned from here, applied from rpi5-1.
  - Anything that can't reasonably be IaC'd (BIOS/IOMMU toggles, HexOS's GUI-only pool
    setup) gets a step-by-step runbook here instead of being skipped.

# TODO

## 1. Backup the 4TB P3 Plus
- [x] Sign up for Backblaze B2
- [x] Create the bucket + a bucket-scoped application key by running [`scripts/b2-p3plus-backup-setup.sh`](scripts/b2-p3plus-backup-setup.sh) (needs the `b2-tools` Homebrew formula; script prompts for your B2 credentials interactively, doesn't store them)
- [x] Install `rclone` + the `b2` CLI on the Intel MBP (the machine with P3 Plus access — the primary Mac is managed and blocks external storage). **Not via Homebrew** — that machine's macOS (Sequoia 15.7.9, can't upgrade) can't satisfy Homebrew's Command Line Tools version gate. Instead: download the static `rclone` binary directly from [downloads.rclone.org](https://downloads.rclone.org/) (no dependencies), and `python3 -m pip install --user b2` (pure Python, works with whatever CLT is already present — invoke as `python3 -m b2` if the `b2` command isn't on PATH afterward)
- [x] `rclone config` on the Intel MBP — add the B2 remote using the **scoped** keyID/applicationKey from the script above, not your master account key
- [x] `rclone copy /path/to/p3plus b2:p3plus-archive-temp --progress --transfers=8`
- [x] `rclone check /path/to/p3plus b2:p3plus-archive-temp` to verify integrity (don't skip this)
- [x] Spot-check a few files by downloading and opening them
- [x] Only proceed to step 2 once you've confirmed the backup is good — this is your only copy once the drive is wiped

## 2. Physical SSD Installation
- [x] Power down the A2 fully, unplug from PDU outlet (or switch it off via PDU Pro if you want a hard cut)
- [x] Check MS-A2 NVMe slot count/keying before opening — confirm both slots are free and compatible with the T500 and P3 Plus form factors
- [x] Install T500 (2TB) and P3 Plus (4TB) into available M.2 slots alongside the existing 1TB boot SSD
- [x] Reassemble, reseat KVM/network cables, power on
- [x] Confirm both new drives are detected (BIOS or live Linux USB) before going further

## 3. Install Proxmox VE
Full runbook (ISO version/checksum, disk-selection safety note, network/VLAN
config, post-install repo setup): [`docs/proxmox-install.md`](docs/proxmox-install.md).
- [x] Download Proxmox VE 9.2-1, verify checksum, mount via Comet X virtual media
- [x] Install to the original 1TB SSD only — T500 and P3 Plus must not be touched
- [x] Static IP `192.168.102.21`, gateway `192.168.102.1` — confirm UCG switch port VLAN mode (access vs. trunk) before this step
- [x] Post-install: no-subscription repo (watch for a *second* enterprise repo file just for Ceph — also needs disabling), `apt full-upgrade`
- [x] NTP source — no local NTP currently exists; check whether the UCG offers a built-in NTP server before deciding to point at public pools instead
- [x] Config backup — see [`docs/proxmox-config-backup.md`](docs/proxmox-config-backup.md) (script written, key installed on rpi5-1; still needs deploying + cron install on the Proxmox host itself)

## 4. Talos VM → Join Existing Cluster
- [x] Secrets bundle is now committed encrypted (SOPS+age) — see [`talos/README.md`](talos/README.md#secrets-sops--age-decided-2026-09-08). Still using plain `talosctl` (not Talhelper) to render machine configs from it.
- [x] Copy the age private key (`~/.config/sops/age/keys.txt`) into 1Password for durability
- [x] Talos image source resolved: built via [Image Factory](https://factory.talos.dev) (not a GitHub release) — see `talos/README.md` for the exact v1.11.5 qcow2 URL, distinct from the `ghcr.io/talos-rpi5/installer` image the Pi control plane uses
- [x] **Two** workers, not one — decided 2026-09-11 so a Talos upgrade doesn't leave the cluster with zero schedulable capacity (see `talos/README.md`). `talos-worker-1` (`.31`) / `talos-worker-2` (`.32`) — `.21-.29` is reserved for physical hosts, `.31+` for VMs — 4 vCPU / 4GB RAM each, patches at `talos/patches/workers/`
- [x] Terraform written for both VMs (`terraform/proxmox/talos-worker.tf`, `images.tf`), applied from rpi5-1
- [x] DHCP reservations added on the UCG for both fixed MACs → `.31`/`.32`
- [x] Both VMs booted, worker configs generated and applied via `talosctl apply-config` (reused the existing cluster's secrets bundle — same cluster CA)
- [x] `kubectl get nodes` confirms both `Ready` with `kubernetes.io/arch=amd64`
- [x] No DaemonSets crash-looping on amd64 (Cilium + cilium-envoy both 5/5 across all nodes)
- [x] Test workload scheduled and confirmed live (spread correctly across both new workers)
- [x] **External LoadBalancer traffic was broken cluster-wide** (found while testing the above) — root cause was an unresolved UCG Fiber routing bug with BGP-learned routes, not anything in the cluster. Pivoted from BGP to Cilium L2 announcements; see `talos/README.md` for the full investigation and current LB pool (`192.168.102.128/26`). The UCG's now-unused BGP peering config should be removed there.

## 5. HexOS VM with T500 + P3 Plus
Runbook: [`docs/hexos-install.md`](docs/hexos-install.md).
- [x] Enable IOMMU in Proxmox host (kernel params) — `amd_iommu=on iommu=pt` added to `GRUB_CMDLINE_LINUX_DEFAULT`, confirmed live post-reboot (the `AMD-Vi: Unknown option - 'on'` dmesg line is a harmless, expected quirk — see runbook)
- [x] Check IOMMU groups for both NVMe drives — both isolated alone in their own group (P3 Plus = group 17 @ `0000:08:00.0`, T500 = group 18 @ `0000:09:00.0`), no ACS override needed
- [ ] Create HexOS VM: allocate adequate RAM (8GB+ baseline, more helps ZFS ARC), reasonable vCPU count — Terraform written (`terraform/proxmox/hexos.tf`), not yet applied (needs the HexOS ISO uploaded to Proxmox first)
- [x] PCIe-passthrough both NVMe drives individually (not virtual disks) — HexOS/ZFS wants raw block access — `hostpci0`/`hostpci1` in `hexos.tf`
- [ ] Install HexOS in the VM
- [ ] Pool layout — decided: stripe (6TB usable, no redundancy) unless HexOS's ZFS AnyRaid is ready to use by then, in which case use that instead for flexible-capacity redundancy. Plain mirror is out (wastes 2TB of the P3 Plus given mismatched capacities).
- [ ] Set up NFS or SMB share, test from another device on the network
- [ ] Once the pool is confirmed healthy, `rclone copy` the archived data back down from B2
- [ ] Verify restored data integrity. **Keep the B2 backup for a few extra weeks** as insurance against early failure of the new (non-redundant, unless AnyRaid) pool before deleting the bucket — don't delete immediately just because the pool checks out on day one.

## Notes / Open Decisions
- ~~Confirm whether Proxmox management IP and Talos VM IP should be on the same VLAN/subnet or split~~ — decided: same VLAN/subnet (`192.168.102.0/24`) as the existing cluster.
- ~~BGP peering config may need an explicit update for the new Talos worker node~~ — moot: BGP itself was abandoned after an unresolved UCG Fiber routing bug, replaced with L2 announcements (see step 4, `talos/README.md`).
- ~~Mirror vs. stripe on mismatched-capacity drives~~ — decided: stripe, or AnyRaid if HexOS has shipped it by the time we get there (see step 5).
- ~~How Talos secrets get versioned~~ — decided: SOPS+age, encrypted bundle committed to the repo (see `talos/README.md`).
