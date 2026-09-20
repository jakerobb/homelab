# homelab
This repo contains IaC and related stuff for my homelab.

## Current architecture

- **Network:** Ubiquiti, Server VLAN `192.168.102.0/24`. Talos jump box (`rpi5-1`,
  `.2`, holds `talosctl` + cluster secrets) · 3-node Talos control plane (`.11`-`.13`,
  Raspberry Pi 5 4GB) · MS-A2 (`.21`) running Proxmox VE, hosting two Talos worker
  VMs — `talos-worker-1` (`.31`) and `talos-worker-2` (`.32`) — joined to the cluster.
- **Existing cluster:** Talos v1.11.5, Kubernetes v1.34.1, Cilium CNI with
  `kubeProxyReplacement`, full eBPF host routing, and L2 announcements for
  LoadBalancer IPs (`192.168.102.128/26`) — BGP was the original design but hit
  an unresolved UCG Fiber routing bug, see `talos/README.md` for the writeup.
  Control-plane nodes use a **custom Pi5 installer image** — any amd64 node must use
  the stock Talos installer instead. Details and gotchas live in
  [`talos/README.md`](talos/README.md).
- **Outside the cluster:** the original RPi5 16GB (`rpi5-1`) stays on Docker Compose
  duty for hardware-pinned things (e.g. UPS NUT client) plus the LAN's Caddy reverse 
  proxy and Unbound resolver, until/unless that changes later. Stack captured in
  [`docker-compose/`](docker-compose/).
- **IaC layout:**
  - [`talos/`](talos/) — non-secret Cilium config and per-node Talos patches
    applied to the existing cluster.
  - [`terraform/proxmox/`](terraform/proxmox/) — Proxmox VM definitions; the two
    Talos worker VMs are provisioned from here, applied from rpi5-1.
  - [`docker-compose/`](docker-compose/) — the `rpi5-1` Compose stack's config
    (secrets SOPS-encrypted); see its README for what's captured vs. excluded.
  - Anything that can't reasonably be IaC'd (BIOS/IOMMU toggles, HexOS's GUI-only pool
    setup) gets a step-by-step runbook here instead of being skipped.

## Hardware inventory

### Rack
- **UniFi Cloud Gateway Fiber** — router/gateway, OS2 (single-mode) fiber WAN.
- **MinisForum MS-A2** (`192.168.102.21`) — AMD Ryzen 8845HS, 32GB RAM, 1TB
  primary/boot NVMe, plus a 2TB and 4TB NVMe passed through to the HexOS VM
  (see [`docs/hexos-install.md`](docs/hexos-install.md)). Runs Proxmox VE,
  hosting the Talos worker VMs and the HexOS VM.
- **UniFi Pro HD 24 PoE** — core switch.
- **1U shelf:** Comet X (KVM-over-IP), SMLIGHT SLZB-06P10 (Zigbee gateway),
  TubesZB Z-Wave PoE kit with Zooz ZAC93 (Z-Wave gateway), UniFi AI Port
  (adds smart-detection features to older UniFi cameras). The Zigbee and
  Z-Wave gateways are both linked into Home Assistant, which runs on
  `rpi5-1`; software stack details to follow separately.
- **2U Raspberry Pi mount:** `rpi5-1` (Talos jump box, holds `talosctl` +
  cluster secrets; also the Docker Compose host for hardware-pinned services
  like the UPS's NUT client), `talos-cp-1`/`talos-cp-2`/`talos-cp-3` (Talos
  control plane, Pi 5 4GB). Room for six more Pis.
- **UniFi PDU Pro** — rack power distribution/monitoring.
- **CyberPower CP1500PFCRM2U** — rack UPS.
- **Noctua 120mm fans** — one installed in the top of the rack, a second
  planned for the bottom.
- **Dig-Octa WLED controller** + **Mean Well 100W 12V power supply** — rack
  accent, task, and status lighting (it's dark in there). Controlled from
  Home Assistant; not yet automated. Only one LED strip is connected so far
  — plan is to run strips along every edge inside the rack.

### On top of the rack
- **2019 MacBook Pro 15"** — connected via a **CalDigit TS3+** dock to the
  network and to the Comet X. Currently idle; earmarked as a possible future
  Talos K8s worker (running Talos in a UTM VM), on hold for now.

### Office
- **UniFi Pro XG 8 PoE** — connected to the Pro HD 24 PoE via OS2 fiber.
- **CalDigit TS5+** dock.
- **2021 MacBook Pro 14"** (M1 Pro, 32GB, 500GB) — primary workstation; not
  part of the homelab infrastructure itself, but what's typically used to
  drive it.

# TODO

The original phased hardware-migration checklist that used to live here
(B2 backup, physical SSD install, Proxmox, Talos worker join, HexOS VM) is
done and has been merged into [TODO.md](TODO.md#hardware-migration-ssd-install-proxmox-talos-worker-hexos-vm),
along with its two loose ends and the rest of the cluster-readiness
backlog. See [TODO.md](TODO.md) for what's outstanding.
