# homelab
This repo contains IaC and related stuff for my homelab.


# TODO

## 1. Backup the 4TB P3 Plus
- [ ] Sign up for Backblaze B2, create a bucket (e.g. `p3plus-archive-temp`)
- [ ] Generate an application key scoped to that bucket only
- [ ] Install `rclone` on whatever machine can currently read the P3 Plus (Mac via USB-NVMe enclosure, or the A2 itself before wipe if you have a spare dock/adapter)
- [ ] `rclone config` — add the B2 remote
- [ ] `rclone copy /path/to/p3plus b2:p3plus-archive-temp --progress --transfers=8`
- [ ] `rclone check /path/to/p3plus b2:p3plus-archive-temp` to verify integrity (don't skip this)
- [ ] Spot-check a few files by downloading and opening them
- [ ] Only proceed to step 2 once you've confirmed the backup is good — this is your only copy once the drive is wiped

## 2. Physical SSD Installation
- [ ] Power down the A2 fully, unplug from PDU outlet (or switch it off via PDU Pro if you want a hard cut)
- [ ] Check MS-A2 NVMe slot count/keying before opening — confirm both slots are free and compatible with the T500 and P3 Plus form factors
- [ ] Install T500 (2TB) and P3 Plus (4TB) into available M.2 slots alongside the existing 1TB boot SSD
- [ ] Reassemble, reseat KVM/network cables, power on
- [ ] Confirm both new drives are detected (BIOS or live Linux USB) before going further

## 3. Install Proxmox VE
- [ ] Download Proxmox VE ISO on your Mac
- [ ] Use the GL.iNet Comet X to mount the ISO (virtual media) or flash to USB and boot from port 2
- [ ] Install Proxmox to the original 1TB SSD — leave T500 and P3 Plus untouched during install
- [ ] Set static management IP (reuse 192.168.102.21 or pick a new one — decide now, since Talos config will reference it)
- [ ] Confirm VLAN tagging is correct for Server VLAN on the bridge (vmbr0)
- [ ] Switch to the no-subscription repo, disable enterprise repo nag, `apt update && apt full-upgrade`
- [ ] Set NTP source (point at your existing infra, not just defaults)
- [ ] Take a config backup / note down the install once stable

## 4. Talos VM → Join Existing Cluster
- [ ] Download the Talos qcow2 image matching the version running on your 3-node Pi control plane
- [ ] Create VM: q35 machine type, UEFI (OVMF), virtio-net, virtio-scsi, **memory ballooning disabled**
- [ ] Boot the VM, capture its maintenance-mode IP
- [ ] Generate/adapt worker config from your existing cluster's `talosctl gen config` output (same cluster CA/secrets)
- [ ] `talosctl apply-config` to join as worker
- [ ] Verify with `kubectl get nodes` — confirm `kubernetes.io/arch=amd64` label auto-applied
- [ ] Check Cilium BGP peering picks up the new node correctly — this is a new peer, so verify your `CiliumBGPClusterConfig` covers it (don't assume it's automatic just because the CRDs exist)
- [ ] Watch for any DaemonSets that might crash-loop on amd64 (the mixed-arch trap you already know about)
- [ ] Schedule a test workload on it to confirm it's live

## 5. HexOS VM with T500 + P3 Plus
- [ ] Check IOMMU groups for both NVMe drives — confirm they're isolated enough for clean passthrough
- [ ] Enable IOMMU in Proxmox host (kernel params) if not already on
- [ ] Create HexOS VM: allocate adequate RAM (8GB+ baseline, more helps ZFS ARC), reasonable vCPU count
- [ ] PCIe-passthrough both NVMe drives individually (not virtual disks) — HexOS/ZFS wants raw block access
- [ ] Install HexOS in the VM
- [ ] Decide pool layout: mirror (2TB usable, gives you redundancy to test) vs. stripe (6TB usable, no redundancy) — given mismatched capacities, mirror wastes 2TB of the P3 Plus unless partitioned separately
- [ ] Set up NFS or SMB share, test from another device on the network
- [ ] Once the pool is confirmed healthy, `rclone copy` the archived data back down from B2
- [ ] Verify restored data integrity, then delete the B2 bucket to stop paying for it

## Notes / Open Decisions
- Confirm whether Proxmox management IP and Talos VM IP should be on the same VLAN/subnet or split
- BGP peering config may need an explicit update for the new Talos worker node, not just automatic pickup
- Mirror vs. stripe on mismatched-capacity drives is worth a deliberate call, not a default
