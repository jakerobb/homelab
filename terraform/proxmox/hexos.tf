# HexOS NAS VM — PCIe passthrough of the T500 (2TB) and P3 Plus (4TB) NVMe
# drives, raw block access for its own ZFS pool rather than virtual disks.
#
# IOMMU group check (2026-09-13, live host): both drives sit alone in their
# own IOMMU group (P3 Plus = group 17, T500 = group 18) — clean isolation,
# no ACS override needed. See docs/hexos-install.md for how these PCI
# addresses were derived.
#
# PCI addresses are stable identifiers of the physical PCIe lanes the drives
# are wired to, not the drives themselves — if either NVMe is ever moved to a
# different M.2 slot on the board, these addresses (and this config) would
# need re-deriving.

locals {
  hexos_iso_file_name = "TrueNAS-SCALE-25.10.3-HexOS.iso"
}

resource "proxmox_download_file" "hexos_iso" {
  node_name    = var.proxmox_node_name
  content_type = "iso"
  datastore_id = "local"
  file_name    = local.hexos_iso_file_name

  # HexOS is TrueNAS SCALE under the hood; this is the plain ISO Proxmox VMs
  # can boot directly, as opposed to the "HexOS Imager" tool on
  # downloads/install docs, which only writes to a physical USB drive (a
  # bare-metal-install workflow that doesn't apply to a VM guest).
  # No published checksum to pin yet (see images.tf's talos_worker_image for
  # the same open TODO on the Talos qcow2).
  url = "https://downloads.hexos.com/${local.hexos_iso_file_name}"
}

resource "proxmox_virtual_environment_vm" "hexos" {
  node_name = var.proxmox_node_name
  name      = "hexos"

  machine = "q35" # required for PCIe passthrough (i440fx doesn't do it cleanly)
  bios    = "ovmf"

  efi_disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
  }

  cpu {
    type  = "host"
    cores = 6
  }

  memory {
    dedicated = 8192
    # No `floating` set — ballooning disabled. ZFS wants to size its ARC
    # against a stable amount of RAM; Proxmox reclaiming memory out from
    # under it fights that.
  }

  scsi_hardware = "virtio-scsi-pci"

  # HexOS's own boot disk — NOT the storage pool. The T500/P3 Plus are passed
  # through raw below and must never be touched by the OS installer.
  disk {
    interface    = "scsi0"
    datastore_id = "local-lvm"
    size         = 32
    file_format  = "raw"
  }

  # Installer media — remove/detach once HexOS is installed and boots clean
  # from scsi0.
  cdrom {
    file_id   = proxmox_download_file.hexos_iso.id
    interface = "ide2"
  }

  # Boot the installer first; flip to just ["scsi0"] after a successful
  # install and first boot confirmation.
  boot_order = ["ide2", "scsi0"]

  hostpci {
    device = "hostpci0"
    id     = "0000:08:00.0" # P3 Plus (4TB)
    pcie   = true
  }

  hostpci {
    device = "hostpci1"
    id     = "0000:09:00.0" # T500 (2TB)
    pcie   = true
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = "02:00:00:00:00:33" # -> 192.168.102.33 (DHCP reservation, add on the UCG)
  }

  vga {
    type = "std" # needs a console for the installer, unlike headless Talos
  }
}
