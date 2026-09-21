# homelab

This repo contains IaC and related stuff for my homelab.

## Current architecture

- **Network:** Ubiquiti, Server VLAN `192.168.102.0/24`. Talos jump box (`rpi5-1`,
  `.2`, holds `talosctl` + cluster secrets) · 3-node Talos control plane (`.11`-`.13`, Raspberry Pi 5 4GB) · MS-A2
  (`.21`) running Proxmox VE, hosting two Talos worker VMs — `talos-worker-1` (`.31`) and `talos-worker-2` (`.32`) —
  joined to the cluster.
- **Existing cluster:** Talos v1.11.5, Kubernetes v1.34.1, Cilium CNI with
  `kubeProxyReplacement`, full eBPF host routing, and L2 announcements for LoadBalancer IPs (`192.168.102.128/26`) — BGP
  was the original design but hit an unresolved UCG Fiber routing bug, see `talos/README.md` for the writeup.
  Control-plane nodes use a **custom Pi5 installer image** — any amd64 node must use the stock Talos installer instead.
  Details and gotchas live in
  [`talos/README.md`](talos/README.md).
- **Outside the cluster:** the original RPi5 16GB (`rpi5-1`) stays on Docker Compose duty for hardware-pinned things
  (e.g. UPS NUT client) plus the LAN's Caddy reverse proxy and Unbound resolver, until/unless that changes later. Stack
  captured in
  [`docker-compose/`](docker-compose/).
- **IaC layout:**
    - [`talos/`](talos/) — non-secret Cilium config and per-node Talos patches applied to the existing cluster.
    - [`terraform/proxmox/`](terraform/proxmox/) — Proxmox VM definitions; the two Talos worker VMs are provisioned from
      here, applied from rpi5-1.
    - [`docker-compose/`](docker-compose/) — the `rpi5-1` Compose stack's config (secrets SOPS-encrypted); see its
      README for what's captured vs. excluded.
    - Anything that can't reasonably be IaC'd (BIOS/IOMMU toggles, HexOS's GUI-only pool setup) gets a step-by-step
      runbook here instead of being skipped.

## Hardware inventory

### Rack

- **UniFi Cloud Gateway Fiber** — router/gateway, OS2 (single-mode) fiber WAN.
- **MinisForum MS-A2** (`192.168.102.21`) — AMD Ryzen 8845HS, 32GB RAM, 1TB primary/boot NVMe, plus a 2TB and 4TB NVMe
  passed through to the HexOS VM (see [`docs/hexos-install.md`](docs/hexos-install.md)). Runs Proxmox VE, hosting the
  Talos worker VMs and the HexOS VM.
- **UniFi Pro HD 24 PoE** — core switch.
- **1U shelf:** Comet X (KVM-over-IP), SMLIGHT SLZB-06P10 (Zigbee gateway), TubesZB Z-Wave PoE kit with Zooz ZAC93
  (Z-Wave gateway), UniFi AI Port (adds smart-detection features to older UniFi cameras). The Zigbee and Z-Wave gateways
  are both linked into Home Assistant, which runs on
  `rpi5-1`.
- **2U Raspberry Pi mount:** `rpi5-1` (Talos jump box, holds `talosctl` + cluster secrets; also the Docker Compose host
  for hardware-pinned services like the UPS's NUT client), `talos-cp-1`/`talos-cp-2`/`talos-cp-3` (Talos control plane,
  Pi 5 4GB). Room for six more Pis.
- **UniFi PDU Pro** — rack power distribution/monitoring.
- **CyberPower CP1500PFCRM2U** — rack UPS.
- **Noctua 120mm fans** — one each in the top and bottom of the rack
- **Dig-Octa WLED controller** + **Mean Well 100W 12V power supply** — rack accent, task, and status lighting (it's dark
  in there). Controlled from Home Assistant; not yet automated. Only one LED strip is connected so far — plan is to run
  strips along every edge inside the rack.

### On top of the rack

- **2018 MacBook Pro 15" / 32GB / 500GB** — connected via a **Plugable TBT3-UDV dock** to the network and to the Comet
  X. Currently idle; earmarked as a possible future Talos K8s worker (running Talos in a UTM VM), on hold for now.

### Office

- **UniFi Pro XG 8 PoE** — connected to the Pro HD 24 PoE via OS2 fiber.
- **CalDigit TS5+** dock.
- **2021 MacBook Pro 14"** (M1 Pro, 32GB, 500GB) — primary workstation; not part of the homelab infrastructure itself,
  but what's typically used to drive it.

## Software Stack

### Docker Compose

Docker Compose is where everything started. It runs on rpi5-1, and includes the following containers:

* watchtower
* caddy
* homeassistant
* scrypted
* modbus-controller
* nut-upsd
* nut-webui
* change-detection
* browserless
* optimizer (NetworkOptimizer)
* network-optimizer-speedtest
* unbound
* influxdb
* grafana
* telegraf
* unpoller
* nut-influx-relay
* ofelia
* mosquitto
* zigbee2mqtt
* matter-server
* zwave-js-ui
* victorialogs
* vector

### Proxmox

Proxmox runs on the MS-A2. It manages the following VMs:

* HexOS/TrueNAS
* talos-worker-1
* talos-worker-2

### Kubernetes cluster

The Kubernetes cluster includes the following workloads:

* ArgoCD
* Cilium
* cert-manager
* cert-manager-config
* external-dns
* local-path-provisioner
* democratic-csi
* metrics-server
* kube-prometheus-stack
* Authelia
* homepage
* ntfy
* ntfy-alertmanager
* renovate
* searxng

# Plans

In general, I plan to move as much as I can from the Pi to Kubernetes, and when that's done, probably convert the Pi
into a Talos worker node. I would at that point get another Pi (with less RAM) to act as the jump box.

I keep a todo list in the repo where it's easy to manage. There are four documents:

* todo/READY.md -- todo-list items which are available to be worked
* todo/FUTURE.md -- items which are blocked by some external dependency
* todo/DONE.md -- items already done
* todo/HARDWARE.md -- planned physical changes. This doc is a mixture of ready- and future-style entries. 
