#!/usr/bin/env python3
"""Compare two renders from scripts/ci/render-manifests.py (the base branch and
the PR) and report what ArgoCD would change on the next sync. Informational:
it never fails a build over a difference, only over a bug in itself.

Resources are matched by (API group, kind, namespace, name), whichever file
they came from. The report has four sections:

- Removed: gone from the render, so ArgoCD prunes them from the cluster
  (every Application here has prune: true).
- Immutable fields: a field the API server refuses to change in place
  (a workload's selector, volumeClaimTemplates, a Service's clusterIP, ...).
  The sync will fail, or the resource needs deleting first.
- Added.
- Changed: field-by-field, old -> new. Labels and annotations that churn on every
  chart bump (helm.sh/chart, app.kubernetes.io/version, checksum/*) are ignored.
  Secret values are never printed, and a change to only a Secret's values is
  ignored (some charts generate them at render time); added/removed keys show.

The markdown goes to --out and, if set, $GITHUB_STEP_SUMMARY. With --comment it
is also posted to the PR as one sticky comment, updated in place on later runs.
That needs a token allowed to write PR comments; a fork PR's read-only token
gets a warning, not a failure. No differences and no earlier comment: no comment.

Usage: scripts/ci/diff-rendered.py BASE_DIR HEAD_DIR [--out FILE] [--comment]
Needs: PyYAML. --comment needs GITHUB_TOKEN, GITHUB_REPOSITORY and GITHUB_EVENT_PATH.
"""

import argparse
import difflib
import json
import os
import re
import sys
from collections import Counter
import urllib.error
import urllib.request
from pathlib import Path

import yaml

MARKER = "<!-- render-diff -->"
COMMENT_LIMIT = 60000  # GitHub's cap is 65536 characters
MAX_VALUE = 140
MAX_DIFF_LINES = 25
MAX_LIST_ITEMS = 6
MAX_RESOURCE_LINES = 60

# Paths whose changes are noise: every chart bump touches them.
NOISE = re.compile(
    r"\.labels\.(helm\.sh/chart|chart|release|heritage|app\.kubernetes\.io/version)$"
    r"|\.annotations\.(checksum/|actions\.github\.com/values-hash$)"
    r"|\.caBundle$"
)

# (kind, path regex) pairs the API server won't change in place. Paths use the
# flattened form from flatten(): dotted, lists keyed by `[name=...]` or `[i]`.
IMMUTABLE = [
    ({"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet"}, r"^spec\.selector\b", "selector"),
    ({"StatefulSet"}, r"^spec\.volumeClaimTemplates\b", "volumeClaimTemplates"),
    ({"StatefulSet"}, r"^spec\.serviceName$", "serviceName"),
    ({"Service"}, r"^spec\.clusterIP$", "clusterIP"),
    ({"Job"}, r"^spec\.(selector|template)\b", "spec.template/selector"),
    ({"PersistentVolumeClaim"}, r"^spec\.(storageClassName|accessModes|volumeName|volumeMode)\b", "PVC spec"),
    ({"CustomResourceDefinition"}, r"^spec\.(group|scope|names\.kind)\b", "CRD group/scope/kind"),
]
IMMUTABLE = [(kinds, re.compile(p), label) for kinds, p, label in IMMUTABLE]


def ident(doc: dict) -> tuple[str, str, str, str] | None:
    meta = doc.get("metadata") or {}
    name = meta.get("name")
    if not isinstance(name, str) or not doc.get("kind"):
        return None
    group = str(doc.get("apiVersion", "")).rpartition("/")[0]
    return group, doc["kind"], str(meta.get("namespace", "")), name


def load(directory: Path) -> dict[tuple, dict]:
    resources: dict[tuple, dict] = {}
    for f in sorted(directory.glob("*.y*ml")):
        for doc in yaml.safe_load_all(f.read_text()):
            if isinstance(doc, dict) and (key := ident(doc)):
                resources[key] = doc
    return resources


def flatten(node, path: str = "", out: dict | None = None) -> dict[str, object]:
    """Dotted path -> leaf value. Lists whose items all carry a `name` (containers,
    env, volumes) are keyed by it, so an insertion doesn't shift every later
    path; other lists stay whole and are compared as sets of items (RBAC rules,
    args, tolerations), see list_changes()."""
    out = {} if out is None else out
    if isinstance(node, dict):
        if not node and path:
            out[path] = {}
        for k, v in node.items():
            flatten(v, f"{path}.{k}" if path else str(k), out)
    elif isinstance(node, list) and node and all(isinstance(i, dict) and "name" in i for i in node):
        for item in node:
            flatten(item, f"{path}[name={item['name']}]", out)
    else:
        out[path] = node
    return out


