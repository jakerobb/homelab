#!/usr/bin/env python3
"""Check that every container image in the rendered manifests exists in its
registry and has a build for each CPU architecture its pod can be scheduled on.

The cluster mixes amd64 and arm64 nodes, and a bumped tag that's missing one
architecture is a silent ImagePullBackOff after the merge (ArgoCD syncs main
as-is). Both architectures are required unless the pod restricts itself with
`nodeSelector: kubernetes.io/arch` or a required `nodeAffinity` expression on
that label, in which case only the allowed ones are.

Reads the output of scripts/ci/render-manifests.py. Images are found by walking
every document for `image:` strings; ArgoCD Application objects are skipped
(their nested `image:` values are overrides the chart renders anyway). The
nearest enclosing pod-spec-like mapping with a nodeSelector or affinity sets the
constraint, so CRs that embed a pod template (Prometheus, ARC) are covered too.

With --baseline (the same render of the PR's base branch), only images that are
new in this render, or whose architecture requirement widened, are checked.
That keeps a lint run from re-fetching every manifest in the cluster, which
would eat Docker Hub's anonymous pull limit (shared with the nodes' own pulls).

Usage: scripts/ci/check-image-arch.py RENDERED_DIR [--baseline BASE_RENDERED_DIR]
Needs: PyYAML. Registry access is anonymous.
"""

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import yaml

ARCHES = frozenset({"amd64", "arm64"})
ARCH_LABELS = {"kubernetes.io/arch", "beta.kubernetes.io/arch"}

MANIFEST_ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])
INDEX_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}


# --- finding images ---------------------------------------------------------

def allowed_arches(node: dict, inherited: frozenset) -> frozenset:
    """Architectures a pod spec (or CR fragment) with these scheduling fields
    can run on, narrowing `inherited`."""
    allowed = inherited
    selector = node.get("nodeSelector")
    if isinstance(selector, dict):
        for label in ARCH_LABELS & selector.keys():
            allowed &= {str(selector[label])}

    required = (
        ((node.get("affinity") or {}).get("nodeAffinity") or {})
        .get("requiredDuringSchedulingIgnoredDuringExecution") or {}
    )
    terms = required.get("nodeSelectorTerms")
    if isinstance(terms, list) and terms:
        # Terms are ORed; the expressions within one term are ANDed.
        union: frozenset = frozenset()
        for term in terms:
            term_allowed = ARCHES
            for expr in (term or {}).get("matchExpressions") or []:
                if expr.get("key") not in ARCH_LABELS:
                    continue
                values = frozenset(map(str, expr.get("values") or []))
                if expr.get("operator") == "In":
                    term_allowed &= values
                elif expr.get("operator") == "NotIn":
                    term_allowed -= values
            union |= term_allowed
        allowed &= union
    return allowed


def walk(node, allowed: frozenset, found: dict) -> None:
    if isinstance(node, dict):
        allowed = allowed_arches(node, allowed)
        for key, value in node.items():
            if key == "image" and isinstance(value, str) and value.strip():
                # A pod that's unschedulable on every arch (empty set) needs
                # nothing from the image; the render check is the place for that.
                found.setdefault(value.strip(), set()).update(allowed)
            else:
                walk(value, allowed, found)
    elif isinstance(node, list):
        for item in node:
            walk(item, allowed, found)


def collect(rendered: Path) -> dict[str, frozenset]:
    """image reference -> architectures it must have, from a render directory."""
    found: dict[str, set] = {}
    for f in sorted(rendered.glob("*.y*ml")):
        for doc in yaml.safe_load_all(f.read_text()):
            if isinstance(doc, dict) and doc.get("kind") != "Application":
                walk(doc, ARCHES, found)
    return {image: frozenset(arches) for image, arches in found.items()}


# --- talking to registries --------------------------------------------------

def parse_ref(ref: str) -> tuple[str, str, str]:
    """-> (registry host, repository, tag or digest), Docker's normalization."""
    name, digest = (ref.split("@", 1) + [None])[:2]
    reference = digest
    if ":" in name.rsplit("/", 1)[-1]:
        name, tag = name.rsplit(":", 1)
        reference = reference or tag
    reference = reference or "latest"
    first, _, rest = name.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        host, repo = first, rest
    else:
        host, repo = "docker.io", name
    if host in ("docker.io", "index.docker.io"):
        host = "registry-1.docker.io"
        if "/" not in repo:
            repo = f"library/{repo}"
    return host, repo, reference


