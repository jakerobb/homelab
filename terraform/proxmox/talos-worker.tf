# Two smaller workers rather than one big one, on purpose: with only 3
# control-plane Pis (tainted, no workloads) and a single worker, a Talos
# upgrade of that one worker would leave the cluster with zero schedulable
# capacity until it came back. Two workers means one can be cordoned/upgraded
# while the other keeps serving. Both still share the MS-A2's fate on a real
# hardware failure — that only gets fixed once more physical machines join.
locals {
  talos_workers = {
    talos-worker-1 = { mac_address = "02:00:00:00:00:31" } # -> 192.168.102.31
    talos-worker-2 = { mac_address = "02:00:00:00:00:32" } # -> 192.168.102.32
  }
}

resource "proxmox_virtual_environment_vm" "talos_worker" {
  for_each = local.talos_workers

  node_name = var.proxmox_node_name
  name      = each.key

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
    dedicated = 4096
    # No `floating` set — ballooning disabled, per root README step 4.
  }

  scsi_hardware = "virtio-scsi-pci"

  disk {
    interface    = "scsi0"
    datastore_id = "local-lvm"
    import_from  = proxmox_download_file.talos_worker_image.id
    file_format  = "raw"
    # Talos's nocloud image is small (a few GB) — grow it on import. Verify on
    # first apply that this actually resizes rather than just failing/ignoring.
    size = 64
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = each.value.mac_address
  }

  vga {
    type = "none" # headless — Talos has no console UI to speak of
  }

  # Boot straight into the imported Talos disk image (already-installed,
  # boots to maintenance mode) — no separate ISO / initial-install step needed.
}
