# Talos cluster config

## Current state (as of 2026-09-07)

- **Talos v1.11.5**, **Kubernetes v1.34.1**.
- 3-node control plane on Raspberry Pi 5 (4GB), already installed and working.
  Control planes use a **custom installer image**, `ghcr.io/talos-rpi5/installer:v1.11.5`,
  since stock Talos doesn't support the Pi5 directly. **Any amd64 worker (e.g. the MS-A2
  Talos VM) must use the standard `ghcr.io/siderolabs/installer:v1.11.5` / stock qcow2 —
  do not reuse the rpi5 installer image for it.**
- CNI: Cilium, with `kubeProxyReplacement` enabled and BGP control plane enabled
  (see `cilium/values.yaml`).
- BGP peering to the Ubiquiti gateway (UCG) is defined in `cilium/bgp-peering.yaml`
  (`CiliumBGPPeerConfig` + `CiliumBGPClusterConfig`). Only nodes labeled
  `bgp-speaker: "true"` participate.
- LoadBalancer IP pool `192.168.103.1-30` is advertised via BGP
  (`cilium/bgp/lb-pool.yaml`, `cilium/bgp/advertisement.yaml`).
- `cilium/bgp/ucg-frr-reference.conf` is a **read-only copy** of the FRR config
  currently running on the UCG itself — it is not applied from here. It's kept as
  documentation of what the router side looks like today.
  **Important:** it hardcodes each control-plane node as a BGP neighbor
  (`192.168.102.11/.12/.13`). Adding a new BGP-speaking node (e.g. the MS-A2 worker)
  requires manually adding its IP as a neighbor on the UCG in addition to labeling
  the k8s node `bgp-speaker=true` — this is **not automatic** and lives outside this repo
  (Ubiquiti network config, not something we have IaC access to yet).

## Where the secrets actually live

The Talos secrets bundle (`secrets.yaml`), the rendered `controlplane.yaml` /
`worker.yaml` machine configs, and `talosconfig` all live on the jump box
**rpi5-1.lan** (`192.168.102.2`, user `jakerobb`) at `~/talos/homelab`. `talosctl`
itself is also installed there. Treat that host as read-only unless a change is
explicitly requested.

These files are **intentionally not committed here** — `controlplane.yaml` /
`worker.yaml` embed real key material (cluster CA, join tokens), not just config.
The `.gitignore` blocks them by filename as a safety net.

## Secrets: SOPS + age (decided 2026-09-08)

The Talos secrets bundle is committed here as `secrets.sops.yaml`, encrypted with
[SOPS](https://github.com/getsops/sops) using an [age](https://github.com/FiloSottile/age)
key (rule in `.sops.yaml` at repo root). This repo is now self-contained for the
secrets bundle — no more hard dependency on rpi5-1 surviving.

- **Age public key:** `age1nqvgqc45f5j9y9ch0lyccdefeazs26xkp732rujp23nqeqmdjefshruqs8`
- **Age private key:** lives only at `~/.config/sops/age/keys.txt` on Jake's Mac.
  Not yet duplicated anywhere else — **TODO: copy it into 1Password** (as a Secure
  Note/Password item) for durability, and optionally into a `SOPS_AGE_KEY` GitHub
  Actions repo secret once a self-hosted runner exists, so CI can decrypt too.
- To decrypt/use: `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt` then
  `sops --decrypt talos/secrets.sops.yaml`.

**Scope note:** this only brings the *secrets bundle* into the repo. The full
per-node machine configs (`controlplane.yaml`/`worker.yaml`) are still generated
directly with `talosctl` on demand (using this decrypted secrets bundle), not
via [Talhelper](https://github.com/budimanjojo/talhelper)'s declarative
`talconfig.yaml`. Adopting Talhelper fully would mean reverse-engineering every
setting already baked into the existing `controlplane.yaml` (KubePrism port,
kube-proxy disablement, disk selectors, kubelet extra args, etc.) — deliberately
deferred rather than guessed at, to avoid drifting the config used to actually
generate a new node away from what's already running. Worth revisiting as a
follow-up once there's time to diff it carefully against the live config.

## Layout

- `cilium/` — Cilium Helm values and BGP/LB CRDs, applied to the existing cluster.
- `patches/control-plane/` — per-node Talos config patches for the existing 3 Pi
  control-plane nodes (hostname only, currently).
- `patches/worker-msa2.yaml` — patch for the new MS-A2 worker VM (hostname
  `talos-worker-msa2`, matching the existing hostname-only patch style — IP
  addressing is handled via DHCP reservation on the UCG, not in Talos config).

## MS-A2 worker: decided values (2026-09-10)

- **Hostname:** `talos-worker-msa2`
- **IP:** `192.168.102.22` (next free slot after the MS-A2 host itself at `.21`) —
  needs a DHCP reservation on the UCG once the VM exists and we know its NIC's MAC
  (or we fix the MAC in the Terraform VM definition ahead of time and reserve it
  before first boot — TBD when that resource gets written).
- **Image source:** Talos doesn't publish a plain qcow2 on GitHub releases anymore —
  VM images are built on demand via [Image Factory](https://factory.talos.dev).
  For v1.11.5 with no customizations (the stock/non-Pi5 installer):
  ```
  https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.11.5/nocloud-amd64.qcow2
  ```
  Directly consumable by Terraform's `proxmox_virtual_environment_download_file`
  resource once that gets written (needs a real Proxmox node name / storage pool
  first).
