# Compose auto-deploy (rpi5-1)

Merging a PR that touches [`docker-compose/`](../docker-compose/) deploys it
to rpi5-1 within ~5 minutes, with no manual `git pull` / `docker compose up
-d` / re-copy / restart step. It's pull-based: a cron job on rpi5-1 runs
[`scripts/compose-deploy/compose-deploy.py`](../scripts/compose-deploy/compose-deploy.py)
straight out of its `~/dev/homelab` checkout, so a merged change to the
script itself also deploys itself on the next run.

**Why not a GitHub Actions deploy job:** the only self-hosted runner lives on
this same box, and running `docker compose` would mean putting the
`gha-runner` user in the `docker` group — root-equivalent on the jump box
that holds the Talos secrets. With pull-based deploys GitHub never gets a
path in; rpi5-1 only ever reads from it, as the user that already owns the
stack.

This is interim tooling for as long as the Compose stack exists — workloads
moving to the cluster get ArgoCD's reconciliation instead.

## What each run does

1. **Fast-forwards `~/dev/homelab` to `origin/main`.** If the checkout has
   uncommitted changes, is on another branch, or has diverged, it stops and
   alerts rather than guessing — hand edits on the host are exactly how
   drift started last time (see the split-brain notes in
   [`docker-compose/README.md`](../docker-compose/README.md)).
2. **Validates the compose file** (`docker compose config`). If it's
   invalid, nothing is touched.
3. **Syncs the files that can't be symlinks.** Everything tracked under
   `docker-compose/` that isn't reached through a symlink in `~/docker` gets
   copied, and the SOPS files get decrypted to their `~/docker` locations
   (the same list as the README's decrypt commands, in the script's
   `DECRYPTED` table). New tracked files are picked up automatically.
   - **Drift protection:** the script records the hash of every file it
     writes. If a file in `~/docker` no longer matches the last thing it
     wrote — edited on the host, or rewritten by the app itself (a Home
     Assistant UI edit to `automations.yaml`, a changedetection.io watch
     added in its UI) — it doesn't overwrite it. It alerts until you either
     backfill the change into the repo (once the repo matches what's on the
     host, the alert clears by itself) or revert it on the host.
   - `change-detection`, `zigbee2mqtt`, and `zwave-js-ui` rewrite their own
     config at runtime or on shutdown, so they're stopped before their files
     are written and started again by step 4.
4. **`docker compose up -d --remove-orphans`**, every run, not just after a
   merge. That applies compose-file and `.env` changes, and also undoes
   drift in the other direction: a container stopped by hand comes back
   within 5 minutes. (To keep something down on purpose, comment it out of
   `docker-compose.yml` via a PR.)
5. **Restarts services whose config changed but that `up -d` didn't
   recreate.** `up -d` only looks at the compose file, not at the contents
   of bind-mounted files. Services are matched to changed files through
   their actual bind mounts (from `docker compose config`), so there's no
   table to maintain. A restart, not just a reload, is what picks up a
   changed single-file bind mount like `caddy/Caddyfile` (see the inode
   gotcha in the compose README).
   - Caddy (`caddy validate`) and Home Assistant (`check_config`) are
     validated first. If validation fails, the service is **not** restarted:
     it keeps running its old config, and you get an alert. Note the broken
     file is already on disk, so fix it forward promptly. Failed restarts
     are retried after the next merge (or with `--retry`).
6. **Notifies** via ntfy topic `homelab-alerts` (the same one Alertmanager
   uses): deploys at low priority, problems at high priority. Each problem
   alerts once, plus a "resolved" message when it clears, not every 5
   minutes. If ntfy is unreachable (it runs on the cluster) or the script
   crashes, the output goes to stderr and cron mails it through the Brevo
   relay ([`email-alerts.md`](email-alerts.md)).

Messages go to an unauthenticated ntfy topic, so they only ever include file
paths and service names, never file contents or command output. Full detail,
including the output of failed commands, goes to
`~/.local/state/compose-deploy/deploy.log` on rpi5-1. That directory also
holds `state.json`: last-deployed commit, file hashes, pending restarts, and
open alerts.

### Expected noise: Watchtower recreates

Watchtower (4am) recreates containers on new images but copies the old
container's labels, including a stale `com.docker.compose.image`. The next
`up -d` sees that mismatch and recreates the container once more, on the
same image. That's harmless (a few seconds of downtime, about 4:05am) and
shows up as `recreated <service>` in a low-priority deploy message.

## Setup (one-time, on rpi5-1)

Prerequisites, all already present: `sops` in `/usr/local/bin`, the age key
at `~/.config/sops/age/keys.txt`, `msmtp-mta` for cron mail, membership in
the `docker` group, and git fetch access to the repo without an agent (the
checkout's SSH remote already works from cron's bare environment).

```bash
cd ~/dev/homelab && git pull --ff-only
```

Preview what it would do. This doesn't pull, write, restart, or notify.

```bash
python3 ~/dev/homelab/scripts/compose-deploy/compose-deploy.py --dry-run
```

As of 2026-09-24, the dry run reports drift on three decrypted files:
`.env`, `homeassistant/secrets.yaml`, and `zwave-js-ui/settings.json`. That
was checked (values compared by hash, not printed), and the differences are
formatting only: blank lines, and SOPS's normalized YAML/JSON. Accept the
current copies as the baseline:

```bash
python3 ~/dev/homelab/scripts/compose-deploy/compose-deploy.py --adopt .env homeassistant/secrets.yaml zwave-js-ui/settings.json -v
```

That first real run also does a normal deploy. Expect it to recreate
`telegraf`, `unpoller`, and `network-optimizer-speedtest` (the Watchtower
label issue above), and nothing else.

Then add the cron entry (`crontab -e`; `MAILTO` is already set there):

```
*/5 * * * * /usr/bin/python3 /home/jakerobb/dev/homelab/scripts/compose-deploy/compose-deploy.py
```

Subscribe to `https://ntfy.jakerobb.org/homelab-alerts` if you haven't
already.

## Operating it

- **Pause auto-deploy:** comment out the cron line. Any uncommitted edit in
  `~/dev/homelab` also pauses it, with an alert.
- **Run now / watch a run:** `compose-deploy.py -v`. A lock prevents
  overlapping runs.
- **Retry failed restarts without a new merge:** `compose-deploy.py --retry`.
- **Drift alert on a file you want to keep as-is on the host:**
  `compose-deploy.py --adopt <path relative to ~/docker>`. It stays adopted
  until the repo's copy changes again, which then overwrites it as usual.
  Prefer backfilling into the repo; adopting just hides the difference.
- **`can't write` alerts for `zwave-js-ui/*`:** those files are root-owned
  (the container runs as root), so the script can't update them. Copy by
  hand with `sudo` using the README's decrypt command, then run
  `compose-deploy.py` to record the result.
