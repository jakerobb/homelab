# Docker Compose stack (rpi5-1)

This is the Docker Compose stack that runs on the RPi5 16GB (`rpi5-1.lan`,
`192.168.102.2`) — the box that stays outside the Talos cluster for
hardware-pinned duties (e.g. UPS NUT client) plus the LAN's Unbound
resolver and metrics/logging stack. Its web UIs are reached through the
cluster's Gateway ([`manifests/lan-routes/`](../manifests/lan-routes/)), which
replaced Caddy on 2026-09-29.

Many of these workloads are not hardware dependent, and movement to
Kubernetes will happen as time permits.

Deployed from `~/docker` on `rpi5-1`. **Merging to `main` is the deploy
step:** a cron job on rpi5-1 pulls, syncs, runs `docker compose up -d`, and
restarts services whose config changed, within about 5 minutes. See
[`docs/compose-deploy.md`](../docs/compose-deploy.md). `~/docker` is not a
copy of this directory anymore (see "Split-brain elimination" below): most
config-time files under `~/docker/` are symlinks into
`~/dev/homelab/docker-compose/`, which is a plain `git clone` of this repo.
The files that can't be symlinked (Docker limitation, see below) and the
decrypted secrets are real copies, which the auto-deploy script keeps in
sync. It alerts, and doesn't overwrite, if they're changed on the host.

## Split-brain elimination (2026-09-20)

Previously: edit on the host and backfill here, or edit here and copy over
by hand — exactly the ad-hoc process that let `caddy/Caddyfile` (a stale
`jetkvm.jakerobb.org` route, dead for who knows how long — `jetkvm1.lan`
doesn't even resolve anymore) and `docker-compose.yml` (a `/dev/ttyAMA0`/
`/dev/serial0` device passthrough added to homeassistant directly on the
host) silently drift out of the repo. Fixed with symlinks from `~/docker/`
into a `~/dev/homelab` git checkout on rpi5-1 — one copy of the content,
`git pull` is the only sync step needed, drift becomes structurally
impossible instead of just easy to avoid.

**Symlinked (works reliably):** `docker-compose.yml`, `resolv-host.conf`, `telegraf/` (whole dir),
`vector/vector.yaml`, plus (added
2026-09-24, none of them bind-mounted by any running service)
`ntfy/conf/server.yml`, `nut-conf-office/ups.conf`, and
`zigbee2mqtt/configuration.sops.yaml`.

**NOT symlinked — reverted to real (manually re-copied) files after a live
test broke Home Assistant** (config unreadable inside the container within
seconds of creating the symlink, caught and fixed before anything actually
restarted and failed on it): `homeassistant/{configuration,automations,
scenes,scripts}.yaml`, `homeassistant/blueprints/`,
`homeassistant/lutron_caseta-*.pem`, `change-detection/url-watches.json`,
`unbound/custom.conf.d/local.conf`,
`mosquitto/config/`.

**Why those specifically fail** — two distinct Docker bind-mount behaviors,
confirmed live against this stack, not just theory:
1. A symlinked **file** as a bind-mount source works, whether it's the
   direct source (`resolv-host.conf`) or reached through a symlinked parent
   *directory* in the path (`telegraf/telegraf.conf`) — Docker resolves the full host path,
   including any symlinks, before creating the mount.
2. A symlinked **directory** used as the bind-mount source itself does
   *not* get resolved the same way (`mosquitto/config` — confirmed via a from-scratch container restart:
   `cat` inside the container returned `No such file or directory` even
   though the symlink itself was intact and pointed somewhere real).
   Similarly, a symlink for a single file *nested inside* an
   already-real, whole-directory bind mount (`./homeassistant:/config`,
   `./change-detection:/datastore`) is invisible from inside the
   container — its mount namespace only has whatever was actually mounted,
   not arbitrary other host paths a symlink happens to point at.

Fixing these properly needs Docker's actual supported mechanism for this —
an explicit extra bind-mount line per file, layered on top of the existing
directory mount (e.g. `./homeassistant/configuration.yaml:/config/configuration.yaml`
*in addition to* `./homeassistant:/config`) — which is a real edit to
`docker-compose.yml`'s volumes, not just a host-side symlink, and wasn't
made without discussing it first given the Home Assistant near-miss above.
Until that's decided, these files stay as copies. They're no longer copied
by hand: [auto-deploy](../docs/compose-deploy.md) syncs them on merge and
alerts when one is changed on the host.

