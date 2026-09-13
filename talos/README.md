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
  `bgp-speaker: "true"` participate. **Only label nodes that actually run
  workload pods** (i.e. the workers, not control-plane nodes) — Cilium has every
  BGP-speaking node advertise LoadBalancer IPs as reachable via itself, so a
  tainted control-plane node with no local pod for the service can end up as an
  ECMP next-hop. The 3 Pi control-plane nodes had `bgp-speaker=true` left over
  from testing before real workers existed; removed 2026-09-12 (now only
  `talos-worker-1`/`-2`) as a correctness cleanup, though it turned out not to
  be the actual cause of the outage below.
- **External LoadBalancer traffic has been broken cluster-wide since the BGP
  setup was first built — under investigation 2026-09-13.** Symptom: BGP
  session established, routes exchanged correctly, `cilium service list` showed
  the right backend, but external clients got a TCP handshake that completed
  with zero data afterward (confirmed even on `bgp-test`, a service that had
  been "up" for 67 days with this issue the whole time — the BGP control plane
  was configured but never actually validated end-to-end until now). ClusterIP
  access worked perfectly throughout, isolating the problem to external
  (north-south) traffic specifically rather than the pods/overlay/BGP config.
  `cilium status --verbose` showed `Routing: Host: Legacy` with `Masquerading:
  IPTables` — Cilium was silently falling back off the modern eBPF host-routing
  path, with no explicit config anywhere requesting that. Leading hypothesis:
  the Talos-hardened `securityContext.capabilities` list (see below) is missing
  `BPF`/`PERFMON`, which that path needs — testing now.
- LoadBalancer IP pool `192.168.103.1-30` is advertised via BGP
  (`cilium/bgp/lb-pool.yaml`, `cilium/bgp/advertisement.yaml`).
- `cilium/bgp/ucg-frr.conf` is the actual FRR config running on the UCG's BGP
  daemon — maintained here as the source of truth, deployed to the router
  manually since there's no Terraform/API access to the UDM/UCG for this.
  **Important:** it hardcodes every peer IP individually (no dynamic
  discovery) — adding a new BGP-speaking k8s node means both labeling it
  `bgp-speaker=true` *and* adding a `neighbor <ip> peer-group HOMELAB` line
  here, then re-deploying to the router. All BGP-speaking nodes share the same
  `HOMELAB` peer-group/remote-as, since `CiliumBGPClusterConfig` uses a single
  cluster-wide `localASN: 65001` regardless of node role.

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
- `patches/workers/` — patches for the two MS-A2 worker VMs (hostname only,
  matching the control-plane patch style — IP addressing is handled via DHCP
  reservation on the UCG, not in Talos config).

## MS-A2 workers: decided values (2026-09-11)

Two workers, not one — with only 3 tainted control-plane Pis and a single
worker, upgrading that one worker would leave the cluster with zero
schedulable capacity in the meantime. Two workers (still both VMs on the same
physical MS-A2 for now) means one can be cordoned/upgraded while the other
keeps serving. Naming is deliberately decoupled from "msa2" — more physical
machines are coming later, and a worker's name shouldn't imply which box it
happens to run on today.

IP addressing convention on `192.168.102.0/24` (decided 2026-09-11): `.21-.29`
reserved for physical hosts, `.31+` for VMs — keeps the two cleanly separated
as more of each show up.

| Hostname | IP | MAC (fixed in Terraform) |
|---|---|---|
| `talos-worker-1` | `192.168.102.31` | `02:00:00:00:00:31` |
| `talos-worker-2` | `192.168.102.32` | `02:00:00:00:00:32` |

Both need a DHCP reservation on the UCG (matching the fixed MAC above) and a
BGP neighbor entry on the UCG's FRR config once they're up — see the BGP note
above, this now applies to **two** IPs, not one.

Each: 4 vCPU, 4GB RAM. (Proxmox's `cores` is a vCPU count, not a physical-core
reservation — the host scheduler spreads vCPU threads across all 32 logical
threads/16 physical cores of the 8945HX as needed, so 8 vCPUs total across
both workers leaves comfortable headroom.)

- **Image source:** Talos doesn't publish a plain qcow2 on GitHub releases anymore —
  VM images are built on demand via [Image Factory](https://factory.talos.dev).
  For v1.11.5 with no customizations (the stock/non-Pi5 installer):
  ```
  https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.11.5/nocloud-amd64.qcow2
  ```
  Consumed by the `proxmox_download_file.talos_worker_image` resource in
  `terraform/proxmox/images.tf`, imported into both workers' disks.
