# Docker Compose stack (rpi5-1)

This is the Docker Compose stack that runs on the RPi5 16GB (`rpi5-1.lan`,
`192.168.102.2`) — the box that stays outside the Talos cluster for
hardware-pinned duties (e.g. UPS NUT client) plus the LAN's Caddy reverse proxy, Unbound
resolver, and metrics/logging stack.

Many of these workloads are not hardware dependent, and movement to
Kubernetes will happen as time permits.

Deployed by copying this directory to `~/docker` on `rpi5-1` and running
`docker compose up -d` from there. Not yet wired into any CI/CD — changes are
made on the host and backfilled here, or edited here and copied over.

## What's captured vs. excluded

Only hand-authored configuration is captured. Runtime state, caches, logs,
and database files are **not** committed — they're excluded the same way
`grafana/grafana.db` was excluded from this capture:

- `homeassistant/.storage/`, `.cloud/`, `.cache/`, `core/`, `deps/`, `tts/`,
  `*.log*`, `home-assistant_v2.db*` — Home Assistant's internal state
  (entity/device registries, auth, HomeKit pairing state, restore state,
  UI-managed integration configs). **Note:** integrations added via the UI
  "Add Integration" flow live only in `.storage/core.config_entries` and are
  *not* reproducible from the YAML files here — if HA needs to be rebuilt
  from scratch, those integrations must be re-added manually.
- `homeassistant/custom_components/` (53MB, HACS-managed: `hacs` itself and
  `ac_infinity`) — reinstall via HACS rather than vendoring the code.
- `scrypted/` — just plugin binaries + a SQLite db, no meaningful config file.
- `matter-server/data/` — Matter fabric/commissioning state.
- `change-detection/` — only `url-watches.json` (the watch list) is
  captured; per-watch history, screenshots, and snapshot archives are not.
- `zwave-js-ui/nodes.json`, `.config-db/`, `logs/`, `sessions/`, `*.jsonl*`
  — Z-Wave node state and session data.
- `zigbee2mqtt/data/{database.db,state.json,coordinator_backup.json,log}`
  — device state and coordinator network backup (**note:** losing the
  coordinator backup without the live network key means re-pairing every
  Zigbee device if the coordinator ever needs replacing — the network key
  itself is captured, encrypted, below).
- `influxdb/data/`, `mosquitto/data/`, `mosquitto/log/`, `ntfy/cache/`,
  `grafana/` (all of it — `grafana-provisioning/` is captured separately
  and is the only hand-authored part), `data/`, `logs/`, `ssh-keys/` (the
  network-optimizer container's SQLite db, PDFs, and license — `ssh-keys/`
  is currently empty).
- `nut-conf/` — empty on the host (0600, no files); nothing to capture.
- `caddy/Caddyfile.bak` — a stale backup, superseded by `Caddyfile`.

## Secrets

This repo is public, so anything with a real credential in it is encrypted
with SOPS + age (same key/mechanism as `talos/secrets.sops.yaml` and
`argocd/secrets/*.sops.yaml` — see the repo root `.sops.yaml`). Decrypt with
the age key from 1Password (`~/.config/sops/age/keys.txt` on `rpi5-1` and
the Talos jump box already have it):

```bash
sops -d --input-type dotenv --output-type dotenv docker-compose/.env.sops.env > .env
sops -d docker-compose/homeassistant/secrets.sops.yaml > homeassistant/secrets.yaml
sops -d --output-type binary docker-compose/homeassistant/lutron_caseta-0512b4cc-key.pem.sops.yaml > homeassistant/lutron_caseta-0512b4cc-key.pem
sops -d --output-type binary docker-compose/secrets/nut-upsd-password.sops.yaml > secrets/nut-upsd-password
sops -d --output-type binary docker-compose/influxdb/config/influx-configs.sops.yaml > influxdb/config/influx-configs
sops -d docker-compose/zigbee2mqtt/configuration.sops.yaml > zigbee2mqtt/data/configuration.yaml
sops -d docker-compose/zwave-js-ui/settings.sops.json > zwave-js-ui/settings.json
sops -d --output-type binary docker-compose/zwave-js-ui/users.json.sops.yaml > zwave-js-ui/users.json
sops -d --output-type binary docker-compose/change-detection/secret.txt.sops.yaml > change-detection/secret.txt
```

Encrypted files (all under `docker-compose/`, matched by the
`docker-compose/.*\.sops\.(yaml|json|env)$` rule in `.sops.yaml`):

| File | Contains |
|---|---|
| `.env.sops.env` | Cloudflare API token, NUT/InfluxDB/Grafana/UniFi credentials and tokens, app passwords |
| `homeassistant/secrets.sops.yaml` | NUT UPS password used by the HA UPS integration |
| `homeassistant/lutron_caseta-0512b4cc-key.pem.sops.yaml` | Lutron Caséta bridge mTLS private key (the paired `-ca.pem`/`-cert.pem` are public certs, committed in the clear) |
| `secrets/nut-upsd-password.sops.yaml` | NUT UPS daemon password (mounted into `nut-upsd` as a Docker secret) |
| `influxdb/config/influx-configs.sops.yaml` | InfluxDB CLI default-profile auth token |
| `zigbee2mqtt/configuration.sops.yaml` | Zigbee network key + PAN ID (whole file encrypted since the key is embedded inline) |
| `zwave-js-ui/settings.sops.json` | Z-Wave S0/S2 network security keys |
| `zwave-js-ui/users.json.sops.yaml` | Z-Wave JS UI admin password hash |
| `change-detection/secret.txt.sops.yaml` | changedetection.io API key |

`.env` is `--input-type dotenv --output-type dotenv` (encrypted line-by-line,
keeping the `KEY=value` shape); `*.pem.sops.yaml`, `nut-upsd-password.sops.yaml`,
`influx-configs.sops.yaml`, and `secret.txt.sops.yaml` are `--input-type binary`
(not valid YAML/JSON on their own, so SOPS wraps the raw bytes); the rest are
encrypted in their native YAML/JSON with SOPS's normal per-value encryption.

## Layout notes

- `docker-compose.yml` uses `${VAR}` substitution throughout for anything
  secret — none of the captured config files have a literal credential in
  plaintext, only the files listed above (which are the *sources* those
  `${VAR}`s or bind-mounted files ultimately come from).
- `resolv.conf` / `resolv-host.conf` are bind-mounted into several
  containers to point them at Unbound (`192.168.102.2`) instead of Docker's
  default embedded DNS — see the `x-dns` anchor and per-service
  `/etc/resolv.conf` mounts in `docker-compose.yml`.
