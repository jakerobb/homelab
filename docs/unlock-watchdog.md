# FileVault unlock watchdog (Mac Studio and MacBook Pro)

The Mac Studio and the MacBook Pro both run FileVault (the decision stays "on"), so after a shutdown or a power cut a
Mac waits at the unlock screen and its Talos worker (`talos-worker-studio`, `talos-worker-mbp`) stays down until someone
unlocks it. This watchdog runs on rpi5-1, notices that state, and unlocks the Mac over SSH (the Studio) or tells you to unlock it by hand (the MacBook Pro, which has no network at the FileVault screen). There is one timer per Mac
(`unlock-watchdog@studio.timer`, `unlock-watchdog@mbp.timer`), each running the same script with that Mac's settings from
`hosts/<name>.env`. The files are in [`../scripts/unlock-watchdog/`](../scripts/unlock-watchdog/); background on
FileVault and the VM daemon is in [`studio-worker-and-ram-upgrade.md`](studio-worker-and-ram-upgrade.md) (Phase 2) and
[`mbp-worker-qemu.md`](mbp-worker-qemu.md).

**Status:** the Studio's unlock path was tested 2026-11-06 and passed (see "Test result" below). The MBP can't be
unlocked remotely, so it only alerts; see "The MacBook Pro: alert only". Whether each timer is enabled is a separate step (see "Operating it").

## What it does

A systemd timer per Mac runs `unlock-watchdog.sh <name>` every minute. It only uses TCP probes, so there is no key to maintain
on the Studio:

| Worker `:50000` | Mac `:22` | Mac `:9273` (Telegraf) | Meaning | Action |
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

Notifications go to the `homelab-alerts` topic on ntfy and to the journal (`journalctl -u unlock-watchdog@studio`, `-u unlock-watchdog@mbp`).
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
  users"). **Confirmed after boot (2026-11-06):** with the Mac up, `sshd` rejects the account with `Access denied for
  user fvunlock by PAM account configuration [preauth]`, before checking the password, so a stolen secret can't log
  in to a running Studio. **Pre-boot behavior, tested the same day:** the pre-boot SSH server accepted `fvunlock` even though it is not on
  Remote Login's allowed list, so the account does not need to be added there.
- The secret file is mode 0600 on a host that only you can log in to, and the password helper prints the password
  only for a password prompt, with the host key pinned.

## Setup

The commands use the Studio (`studio`); for another Mac use its name from `hosts/` (`mbp`).

1. On the Mac: create the unlock user as above, note its short name, and check it is listed by
   `sudo fdesetup list`.
2. In the repo, create the secret **yourself** (the password shouldn't pass through chat or a tool):

   ```bash
   cp scripts/secrets/unlock.yaml.example scripts/secrets/studio-unlock.sops.yaml
   ```

   Edit the two values in the copy, then:

   ```bash
   sops --encrypt --in-place scripts/secrets/studio-unlock.sops.yaml
   ```

   Once merged, the compose-deploy cron copies it to `~/bin/secrets/` on rpi5-1 within ~5 minutes
   ([`compose-deploy.md`](compose-deploy.md#host-scripts-outside-docker)). To use it before the merge, copy it by hand:

   ```bash
   scp scripts/secrets/studio-unlock.sops.yaml jakerobb@rpi5-1.lan:bin/secrets/
   ```

   The encrypted file can be committed alongside the other `*.sops.yaml` files, or just kept on the Pi.
3. On rpi5-1, from a checkout of this repo, install the files and units. The timer stays off:

   ```bash
   ~/dev/homelab/scripts/unlock-watchdog/install.sh
   ```

   It pins each Mac's host key and prints the fingerprint. Compare it with the Mac's before going on
   (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`, run on the Mac). The first run on a Mac that had the old
   Studio-only version replaces it, keeps the Studio's pinned key, and re-enables the Studio's timer if it was on.
