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
- **Caddy** — obviated by Cilium Gateway. Before it can be retired, its routes to non-Compose devices need
  HTTPRoutes of their own (see "Caddy's non-Compose routes" below).

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

### Caddy's non-Compose routes

Caddy also reverse-proxies `*.jakerobb.org` names for devices on the LAN that aren't Compose services. Each needs an
HTTPRoute on `homelab-gateway`, backed by a selector-less Service + EndpointSlice (or similar) pointing at the device,
and behind Authelia. No state, so these can be done any time, independent of the migrations above.

| Hostname                    | Caddy backend today |
|-----------------------------|---------------------|
| `gateway.jakerobb.org`      | `gateway.lan:80`    |
| `rack-led.jakerobb.org`     | `rack-led.lan:80`   |
| `kvm.jakerobb.org`          | `kvm.lan:80`        |
| `modbus-relay.jakerobb.org` | `modbus.lan:80`     |

Caddy's other names move with their apps and don't need separate work: `homeassistant`, `scrypted`, `modbus`
(modbus-controller), `nut` (nut-webui), `changedetection`, `zigbee` and `zwave`. `influxdb`, `grafana` and `logs`
(VictoriaLogs) go away with the observability stack.
