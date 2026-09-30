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
- **modbus-controller** — custom app talking to a Modbus-over-Ethernet device
- **change-detection.io** (`change-detection` + its `browserless` dependency) — **deliberately last; don't suggest it
  as the next migration.** browserless (headless Chromium) is heavy, and Jake has ideas for relying on it less, so it
  waits until everything else has moved. No hardware dependency. Needs a persistent volume for the datastore.

When a service migrates, delete its file from `manifests/lan-routes/` in the same PR.