def short(value) -> str:
    text = value if isinstance(value, str) else json.dumps(value, sort_keys=True)
    return f"`{text if len(text) <= MAX_VALUE else text[:MAX_VALUE] + '…'}`"


def string_change(path: str, old: str, new: str) -> list[str]:
    """One changed string: inline when short, a diff for multi-line text, and the
    differing middle (with a little context) for one long line."""
    if len(old.splitlines()) > 1 or len(new.splitlines()) > 1:
        diff = [l for l in difflib.unified_diff(old.splitlines(), new.splitlines(), lineterm="", n=1)
                if not l.startswith(("---", "+++"))]
        added = sum(l.startswith("+") for l in diff)
        removed = sum(l.startswith("-") for l in diff)
        shown = [l if len(l) <= MAX_VALUE else l[:MAX_VALUE] + "…" for l in diff[:MAX_DIFF_LINES]]
        more = f"\n… {len(diff) - MAX_DIFF_LINES} more diff lines" if len(diff) > MAX_DIFF_LINES else ""
        return [f"- `{path}`: +{added}/−{removed} lines", "```diff", "\n".join(shown) + more, "```"]
    old, new = old.rstrip("\n"), new.rstrip("\n")  # a lone line with a trailing newline
    if len(old) <= MAX_VALUE and len(new) <= MAX_VALUE:
        return [f"- `{path}`: {short(old)} → {short(new)}"]
    p = len(os.path.commonprefix([old, new]))
    q = len(os.path.commonprefix([old[p:][::-1], new[p:][::-1]]))
    ctx = 24
    lo = max(0, p - ctx)
    def middle(v: str) -> str:
        return ("…" if lo else "") + v[lo:len(v) - q + ctx] + ("…" if q > ctx else "")
    return [f"- `{path}`: `{middle(old)}` → `{middle(new)}`"]


def list_changes(path: str, old: list, new: list) -> list[str]:
    """A list compared as a multiset of items; order alone only matters (and is
    reported) for scalar lists such as args and command."""
    dump = lambda i: json.dumps(i, sort_keys=True)  # noqa: E731
    a, b = Counter(map(dump, old)), Counter(map(dump, new))
    gone, came = list((a - b).elements()), list((b - a).elements())
    if not gone and not came:
        return [f"- `{path}`: reordered"] if all(not isinstance(i, (dict, list)) for i in old) else []
    lines = []
    for verb, items in (("removed", gone), ("added", came)):
        for item in items[:MAX_LIST_ITEMS]:
            lines.append(f"- `{path}`: {verb} {short(json.loads(item))}")
        if len(items) > MAX_LIST_ITEMS:
            lines.append(f"- `{path}`: …and {len(items) - MAX_LIST_ITEMS} more {verb}")
    return lines


def field_changes(kind: str, old: dict, new: dict) -> list[str]:
    """Markdown lines (bullets, and diff blocks after them) for one resource."""
    a, b = flatten(old), flatten(new)
    secret = kind == "Secret"
    lines = []
    for path in sorted(a.keys() | b.keys()):
        in_a, in_b = path in a, path in b
        if NOISE.search(path) or (in_a and in_b and a[path] == b[path]):
            continue
        if secret and path.split(".")[0] in ("data", "stringData"):
            if not (in_a and in_b):  # same key with a new value stays hidden
                lines.append(f"- `{path}`: {'removed' if in_a else 'added'}")
        elif not in_a:
            lines.append(f"- `{path}`: added {short(b[path])}")
        elif not in_b:
            lines.append(f"- `{path}`: removed (was {short(a[path])})")
        elif isinstance(a[path], list) and isinstance(b[path], list):
            lines += list_changes(path, a[path], b[path])
        elif isinstance(a[path], str) and isinstance(b[path], str):
            lines += string_change(path, a[path], b[path])
        else:
            lines.append(f"- `{path}`: {short(a[path])} → {short(b[path])}")
    return lines


def immutable_hits(kind: str, old: dict, new: dict) -> list[str]:
    annotations = (new.get("metadata") or {}).get("annotations") or {}
    if any("hook" in k for k in annotations):
        return []  # Helm/ArgoCD hooks are recreated on every sync, so nothing is in place to conflict
    a, b = flatten(old), flatten(new)
    hits = []
    for kinds, pattern, label in IMMUTABLE:
        if kind not in kinds:
            continue
        if any(pattern.search(p) and a.get(p) != b.get(p) for p in a.keys() | b.keys()):
            hits.append(label)
    return hits


