variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://192.168.102.21:8006/"
  type        = string
  default     = "https://192.168.102.21:8006/"
}

variable "proxmox_api_token" {
  description = "Proxmox API token (terraform@pve!provider=<uuid>). Set via TF_VAR_proxmox_api_token or PROXMOX_VE_API_TOKEN env var — never commit this."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure_tls" {
  description = "Skip TLS verification for the Proxmox API (fine for a self-signed homelab cert; set false once a real cert is in place)."
  type        = bool
  default     = true
}

variable "proxmox_node_name" {
  description = "Name of the Proxmox node as configured during install (Datacenter > node name), used to target VM resources."
  type        = string
  default     = "proxmox"
}
