# rpi5-1 OS updates

rpi5-1 (Raspberry Pi OS, Debian 12 bookworm) is the Talos jump box. It holds
`talosctl`/`kubectl` access and cluster secrets, runs the Compose stack, and
receives the etcd and Proxmox backups. Until 2026-09-26 nothing kept its
packages up to date. The last `apt upgrade` in `/var/log/dpkg.log` was
2025-09-05. The 2026-09-26 health check found 117 pending upgrades, 49 of
them from `bookworm-security` (libssh2, libnss3, liblzma5/xz-utils, libexpat,
bind9, ca-certificates from 2023, and others). Nothing reported this, and
`unattended-upgrades` wasn't installed.

## What runs automatically

[`scripts/unattended-upgrades/`](../scripts/unattended-upgrades/) installs
`unattended-upgrades` with Debian's `apt-daily`/`apt-daily-upgrade` timers,
limited to:

- **Debian security** (`bookworm-security`) only. Bookworm is now
  `oldstable`, and Debian LTS keeps publishing its fixes to that same
  archive, so this keeps working until LTS ends (mid-2028).
- **No Docker packages.** A `docker-ce`/`containerd.io` upgrade restarts
  `dockerd` and every Compose container with it. They're blacklisted in case
  the origin list ever widens.
- **No automatic reboot.** New kernels install but don't take effect until
  someone reboots by hand.

These stay manual, on purpose, so they can be timed:

- **Debian point releases** (`bookworm-updates`, main `bookworm`)
- **The Raspberry Pi archive** (kernel, firmware, `rpi-eeprom`, and the
  `chromium` build)
- **Docker** (`download.docker.com`)

## Install (on rpi5-1)

```bash
cd ~/dev/homelab && git pull
```

```bash
scripts/unattended-upgrades/install.sh
```

The script ends with a dry run. Its "Allowed origins" line should list only
`Debian-Security`, and its "Packages that will be upgraded" list should
contain only security packages, with no `docker-*`.

The first install (2026-09-27) didn't pass that check: "Allowed origins"
also listed `codename=bookworm,label=Debian`, from Debian's stock
`50unattended-upgrades`, because apt merges list options across files. The
`#clear` line in `52unattended-upgrades-local` fixes it. It was reinstalled
the same day, and the same fix went to the Proxmox host
([`proxmox-os-updates.md`](proxmox-os-updates.md)).

## One-time catch-up (on rpi5-1)

Unattended-upgrades only applies security updates going forward. The rest of
the backlog, including Docker 29.6.0 → 29.8.x and the Raspberry Pi kernel,
needs one manual run. The Docker upgrade restarts every Compose container,
so do this when a few minutes of downtime is fine. That includes `unbound`
as well as Home Assistant, Zigbee, and NUT. Avoid 03:00–03:30,
when the Proxmox and etcd backups land here.

```bash
sudo apt update && sudo apt full-upgrade
```

```bash
cat /var/run/reboot-required 2>/dev/null && sudo reboot
```

After a reboot, confirm it actually happened with `uptime`, then check the
Compose stack with `docker ps`.

## Checking that it's working

[`scripts/unattended-upgrades/check.sh`](../scripts/unattended-upgrades/check.sh)
runs daily from cron and mails (via cron's `MAILTO`, see
[`email-alerts.md`](email-alerts.md)) if any of these is true:

- `unattended-upgrades` isn't installed, or either apt config file is missing
- its log hasn't been written in over 3 days
- a `-security` package was pending at the previous day's check and still is

It prints nothing when everything is fine. Added 2026-09-27, after the
2026-09-27 health check found the install step above had never been run:
the config was merged but `unattended-upgrades` still wasn't installed.

Install the cron entry on rpi5-1 (`MAILTO` is already set in the crontab).
09:00 is after the `apt-daily-upgrade` timer's 06:00–07:00 window:

```bash
crontab -l | { cat; echo "0 9 * * * \$HOME/dev/homelab/scripts/unattended-upgrades/check.sh > /dev/null"; } | crontab -
```

To check by hand:

```bash
apt list --upgradable 2>/dev/null | grep -c security
```

Expect 0, or a handful that are less than a day old. The run log is
`/var/log/unattended-upgrades/unattended-upgrades.log`.

## Boot order

rpi5-1's EEPROM boot order is `BOOT_ORDER=0xf641`: SD card, then USB, then NVMe (digits read right to left, `f`
repeats). That lets a bootable SD card or USB stick override the SSD for recovery or for writing disks, without
touching the EEPROM config. The flip side: **an SD card left in the Pi boots instead of the SSD.** The full config is
`BOOT_UART=1`, `BOOT_ORDER=0xf641`, `NET_INSTALL_AT_POWER_ON=1`, `PCIE_PROBE=1`; check it with
`sudo rpi-eeprom-config`. The same order was set on the Pi that became `talos-worker-3`. See
[the jump box swap](jump-box-swap.md#1-prepare-the-new-pi-from-an-sd-card) for how it was set (upgrade the `rpi-eeprom`
package first, then `rpi-eeprom-config --apply`).

## Future: Debian 13 (trixie)

Raspberry Pi OS moved to trixie in late 2025, so bookworm is now
`oldstable`. Upgrading in place is possible but not officially supported by
Raspberry Pi. The supported path is a fresh image and a restore of the
Compose stack and jump-box tooling. Not urgent while bookworm LTS still gets
security fixes. Not done in the 2026-10-06 jump box swap, which moved the
existing bookworm SSD onto the replacement 4GB Pi unchanged (the old 16GB Pi
became a Talos worker). Tracked in [`../todo/FUTURE.md`](../todo/FUTURE.md).
