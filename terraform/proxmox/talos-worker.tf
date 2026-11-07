# One worker VM on the MS-A2 (collapsed from two on 2026-11-04). Two VMs on one
# host shared its fate anyway and each Talos node costs about 1.5 GiB of fixed
# overhead (cilium-agent, envoy, otel, kubelet). A Talos upgrade of this worker
# no longer leaves the cluster without schedulable capacity, since the Pi
# (talos-worker-3), the MacBook Pro VM and the planned Mac Studio VM are
# separate workers on separate machines. Still a `for_each` map so a second VM
# is a one-line addition. See docs/studio-worker-and-ram-upgrade.md.
locals {
  talos_workers = {
    talos-worker-1 = { mac_address = "02:00:00:00:00:31" } # -> 192.168.102.31
  }
}

resource "proxmox_virtual_environment_vm" "talos_worker" {
  for_each = local.talos_workers

  node_name = var.proxmox_node_name
  name      = each.key

  # Never let an apply power-cycle a worker (added 2026-09-27, same reasoning
  # as hexos.tf). The provider's default would reboot the worker undrained to
  # apply a change like a memory bump. Instead, apply, then drain and
  # stop/start the worker (or set the value live with `qm set` first) — see
  # docs/proxmox-os-updates.md#resizing-the-talos-worker-vms.
  reboot_after_update = false

  machine = "q35"
  bios    = "ovmf"

  efi_disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
  }

  cpu {
    type  = "host"
    cores = 8
  }

  memory {
    # 16 GiB since 2026-11-04 (was 8 GiB, on each of two workers). With HexOS's
    # 10 GiB that's 26 GiB of the host's 29 GiB usable, the same total as
    # before the collapse. The workers use well under 4 GiB between them, so
    # this is mostly headroom for the heavy stateful pods (Prometheus,
    # ClickHouse). Ballooning is off on every VM, so it can't be clawed back
    # later.
    dedicated = 16384
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

  lifecycle {
    # import_from only matters at disk creation time. Once a worker exists,
    # Talos owns its own upgrades (talosctl upgrade — see talos/README.md);
    # letting a changed talos_worker_image propagate here would make Terraform
    # re-import the boot disk on an already-running node, discarding whatever
    # talosctl already applied in place. A future image change should only
    # affect a from-scratch worker (new for_each key, or after a manual taint).
    ignore_changes = [disk[0].import_from]
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
