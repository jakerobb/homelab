# Talos worker in a UTM VM on a Mac

Manual runbook for joining a physical Mac to the Talos cluster as a worker,
running Talos in a [UTM](https://mac.getutm.app/) VM — used first for
`talos-worker-mbp` (2018 MacBook Pro, see
[`talos/README.md`](../talos/README.md#additional-worker-talos-worker-mbp-added-2026-09-22)),
written generically enough to reuse when the Mac Studio joins later. Variables
to substitute per-host: node name, MAC/IP, RAM/CPU split, and which host
network interface to bridge to.

This is **not** Proxmox/Terraform-managed — out of `terraform/proxmox/`'s
scope entirely, since there's no way to control a real Mac's hypervisor
remotely the way Terraform drives Proxmox. Steps 1-6 below are manual, done
on the Mac itself; everything after that is remote (SSH to rpi5-1), same as
any other new node.

## 1. Install UTM

Download from [mac.getutm.app](https://mac.getutm.app/) and install normally.

## 2. Get the current Talos image

**Check `talos/README.md`'s "Current state" section first** for the
currently-correct Talos version — don't reuse a version from an old runbook
run, that section is the source of truth and moves as the cluster changes.

**Don't just reuse the shared `iscsi-tools`+`util-linux-tools` schematic ID
as-is** — that one's shared with the Proxmox (real-hardware) workers.
UTM/QEMU VMs specifically need one more customization on top:
`extraKernelArgs: [tsc=reliable]`, working around a QEMU/UTM-specific
false-positive clock-instability issue found on `talos-worker-mbp` (see
`talos/README.md`'s "Additional worker: talos-worker-mbp" section for the
full diagnosis — recurring `NodeClockNotSynchronising` alerts from the
kernel's `acpi_pm` watchdog misreading normal hypervisor scheduling jitter
as real TSC drift). Request a fresh schematic with both the extensions and
this kernel arg:
```bash
curl -X POST --data-binary @- https://factory.talos.dev/schematics <<'EOF'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
  extraKernelArgs:
    - tsc=reliable
EOF
```
Use the returned schematic ID for everything below — **don't** try to add
this kernel arg later via `machine.install.extraKernelArgs` in a machine
config patch; Talos silently no-ops it with a `"not supported when booting
using SDBoot"` warning. It only works baked into the installer image itself.

Download **both** of these onto the Mac (URLs follow this pattern, substitute
the current schematic ID/version):

- The disk image, to become the node's boot disk:
  `https://factory.talos.dev/image/<schematic-id>/<version>/nocloud-amd64.qcow2`
- The install ISO — **needed even though the qcow2 looks bootable on its
  own** (see the gotcha in step 5):
  `https://factory.talos.dev/image/<schematic-id>/<version>/metal-amd64.iso`

## 3. Create the UTM VM

1. **+** → **Virtualize** (not Emulate — a Mac's Talos worker is always
   x86_64-on-x86_64 or arm64-on-arm64, so this gets full hardware
   acceleration either way) → **Linux**.
2. Check **Skip ISO Boot** if offered. Leave **"Use Apple Virtualization"**
   unchecked — this needs the standard QEMU/OVMF backend for full UEFI +
   device control.
3. Hardware: set RAM/CPU cores per this host's budget (leave real headroom
   for macOS + UTM overhead — for the MBP this was 24GB/6 cores of 32GB/6
   physical cores).
4. Storage: doesn't matter, minimal — gets deleted in step 4.
5. Skip Shared Directory. Name it after the node (e.g. `talos-worker-mbp`),
   save. **Don't boot yet.**

## 4. Swap in the real disk, size it, set up networking

1. Edit the VM → **Drives** → delete the placeholder drive UTM created →
   **Import** → select the downloaded `nocloud-amd64.qcow2`.
2. **Resize it before installing** — the Factory qcow2's default size is only
   a few GB (same image workers 1/2 also start from; Terraform grows theirs
   with `size = 64` on import, UTM doesn't do this automatically). Use the
   drive's **Resize** option to grow it to at least 64GB.
3. **Network** → mode **Bridged (Advanced)**, pick the interface for this
   host's actual wired connection to the Server VLAN (not Wi-Fi/Shared/NAT —
   needs its own L2 presence, same as Proxmox's `vmbr0` bridge for the
   existing workers).
4. Set the network adapter's **MAC address** explicitly (a fresh
   `02:00:00:00:00:<octet>` per the `.31+`/VM addressing convention in root
   `README.md`) and **Emulated network card: virtio-net-pci** — not e1000.
   e1000 is genuine per-packet hardware emulation with real overhead;
   virtio-net-pci is paravirtualized and isn't capped by any nominal link
   speed, so it can actually use a faster host NIC (e.g. 2.5GbE) if present.
   Matches the existing Proxmox workers' `network_device { model = "virtio"
   }` too.
5. Also attach the downloaded **`metal-amd64.iso`** as a second drive (CD-ROM)
   — see the gotcha below for why. Set boot order to boot from the CD-ROM
   first.

## 5. Set the DHCP reservation, then boot

Add a DHCP reservation on the UCG (UniFi Network app) for this VM's MAC →
its intended IP, **before** first boot — same manual step used for the
existing Proxmox workers (no Terraform provider for UCG reservations in this
repo). Doing this first means the VM gets the right IP immediately instead of
a throwaway lease.

Boot the VM.

**Gotcha: don't import the qcow2 directly as the sole boot disk and expect
interactive maintenance mode.** The Factory `nocloud-amd64.qcow2` image's
`nocloud` platform variant tries to acquire its config from a real NoCloud
metadata source (a cidata ISO or network service) and — unlike a bare-metal
boot — never falls back to opening the interactive maintenance API if one
isn't found. Symptom: `talosctl -n <ip> --insecure get disks` (or anything
else against the maintenance API) hangs with `connection refused` on port
`50000` indefinitely, and the node's own console log sits forever at
`downloading config {platform: nocloud}` with `apid` stuck in
`Waiting: Waiting for config to be ready` — no further progress, no
additional retry logs, nothing to wait out. Booting from the `metal-amd64.iso`
instead (step 4.5 above) sidesteps this entirely — the `metal` platform has
no such expectation and goes straight into normal interactive maintenance
mode, while the qcow2 disk still ends up as the real installed-to target.

Confirm the VM comes up in Talos maintenance mode (console shows the Talos
dashboard, `CONNECTIVITY OK`, the expected IP) before moving on.

## 6. Hand off — everything from here is remote (SSH to rpi5-1)

1. Confirm the real install-disk device name for this hypervisor's disk
   transport — check `talosctl -n <ip> --insecure get disks`. **Don't assume
   `/dev/sda` or `/dev/nvme0n1` by analogy to another worker** — UTM/QEMU's
   default drive interface shows up as SATA/AHCI (`/dev/sda`), which is
   *different* from Proxmox's virtio-scsi-as-NVMe-named-`/dev/nvme0n1`
   workers. This is genuinely hypervisor-specific, not something to bake into
   the shared `~/talos/homelab/worker.yaml` template — it stays a per-node
   patch override, same as hostname.
2. **Check the shared `~/talos/homelab/worker.yaml` template's `install.image`
   is actually current** before trusting it as a base (compare against a live
   existing worker's `talosctl get machineconfig -o yaml` — this repo has
   already caught this template drifting stale once, see
   `talos/README.md`'s writeup). Fix it on rpi5-1 directly if it has (not
   committed — that directory isn't tracked in git, see `talos/README.md`'s
   "Where the secrets actually live").
3. Generate this node's config: `talosctl machineconfig patch
   ~/talos/homelab/worker.yaml -p @<new-patch> -o <node>.yaml`, where the new
   patch sets `machine.network.hostname`, `machine.install.disk` (per step 1),
   `machine.install.image` (the current Factory schematic/version), and the
   `iscsi_tcp` kernel module + `/etc/iscsi`/`/var/lib/iscsi` `extraMounts`
   block every worker needs (copy an existing
   `talos/patches/workers/worker-*.yaml` as the template). Commit the new
   patch file to this repo.
4. `talosctl apply-config --insecure -n <ip> -f <node>.yaml` — installs Talos
   to the real disk and reboots automatically.
5. Once it rejoins: `talosctl -n <ip> get extensions` (expect `iscsi-tools`),
   `kubectl get nodes` (expect `Ready`), a throwaway `hexos-iscsi` PVC + pod
   pinned to this node via `nodeSelector: kubernetes.io/hostname: <node>` to
   confirm iSCSI actually mounts and writes *on this specific node* — then
   delete both.
6. Confirm no `install.image` drift: `talosctl -n <ip> get machineconfig -o
   yaml` should show the same Factory URL used in step 3 (this repo has hit
   silent drift here before on the existing workers).
7. Detach/eject the `metal-amd64.iso` from the VM's Drives once install is
   confirmed working — not needed again unless reinstalling from scratch.
