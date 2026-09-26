# READY

Cluster-readiness backlog — each of these is its own effort, meant to be tackled separately rather than all at once.
This list is in roughly priority order. "Compose workload migration" is deliberately last; we want a stable, robust,
observable cluster before we bring in critical workloads.

## Migrate domain names Hover -> CloudFlare

I have several domain names registered at Hover:
* jakerobb.dev -- my personal website
* soleman.ski -- Squarespace site for my father-in-law's business. I never finished it. 
* commaspacebitch.com -- a joke domain I registered twenty years ago, never used, and should stop paying for.

Just grabbed these because I could; completely unused; some forwarded to jakerobb.dev
* jakerobb.me
* robb.online
* robb.software

Reserved business opportunities:
* indigoapps.dev -- Indigo because it's the color Apple left out of its original rainbow logo; the idea was that I'd build apps Apple neglected. No specific ideas.
* fastodon.dev, fastodon.me - I was into Mastodon for a while and thought I wanted to build and host an ActivityPub server in Go rather than Ruby; it would be super performant, hence the name. 
* camaroev.net, camaro-ev.com, camaroev.org, camaroquestions.com, firebirdquestions.com, transamquestions.com, fbodyquestions.com, modyourcamaro.com -- I love Camaros and wanted to build something here. 

## Make a Documentation app/site -- docs.jakerobb.org

Serves a hyperlinked view of all the docs. What everything is, how it works, how it's connected, how to fix common 
issues, how to get access, etc. This should be behind Authelia, linked from Homepage, and deployed as an ArgoCD
application just like everything else.

## Compose workload migration

**Not started — deliberately held until the cluster itself is robust**
Move each service off the RPi5 16GB's Docker Compose stack into the cluster, one at a time, in separate sessions. For
each, consider whether a more K8s-appropriate or K8s-native alternative exists. Each application should be a separate
ArgoCD Application resource. Put each application behind Authelia -- using OIDC if possible; ExternalAuth filtering
otherwise. Persistent storage moves from the Pi to democratic-csi PVC.

### Do not migrate

- **Observability stack** (`influxdb`, `grafana`, `telegraf`, `victorialogs`, `vector`) - Superseded by whatever comes
  out of the "Log and Metrics aggregation" item instead of running two parallel timeseries stacks — see that section for
  the current direction. Where reasonably easy, migrate the existing InfluxDB history into the new stack for continuity
  (not required, per Jake).
- **Watchtower** — obviated by Renovate
- **Ofelia** — replaced by K8s CronJobs
- **Caddy** — obviated by Cilium Gateway

### To be migrated

- **Unpoller** (UniFi metrics aggregation) — probably switching from InfluxDB as a target to Prometheus
- **NetworkOptimizer** (`optimizer` + `network-optimizer-speedtest`) — no hardware dependency, network-based app. Needs
  a persistent volume (SQLite, configs, license under `./data`)
- **change-detection.io** (`change-detection` + its `browserless` dependency) — no hardware dependency. Needs a
  persistent volume for the datastore.
- **NUT UPS monitoring** (`nut-upsd`, `nut-webui`, `nut-influx-relay`) —
  `nut-upsd` needs direct USB access to the CyberPower UPS and almost certainly has to stay Pi-pinned; `nut-webui` and
  `nut-influx-relay` only talk to it over the network, though, so those two could plausibly migrate independently even
  if `nut-upsd` doesn't.
- **Home automation stack** (`homeassistant`, `zigbee2mqtt`, `zwave-js-ui`,
  `matter-server`, `mosquitto`) — none hardware-pinned; ZWave and Zigbee integrations are all network-based.
- **scrypted** — camera/NVR bridge
- **modbus-controller** — custom app talking to a Modbus-over-Ethernet device
