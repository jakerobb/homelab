# Studio FileVault unlock watchdog

The Mac Studio runs FileVault (the decision stays "on"), so after a shutdown or a power cut it waits at the unlock
screen and `talos-worker-studio` stays down until someone unlocks it. This watchdog runs on rpi5-1, notices that
state, and unlocks the Mac over SSH. The files are in
[`../scripts/studio-unlock-watchdog/`](../scripts/studio-unlock-watchdog/); background on FileVault and the VM
daemon is in [`studio-worker-and-ram-upgrade.md`](studio-worker-and-ram-upgrade.md) (Phase 2).

**Status:** built and dry-run tested 2026-11-07 against the live Studio (every branch of the decision table, and the
password helper against a dummy secret). The real unlock path has **not** been exercised: that needs the secret
below and a deliberate cold shutdown of the Studio. Don't enable the timer until you've done that test.

## What it does

A systemd timer runs `studio-unlock-watchdog.sh` every minute. It only uses TCP probes, so there is no key to maintain
on the Studio:

| Worker `:50000` | Studio `:22` | Studio `:9273` (Telegraf) | Meaning | Action |
|---|---|---|---|---|
| open | | | healthy | reset state (notify if it had been trying) |
| closed | closed | | off, or mid-boot | nothing |
| closed | open | open | unlocked, but the VM isn't running | alert after 15 min; **never** unlock |
| closed | open | closed | at the unlock screen (or just booting) | after 3 minutes in a row, try the unlock |

Before the unlock the Mac answers on 22 (the pre-boot SSH server) but runs no LaunchDaemons, which is why `:9273` and
`:50000` are closed. The unlock is a password-only SSH login against a pinned host key (the pre-boot server uses the
same host key as the running system, checked 2026-11-06). After it, the script waits up to 4 minutes for Telegraf to appear, then sends a notification.

Limits, so a wrong password can't become an authentication storm: at most 3 attempts, 15 minutes apart, then it stops
and sends a priority-5 alert until the worker answers again (which resets everything). It never touches a Mac that
answers on `:9273`.

Notifications go to the `homelab-alerts` topic on ntfy and to the journal (`journalctl -u studio-unlock-watchdog`).
ntfy runs in the cluster, so if the cluster is down the journal is the only record.

## The security tradeoff

The Pi holds a credential that unlocks the Studio's disk. Anyone who gets that secret *and* network access to the
Studio's pre-boot SSH can boot it. That is the same trust boundary as the Pi's other secrets (it already holds the
cluster's `talosconfig` and the B2 keys), and the secret is SOPS-encrypted in the repo convention, decrypted by the
age key that `jakerobb` already holds on the Pi. To keep the exposure small:

- **Use a dedicated account, not your login.** Create a standard (non-admin) user on the Studio that exists only for
  this and give it a long random password. On macOS 27.2 a new account is enabled for FileVault automatically (older
  releases needed System Settings, Privacy & Security, FileVault); confirm with `sudo fdesetup list`. A stolen copy of the secret then unlocks the disk and logs in as a user with no rights.
- Keep that user out of Remote Login's allowed list (System Settings, General, Sharing, Remote Login, "Only these
  users"). **Untested:** whether the pre-boot SSH server honors that list or accepts any FileVault user. Check it
  during the test below; if a non-listed user can't unlock, add it and accept the wider exposure, or fall back to
  your own account.
- The secret file is mode 0600 on a host that only you can log in to, and the password helper prints the password
  only for a password prompt, with the host key pinned.

## Setup

1. On the Studio: create the unlock user as above, note its short name, and check it is listed by
   `sudo fdesetup list`.
2. In the repo, create the secret **yourself** (the password shouldn't pass through chat or a tool):

   ```bash
   cp scripts/secrets/studio-unlock.example.yaml scripts/secrets/studio-unlock.sops.yaml
   ```

   Edit the two values in the copy, then:

   ```bash
   sops --encrypt --in-place scripts/secrets/studio-unlock.sops.yaml
   ```

   ```bash
   scp scripts/secrets/studio-unlock.sops.yaml jakerobb@rpi5-1.lan:bin/secrets/
   ```

   The encrypted file can be committed alongside the other `*.sops.yaml` files, or just kept on the Pi.
3. On rpi5-1, from a checkout of this repo, install the files and units. The timer stays off:

   ```bash
   ~/dev/homelab/scripts/studio-unlock-watchdog/install.sh
   ```

   It pins the Studio's host key and prints the fingerprint. Compare it with the Studio's before going on
   (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`, run on the Studio).
4. Dry-run it against the live (unlocked, healthy) Studio. It should say `healthy`:

   ```bash
   DRY_RUN=1 /usr/local/lib/studio-unlock-watchdog/studio-unlock-watchdog.sh
   ```

## The test (before enabling)

Do this with the KVM or the keyboard attached, in case the unlock fails.

1. Cordon and drain `talos-worker-studio`, then shut the Studio down from the Apple menu, and power it on. It stops at
   the FileVault screen.
2. With the timer still off, run the script by hand on rpi5-1 three times a minute apart (the first two only count):

   ```bash
   /usr/local/lib/studio-unlock-watchdog/studio-unlock-watchdog.sh
   ```

   On the third it should log `Unlocking the Studio`, SSH in, and within a few minutes report that Telegraf is
   answering. Confirm the node returns to `Ready`, then uncordon it.
3. Note the result in the table above (did the dedicated user work, does Remote Login's list matter, how long did it
   take). Only then `sudo systemctl enable --now studio-unlock-watchdog.timer`.

## Operating it

- **Turn it off** for planned Studio downtime you don't want undone (a RAM swap, a long power-off):
  `sudo systemctl stop studio-unlock-watchdog.timer`. Turn it back on afterwards.
- **After a password change on the Studio**, update the SOPS file on the Pi, or the next unlock will fail and, after
  three tries, give up with the priority-5 alert.
- **State** lives in `/var/lib/studio-unlock-watchdog/` (counters and the pinned host key). Deleting a file there is
  safe; the script rebuilds it.
- The macOS Apple-menu **Restart** needs none of this (it unlocks itself), and neither does a Mac that is already up.