def name_of(key: tuple) -> str:
    group, kind, ns, name = key
    return f"{kind}{'.' + group if group else ''} `{ns + '/' if ns else ''}{name}`"


def report(base: dict, head: dict) -> tuple[str, int]:
    removed = sorted(base.keys() - head.keys())
    added = sorted(head.keys() - base.keys())
    changed = []  # (key, lines, immutable labels)
    for key in sorted(base.keys() & head.keys()):
        if base[key] == head[key]:
            continue
        lines = field_changes(key[1], base[key], head[key])
        if lines:
            changed.append((key, lines, immutable_hits(key[1], base[key], head[key])))

    total = len(removed) + len(added) + len(changed)
    if not total:
        return "", 0

    out = [
        MARKER,
        "## Rendered manifest changes",
        "",
        f"What ArgoCD would change on sync, compared with the base branch: "
        f"**{len(added)} added, {len(removed)} removed, {len(changed)} changed**. "
        "Informational only; this check never fails the PR.",
        "",
    ]

    if removed:
        out += ["### ⚠️ Removed (ArgoCD will prune these)", ""]
        out += [f"- {name_of(k)}" for k in removed]
        out.append("")

    risky = [(k, hits) for k, _, hits in changed if hits]
    if risky:
        out += ["### ⚠️ Immutable fields changed (the sync will fail or need a delete first)", ""]
        out += [f"- {name_of(k)}: {', '.join(hits)}" for k, hits in risky]
        out.append("")

    if added:
        out += ["### Added", ""]
        out += [f"- {name_of(k)}" for k in added]
        out.append("")

    if changed:
        out += ["### Changed", ""]
        for key, lines, _ in changed:
            n = sum(l.startswith("- ") for l in lines)
            if len(lines) > MAX_RESOURCE_LINES:
                lines = lines[:MAX_RESOURCE_LINES] + [f"- …and more; {len(lines) - MAX_RESOURCE_LINES} further lines omitted"]
            out += [f"<details><summary>{name_of(key)} ({n} change{'s' if n != 1 else ''})</summary>", ""]
            out += lines + ["", "</details>", ""]

    return "\n".join(out), total


# --- the sticky PR comment --------------------------------------------------

def api(method: str, url: str, token: str, body: dict | None = None):
    req = urllib.request.Request(
        url,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b"null")


def post_comment(markdown: str) -> None:
    token = os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GITHUB_REPOSITORY")
    event = os.environ.get("GITHUB_EVENT_PATH")
    if not (token and repo and event):
        print("::warning::--comment needs GITHUB_TOKEN, GITHUB_REPOSITORY and GITHUB_EVENT_PATH; skipping")
        return
    pr = json.loads(Path(event).read_text()).get("pull_request", {}).get("number")
    if not pr:
        print("::warning::not a pull_request event; skipping the comment")
        return

    base = f"https://api.github.com/repos/{repo}/issues"
    try:
        existing = None
        page = 1
        while existing is None:
            comments = api("GET", f"{base}/{pr}/comments?per_page=100&page={page}", token)
            if not comments:
                break
            existing = next((c for c in comments if MARKER in (c.get("body") or "")), None)
            page += 1
        if not markdown:
            if existing is None:
                return
            markdown = (f"{MARKER}\n## Rendered manifest changes\n\nNo differences from the base "
                        "branch in what ArgoCD would apply.")
        if len(markdown) > COMMENT_LIMIT:
            markdown = (markdown[:COMMENT_LIMIT].rsplit("\n", 1)[0]
                        + "\n\n_…truncated; the full report is in this run's job summary._")
        if existing:
            api("PATCH", f"{base}/comments/{existing['id']}", token, {"body": markdown})
        else:
            api("POST", f"{base}/{pr}/comments", token, {"body": markdown})
    except urllib.error.HTTPError as e:
        # A fork PR's token is read-only; that's not worth failing over.
        print(f"::warning::Couldn't post the PR comment (HTTP {e.code}); the job summary has the report")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("base", type=Path)
    ap.add_argument("head", type=Path)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--comment", action="store_true")
    args = ap.parse_args()
    for d in (args.base, args.head):
        if not d.is_dir():
            ap.error(f"{d} isn't a directory (a render that failed?)")

    markdown, total = report(load(args.base), load(args.head))
    print(markdown if total else "No differences in what ArgoCD would apply.")

    if args.out:
        args.out.write_text(markdown)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        if markdown:
            with open(summary, "a") as f:
                f.write(markdown + "\n")
    if args.comment:
        post_comment(markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
