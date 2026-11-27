#!/usr/bin/env python3
"""Pull-based deploy for hosts that aren't the rpi5-1 jump box (the Mac VM hosts).

Runs from launchd (every 5 minutes) out of a dedicated clone of the repo, so a merged change to this script deploys
itself on the next run. Each run:

  1. Fast-forwards the clone to origin/main (refuses if it has local edits or is on another branch).
  2. Reads this host's manifest, scripts/host-deploy/manifests/<LocalHostName, lowercased>.json.
  3. Writes the manifest's "files" (user-owned destinations) when the repo copy changed, but never over a file that
     was edited outside the repo since this script last wrote it (drift: alert instead).
  4. Compares the manifest's "installs" (root-owned destinations this script can't, and shouldn't, write) with the
     repo and alerts, naming the installer to run, when one is missing or stale. The alert clears itself.
  5. Reports problems and file updates to ntfy; stderr (which launchd logs) if ntfy itself is unreachable.

The manifest is the only per-host part. See docs/host-deploy.md. The structure mirrors compose-deploy.py on rpi5-1.
"""
import argparse
import fcntl
import hashlib
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HOME = Path.home()
DEFAULT_CHECKOUT = HOME / ".local" / "share" / "host-deploy" / "homelab"
BRANCH = "main"
STATE_DIR = HOME / ".local" / "state" / "host-deploy"
STATE_FILE = STATE_DIR / "state.json"
LOG_FILE = STATE_DIR / "deploy.log"
LOG_MAX_BYTES = 1_000_000
NTFY_URL = os.environ.get("HOST_DEPLOY_NTFY_URL", "https://ntfy.jakerobb.org/homelab-alerts")  # override: tests

args = None
REPO = DEFAULT_CHECKOUT
HOST = ""


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
        print(f"host-deploy: can't write log: {e}", file=sys.stderr)


def run(cmd, cwd=None, timeout=300):
    """Runs a command, logging (locally only) the output of failures."""
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        log(f"TIMEOUT after {timeout}s: {' '.join(map(str, cmd))}")
        return subprocess.CompletedProcess(cmd, 124, b"", b"timed out")
    if p.returncode != 0:
        log(f"FAILED ({p.returncode}): {' '.join(map(str, cmd))}\n"
            + p.stdout.decode(errors="replace")[-4000:] + p.stderr.decode(errors="replace")[-4000:])
    return p


def git(*a, **kw):
    return run(["git", *a], cwd=REPO, **kw)


def sha(data):
    return hashlib.sha256(data).hexdigest() if data is not None else None


def read(path):
    try:
        return Path(path).read_bytes()
    except FileNotFoundError:
        return None


def local_host_name():
    p = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True)
    name = p.stdout.decode().strip() if p.returncode == 0 else ""
    return (name or socket.gethostname().split(".")[0]).lower()


def notify(title, message, priority, tags):
    req = urllib.request.Request(NTFY_URL, data=message.encode(), method="POST",
                                 headers={"Title": title, "Priority": str(priority), "Tags": tags})
    try:
        urllib.request.urlopen(req, timeout=15).close()
    except OSError as e:
        # stderr -> launchd's log, so a problem still gets out when ntfy (which lives on the cluster) is down.
        print(f"host-deploy: ntfy unreachable ({e}); undelivered notification:\n{title}\n{message}", file=sys.stderr)


