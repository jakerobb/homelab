# Proxmox (Terraform)

Provider: [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest) v0.112.0.

## Status

Proxmox VE is installed (root README step 3 done — hostname `proxmox`, static IP
`192.168.102.21`, ext4 on the 1TB boot SSD). `images.tf` and `talos-worker.tf`
have a clean `terraform plan` against the real host (ran from rpi5-1, 2 to add,
0 to change/destroy) — `local-lvm` and `vmbr0` are confirmed real, not just
assumed defaults. **Not applied yet.** Known follow-ups before/at first apply:

- Pin `checksum`/`checksum_algorithm` on the `proxmox_download_file` resource once
  we have a checksum for the Image Factory qcow2 (Image Factory doesn't publish one
  alongside the image the way GitHub releases do)
- Verify the disk actually grows to `size = 64` (GB) on import rather than staying
  at the source image's native (much smaller) size — untested
- Once applied, add DHCP reservations on the UCG for both fixed MACs
  (`02:00:00:00:00:31` → `.31`, `...:32` → `.32`)
- `hexos` VM is still unwritten — needs IOMMU group info gathered from the live
  host first (root README step 5), plus a real decision on `hostpci` passthrough
  syntax for the two NVMe drives

## Auth

Uses an API token, not the root password — see the comment in `providers.tf` for how
to create one after install. Set it via environment variable, never in a `.tf`/`.tfvars`
file:

```bash
export TF_VAR_proxmox_api_token="terraform@pve!provider=<uuid>"
```

## Resources

- `talos-worker-1` / `talos-worker-2` (`talos-worker.tf` + `images.tf`, `for_each`
  over `local.talos_workers`) — q35, UEFI (OVMF), virtio-net, virtio-scsi, memory
  ballooning disabled, 4 vCPU / 4GB RAM each, boots the stock (non-rpi5) Talos
  v1.11.5 qcow2 imported via Image Factory. Two workers rather than one so a
  Talos upgrade doesn't leave the cluster with zero schedulable capacity — see
  `../../talos/README.md` for that rationale and the version/installer-image
  gotcha.
- `hexos` VM — not yet written. 8GB+ RAM baseline, PCIe passthrough of both NVMe
  drives (not virtual disks).

## Running this

This repo is cloned read-only (HTTPS, no credentials needed — it's a public repo)
on **rpi5-1** at `~/dev/homelab`, which is also where Terraform itself now lives
(`/usr/local/bin/terraform`, v1.16.2) — same jump-box convention as `talosctl`.
Run `terraform plan`/`apply` from there rather than from a Mac.
