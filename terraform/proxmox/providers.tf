provider "proxmox" {
  endpoint = var.proxmox_endpoint

  # API token, not root password. Create after Proxmox install with:
  #   pveum user add terraform@pve
  #   pveum aclmod / -user terraform@pve -role Administrator
  #   pveum user token add terraform@pve provider --privsep 0
  # Then export PROXMOX_VE_API_TOKEN="terraform@pve!provider=<uuid>" — do not put it in a .tf/.tfvars file.
  api_token = var.proxmox_api_token

  insecure = var.proxmox_insecure_tls
}
