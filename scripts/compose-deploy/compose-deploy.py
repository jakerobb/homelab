#!/usr/bin/env python3
"""Pull-based GitOps reconciler for the rpi5-1 Docker Compose stack.

Runs from cron on rpi5-1, straight out of the ~/dev/homelab checkout (so a
merged change to this script deploys itself on the next run). Each run:

  1. Fast-forwards the checkout to origin/main (refuses if it has local edits).
  2. Validates the compose file.
  3. Brings the non-symlinked copies and SOPS-decrypted files in ~/docker up
     to date with the repo — but never overwrites a file that was changed
     outside the repo since this script last wrote it (drift: alert instead).
  4. `docker compose up -d --remove-orphans` (also self-heals anything that
     was stopped or edited by hand).
  5. Restarts services whose bind-mounted config changed but that `up -d`
     didn't recreate (it only looks at the compose file, not mount contents),
     validating Caddy/Home Assistant config first.
  6. Reports deploys and problems to ntfy; mails via cron (stderr) if ntfy
     itself is unreachable or the script crashes.

See docs/compose-deploy.md for setup and operation.
"""
import argparse
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HOME = Path.home()
REPO = HOME / "dev" / "homelab"
BRANCH = "main"
SRC = REPO / "docker-compose"
DEPLOY = HOME / "docker"
STATE_DIR = HOME / ".local" / "state" / "compose-deploy"
STATE_FILE = STATE_DIR / "state.json"
LOG_FILE = STATE_DIR / "deploy.log"
LOG_MAX_BYTES = 1_000_000
# Unauthenticated topic — keep messages to paths/service names, never file
# contents or command output (which could carry secrets).
NTFY_URL = "https://ntfy.jakerobb.org/homelab-alerts"

# Deploy-relative destination -> (SRC-relative SOPS source, extra sops args).
# Mirrors the decrypt commands in docker-compose/README.md.
DECRYPTED = {
    ".env": (".env.sops.env", ["--input-type", "dotenv", "--output-type", "dotenv"]),
    "homeassistant/secrets.yaml": ("homeassistant/secrets.sops.yaml", []),
    "homeassistant/lutron_caseta-0512b4cc-key.pem": (
        "homeassistant/lutron_caseta-0512b4cc-key.pem.sops.yaml", ["--output-type", "binary"]),
    "secrets/nut-upsd-password": ("secrets/nut-upsd-password.sops.yaml", ["--output-type", "binary"]),
    "influxdb/config/influx-configs": (
        "influxdb/config/influx-configs.sops.yaml", ["--output-type", "binary"]),
    "zigbee2mqtt/data/configuration.yaml": ("zigbee2mqtt/configuration.sops.yaml", []),
    "zwave-js-ui/settings.json": ("zwave-js-ui/settings.sops.json", []),
    "zwave-js-ui/users.json": ("zwave-js-ui/users.json.sops.yaml", ["--output-type", "binary"]),
    "change-detection/secret.txt": ("change-detection/secret.txt.sops.yaml", ["--output-type", "binary"]),
}

# Services that rewrite their own config files at runtime/shutdown: stop them
# before writing, or they'd clobber the new file on the way down.
STOP_BEFORE_WRITE = {"change-detection", "zigbee2mqtt", "zwave-js-ui"}

# Config checks run before restarting a service; on failure the running
# container keeps its old config and we alert instead of restarting into a
# broken one.
VALIDATORS = {
    "caddy": ["run", "--rm", "--no-deps", "-T", "--entrypoint", "caddy", "caddy",
              "validate", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"],
    "homeassistant": ["exec", "-T", "homeassistant", "python", "-m", "homeassistant",
                      "--script", "check_config", "--config", "/config"],
}

args = None


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    if args.verbose or args.dry_run:
        print(line)
    try:
        if LOG_FILE.exists() and LOG_FILE.stat().st_size > LOG_MAX_BYTES:
            LOG_FILE.replace(LOG_FILE.with_suffix(".log.1"))
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError as e:
        print(f"compose-deploy: can't write log: {e}", file=sys.stderr)


def run(cmd, cwd=None, timeout=300, stdin=None):
    """Runs a command, logging (locally only) the output of failures."""
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=timeout, stdin=stdin)
    except subprocess.TimeoutExpired:
        log(f"TIMEOUT after {timeout}s: {' '.join(map(str, cmd))}")
        return subprocess.CompletedProcess(cmd, 124, b"", b"timed out")
    if p.returncode != 0:
        log(f"FAILED ({p.returncode}): {' '.join(map(str, cmd))}\n"
            + p.stdout.decode(errors="replace")[-4000:]
            + p.stderr.decode(errors="replace")[-4000:])
    return p


