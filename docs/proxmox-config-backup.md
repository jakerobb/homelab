# Proxmox host config backup

Protects the Proxmox host state that isn't reproducible from this repo (the web
UI's TLS cert, hashed user/token database, `storage.cfg`) — not VM data, and not
a substitute for Proxmox Backup Server once there's real VM workloads worth
protecting with proper incremental backups.

## How it works

`scripts/proxmox-config-backup.sh` tars up `/etc/pve`, network config, apt
sources, and chrony config, then ships it to a dedicated `pve-backup` account on
rpi5-1 via a restricted SSH key (no PTY/port-forwarding — file transfer only),
pruning anything older than 14 days on the receiving end.

The script itself is versioned here, but it's **deployed manually** to the
Proxmox host (not something Terraform manages) and run via cron there.

## One-time setup (done 2026-09-11)

- Created `pve-backup` system user on rpi5-1 (`/home/pve-backup`, no sudo —
  deliberately not reusing `jakerobb`, which has passwordless sudo there)
- Generated `/root/.ssh/pve-backup-ed25519` on the Proxmox host, installed the
  public key into `pve-backup`'s `authorized_keys` on rpi5-1 with the `restrict`
  flag

## Deploying the script + cron job (on the Proxmox host)

```bash
# Copy the script content from scripts/proxmox-config-backup.sh in this repo
# to /usr/local/sbin/proxmox-config-backup.sh on the Proxmox host, then:
chmod 700 /usr/local/sbin/proxmox-config-backup.sh

# Test it once by hand before trusting it to cron
/usr/local/sbin/proxmox-config-backup.sh
ssh pve-backup@rpi5-1.lan ls -la backups/proxmox/   # from the Proxmox host, confirm the file landed

# Install the daily cron job (03:00)
echo "0 3 * * * root /usr/local/sbin/proxmox-config-backup.sh" > /etc/cron.d/proxmox-config-backup
```
