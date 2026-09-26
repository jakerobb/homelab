# Same B2 bucket and same scoped key as terraform/proxmox (see its backend.tf
# for why there's no native locking), just a different state key. ./tf.sh
# injects the credentials from ../proxmox/secrets/b2-state-backend.sops.yaml.
terraform {
  backend "s3" {
    bucket = "jakerobb-homelab-tfstate"
    key    = "cloudflare/terraform.tfstate"
    region = "us-east-005"

    endpoints = {
      s3 = "https://s3.us-east-005.backblazeb2.com"
    }

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