def git(*a, **kw):
    return run(["git", *a], cwd=REPO, **kw)


def compose(*a, **kw):
    return run(["docker", "compose", *a], cwd=DEPLOY, **kw)


def sha(data):
    return hashlib.sha256(data).hexdigest() if data is not None else None


def read(path):
    try:
        return path.read_bytes()
    except FileNotFoundError:
        return None


def is_linked(rel):
    """True if ~/docker/<rel> is (or sits under) a symlink into the checkout."""
    d = DEPLOY / rel
    return d.exists() and d.resolve() == (SRC / rel).resolve()


def services_for(paths, mounts):
    """Services with a bind mount at, or containing, any of the given paths."""
    return {svc for svc, sources in mounts.items()
            for s in sources for p in paths if p == s or s in p.parents}


def notify(title, message, priority, tags):
    req = urllib.request.Request(
        NTFY_URL, data=message.encode(), method="POST",
        headers={"Title": title, "Priority": str(priority), "Tags": tags})
    try:
        urllib.request.urlopen(req, timeout=15).close()
    except OSError as e:
        # stderr -> cron mail, so a problem still gets out when ntfy (which
        # lives on the cluster) is down.
        print(f"compose-deploy: ntfy unreachable ({e}); undelivered notification:\n"
              f"{title}\n{message}", file=sys.stderr)


