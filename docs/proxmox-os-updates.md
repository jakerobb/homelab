# Proxmox host OS updates

The Proxmox host (`proxmox.lan`, PVE 9 on Debian 13 trixie) runs
talos-worker-1, talos-worker-2, and the HexOS VM. Until 2026-09-27 nothing
kept its packages up to date: the last `apt upgrade` was the 2026-09-13
install, and the 2026-09-27 check found 30 pending upgrades, 4 of them from
`trixie-security`.

It uses the same setup as rpi5-1 ([`rpi5-1-os-updates.md`](rpi5-1-os-updates.md)),
from the same [`scripts/unattended-upgrades/`](../scripts/unattended-upgrades/).

## What runs automatically

`unattended-upgrades` with Debian's `apt-daily`/`apt-daily-upgrade` timers,
limited to **Debian security** (`trixie-security`). It never reboots on its
own and never removes old kernels.

These stay manual, on purpose, so they can be timed:

- **Proxmox's own repo** (`pve-no-subscription`): PVE, QEMU, the
  `proxmox-kernel-*` kernels, Ceph client libraries. Upgrading these can
  restart VM-facing services, and a kernel only takes effect after a reboot,
  which takes both Talos workers and HexOS down together.
- **Debian point releases** (`trixie`, `trixie-updates`)

## Install (done 2026-09-27)

The repo isn't cloned on the Proxmox host, and it has no `sudo` (everything
runs as root; `install.sh` handles that). Copy the directory over from
rpi5-1 and run it there. On rpi5-1:

```bash
tar c -C ~/dev/homelab/scripts unattended-upgrades | ssh proxmox 'rm -rf /root/uu && mkdir /root/uu && tar x -C /root/uu && /root/uu/unattended-upgrades/install.sh; rm -rf /root/uu'
```

The script ends with a dry run. Its "Allowed origins" line should list only
`codename=trixie-security,label=Debian-Security`.

## SSH from rpi5-1

rpi5-1 logs into the Proxmox host as root with `~/.ssh/id_ed25519_proxmox`,
via a `Host proxmox proxmox.lan` entry in rpi5-1's `~/.ssh/config`. The key
has no passphrase, so cron can use it. The public key was installed on the
Proxmox host (2026-09-27) with, on rpi5-1:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_proxmox.pub root@proxmox.lan
```

## Checking that it's working

rpi5-1 already has tested outbound mail ([`email-alerts.md`](email-alerts.md)),
and the Proxmox host's mail setup has never been checked, so the daily
[`check.sh`](../scripts/unattended-upgrades/check.sh) runs from rpi5-1's
crontab, piped over SSH, and cron on rpi5-1 mails anything it prints to
stderr. That includes SSH itself failing, so an unreachable host also
produces a mail. Installed 2026-09-27 on rpi5-1 (`MAILTO` is already set in
the crontab):

```bash
crontab -l | { cat; echo "5 9 * * * ssh -o BatchMode=yes proxmox \"bash -s\" < \$HOME/dev/homelab/scripts/unattended-upgrades/check.sh > /dev/null"; } | crontab -
```

To check by hand, on the Proxmox host:

```bash
apt list --upgradable 2>/dev/null | grep -c security
```

Expect 0, or a handful that are less than a day old. The run log is
`/var/log/unattended-upgrades/unattended-upgrades.log`.

## Manual upgrades

On the Proxmox host:

```bash
apt update && apt full-upgrade
```

If a new `proxmox-kernel-*` was installed, it needs a reboot, which takes
down talos-worker-1, talos-worker-2, and HexOS. Afterwards, confirm the host
actually rebooted with `uptime`, and that both workers are `Ready` in
`kubectl get nodes`.

### After a reboot: read-only iSCSI volumes

HexOS is `truenas.lan`, the democratic-csi `hexos-iscsi` backend, so a
Proxmox reboot also cuts storage to every PVC. Any volume that was mounted
on a node that stayed up (talos-worker-mbp, in practice) and got written to
during the outage aborts its ext4 journal and turns read-only. It doesn't
recover when HexOS comes back. Some pods crash-loop on it (Prometheus:
`read-only file system`), but others keep running and just fail every write
(on 2026-09-27, ClickHouse and signoz-0 were `Running` and read-only). So
"all pods Running" is not enough. Check, on rpi5-1:

```bash
talosctl -n 192.168.102.34 dmesg | grep -E "EXT4-fs.*(aborted journal|read-only)"
```

The fix is to delete each affected pod. Once no pod on the node uses the
volume, the kubelet unmounts it, and the next mount replays the journal
(`EXT4-fs (sdX): recovery complete` in dmesg). Do one pod at a time and
check that it's writable again. For example:

```bash
kubectl -n signoz delete pod signoz-0
```

Pods on the rebooted workers themselves come back clean, since their mounts
are fresh. Old pods from those workers may linger as `Error` after their
replacements are running; clear them with:

```bash
kubectl delete pods -A --field-selector=status.phase=Failed
```

Draining the workers first doesn't help: iSCSI storage goes down
cluster-wide either way. Scaling the PVC-backed workloads down before the
reboot would avoid it, but ArgoCD self-heal (and the Prometheus and
ClickHouse operators) would scale them straight back up. Deleting the pods
afterwards is simpler.
