resource "proxmox_download_file" "talos_worker_image" {
  node_name    = var.proxmox_node_name
  content_type = "import"
  datastore_id = "local"
  file_name    = "talos-v1.11.5-iscsi-nocloud-amd64.qcow2"

  # Stock (non-Pi5) Talos v1.11.5 + siderolabs/iscsi-tools extension (needed
  # for democratic-csi iSCSI volumes against HexOS/TrueNAS) — see
  # talos/README.md for how this schematic ID/URL was derived from Image
  # Factory. Both running workers were upgraded in place via `talosctl
  # upgrade` rather than rebuilt from this image; this keeps a from-scratch
  # worker rebuild consistent with what's actually running.
  # TODO: pin checksum/checksum_algorithm once we can fetch a checksum alongside the image.
  url = "https://factory.talos.dev/image/c9078f9419961640c712a8bf2bb9174933dfcf1da383fd8ea2b7dc21493f8bac/v1.11.5/nocloud-amd64.qcow2"
}