def http(url: str, headers: dict, retries: int = 3) -> tuple[int, dict, bytes]:
    delay = 2.0
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < retries:
                time.sleep(delay)
                delay *= 2
                continue
            return e.code, dict(e.headers), e.read()
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt < retries:
                time.sleep(delay)
                delay *= 2
                continue
            raise RuntimeError(f"{url}: {e}") from e
    raise AssertionError("unreachable")


def bearer_token(challenge: str) -> str | None:
    params = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
    if "realm" not in params:
        return None
    query = {k: params[k] for k in ("service", "scope") if k in params}
    url = params["realm"] + "?" + urllib.parse.urlencode(query)
    status, _, body = http(url, {})
    if status != 200:
        return None
    data = json.loads(body)
    return data.get("token") or data.get("access_token")


class Registry:
    def __init__(self, host: str):
        self.host = host
        self.tokens: dict[str, str] = {}

    def get(self, repo: str, path: str, accept: str) -> tuple[int, dict, bytes]:
        url = f"https://{self.host}/v2/{repo}/{path}"
        headers = {"Accept": accept}
        if repo in self.tokens:
            headers["Authorization"] = f"Bearer {self.tokens[repo]}"
        status, hdrs, body = http(url, headers)
        if status == 401:
            challenge = next((v for k, v in hdrs.items() if k.lower() == "www-authenticate"), "")
            token = bearer_token(challenge) if challenge.lower().startswith("bearer") else None
            if token:
                self.tokens[repo] = token
                headers["Authorization"] = f"Bearer {token}"
                status, hdrs, body = http(url, headers)
        return status, hdrs, body


registries: dict[str, Registry] = {}


def platforms(ref: str) -> set[str]:
    """linux architectures the image is published for. Raises on any problem."""
    host, repo, reference = parse_ref(ref)
    reg = registries.setdefault(host, Registry(host))
    status, hdrs, body = reg.get(repo, f"manifests/{reference}", MANIFEST_ACCEPT)
    if status != 200:
        raise RuntimeError(f"{host}/{repo}:{reference} -> HTTP {status}"
                           + (" (not found, or private)" if status in (401, 403, 404) else ""))
    manifest = json.loads(body)
    media_type = manifest.get("mediaType") or next(
        (v for k, v in hdrs.items() if k.lower() == "content-type"), "")

    if media_type in INDEX_TYPES or "manifests" in manifest:
        return {
            m["platform"]["architecture"]
            for m in manifest.get("manifests", [])
            if m.get("platform", {}).get("os") == "linux"
        }

    # A single-platform manifest: the architecture lives in the config blob.
    config = manifest.get("config", {}).get("digest")
    if not config:
        raise RuntimeError(f"{ref}: unrecognized manifest (no manifests or config)")
    status, _, body = reg.get(repo, f"blobs/{config}", "application/json")
    if status != 200:
        raise RuntimeError(f"{ref}: config blob -> HTTP {status}")
    cfg = json.loads(body)
    return {cfg["architecture"]} if cfg.get("os") == "linux" else set()


# --- main -------------------------------------------------------------------

def check(item: tuple[str, frozenset]) -> tuple[str, frozenset, str | None]:
    image, needed = item
    try:
        have = platforms(image)
    except Exception as e:  # noqa: BLE001 - report any failure against the image
        return image, needed, f"can't read its manifest: {e}"
    missing = sorted(needed - have)
    if missing:
        return image, needed, f"no linux/{', linux/'.join(missing)} build (has: {', '.join(sorted(have)) or 'none'})"
    return image, needed, None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("rendered", type=Path)
    ap.add_argument("--baseline", type=Path, help="render of the base branch; only check what changed from it")
    args = ap.parse_args()

    images = collect(args.rendered)
    total = len(images)
    if args.baseline:
        base = collect(args.baseline)
        # New images, and images whose arch requirement widened (say, a
        # nodeSelector was dropped), need checking; unchanged ones already run.
        images = {i: a for i, a in images.items() if i not in base or not a <= base[i]}
        print(f"{total} image(s) rendered, {len(images)} new or widened vs the baseline.")
    else:
        print(f"{total} image(s) rendered; checking all of them.")

    failures = 0
    with ThreadPoolExecutor(max_workers=8) as pool:
        for image, needed, problem in pool.map(check, sorted(images.items())):
            arches = "+".join(sorted(needed)) or "(none)"
            if problem:
                failures += 1
                print(f"::error title=Image architecture::{image} (needs {arches}): {problem}", flush=True)
            else:
                print(f"ok  {image}  [{arches}]", flush=True)

    print(f"{len(images)} image(s) checked, {failures} problem(s).")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