class Deploy:
    def __init__(self, state):
        self.state = state
        self.files = state.setdefault("files", {})      # dest -> {"src": sha, "dest": sha}
        self.pending = state.setdefault("pending", {})  # service -> failure message
        self.alerted = state.setdefault("alerted", {})  # problem key -> message
        self.problems = {}
        self.actions = []

    def problem(self, key, msg):
        log(f"PROBLEM [{key}] {msg}")
        self.problems[key] = msg

    def action(self, msg):
        log(msg)
        self.actions.append(msg)

    # --- 1. checkout --------------------------------------------------------

    def update_checkout(self):
        """Returns (old_head, new_head), or None if the deploy can't proceed."""
        branch = git("branch", "--show-current").stdout.decode().strip()
        if branch != BRANCH:
            self.problem("checkout", f"~/dev/homelab on rpi5-1 is on branch '{branch}', not "
                                     f"'{BRANCH}'; auto-deploy paused until it's switched back.")
            return None
        dirty = git("status", "--porcelain", "--untracked-files=no").stdout.decode().strip()
        if dirty:
            self.problem("checkout", "~/dev/homelab on rpi5-1 has uncommitted changes "
                                     f"({len(dirty.splitlines())} files); auto-deploy paused. "
                                     "Commit them via a PR or discard them.")
            return None
        if git("fetch", "--quiet", "origin", BRANCH, timeout=60).returncode != 0:
            self.problem("fetch", "git fetch failed on rpi5-1; deploying what's already checked out.")
        head = git("rev-parse", "HEAD").stdout.decode().strip()
        old = self.state.get("head") or head
        behind = git("rev-list", "--count", f"HEAD..origin/{BRANCH}").stdout.decode().strip()
        if behind not in ("", "0"):
            if args.dry_run:
                log(f"would pull {behind} commit(s) (dry run: working from current checkout)")
            elif git("merge", "--ff-only", "--quiet", f"origin/{BRANCH}").returncode != 0:
                self.problem("checkout", "~/dev/homelab on rpi5-1 can't fast-forward to "
                                         f"origin/{BRANCH} (diverged?); auto-deploy paused.")
                return None
            head = git("rev-parse", "HEAD").stdout.decode().strip()
        if head != old:
            self.action(f"pulled {old[:7]}..{head[:7]}")
        return old, head

    def changed_since(self, old, new):
        if old == new:
            return []
        p = git("diff", "--name-only", "--no-renames", old, new, "--", "docker-compose/")
        if p.returncode != 0:  # old commit unknown (history rewritten?) — treat all as changed
            p = git("ls-files", "docker-compose/")
        return [line.removeprefix("docker-compose/") for line in p.stdout.decode().splitlines()]

    # --- 3. managed files ---------------------------------------------------

    def managed_entries(self):
        """dest -> (source path, render function) for every file we copy/decrypt."""
        entries = {}
        tracked = git("ls-files", "-z", "docker-compose/").stdout.decode().split("\0")
        for path in filter(None, tracked):
            rel = path.removeprefix("docker-compose/")
            if rel != "README.md" and ".sops." not in rel and not is_linked(rel):
                entries[rel] = (SRC / rel, lambda src=SRC / rel: src.read_bytes())
        for dest, (src, sops_args) in DECRYPTED.items():
            entries[dest] = (SRC / src, lambda src=SRC / src, a=sops_args: self.decrypt(src, a))
        return entries

    def decrypt(self, src, sops_args):
        p = run(["sops", "--decrypt", *sops_args, str(src)], timeout=60)
        if p.returncode != 0:
            raise RuntimeError(f"sops couldn't decrypt {src.relative_to(REPO)}")
        return p.stdout

    def plan_files(self):
        """Returns [(dest, content, src_sha)] to write; records/flags the rest."""
        writes = []
        entries = self.managed_entries()
        for gone in set(self.files) - set(entries):
            del self.files[gone]
        for dest, (src, render) in sorted(entries.items()):
            try:
                src_sha, dest_sha = sha(src.read_bytes()), sha(read(DEPLOY / dest))
            except OSError as e:
                self.problem(f"file:{dest}", f"can't read ~/docker/{dest}: {e.strerror}")
                continue
            rec = self.files.get(dest)
            if rec == {"src": src_sha, "dest": dest_sha}:
                continue
            try:
                content = render()
            except (OSError, RuntimeError) as e:
                self.problem(f"file:{dest}", str(e))
                continue
            if dest_sha == sha(content):
                self.files[dest] = {"src": src_sha, "dest": dest_sha}
            elif dest_sha is None or (rec and rec["dest"] == dest_sha):
                writes.append((dest, content, src_sha))
            elif args.adopt is not None and (not args.adopt or dest in args.adopt):
                # Recording the current source means the next repo change to
                # this file overwrites the adopted copy as usual.
                self.files[dest] = {"src": src_sha, "dest": dest_sha}
                self.action(f"adopted ~/docker/{dest} as-is")
            else:
                self.problem(f"drift:{dest}",
                             f"~/docker/{dest} differs from the repo and wasn't written by "
                             "auto-deploy (edited on the host, or by the app itself). Backfill "
                             f"it into docker-compose/{src.relative_to(SRC)} or revert it, or "
                             f"accept it with: compose-deploy.py --adopt {dest}")
        return writes

    def write(self, dest, content, src_sha):
        path = DEPLOY / dest
        try:
            if path.exists():
                # In place, keeping the inode (single-file bind mounts keep
                # tracking it) and existing owner/permissions.
                with open(path, "r+b") as f:
                    f.write(content)
                    f.truncate()
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with open(path, "wb", opener=lambda p, fl: os.open(p, fl, 0o600)) as f:
                    f.write(content)
        except OSError as e:
            self.problem(f"file:{dest}", f"can't write ~/docker/{dest}: {e.strerror} — copy it "
                                         "by hand (see docker-compose/README.md)")
            return False
        self.files[dest] = {"src": src_sha, "dest": sha(content)}
        self.action(f"updated ~/docker/{dest}")
        return True

    # --- main flow ----------------------------------------------------------

    def container_ids(self):
        p = compose("ps", "-a", "--format", "json")
        ids = {}
        for line in p.stdout.decode().splitlines():  # one JSON object per line
            c = json.loads(line)
            ids[c["Service"]] = c["ID"]
        return ids

    def run(self):
        heads = self.update_checkout()
        if not heads:
            return
        old, new = heads
        changed = self.changed_since(old, new)

        p = compose("config", "--format", "json")
        if p.returncode != 0:
            self.problem("compose-config", "docker-compose.yml doesn't validate on rpi5-1 "
                                           "(`docker compose config`); nothing deployed.")
            return
        mounts = {svc: [Path(v["source"]) for v in spec.get("volumes", []) if v["type"] == "bind"]
                  for svc, spec in json.loads(p.stdout)["services"].items()}

        writes = self.plan_files()
        # Files that changed through the symlinks just by pulling (plus
        # deletions); copies are covered by `writes` instead.
        pulled = [DEPLOY / rel for rel in changed if is_linked(rel) or not (DEPLOY / rel).exists()]

        if args.dry_run:
            for dest, _, _ in writes:
                log(f"would update ~/docker/{dest}")
            touched = pulled + [DEPLOY / d for d, _, _ in writes]
            log(f"would restart (if not recreated): {sorted(services_for(touched, mounts)) or 'none'}")
            for line in compose("up", "-d", "--remove-orphans", "--dry-run").stderr.decode().splitlines():
                if any(w in line for w in ("Recreate ", "Create ", "Remov")):
                    log(f"compose:{line}")
            self.state["head"] = old  # dry run never advances
            return

        stopped = services_for([DEPLOY / d for d, _, _ in writes], mounts) & STOP_BEFORE_WRITE
        if stopped:
            compose("stop", *sorted(stopped))
        written = [DEPLOY / d for d, c, s in writes if self.write(d, c, s)]

        before = self.container_ids()
        if compose("up", "-d", "--remove-orphans").returncode != 0:
            self.problem("compose-up", "`docker compose up -d` failed on rpi5-1; see "
                                       "~/.local/state/compose-deploy/deploy.log")
        after = self.container_ids()
        fresh = {s for s in after if before.get(s) != after[s]} | stopped
        for s in sorted(fresh - stopped):
            self.action(f"recreated {s}")
        for s in sorted(stopped):
            self.action(f"stopped, updated, and started {s}")

        restart = services_for(pulled + written, mounts)
        if new != old or args.retry:
            restart |= set(self.pending)
        for svc in sorted(restart - fresh):
            self.restart(svc)
        self.pending = {s: m for s, m in self.pending.items() if s not in fresh}
        self.state["pending"] = self.pending
        for svc, msg in self.pending.items():
            self.problems.setdefault(f"restart:{svc}", msg)
        self.state["head"] = new

    def restart(self, svc):
        validator = VALIDATORS.get(svc)
        if validator and compose(*validator, timeout=600).returncode != 0:
            self.pending[svc] = (f"{svc}'s new config failed validation; NOT restarted, it's still "
                                 "running the old config (but will load the broken one on its next "
                                 "restart). Fix in the repo; retried on the next merge.")
            self.problem(f"restart:{svc}", self.pending[svc])
            return
        if compose("restart", svc, timeout=600).returncode != 0:
            self.pending[svc] = f"`docker compose restart {svc}` failed; retried on the next merge."
            self.problem(f"restart:{svc}", self.pending[svc])
            return
        self.pending.pop(svc, None)
        self.action(f"restarted {svc} (config changed)")

    def report(self):
        for key, msg in self.problems.items():
            if self.alerted.get(key) != msg:
                notify(f"rpi5-1 compose deploy: {key}", msg, 4, "warning")
                self.alerted[key] = msg
        for key in set(self.alerted) - set(self.problems):
            notify(f"rpi5-1 compose deploy: resolved {key}", self.alerted.pop(key), 2, "white_check_mark")
        if self.actions:
            head = self.state.get("head", "")[:7]
            notify(f"rpi5-1 compose deploy @ {head}", "\n".join(self.actions), 2, "whale")


def main():
    global args
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true",
                    help="show what would change; don't pull, write, notify, or touch containers")
    ap.add_argument("--adopt", nargs="*", metavar="DEST",
                    help="accept the current ~/docker copy of these files (all drifted files if "
                         "none given) as deployed, e.g. after a formatting-only difference")
    ap.add_argument("--retry", action="store_true",
                    help="retry failed restarts now instead of waiting for the next merge")
    ap.add_argument("-v", "--verbose", action="store_true", help="also log to stdout")
    args = ap.parse_args()

    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = open(STATE_DIR / "lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return  # previous run still going (e.g. a slow HA config check)

    state = json.loads(STATE_FILE.read_text()) if STATE_FILE.exists() else {}
    d = Deploy(state)
    d.run()
    if args.dry_run:
        return
    # Problems not re-evaluated this run (e.g. checkout paused before the
    # file checks) stay alerted rather than being reported as resolved.
    if "checkout" in d.problems or "compose-config" in d.problems:
        for key, msg in d.alerted.items():
            d.problems.setdefault(key, msg)
    d.report()
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True))
    tmp.replace(STATE_FILE)


if __name__ == "__main__":
    main()
