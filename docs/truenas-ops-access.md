# TrueNAS ops access (the `claude-ops` user)

Claude Code has scoped SSH access to the HexOS/TrueNAS VM, for jobs that need
the NAS side of a Kubernetes volume. It was set up on 2026-10-06 so Claude
could run a filesystem check on an iSCSI volume without Jake pasting commands.

## What it is

- **User:** `claude-ops` (uid 3003) on the TrueNAS VM, `192.168.102.33`
  (`truenas.lan`). Password login is disabled; SSH key only. Shell is bash,
  home is `/mnt/data/claude-ops`.
- **Where it connects from:** Jake's Mac only, as `ssh truenas-ops`. The
  `Host truenas-ops` entry in `~/.ssh/config` pins the key
  `~/.ssh/id_ed25519_truenas_ops` (no passphrase, so Claude can use it
  unattended) and turns off the 1Password agent for that host. The entry has to
  stay above `Host *`: OpenSSH uses the first value it finds, so below it the
  agent setting would win. A copy of the key pair is in 1Password.
- **Sudo, no password, only these:**
  - `/usr/sbin/zfs list *`
  - `/usr/sbin/zfs snapshot *`
  - `/usr/sbin/e2fsck *`

  Check the effective list any time with `ssh truenas-ops 'sudo -n -l'`. There
  is deliberately no `zfs destroy`: Claude can snapshot but not delete, so
  Jake removes snapshots by hand. The `*` is a sudoers wildcard, so `e2fsck`
  can be pointed at any block device, not just a zvol. The access is scoped by
  command, not sandboxed to one volume.

## Setting it up again

In the TrueNAS UI, Credentials → Users → Add:

1. Username `claude-ops`, "Disable Password" ticked, shell `/usr/bin/bash`,
   SSH Access ticked, SMB and TrueNAS Access unticked.
2. Paste the public key (`~/.ssh/id_ed25519_truenas_ops.pub`) into "Public SSH
   Key".
3. Under Sudo Commands, tick **neither** "Allow all…" box, and put the three
   commands above in "Allowed sudo commands with no password".
4. Home directory: tick "Create Home Directory" under `/mnt/data`.

Gotchas the form has (hit on 2026-10-06):

- Save stays greyed out with "`/var/empty`: the home directory must be set to a
  writable path within a data pool" until you clear and re-paste the public
  key.
- Then the save itself can fail and name a path (it suggested `/mnt/data/jake`).
  Setting the "Create Home Directory Under" field to `/mnt/data/` worked.

## Revoking it

Delete the user in the TrueNAS UI (or untick SSH Access to pause it), and
remove the `Host truenas-ops` block and the key files from the Mac.

## What it's for: filesystem checks on a PVC

**Result of the first use (2026-10-06):** the volume
`data/k8s-iscsi/pvc-1bf90a21-…` (SigNoz's metadata DB) carried an ext4 "error
count since last fsck" flag from the 2026-09-27 disk-full freeze. A read-only
check (`e2fsck -fn`) came back clean, with nothing to repair. A repairing check
(`e2fsck -f -p`) was refused with "is in use", even with the pod scaled to zero,
the Kubernetes VolumeAttachment gone and no iSCSI session left on the node: the
iSCSI target keeps the zvol open as long as the LUN is exported. So the flag was
left alone. It's harmless (the kernel logs it once when the volume mounts), and
the "Kernel storage error" alert's pattern
([`terraform/signoz/alert-kernel-storage.tf`](../terraform/signoz/alert-kernel-storage.tf))
doesn't match it.

What that means for the next time one is wanted:

1. `sudo zfs snapshot <zvol>@pre-fsck` (find the zvol with
   `zfs list -t volume | grep <pvc-id>`).
2. To use the volume's data, scale the workload to 0. ArgoCD's `selfHeal`
   would put it back within about 3 minutes, so pause auto-sync on `root` and
   on the app first, and restore it after
   (`{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}`).
3. `sudo e2fsck -fn /dev/zvol/<zvol>` always works as a read-only check, even
   while the volume is attached, though it can show false errors on a mounted
   filesystem.
4. A real repair needs an initiator to hold the LUN, not the target: a
   privileged pod on a worker that logs in to the LUN with `iscsiadm` and runs
   `e2fsck` on the resulting `/dev/sdX`, never mounting it. Nothing sets that up
   today.
