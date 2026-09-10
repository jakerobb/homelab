# Proxmox (Terraform)

Provider: [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest) v0.112.0.

## Status

Proxmox VE isn't installed yet (root README, step 3), so there are no VM resources
here yet — `main.tf` will hold the Talos worker VM and HexOS VM definitions once the
host exists and we know real values for:

- `proxmox_node_name` (set during Proxmox install)
- Storage pool name(s) for VM disks (default `local-lvm` unless changed at install)
- The bridge/VLAN to attach VM NICs to (Server VLAN on `vmbr0`, per root README step 3)
- Whether the two NVMe drives get passed through as raw PCI devices (`hostpci`, see
  root README step 5) — this needs IOMMU group info gathered *after* Proxmox is up

## Auth

Uses an API token, not the root password — see the comment in `providers.tf` for how
to create one after install. Set it via environment variable, never in a `.tf`/`.tfvars`
file:

```bash
export TF_VAR_proxmox_api_token="terraform@pve!provider=<uuid>"
```

## Planned resources

- `talos-worker-msa2` VM — q35, UEFI (OVMF), virtio-net, virtio-scsi, memory
  ballooning disabled, boots the stock (non-rpi5) Talos qcow2. See
  `../../talos/README.md` for the version/installer-image gotcha.
- `hexos` VM — 8GB+ RAM baseline, PCIe passthrough of both NVMe drives (not virtual
  disks).