4. Dry-run it against the live (unlocked, healthy) Studio. It should say `healthy`:

   ```bash
   DRY_RUN=1 /usr/local/lib/unlock-watchdog/unlock-watchdog.sh studio
   ```

## The MacBook Pro: alert only

The MBP (`jakerobb-mbp`, `192.168.102.9`, worker `talos-worker-mbp` at `.34`) is set to `UNLOCK_MODE=alert` in
`hosts/mbp.env`, so the watchdog never tries to unlock it. Tested 2026-11-27: after a full shutdown and power-on, the
Mac sat at the FileVault screen with **no network at all** (no ping, no ARP entry on rpi5-1, nothing on `:22`). Its
network is an add-on adapter (`en11`), the pre-boot environment doesn't bring it up, and an Intel MacBook may not offer
pre-boot SSH anyway. So the unlock has to be done at its keyboard. (Enter the account password; no login is needed
afterwards, because the VM daemon starts at boot. The node was Ready again within minutes of the unlock.)

What the watchdog does instead: when `:50000` (the worker) is closed and Telegraf (`:9273`) isn't answering, it logs
what it sees (ping, `:22`) and, once the worker has been down for 10 minutes (`DOWN_ALERT`), sends one ntfy alert,
"MacBook Pro may need unlocking", saying whether the Mac answers ping and SSH. It repeats that alert every hour
(`REALERT`) until the worker is back, then sends "worker is back". A Mac that is up but whose worker is down still gets the
existing "Mac is up, worker down" alert, and that alert's text points at the VM daemon.

The rest (the pinned host key, the per-host secret, the unlock logic) stays in place in case pre-boot SSH on Intel is
pursued later. To try it, remove `UNLOCK_MODE=alert` from `mbp.env`, create `mbp-unlock.sops.yaml` as for the Studio, and
run the test below against the MBP. The MBP's `mbp-unlock.sops.yaml` isn't needed in alert mode.

## The test (before enabling)

Do this with the KVM or the keyboard attached, in case the unlock fails.

1. Cordon and drain `talos-worker-studio`, then shut the Studio down from the Apple menu, and power it on. It stops at
   the FileVault screen.
2. With the timer still off, run the script by hand on rpi5-1 three times a minute apart (the first two only count):

   ```bash
   /usr/local/lib/unlock-watchdog/unlock-watchdog.sh studio
   ```

   On the third it should log `Unlocking the Studio`, SSH in, and within a few minutes report that Telegraf is
   answering. Confirm the node returns to `Ready`, then uncordon it.
3. Only then `sudo systemctl enable --now unlock-watchdog@studio.timer`.

### Test result (2026-11-06)

- Shut down from the Apple menu at 22:16:41; back at the FileVault screen at 22:19:40 (SSH answering, Telegraf and the
  worker closed).
- Three manual runs a minute apart: two counts, then on the third (22:21:59) the unlock attempt as `fvunlock`, which was
  **not** on Remote Login's allowed list. The `ssh` exited 255 as the Mac continued booting, and Telegraf answered soon
  after. The worker VM came back on its own and the node rejoined `Ready` a few minutes later.
- One attempt was needed, so the retry cap and cooldown were not exercised. The three-minute wait before the first
  attempt is by design (`LOCKED_THRESHOLD`).

## Operating it

- **Turn it off** for planned Studio downtime you don't want undone (a RAM swap, a long power-off):
  `sudo systemctl stop unlock-watchdog@studio.timer`. Turn it back on afterwards.
- **After a password change on the Studio**, update the SOPS file on the Pi, or the next unlock will fail and, after
  three tries, give up with the priority-5 alert.
- **State** lives in `/var/lib/unlock-watchdog/<name>/` (counters and the pinned host key). Deleting a file there is
  safe; the script rebuilds it.
- The macOS Apple-menu **Restart** needs none of this (it unlocks itself), and neither does a Mac that is already up.
