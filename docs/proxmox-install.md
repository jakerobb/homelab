# Installing Proxmox VE on the MS-A2

Manual runbook — a one-time OS install via KVM-over-IP isn't something Terraform
can do. This replaces the Windows install entirely.

## 1. Get the ISO

- **Proxmox VE 9.2-1** — `https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso`
  (SHA256 `4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c`)
- If the Comet X's virtual media library supports adding media by URL directly,
  use that — saves uploading ~1.7GB twice. Otherwise download to the Mac first,
  then upload to the Comet X.
- **Verify the checksum** after download, before mounting:
  ```bash
  shasum -a 256 proxmox-ve_9.2-1.iso
  # should match 4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c
  ```

## 2. Boot the installer

- Mount the ISO as virtual media on the Comet X, power on the MS-A2, and use its
  boot menu to boot from the virtual optical drive.

## 3. Disk selection — the step that matters most

By this point all three drives are physically installed (1TB boot SSD + T500 2TB +
P3 Plus 4TB). **The installer must target only the original 1TB boot SSD.**
The P3 Plus is already backed up to B2, so this isn't a data-loss risk anymore,
but there's still no reason to let the installer anywhere near the T500 or P3
Plus — they're HexOS's disks later, passed through raw. Double-check the selected
target disk by size/model before confirming.

Filesystem: plain **ext4** is the simpler choice here — this is a single boot
disk with no redundancy to gain from ZFS, and keeping the host's own root
filesystem lightweight avoids stacking a second ZFS ARC on top of whatever
HexOS's VM does later. (ZFS-on-root is a reasonable alternative if you want
host-level snapshots, but not required.)

## 4. Network configuration (in the installer)

- **Hostname:** `pve` (matches the default already set in
  `terraform/proxmox/variables.tf` — using something else is fine, just update
  that default afterward).
- **Static IP:** `192.168.102.21/24`
- **Gateway:** `192.168.102.1` (the UCG, per the existing FRR config in
  `talos/cilium/bgp/ucg-frr-reference.conf`)
- **VLAN tagging — check this before you get here:** confirm in the UniFi
  controller whether the switch port feeding the MS-A2 delivers the Server VLAN
  **untagged (access port)** or **tagged (trunk)**.
  - If untagged/access (likely, matching how the Pi control-plane nodes are set
    up with no VLAN awareness in their own OS config): no special bridge config
    needed, just use the default `vmbr0` with the static IP above.
  - If tagged/trunk: `vmbr0` needs VLAN awareness enabled, and the management IP
    needs to live on a `vmbr0.102`-style VLAN interface instead of directly on
    `vmbr0`.

## 5. Post-install housekeeping

Proxmox VE 9 (Debian 13/trixie) uses the new deb822 `.sources` format, not the
old one-line `.list` files.

```bash
# Disable the enterprise repo nag (add "Enabled: no" to the existing entry)
sed -i '/^Suites:/a Enabled: no' /etc/apt/sources.list.d/pve-enterprise.sources

# Add the no-subscription repo
cat > /etc/apt/sources.list.d/proxmox.sources <<'SOURCES'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
SOURCES

# PVE 9 also ships a SEPARATE enterprise repo just for Ceph packages, which also
# 401s on `apt update` without a subscription. We're not running Ceph on a
# single-node box, so just disable it too (check the exact filename first —
# it's been renamed between point releases before):
ls /etc/apt/sources.list.d/*.sources
sed -i '/^Suites:/a Enabled: no' /etc/apt/sources.list.d/ceph.sources

apt update && apt full-upgrade -y
```

- **NTP:** point at your existing infra rather than defaults — edit
  `/etc/chrony/chrony.conf` (Proxmox 9 uses chrony) and replace the default pool
  with whatever NTP source the rest of the homelab uses.
- **Config backup:** once stable, back up `/etc/pve` (or at minimum note the
  install) — there's no automation for this yet.

## 6. After this

Terraform in `terraform/proxmox/` can take over from here — it needs an API
token (see `terraform/proxmox/README.md`) and the real values for node name,
storage pool, and bridge/VLAN that only exist once this install is done.