**One general gotcha, hit repeatedly during this migration:** a container
that was already running when its bind-mount source changed on the host
(symlink created, or reverted back to a real file/dir) keeps serving
whatever it resolved at its *own* start time — Linux bind-mounts a specific
filesystem object, not a path that's continuously re-resolved. `docker
compose up -d` only recreates a container if the *compose file* content
changed; it does **not** notice a bind-mount source changing type on disk.
A container whose mount source was directly replaced (not just a file
*within* an unchanged directory) needs an explicit restart
(`docker compose restart <service>`) to pick it up — confirmed necessary
for `mosquitto` and `unbound`.

## What's captured vs. excluded

Only hand-authored configuration is captured. Runtime state, caches, logs,
and database files are **not** committed:

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
- `mosquitto/data/`, `mosquitto/log/`, `ntfy/cache/`.
- `nut-conf/` — genuinely empty (confirmed 2026-09-20, permissions had
  drifted to unreadable — fixed to `u+x`), and unreferenced by anything: the
  `nut-upsd` container generates its real `/etc/nut/ups.conf` itself
  (`instantlinux/nut-upsd`'s own entrypoint, from env vars), not from this
  bind mount. `nut-conf-office/ups.conf`, tracked below in this same repo,
  is consequently **orphaned** — not mounted by any service in
  `docker-compose.yml`, doesn't correspond to `nut-conf/` despite the
  similar name. Left in place rather than deleted, since removing it wasn't
  asked for and it's possible it predates the current image's
  auto-generation behavior and has some other purpose not yet understood.

## Secrets

This repo is public, so anything with a real credential in it is encrypted
with SOPS + age (same key/mechanism as `talos/secrets.sops.yaml` — see the repo root `.sops.yaml`). Decrypt with
the age key from 1Password (`~/.config/sops/age/keys.txt` on `rpi5-1` and
the Talos jump box already have it):

```bash
sops -d --input-type dotenv --output-type dotenv docker-compose/.env.sops.env > .env
sops -d docker-compose/homeassistant/secrets.sops.yaml > homeassistant/secrets.yaml
sops -d --output-type binary docker-compose/homeassistant/lutron_caseta-0512b4cc-key.pem.sops.yaml > homeassistant/lutron_caseta-0512b4cc-key.pem
sops -d --output-type binary docker-compose/secrets/nut-upsd-password.sops.yaml > secrets/nut-upsd-password
sops -d docker-compose/zigbee2mqtt/configuration.sops.yaml > zigbee2mqtt/data/configuration.yaml
sops -d docker-compose/zwave-js-ui/settings.sops.json > zwave-js-ui/settings.json
sops -d --output-type binary docker-compose/zwave-js-ui/users.json.sops.yaml > zwave-js-ui/users.json
sops -d --output-type binary docker-compose/change-detection/secret.txt.sops.yaml > change-detection/secret.txt
```

Encrypted files (all under `docker-compose/`, matched by the
`docker-compose/.*\.sops\.(yaml|json|env)$` rule in `.sops.yaml`):

| File | Contains |
|---|---|
| `.env.sops.env` | Cloudflare API token, NUT/UniFi credentials and tokens, app passwords. `INFLUXDB_ADMIN_PASSWORD` and `INFLUXDB_ADMIN_TOKEN` stay for NetworkOptimizer's in-cluster InfluxDB (restored from the Compose instance's metadata), no longer used by anything in Compose |
| `homeassistant/secrets.sops.yaml` | NUT UPS password used by the HA UPS integration |
| `homeassistant/lutron_caseta-0512b4cc-key.pem.sops.yaml` | Lutron Caséta bridge mTLS private key (the paired `-ca.pem`/`-cert.pem` are public certs, committed in the clear) |
| `secrets/nut-upsd-password.sops.yaml` | NUT UPS daemon password (mounted into `nut-upsd` as a Docker secret) |
| `zigbee2mqtt/configuration.sops.yaml` | Zigbee network key + PAN ID (whole file encrypted since the key is embedded inline) |
| `zwave-js-ui/settings.sops.json` | Z-Wave S0/S2 network security keys |
| `zwave-js-ui/users.json.sops.yaml` | Z-Wave JS UI admin password hash |
| `change-detection/secret.txt.sops.yaml` | changedetection.io API key |

`.env` is `--input-type dotenv --output-type dotenv` (encrypted line-by-line,
keeping the `KEY=value` shape); `*.pem.sops.yaml`, `nut-upsd-password.sops.yaml`,
and `secret.txt.sops.yaml` are `--input-type binary`
(not valid YAML/JSON on their own, so SOPS wraps the raw bytes); the rest are
encrypted in their native YAML/JSON with SOPS's normal per-value encryption.

## Layout notes

- `docker-compose.yml` uses `${VAR}` substitution throughout for anything
  secret — none of the captured config files have a literal credential in
  plaintext, only the files listed above (which are the *sources* those
  `${VAR}`s or bind-mounted files ultimately come from).
- DNS: bridge-network containers use Docker's embedded DNS (`127.0.0.11`),
  which forwards to Unbound (`192.168.102.2`) via the `x-dns` anchor.
  Host-network containers don't get the embedded resolver, so they
  bind-mount `resolv-host.conf` instead. This only works because Unbound
  sets `interface-automatic: yes` (see `unbound/custom.conf.d/local.conf`):
  without it, UDP replies to bridge containers come back from `172.18.0.1`
  and get dropped, so every lookup times out.
