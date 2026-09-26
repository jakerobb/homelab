# homelab

This repo contains IaC and related stuff for my homelab and home network in general, serving two primary purposes:

1. Document everything so that, in the event of my demise, there is some record of what I've done and how it all works.
2. Automate as much as possible so that it stays current and functional even in my absence.

Passwords and other secrets are in 1Password in the Tech vault, which is shared with the family.

## Current architecture

- **Network:**
    - **Router/Gateway** UniFi Cloud Gateway Fiber. Access it at unifi.ui.com.
    - **VLANs**
        - Management - 192.168.0.0/24 - UniFi devices (switches, APs, etc)
        - Trusted - 192.168.92.0/24 - Adult-owned computers, phones, tablets
        - Server - 192.168.102.0/24 - Servers, NAS, and protocol gateways (Zigbee/ZWave)
        - Security - 192.168.39.0/24 - NVR, Cameras, sensors
        - IoT - 192.168.62.0/24 - IoT devices that don't need internet connectivity. Smart switches, etc.
        - Cloud IoT - 192.168.55.0/24 - IoT devices that do need internet connectivity. AppleTV, HomePod, etc.
        - Kids - 192.168.77.0/24 - Kid-owned computers, phones, tablets
        - Guest - 192.168.42.0/24 - Unregistered devices.
    - **WAN connections**
        - Metronet Fiber - 2Gbps symmetric, via a Nokia XS-010X-Q ONT. Connected to the CGFiber via 10GbE. Static IP.
        - UniFi 5G Max Outdoor with a T-Mobile SIM with a tablet plan. Mounted in the living room behind the television.
          Connected via 1GbE to the Living Room AV Switch (USW-Flex); uses GRE tunneling to form a virtual WAN link to
          the CGFiber.
    - **Servers**
        - `rpi5-1` - .2 on the Server VLAN. Docker Compose host and Jump box for Talos, Terraform, and Kubectl. Also has
          a USB connection to the CyberPower UPS. Security updates apply automatically; see
          [`docs/rpi5-1-os-updates.md`](docs/rpi5-1-os-updates.md).
        - 3-node Talos control plane (`.11`-`.13`, Raspberry Pi 5 4GB with PoE+NVMe HATs and 256G NVMe storage)
            - `.10` is the cluster virtual IP
        - MS-A2 (`.21`) running Proxmox VE, hosting:
            - two Talos worker VMs — `talos-worker-1` (`.31`) and `talos-worker-2` (`.32`)
            - TrueNAS / HexOS (`.33`)
        - MacBook Pro (see "On top of the rack" below), running a third Talos
          worker VM — `talos-worker-mbp` (`.34`) — under UTM. The Mac host itself is `.9`; SSH in as
          `jakerobb@192.168.102.9` (key auth).
