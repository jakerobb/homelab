#!/usr/bin/env bash
# Installs and configures unattended-upgrades (Debian security only) on
# rpi5-1. Idempotent. Run on rpi5-1 from this directory.
# See docs/rpi5-1-os-updates.md.
set -euo pipefail

cd "$(dirname "$0")"

sudo apt-get update
sudo apt-get install -y unattended-upgrades

sudo install -m 0644 20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades
sudo install -m 0644 52unattended-upgrades-local /etc/apt/apt.conf.d/52unattended-upgrades-local

# Shows which origins are allowed and which packages would be upgraded,
# without changing anything.
sudo unattended-upgrade --dry-run --debug 2>&1 | grep -E 'Allowed origins|Packages that will be upgraded|blacklist'
