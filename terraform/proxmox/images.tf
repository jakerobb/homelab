resource "proxmox_download_file" "talos_worker_image" {
  node_name    = var.proxmox_node_name
  content_type = "import"
  datastore_id = "local"
  file_name    = "talos-v1.11.5-nocloud-amd64.qcow2"

  # Stock (non-Pi5) Talos v1.11.5, no extensions — see talos/README.md for how
  # this schematic ID/URL was derived from Image Factory.
  # TODO: pin checksum/checksum_algorithm once we can fetch a checksum alongside the image.
  url = "https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.11.5/nocloud-amd64.qcow2"
}