- **Kubernetes cluster:** Talos + Kubernetes (see [`talos/README.md`](talos/README.md#current-state) for current
  versions), Cilium CNI with `kubeProxyReplacement`, full eBPF host routing, and L2 announcements for LoadBalancer IPs
  (`192.168.102.128/26`). Details and gotchas live in [`talos/README.md`](talos/README.md).
- **IaC layout:**
    - [`talos/`](talos/) — non-secret Cilium config and per-node Talos patches applied to the existing cluster.
    - [`terraform/proxmox/`](terraform/proxmox/) — Proxmox VM definitions; the two Talos worker VMs are provisioned from
      here, applied from rpi5-1.
    - [`docker-compose/`](docker-compose/) — the `rpi5-1` Compose stack's config (secrets SOPS-encrypted); see its
      README for what's captured vs. excluded. Auto-deployed on merge by a pull-based cron job on rpi5-1
      ([`docs/compose-deploy.md`](docs/compose-deploy.md)).
    - Anything that can't reasonably be IaC'd (BIOS/IOMMU toggles, HexOS's GUI-only pool setup) gets a step-by-step
      runbook here instead of being skipped.

## Hardware inventory

### Crawlspace

We have an unfinished crawlspace below our entryway landing, accessible from the garage. Poured concrete floor,
insulated. It shares the space with our well expansion tank and well pump control circuits. The expansion tank is in an
appliance drip tray.

Power for the electronics is not on the same circuit as the well pump.

The top of the crawlspace is at roughly ground level, so the floor benefits from geothermal cooling. Ambient air in the
crawlspace tends to stay at ~65ºF year round (even when outdoor temps exceed 100ºF) as long as the door remains closed,
and that has not changed with the addition of 200+ watts of thermal load.

The rack rolls on casters which were not included. I measured the bolt pattern and
found [ones that match on Amazon](https://www.amazon.com/dp/B08TC3R3CH). The included adjustable feet are inside the
rack, screwed in to their original mounting holes backwards. Be careful about cable tension when moving the rack.

The rack's glass front door is easily removable; open the door and pull the top hinge pin down; it's spring-loaded. When
it releases, lift the bottom pin up and out of its hole, then set the door aside. The side doors also remove easily with
simple spring-clips. The back can be removed as well, but this requires a #2 Philips screwdriver.

#### SysRacks SRW600 12U

- Front rail (top to bottom)
    - Custom 1U bezel from ThingsInRack, painted UniFi
      silver. https://imgur.com/a/12u-network-rack-w-unifi-gear-i5cTOC6. From left to right:
        - Keystone jack providing USB power to the Lutron Caseta gateway
            - The backside is connected to one of the UniFi PDU Pro's USB ports.
        - **Lutron Caseta gateway**
        - Power supply for the Cloud Gateway Fiber
        - Keystone jack for connection to Nokia ONT
        - **UniFi Cloud Gateway Fiber**
        - a custom notch allowing the CGFiber's power cable to route cleanly around the back
    - **UniFi Pro HD 24 PoE** — core switch.
    - 24-keystone patch panel
    - **1U shelf:**
        - GL.iNet Comet X (4-way KVM-over-IP)
        - SMLIGHT SLZB-06P10 (PoE Zigbee gateway)
        - TubesZB Z-Wave PoE kit with Zooz ZAC93 (PoE Z-Wave gateway)
        - UniFi AI Port (adds smart-detection features to older UniFi cameras)
        - UniFi Door Hub Mini (linked to the G6 Entry)
    - UniFi UNVR (4-bay, gen1).
        - Populated with a single WD UltraStar DC HC555 16TB SATA HDD. This gives plenty of retention for now. I don't
          really need redundancy for the NVR, but it would be nice, and when I add more cameras I'm sure I will want
          more space. Maybe someday when HDD prices come down.
    - **2U Raspberry Pi mount:** `rpi5-1` (Talos jump box, holds `talosctl` + cluster secrets; also the Docker Compose
      host for hardware-pinned services like the UPS's NUT client), `talos-cp-1`/`talos-cp-2`/`talos-cp-3` (Talos
      control plane, Pi 5 4GB). Room for six more Pis.
    - **Ubiquiti brush panel** for power cable routing
    - **UniFi PDU Pro** — rack power distribution/monitoring.
        - Everything in the rack gets power from this
        - In turn, this is plugged into the CyberPower UPS.
    - **CyberPower CP1500PFCRM2U** — rack UPS.
- Back rail:
    - **Dig-Octa WLED controller** + **Mean Well 100W 12V power supply** — rack accent, task, and status lighting (it's
      dark in there). Controlled from Home Assistant; not yet automated. Only one LED strip is connected so far — plan
      is to run strips along every edge inside the rack.
- For lack a better location, sitting on top of the Pro HD, behind the CGFiber, with its vents pointed directly at the
  top exhaust fan:
    - **MinisForum MS-A2** (`192.168.102.21`) — AMD Ryzen 8845HS, 32GB RAM, 1TB primary/boot NVMe, plus a 2TB and 4TB
      NVMe passed through to the HexOS VM (see [`docs/hexos-install.md`](docs/hexos-install.md)). Runs Proxmox VE,
      hosting the Talos worker VMs and the HexOS VM.
- **Noctua 120mm fans** — one each in the top and bottom of the rack
- I do not use cage nuts. Everything in the rack is either mounted with Patchbox's /dev/mount (1U items only) or
  RackStuds (all other items). I like /dev/mount better, but they are physically incompatible with non-1U items unless
  said items have extra mounting holes.
- UniFi SuperLink Environment sensor attached magnetically to the inside top of the rack near the Lutron gateway,
  monitoring heat.
- The wire management situation in the back could definitely be better.
- I use [these short extension cords](https://www.amazon.com/dp/B0BGHKHG2W) to declutter the PDU's front appearance.

### On top of the rack

- **2018 MacBook Pro 15" / 32GB / 500GB** — connected via a **Plugable TBT3-UDV dock** to the network and to the Comet
  X. Runs a Talos worker VM under UTM, `talos-worker-mbp` (`192.168.102.34`) — a deliberately temporary stopgap until
  the Mac Studio (see `todo/HARDWARE.md`) arrives and takes over worker duty. See
  [`docs/utm-talos-worker.md`](docs/utm-talos-worker.md) for the runbook and
  [`talos/README.md`](talos/README.md#additional-worker-talos-worker-mbp-added-2026-09-22) for the decision writeup.
  A native Telegraf agent on the physical host itself (outside the VM) ships CPU die temp, thermal throttling, fan
  RPM, power source, and host disk space to SigNoz — see [`docs/mac-host-metrics.md`](docs/mac-host-metrics.md).

### Elsewhere in the crawlspace

- UniFi G5 Turret Ultra - camera mounted to the beam overhead with a view of the network rack. Connected via the UniFi
  AI Port (in the rack) to enable smart detections.
- UniFi SuperLink Environment sensor inside the drip tray with the well expansion tank, providing prompt leak detection
  before water can spread across the space.
- Labeled storage bins with wires, cables, adapters, mounting accessories, and more. If it's tech-adjacent, it's
  probably in here.
- UniFi USL-Entry sensor on the crawlspace door so I can tell when I accidentally leave the door open.

### Office

- **UniFi Pro XG 8 PoE** — on a tray mounted under the desk, connected to the Pro HD 24 PoE via OS2 fiber. Downstream:
    - Office AP (UniFi U7 Pro XGS) - mounted to the underside of the desk.
    - Living Room AP (UniFi U7 Pro XGS) - mounted on the left inside of the built-in cupboard under the TV.
    - HP Color LaserJet Pro M454dw
    - Living Room AV switch (UniFi USW-Flex) -- in the Living Room AV cupboard below the TV.
    - UniFi Vape Detection & Air Quality Sensor. Sits on the desk behind the monitors. Lights up green/yellow/orange/red
      to indicate CO2 levels in decreasing order of safety.
    - UniFi UPS Tower - on the desk behind the monitors, providing battery backup power for both monitors, the CalDigit
      dock, and the network switch.
    - **CalDigit TS5+** dock, 10GbE. Connected accessories:
        - **2021 MacBook Pro 14"** (M1 Pro, 32GB, 500GB) — primary workstation; not part of the homelab infrastructure
          itself, but what's typically used to drive it. Owned by my employer.
            - **Apple Studio Display** 27" 5K display
            - **ACER PB328** 32" 2560x1440 display
            - Apple extended keyboard (I keep it wired)
            - Kensington Expert Mouse 7
            - Logitech C920 webcam

### Living Room

Everything is in the built-in cupboard below the TV.

- LG 65C5 television, not connected to the internet
- In the cupboard:
    - UniFi USW-Flex - providing GbE network connectivity to the cabinet (and PoE for the U5G)
        - Denon AVR-X1600H -- no internet connectivity; this just allows remote control from the app
        - AppleTV 4K 32GB (2nd generation) -- this is the model with Ethernet and a Thread radio.
        - UniFi U5G-Max-Outdoor - there is probably a better place to mount this. Perhaps outdoors!
        - UniFi PowerAmp -- powers the deck speakers. Stream to it with AirPlay.
    - UniFi U7 Pro XGS - wifi access point. Has a dedicated 10GbE uplink, separate from the Flex switch.
    - UniFi SuperLink Environment sensor - monitoring temps in the cupboard. If they spike too high, check the AC
      Infinity controller, or open the cupboard for a while.
- Front speakers: L/C/R are all Ascend Acoustics HBM-200
- Rear speakers: UniFi UACC-In-Ceiling-Speaker
- Lighting:
    - 6x Philips Hue Smart Slim 6-Inch LED Recessed Light - White and Color Ambiance - 1200LM
        - Set up in HomeAssistant with individual control and in HomeKit as "Living Room Lights" as a set. "Hey Siri,
          set the living room lights to purple"
    - Philips Hue Tap Dial Switch is mounted between the two primary seating positions.
        - Button 1: turn on the front row of lights, 30%, 3500K
        - Button 2: turn on the middle row of lights, 30%, 3500K
        - Button 3: turn on the rear row of lights, 30%, 3500K
        - Button 4: Movie mode! Turn on only the right-rear light at 30%, all others off.
        - Dial: adjust brightness of whichever lights are already on up/down. If no lights on, target all lights. Bigger
          steps if you turn faster.
    - Inovelli Blue wall switch
        - Tap up to turn the lights up 10%, or if they're off, set to 30%.
        - Tap down to turn the lights down 10%
        - Hold down -- all off
        - Hold up -- all on
        - Triple-tap up -- all to 70%

### Theater

- Epson PowerLite Home Cinema 8350 - 1080p projector
- retractable 100" projection screen; wired to come down automatically when the projector powers on
- Denon AVR-2313ci
- Front speakers: old RCAs from Jake's ancient home theater system. L/R only, no center. Eventually want to get Ascend
  Acoustics CBM-170 L/R and a CMT340 center.
- Rear speakers: Ascend Acoustics HBM-200.
- Currently no source devices. Had an AppleTV here but gave it to a friend in need; planning to move the gen2 4K here
  when Apple next releases an updated model.
- Currently no network connectivity. Removed existing wiring when we rearranged the living room; need to run something
  from the rack. I have a Flex mini 2.5G ready to be hooked up.

### Garage

* UniFi USL-Environment on the west wall, up high
* UniFi G6 Turret camera mounted high on the front (north) wall
    * Bridged to HomeKit using scrypted as "Garage camera"
* UniFi U7 Pro XGS mounted next to the G6 Turret

### Other

- There is an AC Infinity CloudLine T4 and AI controller mounted near the furnace. This is plumbed into the Living Room
  AV cupboard. Fan speed is fixed at 5. Tap the buttons on the controller to turn it up or down.
    - The controller is paired with HomeAssistant, but you can only monitor, not control it, from there.
    - You can control it from the AC Infinity app. I hate the app; it's a huge pain.
    - Mostly you can just leave this alone; it will just do its thing.
- There is a UniFi USL-Environment sensor under the deck, just sitting on top of one of the posts.
- There is a UniFi USL-Environment sensor on the swingset, mounted up high inside the clubhouse area

## Inventory by device type

### Switches

Pro HD 24 PoE - in the rack Pro XG 8 PoE - under the office desk USW-Flex - in the living room cupboard. If I move the
U5G-Max to an outdoor mounting location, the PoE need goes away and this can be swapped out for a Flex Mini 2.5G 2x Flex
mini 2.5G, currently unused. One is spoken for above; the other goes to the theater once I restore wired connectivity
there. Flex mini, currently unused

### Access Points

- **Garage AP** -- UniFi U7 Pro XGS, mounted high on the front wall of the garage.
- **Living Room AP** -- UniFi U7 Pro XGS, mounted on the left inside of the built-in cupboard under the TV.
- **Office AP** -- UniFi U7 Pro XGS, mounted to the underside of the desk in my office.

### Cameras

- **Doorbell** - UniFi G6 Entry. Linked to the Door Hub Mini with eventual intentions to enable Apple Wallet
  tap-to-unlock.
- **Garage** - UniFi G6 Turret.
- **Crawlspace** - UniFi G5 Turret Ultra. mounted to the beam overhead with a view of the network rack. Connected via
  the UniFi AI Port (in the rack) to enable smart detections.

### Other

- UniFi USL-Entry door sensor on the crawlspace door
- UniFi USL-Environment temp/humidity/leak sensors:
    - Inside top of rack, above the Lutron gateway
    - Crawlspace floor, inside the appliance drip tray with the expansion tank
    - Garage -- up high on the west wall near the sawhorses
    - Under deck -- on top of one of the posts between the cars
    - Outside -- in the swingset/playhouse, attached magnetically, up high
- UniFi Vape Detection / Air Quality sensor -- on my desk behind the monitors

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

Infrastructure
* Authelia
* ArgoCD
* Cilium
* cert-manager
  * cert-manager-config
* external-dns
* ntfy
* ntfy-alertmanager

Storage
* local-path-provisioner
* democratic-csi

Observability
* metrics-server
* kube-prometheus-stack
* SigNoz
  * signoz-k8s-infra

Operations
* renovate

Applications
* homepage
* searxng

## External Dependencies

### Critical

* I use Claude Code to help keep everything running smoothly. It checks for issues daily and fixes them automatically.
  There's a $200/year ($17/month) subscription.
* I use Backblaze B2 to keep offsite backups of important data. The cost varies depending on how much we store.
  Currently under $20/month.
* I use CloudFlare for DNS. It's free.
* I also use Hover for DNS. It's not free; I need to move stuff to CloudFlare.
* I use Akamai/Linode to serve my personal website. If I'm dead, I would really like this to remain up.
  Currently ~$90/month; I am working to move as much as possible in-house. I should be able to get it down to $5/month.
* We have an Apple One Premier subscription. This provides cloud storage for our photo libraries and phone backups, as
  well as Apple TV, Apple Music, Apple News, Apple Arcade, and Apple Fitness. Currently $39.95/mo. We use TV and Music
  extensively, but they are technically optional; this is here for the cloud storage part.

### Optional

We also subscribe to several streaming TV services:

- Amazon Prime
- Netflix
- WOW
- Disney+/Hulu
- HBO
- Paramount+
- Peacock ($19.99 / month)
- Discovery+
- YouTube Premium

None of these are strictly necessary, but we use them all regularly.

### In the event of my demise

* It probably makes sense to drop YouTube Premium; I think I'm the only one using it.
* I also have a Reddit Premium subscription which can be canceled.

## Plans

In general, I plan to move as much as I can from the Pi to Kubernetes, and when that's done, probably convert the Pi
into a Talos worker node. I would at that point get another Pi (with less RAM) to act as the jump box.

I keep a todo list in the repo where it's easy to manage. There are four documents:

* todo/READY.md -- todo-list items which are available to be worked
* todo/FUTURE.md -- items which are blocked by some external dependency
* todo/DONE.md -- items already done
* todo/HARDWARE.md -- planned physical changes. This doc is a mixture of ready- and future-style entries. 
