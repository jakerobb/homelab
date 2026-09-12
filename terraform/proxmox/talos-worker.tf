resource "proxmox_virtual_environment_vm" "talos_worker_msa2" {
  node_name = var.proxmox_node_name
  name      = "talos-worker-msa2"

  machine = "q35"
  bios    = "ovmf"

  efi_disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
  }

  cpu {
    type  = "host"
    cores = 4
  }

  memory {
    dedicated = 8192
    # No `floating` set — ballooning disabled, per root README step 4.
  }

  scsi_hardware = "virtio-scsi-pci"

  disk {
    interface    = "scsi0"
    datastore_id = "local-lvm"
    import_from  = proxmox_download_file.talos_worker_msa2.id
    file_format  = "raw"
    # Talos's nocloud image is small (a few GB) — grow it on import. Verify on
    # first apply that this actually resizes rather than just failing/ignoring.
    size = 64
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = "02:00:00:00:00:22" # locally-administered, encodes the planned .22 IP for memorability
  }

  vga {
    type = "none" # headless — Talos has no console UI to speak of
  }

  # Boot straight into the imported Talos disk image (already-installed,
  # boots to maintenance mode) — no separate ISO/ initial-install step needed.
}
