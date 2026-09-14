# HexOS VM on the MS-A2 (T500 + P3 Plus passthrough)

Manual runbook for the parts Terraform can't do (host kernel params, IOMMU
group inspection, HexOS's own GUI installer/pool setup) — mirrors
[`docs/proxmox-install.md`](proxmox-install.md)'s split between runbook and
Terraform. Root README step 5.

## 1. Enable IOMMU on the Proxmox host

The MS-A2 is AMD (8945HX), so this is AMD-Vi, not Intel VT-d. Proxmox was
installed to plain ext4 (not ZFS-on-root), so boot is standard GRUB, not
`proxmox-boot-tool`.

```bash
# Check whether it's already on
    cat /proc/cmdline

# If amd_iommu=on isn't present, edit /etc/default/grub:
#   GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"
update-grub
reboot
```

After reboot, confirm it took:

```bash
dmesg | grep -i -e AMD-Vi -e "iommu.*enabled"
```

**Gotcha:** expect a `AMD-Vi: Unknown option - 'on'` line in there — harmless.
Unlike Intel's `intel_iommu=on`, AMD's IOMMU driver has no `on` suboption (it
auto-enables when hardware/BIOS support is present), so the kernel just
ignores that word. What actually matters is the subsequent lines confirming
AMD-Vi came up (`IOMMU performance counters supported`, `Interrupt remapping
enabled`, etc.) and that `iommu=pt` parsed without complaint.

## 2. Identify the two NVMe drives' PCI addresses

Both the T500 and P3 Plus will show up alongside the boot SSD as generic
"Non-Volatile memory controller" entries — need to correlate by size/model,
not just list them.

```bash
# Model + serial per NVMe device, to tell the boot SSD apart from T500/P3 Plus
nvme list

# PCI address + vendor:device ID for each NVMe controller
lspci -nn | grep -i nvme

# Correlate a specific /dev/nvmeX to its PCI address
for n in /sys/class/nvme/nvme*; do
  echo "$n -> $(readlink -f $n/device)"
done
```

## 3. Check IOMMU groups for those two PCI addresses

```bash
for g in /sys/kernel/iommu_groups/*/devices/*; do
  echo "Group $(basename $(dirname $(dirname $g))): $(basename $g) $(lspci -nns $(basename $g))"
done | sort -t' ' -k2 -V
```

For clean passthrough, each target NVMe controller should be **alone** (or
grouped only with something else that's also being passed through / clearly
harmless) in its own group. If a target drive shares a group with unrelated
host devices (e.g. USB controller, SATA controller Proxmox needs), passthrough
of just that drive isn't safe without an ACS override — flag it here rather
than proceeding, since `pcie_acs_override` trades isolation guarantees for
convenience and consumer/prosumer boards vary a lot.

## Results (live host, 2026-09-13)

- Boot SSD (leave alone): `0000:07:00.0` — Micron/Crucial E100
- **P3 Plus (4TB):** `0000:08:00.0` — alone in IOMMU group 17
- **T500 (2TB):** `0000:09:00.0` — alone in IOMMU group 18

Both target drives are isolated alone in their own group — clean passthrough,
no ACS override needed. These addresses are now in
[`terraform/proxmox/hexos.tf`](../terraform/proxmox/hexos.tf).

**Gotcha found 2026-09-13, on first `terraform apply`:** a raw `hostpciN` PCI
ID on the VM config is rejected outright for non-root API tokens (`only root
can set 'hostpciN' config for non-mapped devices` — HTTP 500), which breaks
this repo's API-token-only convention (`providers.tf`). Fixed by using named
PCI resource mappings instead (`proxmox_hardware_mapping_pci`, referenced via
`mapping = "..."` on the `hostpci` block rather than a raw `id`) — Terraform
creates the mappings too, no manual GUI step needed.

**Second gotcha, same day:** the mapping applies at `terraform apply` but the
VM then fails to *start* with `PCI device mapping invalid (hardware probably
changed): missing expected property 'subsystem-id'`. The `subsystem_id`
attribute is documented as optional but is actually required for Proxmox to
consider the mapping complete enough to use. Get it per drive with:

```bash
lspci -nn -vvv -s 08:00.0 | grep -i subsystem   # P3 Plus
lspci -nn -vvv -s 09:00.0 | grep -i subsystem   # T500
```

## 4. The installer ISO

The HexOS website pushes the "HexOS Imager" tool, which only writes to a
physical USB drive — a bare-metal-install workflow that doesn't apply to a VM
guest. HexOS is TrueNAS SCALE underneath, though, and there's a plain ISO:
`https://downloads.hexos.com/TrueNAS-SCALE-25.10.3-HexOS.iso` (2.18GB,
confirmed reachable 2026-09-13). `terraform/proxmox/hexos.tf` has Proxmox
download it directly (`proxmox_download_file`, same pattern as the Talos
worker qcow2 in `images.tf`) — no manual upload needed.

## 5. Apply the Terraform, install HexOS

From rpi5-1 (same convention as the Talos workers):

```bash
cd ~/dev/homelab/terraform/proxmox
terraform plan   # confirm: 1 to add (hexos), 0 to change/destroy
terraform apply
```

**Third gotcha:** the default `std` VGA adapter corrupted irrecoverably
partway through the installer's ncurses wizard (once it changed console
resolution) — a known weak spot with Linux guest console mode switches under
Cirrus/std emulation. Fixed by switching `vga.type` to `virtio` in
`hexos.tf`, which needs the VM stopped (hard **Stop**, not Shutdown — ACPI
shutdown may not register mid-installer) before reapplying.

Then, in the Proxmox web UI, open the `hexos` VM's **Console** (noVNC) and
walk through HexOS's installer same as any other OS install — target its own
32GB virtual boot disk (`scsi0`), **not** either passed-through NVMe. Once
installed and confirmed booting cleanly on its own:

- In the Proxmox UI (or by editing `hexos.tf`), change `boot_order` to just
  `["scsi0"]` and detach/remove the `cdrom` block.
- Confirm both passed-through drives are visible inside HexOS as raw block
  devices before proceeding to pool setup.

## 6. Pool + share setup (GUI-only, HexOS)

- [ ] Create the pool: stripe across both drives (6TB usable, no redundancy) —
      unless HexOS's ZFS AnyRaid has shipped by now, in which case use that
      instead for flexible-capacity redundancy (see root README step 5 notes
      on why plain mirror is out).
- [ ] Set up an NFS or SMB share, test from another device on the network.
- [ ] Once the pool is confirmed healthy, `rclone copy` the archived data back
      down from B2.
- [ ] Verify restored data integrity. Keep the B2 backup for a few extra weeks
      as insurance before deleting the bucket.