class Deploy:
    def __init__(self, state):
        self.state = state
        self.files = state.setdefault("files", {})      # dest -> {"src": sha, "dest": sha}
        self.alerted = state.setdefault("alerted", {})  # problem key -> message
        self.problems = {}
        self.actions = []

    def problem(self, key, msg):
        log(f"PROBLEM [{key}] {msg}")
        self.problems[key] = msg

    def action(self, msg):
        log(msg)
        self.actions.append(msg)

    def update_checkout(self):
        """Returns False if the deploy can't proceed."""
        if not (REPO / ".git").exists():
            self.problem("checkout", f"{REPO} isn't a git clone on {HOST}; see docs/host-deploy.md to set it up.")
            return False
        branch = git("branch", "--show-current").stdout.decode().strip()
        if branch != BRANCH:
            self.problem("checkout", f"{REPO} on {HOST} is on branch '{branch}', not '{BRANCH}'; "
                                     "auto-deploy paused until it's switched back.")
            return False
        dirty = git("status", "--porcelain", "--untracked-files=no").stdout.decode().strip()
        if dirty:
            self.problem("checkout", f"{REPO} on {HOST} has uncommitted changes "
                                     f"({len(dirty.splitlines())} files); auto-deploy paused. "
                                     "This clone is for the deploy job only: discard them.")
            return False
        if git("fetch", "--quiet", "origin", BRANCH, timeout=60).returncode != 0:
            self.problem("fetch", f"git fetch failed on {HOST}; deploying what's already checked out.")
        behind = git("rev-list", "--count", f"HEAD..origin/{BRANCH}").stdout.decode().strip()
        if behind not in ("", "0"):
            old = git("rev-parse", "--short", "HEAD").stdout.decode().strip()
            if args.dry_run:
                log(f"would pull {behind} commit(s) (dry run: working from the current checkout)")
            elif git("merge", "--ff-only", "--quiet", f"origin/{BRANCH}").returncode != 0:
                self.problem("checkout", f"{REPO} on {HOST} can't fast-forward to origin/{BRANCH} "
                                         "(diverged?); auto-deploy paused.")
                return False
            else:
                log(f"pulled {old}..{git('rev-parse', '--short', 'HEAD').stdout.decode().strip()}")
        return True

    def load_manifest(self):
        path = Path(args.manifest) if args.manifest else REPO / "scripts" / "host-deploy" / "manifests" / f"{HOST}.json"
        if not path.exists():
            self.problem("manifest", f"no manifest for host '{HOST}' (expected {path} in the repo); "
                                     "nothing deployed or checked.")
            return None
        try:
            return json.loads(path.read_text())
        except ValueError as e:
            self.problem("manifest", f"{path} isn't valid JSON ({e}); nothing deployed or checked.")
            return None

    def deploy_files(self, entries):
        for e in entries:
            src, dest = REPO / e["src"], Path(e["dest"]).expanduser()
            mode = int(str(e.get("mode", "644")), 8)
            wanted = read(src)
            if wanted is None:
                continue  # a file missing from the repo is ignored
            have = read(dest)
            rec = self.files.get(str(dest))
            if have == wanted:
                self.files[str(dest)] = {"src": sha(wanted), "dest": sha(have)}
                continue
            if have is not None and (rec is None or rec["dest"] != sha(have)):
                self.problem(f"drift:{dest}", f"{dest} differs from the repo and wasn't written by auto-deploy "
                                              f"(edited on {HOST}?). Revert it or delete it to let auto-deploy "
                                              f"rewrite it from {e['src']}.")
                continue
            if args.dry_run:
                log(f"would update {dest}")
                continue
            try:
                dest.parent.mkdir(parents=True, exist_ok=True)
                tmp = dest.with_name(f".{dest.name}.host-deploy")
                with open(tmp, "wb", opener=lambda p, fl: os.open(p, fl, mode)) as f:
                    f.write(wanted)
                os.chmod(tmp, mode)
                tmp.replace(dest)  # a process running the old copy keeps its inode
            except OSError as ex:
                self.problem(f"file:{dest}", f"can't write {dest}: {ex.strerror}")
                continue
            self.files[str(dest)] = {"src": sha(wanted), "dest": sha(wanted)}
            self.action(f"updated {dest}")
        wanted_dests = {str(Path(e["dest"]).expanduser()) for e in entries}
        for gone in set(self.files) - wanted_dests:
            del self.files[gone]

    def check_installs(self, entries):
        """One problem per installed file that needs a manual (root) install."""
        def install_problem(key, what, why, e):
            note = f" ({e['note']})" if e.get("note") else ""
            self.problem(f"install:{key}", f"{what} {why}, and auto-deploy can't write root-owned files. "
                                           f"On {HOST}: cd {REPO} && ./{e['installer']}{note}")

        for e in entries:
            wanted = read(REPO / e["src"])
            if wanted is None:
                continue
            if "dest" in e:
                dest = e["dest"]
                try:
                    installed = Path(dest).read_bytes()
                except FileNotFoundError:
                    install_problem(dest, dest, "is missing", e)
                except OSError as ex:
                    install_problem(dest, dest, f"can't be read ({ex.strerror})", e)
                else:
                    if installed != wanted:
                        install_problem(dest, dest, "is out of date with the repo", e)
            else:
                # Files this user can't read (sudoers.d, mode 0440): the installer records the sha256 of the repo
                # file it installed, in a readable place, and we compare that.
                hash_file = e["hash_file"]
                try:
                    recorded = Path(hash_file).read_text().split()[:1]
                except FileNotFoundError:
                    install_problem(hash_file, e["src"], f"has no install record ({hash_file} is missing)", e)
                    continue
                except OSError as ex:
                    install_problem(hash_file, hash_file, f"can't be read ({ex.strerror})", e)
                    continue
                if recorded != [sha(wanted)]:
                    install_problem(hash_file, e["src"], "changed since the last install", e)

    def run(self):
        if not self.update_checkout():
            return
        manifest = self.load_manifest()
        if manifest is None:
            return
        self.deploy_files(manifest.get("files", []))
        self.check_installs(manifest.get("installs", []))
        self.state["head"] = git("rev-parse", "HEAD").stdout.decode().strip()

    def report(self):
        for key, msg in self.problems.items():
            if self.alerted.get(key) != msg:
                notify(f"{HOST} host-deploy: {key}", msg, 4, "warning")
                self.alerted[key] = msg
        for key in set(self.alerted) - set(self.problems):
            notify(f"{HOST} host-deploy: resolved {key}", self.alerted.pop(key), 2, "white_check_mark")
        if self.actions:
            notify(f"{HOST} host-deploy @ {self.state.get('head', '')[:7]}", "\n".join(self.actions), 2, "package")


def main():
    global args, REPO, HOST
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--checkout", default=str(DEFAULT_CHECKOUT), help="the deploy clone (default: %(default)s)")
    ap.add_argument("--manifest", help="manifest path (default: manifests/<LocalHostName>.json in the clone)")
    ap.add_argument("--host", help="host name for manifest lookup and messages (default: LocalHostName, lowercased)")
    ap.add_argument("--dry-run", action="store_true", help="show what would change; don't pull, write or notify")
    ap.add_argument("-v", "--verbose", action="store_true", help="also log to stdout")
    args = ap.parse_args()
    REPO = Path(args.checkout).expanduser()
    HOST = args.host or local_host_name()

    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = open(STATE_DIR / "lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return  # previous run still going

    state = json.loads(STATE_FILE.read_text()) if STATE_FILE.exists() else {}
    d = Deploy(state)
    d.run()
    if args.dry_run:
        return
    # Problems not re-evaluated this run (checkout or manifest unusable) stay alerted, not "resolved".
    if "checkout" in d.problems or "manifest" in d.problems:
        for key, msg in d.alerted.items():
            d.problems.setdefault(key, msg)
    d.report()
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True))
    tmp.replace(STATE_FILE)


if __name__ == "__main__":
    main()
