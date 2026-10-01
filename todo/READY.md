# READY

Cluster-readiness backlog — each of these is its own effort, meant to be tackled separately rather than all at once.
This list is in roughly priority order. "Compose workload migration" is deliberately last; we want a stable, robust,
observable cluster before we bring in critical workloads.

## Compose workload migration

**In progress (since 2026-09-28).** Migrated services move to [`DONE.md`](DONE.md) as they land.
Move each service off the RPi5 16GB's Docker Compose stack into the cluster, one at a time, in separate sessions. For
each, consider whether a more K8s-appropriate or K8s-native alternative exists. Each application should be a separate
ArgoCD Application resource. Put each application behind Authelia -- using OIDC if possible; ExternalAuth filtering
otherwise. Persistent storage moves from the Pi to democratic-csi PVC.

### Do not migrate

- **Observability stack** (`influxdb`, `grafana`, `telegraf`, `victorialogs`, `vector`) - Superseded by whatever comes
  out of the "Log and Metrics aggregation" item instead of running two parallel timeseries stacks — see that section for
  the current direction. Where reasonably easy, migrate the existing InfluxDB history into the new stack for continuity
  (not required, per Jake). NetworkOptimizer's buckets are the exception: they moved to the app's own in-cluster
  InfluxDB on 2026-09-29 (see [`DONE.md`](DONE.md)), so the Compose InfluxDB now serves only Telegraf.
- **`nut-upsd`** — needs USB access to the CyberPower UPS, so it stays on rpi5-1 until the hardware plan in
  [`HARDWARE.md`](HARDWARE.md) moves that Pi into the cluster. Its relay and web UI were replaced by nut-exporter
  (see [`DONE.md`](DONE.md)).

### To be migrated

- **Home automation stack** (`homeassistant`, `zigbee2mqtt`, `zwave-js-ui`,
  `matter-server`, `mosquitto`) — none hardware-pinned. The Zigbee and Z-Wave coordinators are on Ethernet, not USB.
  Home Assistant doesn't use Bluetooth, so the `/run/dbus` mount can go. Its `/dev/ttyAMA0` / `/dev/serial0` devices
  (the Pi's GPIO UART) were for an integration that never worked and isn't in use, so drop them and `privileged: true`
  rather than carrying them over.
- **scrypted** — camera/NVR bridge
- **change-detection.io** (`change-detection` + its `browserless` dependency) — **deliberately last; don't suggest it
  as the next migration.** browserless (headless Chromium) is heavy, and Jake has ideas for relying on it less, so it
  waits until everything else has moved. No hardware dependency. Needs a persistent volume for the datastore.

When a service migrates, delete its file from `manifests/lan-routes/` in the same PR.

## Dual-stack cluster (IPv4 + IPv6)

The cluster is IPv4-only: pods (`10.244.0.0/16`), Services and the Cilium LB pool (`192.168.102.128/26`) have no
IPv6, and the nodes have no IPv6 addresses. That was fine until the in-cluster Unbound
([`../argocd/README.md`](../argocd/README.md#unbound-in-cluster-copy-deployed-2026-09-29)) needed an IPv6 address to
hand out. Its VIP is IPv4 only (`192.168.102.130`), so for now DHCPv6/RA on the Server and Trusted VLANs should keep
advertising only the jump box's `fd3d:b17d:9f8e:102::2` as an IPv6 resolver.

Dual-stack is a project of its own, not a side effect of Unbound: it touches every workload and needs a maintenance
window. Rough steps:

- Add an IPv6 pod CIDR and service CIDR (from the `fd3d:b17d:9f8e::/48` ULA space) to the control-plane config, and
  enable IPv6 in Cilium (`talos/cilium/values.yaml`). Cilium's pod CIDR allocation has to match the Talos
  `podSubnets`, same as for IPv4.
- Give every node a stable IPv6 address (SLAAC or a reservation), including the MBP's UTM VM.
- Add an IPv6 block to the `homelab-pool` LB pool, and set `ipFamilyPolicy: PreferDualStack` on the Gateway's and the
  Unbound Service, with a pinned IPv6 address for Unbound.
- **Check first:** whether Cilium's L2 announcements answer IPv6 neighbor discovery (NDP) on the version we run. If
  they don't, an IPv6 LB IP can't be announced on the LAN, and the alternatives (BGP, a different approach) change the
  plan.
- Check every workload that hard-codes an address family or a `0.0.0.0` bind, and the UniFi firewall rules between
  VLANs, which need IPv6 equivalents for anything the cluster serves.
- On the UniFi side, DHCPv6 only hands out DNS servers to clients that speak DHCPv6. SLAAC with RDNSS reaches more
  devices (Android in particular ignores DHCPv6), so switch the Server and Trusted VLANs to SLAAC when adding the
  Unbound IPv6 address, as some of the other dual-stack VLANs already are.

Then add the IPv6 VIP to the Server and Trusted VLANs' IPv6 DNS servers next to the jump box's.

## NetworkOptimizer preview pin → stable release

**Unblocked 2026-09-30:** the stable NetworkOptimizer **2.9.0** release shipped 2026-09-29. Was waiting on it
([Ozark-Connect/NetworkOptimizer releases](https://github.com/Ozark-Connect/NetworkOptimizer/releases)). On 2026-09-24
the app was pinned to `ghcr.io/ozark-connect/network-optimizer:2.9.0-preview2` (bumped to `-preview7` on 2026-09-28) to
try out a new feature the developer asked us to test. Renovate won't move it either: it treats `-previewN` as a variant
suffix, so it never proposes a plain `2.9.0`. Once 2.9.0 (or later) ships, set both containers in
[`../manifests/network-optimizer/deployment.yaml`](../manifests/network-optimizer/deployment.yaml) (`network-optimizer`
and `speedtest`, which are released in lockstep) to that version. Renovate tracks them from there. (It ran on Compose
until 2026-09-28; see [`DONE.md`](DONE.md).)

## Talos workload isolation (`SecurityProfileConfig`)

**Unblocked 2026-09-30:** Talos v1.14.2 (2026-09-29) includes the fix (`fix: use correct conditions on CRI <> sandboxd dependency`). Was waiting on a release that fixes
[siderolabs/talos#14374](https://github.com/siderolabs/talos/issues/14374) — a
startup race between CRI and `sandboxd` that causes every node to
restart-loop for 1–3 minutes on every boot with `workloadIsolation: true`
enabled. Fixed upstream 2026-09-16, one day after the currently-running
Talos version was published, so we're still on the affected release. See
[`../talos/README.md`](../talos/README.md#workload-isolation-talos-114-feature-not-enabled)
for what this feature would buy us and why it's otherwise appealing. No
target date — check the changelog of each new Talos release for #14374
specifically before assuming it's fixed.

Next step: upgrade the nodes to v1.14.2 first, then enable the feature and confirm a clean boot on one node before rolling it out.
