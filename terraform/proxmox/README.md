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
- `hexos.tf` written (2026-09-13) — IOMMU is on, both target drives sit alone
  in their own IOMMU group (clean passthrough, no ACS override needed), see
  `docs/hexos-install.md`. Installer ISO is downloaded by Proxmox directly
  (`proxmox_download_file`, same pattern as the Talos qcow2) — HexOS's own
  site only offers a USB-flashing tool, but it's TrueNAS SCALE underneath and
  a plain ISO exists at `downloads.hexos.com`. **Not applied yet.**

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
- `hexos` VM (`hexos.tf`) — q35, UEFI (OVMF), 6 vCPU / 8GB RAM (ballooning
  disabled — ZFS ARC wants stable RAM), boots from the TrueNAS SCALE-based
  HexOS ISO (`hexos_iso` resource, downloaded directly by Proxmox) on first
  apply. `hostpci0`/`hostpci1` pass through the P3 Plus (`0000:08:00.0`) and
  T500 (`0000:09:00.0`) individually and raw, not as virtual disks.

## Running this

This repo is cloned read-only (HTTPS, no credentials needed — it's a public repo)
on **rpi5-1** at `~/dev/homelab`, which is also where Terraform itself now lives
(`/usr/local/bin/terraform`, v1.16.2) — same jump-box convention as `talosctl`.
Run `terraform plan`/`apply` from there rather than from a Mac.
