# MacBook Pro worker under QEMU (replacing UTM)

`talos-worker-mbp` ran in a UTM VM, started by hand. This moves it to the same setup as the Mac Studio: **QEMU with
Hypervisor.framework (HVF), run by a root LaunchDaemon** that restarts the VM when the guest reboots, with
[host-deploy](host-deploy.md) keeping the host's files in sync and the [`talos-vm-kick`](studio-worker-and-ram-upgrade.md#restarting-a-wedged-vm)
helper for a wedged VM. The reasons are the same as on the Studio: UTM is a GUI app, so after a FileVault unlock (the
Mac sits at the login window with no GUI session) the VM wouldn't start, and a hand-started VM doesn't come back after
a reboot or power cut.

**Status (2026-11-27):** QEMU is built on the MBP and the launcher is tested against a scratch disk. The cutover
below has not been done. [`utm-talos-worker.md`](utm-talos-worker.md) stays as the history and for the first-time
install of a node (the Talos image, the maintenance-mode quirks).

## Pieces

- **QEMU.** Homebrew won't install on this Mac (its Command Line Tools are older than Homebrew requires, and Apple
  doesn't offer newer ones for this hardware), so
  [`build-qemu-macos-x86.sh`](../scripts/talos-vm-host/build-qemu-macos-x86.sh) builds QEMU 11.1.3 (x86_64 system
  emulator only, with HVF and vmnet) and its libraries from source into `~/.local/qemu`: no sudo, and nothing outside
  macOS linked (the script fails if anything under `/usr/local` is). Sources are pinned to the sha256 sums Homebrew
  publishes. About 40 minutes. It was built on 2026-11-27; re-run it to move to a newer QEMU (bump the versions and
  sums in the script).
- **Launcher.** [`../scripts/talos-vm-host/run-vm.sh`](../scripts/talos-vm-host/run-vm.sh) is shared with the Studio.
  The host's plist sets `VM_ARCH`, `VM_MAC`, `VM_CPUS`, `VM_MEM_MB` and `BRIDGE_IF`
  ([`../scripts/mbp-worker/`](../scripts/mbp-worker/)). For x86_64 it reproduces UTM's hardware, read from UTM's process
  arguments: q35, UEFI (OVMF), the CPU model `Skylake-Client`, the NIC at PCI slot 1 so Talos still names it `enp0s1`
  (which `worker-mbp.yaml`'s static IPv6 config uses), and the disk on the AHCI controller so it is still `/dev/sda`
  (its `install.disk`). Don't switch either to virtio without changing that machine config at the same time.
- **Files and paths.** `~/talos-vm/` holds `disk.qcow2`, `vars.fd` (UEFI variables, created on first start),
  `console.log` and the monitor socket, the same layout as the Studio, which is what `talos-vm-kick` looks for. The
  launcher is installed as `/usr/local/sbin/talos-worker-mbp-run` and the plist as
  `/Library/LaunchDaemons/com.jakerobb.talos-worker-mbp.plist`. The daemon log is `/var/log/talos-worker-mbp.log`.
- **Accepted risk.** The root daemon runs a QEMU binary that lives in your home directory, as the Studio does with
  Homebrew's. Anyone who can write to `~/.local/qemu` can run code as root at the next VM start. Same trust boundary as
  your login.

## One-time setup on the MBP

From a checkout of this repo on `main`, as your normal user:

```bash
./scripts/host-deploy/install.sh        # the deploy loop; it will say what else needs installing
./scripts/talos-vm-host/install.sh      # talos-vm-kick and its sudoers rule
```

Add a Healthchecks.io check for it (`host-deploy jakerobb-mbp`, period 5 minutes, grace 15) and put its URL in
`~/.config/host-deploy/heartbeat-url`, as in [host-deploy](host-deploy.md#heartbeat).

## Cutover (an outage for the node: plan about 30 minutes)

The node should already be cordoned and drained. Everything on it moves to the other workers (checked 2026-11-27:
requests fit with room to spare, nothing is pinned to it).

1. Shut the node down cleanly, then close UTM completely (Cmd-Q, not just the VM window):

   ```bash
   talosctl -n 192.168.102.34 shutdown
   ```

2. Put the disk where the daemon expects it. Keep a copy-on-write clone as the rollback (APFS clones cost no space
   until the two diverge; delete it after a week or so):

   ```bash
   mkdir -p ~/talos-vm
   D=~/Library/Containers/com.utmapp.UTM/Data/Documents/talos-worker-mbp.utm/Data/nocloud-amd64.qcow2
   cp -c "$D" ~/talos-vm/disk.qcow2.utm-backup
   mv "$D" ~/talos-vm/disk.qcow2
   ```

3. Install and start the daemon (`sudo` prompts):

   ```bash
   ./scripts/mbp-worker/install.sh
   tail -f ~/talos-vm/console.log
   ```

4. Check the node comes back and looks the same: `kubectl get nodes` shows `talos-worker-mbp` Ready, and
   `talosctl -n 192.168.102.34 get links` shows `enp0s1` with MAC `02:00:00:00:00:34`. The UEFI variables are new, so
   the first boot falls back to the disk's default boot file, which Talos installs.
5. **Test a plain reboot before uncordoning.** On the Studio, Talos's default kexec reboot hung under HVF and wedged
   QEMU (see [the Studio doc](studio-worker-and-ram-upgrade.md#rebooting-the-studio)). Whether it does on x86 is
   unknown: run `talosctl -n 192.168.102.34 reboot` and watch. If the node doesn't come back within about 5 minutes,
   run `sudo -n /usr/local/sbin/talos-vm-kick` and add `kernel.kexec_load_disabled: "1"` to `machine.sysctls` in
   [`worker-mbp.yaml`](../talos/patches/workers/worker-mbp.yaml), as the Studio's patch does.
6. `kubectl uncordon talos-worker-mbp`.

**Rollback** (before you delete the clone): `sudo launchctl bootout system/com.jakerobb.talos-worker-mbp`, then
`mv ~/talos-vm/disk.qcow2.utm-backup <the UTM path above>/nocloud-amd64.qcow2` (overwriting), and start the VM in UTM.

## After the cutover

- **Re-install on host-deploy alerts.** A change to `run-vm.sh` or the plist raises a NEEDS_INSTALL alert on both Macs
  and re-running the installer restarts that Mac's VM, so drain the node first.
- **FileVault.** After a power cut the MBP waits at the unlock screen. The rpi5-1
  [unlock watchdog](studio-unlock-watchdog.md) is being extended to cover it.
- **Disk.** UTM's image store filling the host disk has frozen the VM before. The qcow2 is about 65 GB and the host has
  about 95 GB free; keep the Telegraf disk alert ([host metrics](mac-host-metrics.md)).
