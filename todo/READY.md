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
  (not required, per Jake).
- **Caddy** — obviated by Cilium Gateway. Its routes now live in `manifests/lan-routes/`; see "Retire Caddy" below.

### To be migrated

- **change-detection.io** (`change-detection` + its `browserless` dependency) — no hardware dependency. Needs a
  persistent volume for the datastore.
- **NUT UPS monitoring** (`nut-upsd`, `nut-webui`, `nut-influx-relay`) —
  `nut-upsd` needs direct USB access to the CyberPower UPS and almost certainly has to stay Pi-pinned; `nut-webui` and
  `nut-influx-relay` only talk to it over the network, though, so those two could plausibly migrate independently even
  if `nut-upsd` doesn't.
- **Home automation stack** (`homeassistant`, `zigbee2mqtt`, `zwave-js-ui`,
  `matter-server`, `mosquitto`) — none hardware-pinned. The Zigbee and Z-Wave coordinators are on Ethernet, not USB.
  Home Assistant doesn't use Bluetooth, so the `/run/dbus` mount can go. Its `/dev/ttyAMA0` / `/dev/serial0` devices
  (the Pi's GPIO UART) were for an integration that never worked and isn't in use, so drop them and `privileged: true`
  rather than carrying them over.
- **scrypted** — camera/NVR bridge
- **modbus-controller** — custom app talking to a Modbus-over-Ethernet device

When a service migrates, delete its file from `manifests/lan-routes/` in the same PR.

### Retire Caddy

**In progress (2026-09-29).** Every Caddy hostname, including the non-Compose LAN devices (`gateway`, `kvm`,
`rack-led`, `modbus-relay`), now has an HTTPRoute in `manifests/lan-routes/`. See
[`../argocd/README.md`](../argocd/README.md#lan-routes-replacing-caddy-added-2026-09-29). Remaining:

1. UniFi firewall: allow the cluster nodes into the IoT VLAN (`192.168.62.0/24`), as rpi5-1 already is.
2. Delete the Cloudflare CNAMEs to `caddy.lan` for `gateway`, `homeassistant`, `modbus`, `modbus-relay`, `nut` and
   `scrypted`, so external-dns can create their `A` records.
3. Verify every hostname through the Gateway, including websockets (Home Assistant, Z-Wave JS UI, Zigbee2MQTT,
   Scrypted, KVM).
4. Remove Caddy from `docker-compose/`, then delete the wildcard `*.jakerobb.org` and `caddy.jakerobb.org` CNAMEs and
   the `caddy.lan` DNS entry.
