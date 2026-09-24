# Shared remote state (2026-09-24) — a private B2 bucket via B2's
# S3-compatible API, so the GitHub Actions runner and manual ./tf.sh runs on
# the jump box both see the same state. Setup/migration runbook:
# docs/gha-terraform.md.
#
# Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (a B2
# application key scoped to this one bucket), injected by ./tf.sh from
# secrets/b2-state-backend.sops.yaml — never set here.
#
# No state locking: B2 rejects the If-None-Match conditional write that
# `use_lockfile` depends on (501 NotImplemented —
# https://github.com/hashicorp/terraform/issues/37143, closed "not planned").
# Instead, tf.sh takes a host-level flock, and every run (CI or manual)
# happens on the jump box, so that lock covers everything that should ever
# touch this state.
terraform {
  backend "s3" {
    bucket = "jakerobb-homelab-tfstate"
    key    = "proxmox/terraform.tfstate"
    region = "us-east-005"

    endpoints = {
      s3 = "https://s3.us-east-005.backblazeb2.com"
    }

    # B2 is S3-compatible, not AWS — skip the AWS-only checks/features it
    # doesn't implement.
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
