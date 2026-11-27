# Host deploy (Mac VM hosts)

A pull-based deploy loop for the Macs that run Talos VMs, modelled on [compose-deploy](compose-deploy.md) on rpi5-1.
Every 5 minutes a launchd job fast-forwards a dedicated clone of this repo to `origin/main`, writes any files the host
owns itself, and **alerts through ntfy when a root-owned install is out of date**, naming the installer to run. It never
has root, so it can't install those itself; the alert is the "something needs installing" signal.

Today it runs on the Mac Studio. The MacBook Pro is next (see [`../todo/READY.md`](../todo/READY.md)). Nothing in the
script or the launchd job is host-specific: the only per-host part is a manifest.

## What each run does

1. **Fast-forwards the deploy clone** (`~/.local/share/host-deploy/homelab`). If it has uncommitted changes, is on another
   branch or has diverged, the run stops and alerts rather than guess.
2. **Reads this host's manifest**, `scripts/host-deploy/manifests/<LocalHostName, lowercased>.json` (`scutil --get
   LocalHostName`; the Studio is `m5ultramacstudio`).
3. **Writes the manifest's `files`**: destinations the host user owns, such as scripts and config in the home directory. A
   file edited outside the repo since the last write is flagged as drift, not overwritten. The first set is empty.
4. **Checks the manifest's `installs`**: root-owned destinations (`/usr/local/sbin`, `/Library/LaunchDaemons`). A missing
   or stale one raises an alert like
   `/usr/local/sbin/talos-worker-studio-run is out of date with the repo … On m5ultramacstudio: cd <clone> &&
   ./scripts/studio-worker/install.sh (this restarts the VM: cordon and drain talos-worker-studio first)`. The alert fires
   once, and a "resolved" message follows when the installed copy matches. Files this user can't read (`/etc/sudoers.d`)
   are compared through a record of the installed repo file's sha256 that its installer writes in a readable place.
5. **Notifies** the `homelab-alerts` ntfy topic: problems at high priority, resolutions and file updates at low. Pulls
   alone aren't announced. Messages contain paths and host names only. Detail goes to
   `~/.local/state/host-deploy/deploy.log`, and launchd's own output to `launchd.log` there. If ntfy (which runs on the
   cluster) is unreachable, the message goes to `launchd.log`.

## Why a separate clone

The job pauses and alerts if its clone is dirty or off `main`. Your working copy is usually one or the other, so the job
gets its own at `~/.local/share/host-deploy/homelab`, cloned over HTTPS (the repo is public, so no credentials and no ssh
agent, which a daemon can't use). Installers run from either clone, but the alert names the deploy clone since it's always
current. Don't edit in it.

## Setup (one time per host)

On the Mac, as your normal user, from any checkout of the repo:

```bash
./scripts/host-deploy/install.sh
/usr/bin/python3 ~/.local/share/host-deploy/homelab/scripts/host-deploy/host-deploy.py -v --dry-run
```

`install.sh` clones the deploy checkout, installs the launchd job (a system LaunchDaemon that runs as your user, so it
starts at boot with no GUI session, which matters under FileVault) and starts it. Its first real run raises alerts for
anything in the manifest that isn't installed yet. The plist hard-codes `/Users/jakerobb`; change it for another account.

## The manifest

```json
{
  "files":    [{"src": "scripts/x/y.sh", "dest": "~/bin/y.sh", "mode": "755"}],
  "installs": [
    {"src": "scripts/x/run.sh", "dest": "/usr/local/sbin/run", "installer": "scripts/x/install.sh", "note": "optional text appended to the alert"},
    {"src": "scripts/x/rule.sudoers", "hash_file": "/usr/local/share/homelab/rule.sha256", "installer": "scripts/x/install.sh"}
  ]
}
```

`src` is repo-relative. A source missing from the repo is ignored. To add a host, add `manifests/<name>.json` and run
`install.sh` there. To put another file under management, add a line and merge: the next run picks it up.

## Heartbeat

If this job stopped (launchd job gone, host down, the script crashing on startup), nothing would alert, since it is also
what raises the other alerts. So each completed run pings a [Healthchecks.io](https://healthchecks.io) check, and a crash
pings its `/fail` URL. A paused deploy (dirty clone, missing manifest) still pings: that's alerted on ntfy, and the
heartbeat only means the job ran. `--dry-run` never pings.

The ping URL is a secret, so it lives on the host, not in the repo (the Mac has no SOPS key). Per host:

1. In Healthchecks.io create a check named `host-deploy <LocalHostName>` (e.g. `host-deploy m5ultramacstudio`), period 5
   minutes, grace 15 minutes, with the usual email integration.
2. On that Mac, as your normal user:

   ```bash
   mkdir -p ~/.config/host-deploy && chmod 700 ~/.config/host-deploy
   printf '%s\n' '<ping URL>' > ~/.config/host-deploy/heartbeat-url && chmod 600 ~/.config/host-deploy/heartbeat-url
   ```

Without the file there is no heartbeat and nothing else changes. The next run (within 5 minutes) sends the first ping.

## Operating it

- **Run now:** `/usr/bin/python3 ~/.local/share/host-deploy/homelab/scripts/host-deploy/host-deploy.py -v` (`--dry-run`
  changes nothing).
- **Pause:** `sudo launchctl bootout system/com.jakerobb.host-deploy`; resume with `install.sh`.
- **Heartbeat:** see [Heartbeat](#heartbeat).
- **Alert after a restart-the-VM install:** drain the node first (the alert says so), then run the installer it names.
  `studio-worker/install.sh` leaves the VM alone when nothing it installs has changed.
