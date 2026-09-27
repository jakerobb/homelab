#!/usr/bin/env bash
# Installs and configures unattended-upgrades (Debian security only) on
# rpi5-1 or the Proxmox host. Idempotent. Run on the target host from this
# directory. See docs/rpi5-1-os-updates.md and docs/proxmox-os-updates.md.
set -euo pipefail

cd "$(dirname "$0")"

# The Proxmox host has no sudo; everything there runs as root.
sudo() { if [ "$(id -u)" -eq 0 ]; then "$@"; else command sudo "$@"; fi; }

sudo apt-get update
sudo apt-get install -y unattended-upgrades

sudo install -m 0644 20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades
sudo install -m 0644 52unattended-upgrades-local /etc/apt/apt.conf.d/52unattended-upgrades-local

# Shows which origins are allowed and which packages would be upgraded,
# without changing anything.
sudo unattended-upgrade --dry-run --debug 2>&1 | grep -E 'Allowed origins|Packages that will be upgraded|blacklist'
