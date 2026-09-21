# Proxmox (Terraform)

Provider: [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest) — pinned version lives in `versions.tf`.

## Status

Proxmox VE is installed (root README step 3 done — hostname `proxmox`, static IP
`192.168.102.21`, ext4 on the 1TB boot SSD). `images.tf`, `talos-worker.tf`, and
`hexos.tf` are all applied: both Talos worker VMs and the HexOS VM have been
running in production for a while now — see `talos/README.md` and
`docs/hexos-install.md` for their current state. DHCP reservations for both
fixed worker MACs (`02:00:00:00:00:31` → `.31`, `...:32` → `.32`) are in place
on the UCG.

Known follow-up, not a blocker:

- Pin `checksum`/`checksum_algorithm` on the `proxmox_download_file` resource once
  we have a checksum for the Image Factory qcow2 (Image Factory doesn't publish one
  alongside the image the way GitHub releases do)

## Auth

Uses an API token, not the root password — see the comment in `providers.tf` for how
to create one after install. Never put it in a `.tf`/`.tfvars` file.

**Run via `./tf.sh` instead of `terraform` directly** (added 2026-09-21, so the token
never needs pasting into a shell by hand): `./tf.sh plan`, `./tf.sh apply`, etc. — a thin
wrapper that decrypts `secrets/proxmox-api-token.sops.yaml` (SOPS + age, same repo key as
everywhere else — see `talos/README.md#secrets-sops--age`) and injects it as
`TF_VAR_proxmox_api_token` for just that one command, same `sops exec-env` pattern as
`scripts/etcd-snapshot-backup.sh`'s B2 credentials. One-time setup, see
`secrets/proxmox-api-token.yaml.example`.

Plain manual export still works too, if you ever need it outside the wrapper:

```bash
export TF_VAR_proxmox_api_token="terraform@pve!provider=<uuid>"
terraform plan   # not ./tf.sh, since the wrapper would override this with the sops value
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
  apply. `hostpci0`/`hostpci1` pass through the P3 Plus and T500 individually
  and raw, not as virtual disks — via named `proxmox_hardware_mapping_pci`
  mappings rather than raw PCI IDs, since raw `hostpciN` IDs are rejected for
  non-root API tokens (see `docs/hexos-install.md`).

## Running this

This repo is cloned read-only (HTTPS, no credentials needed — it's a public repo)
on **rpi5-1** at `~/dev/homelab`, which is also where Terraform itself now lives
(`/usr/local/bin/terraform`, v1.16.2) — same jump-box convention as `talosctl`.
Run `terraform plan`/`apply` from there rather than from a Mac.
