resource "proxmox_download_file" "talos_worker_image" {
  node_name    = var.proxmox_node_name
  content_type = "import"
  datastore_id = "local"
  file_name    = "talos-v1.11.5-iscsi-nocloud-amd64.qcow2"

  # Stock (non-Pi5) Talos + siderolabs/iscsi-tools extension (needed for
  # democratic-csi iSCSI volumes against HexOS/TrueNAS) — see talos/README.md
  # for how this schematic ID/URL was derived from Image Factory. Both
  # running workers are upgraded in place via `talosctl upgrade`, not
  # rebuilt from this image, so this pin can silently drift behind what's
  # actually running (it has before — see talos/README.md's "Machine-config
  # install.image drift" section). Before rebuilding a worker from scratch,
  # check talos/README.md's "Current state" for the schematic/version
  # actually in use and update this URL to match first.
  # TODO: pin checksum/checksum_algorithm once we can fetch a checksum alongside the image.
  url = "https://factory.talos.dev/image/c9078f9419961640c712a8bf2bb9174933dfcf1da383fd8ea2b7dc21493f8bac/v1.11.5/nocloud-amd64.qcow2"
}
