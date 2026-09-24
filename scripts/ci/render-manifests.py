#!/usr/bin/env python3
"""Render everything ArgoCD would apply from this repo into plain YAML, for
kubeconform (see .github/workflows/lint.yml).

- argocd/apps/**: every file as-is (the root app syncs that tree recursively),
  plus, for each Application in it, what its source(s) render to:
    - Helm chart from a chart repo (`chart:`) -> `helm template` with the
      Application's releaseName/namespace/valuesObject/values/valueFiles
      (`$ref/...` valueFiles resolve against this checkout)
    - Helm chart in an external git repo (`path:`) -> shallow clone at
      targetRevision, then `helm template`
    - `path:` in this repo -> only checked for existence here; the directory
      itself is rendered by the manifests/ pass below
- manifests/*/: `kubectl kustomize` where there's a kustomization.yaml,
  otherwise every *.yaml/*.yml file in the directory (ArgoCD's directory
  mode, non-recursive).

Rendering failures (chart not found, bad values that break a template, a path
that doesn't exist) are errors in their own right, not just kubeconform input.

Usage: scripts/ci/render-manifests.py OUT_DIR
Needs: helm, kubectl (for kustomize), git, PyYAML.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
THIS_REPO_URLS = {
    "https://github.com/jakerobb/homelab.git",
    "https://github.com/jakerobb/homelab",
}

# What the cluster runs, passed to `helm template` so charts that gate on
# .Capabilities render the same templates they would under ArgoCD.
KUBE_VERSION = os.environ.get("KUBE_VERSION", "1.37.1")
API_VERSIONS = [
    "monitoring.coreos.com/v1",
    "gateway.networking.k8s.io/v1",
    "cert-manager.io/v1",
    "snapshot.storage.k8s.io/v1",
    "cilium.io/v2",
]

errors: list[str] = []


def error(msg: str) -> None:
    errors.append(msg)
    print(f"::error::{msg}", flush=True)


def run(cmd: list[str], **kw) -> str | None:
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        error(f"`{' '.join(cmd)}` failed:\n{p.stderr.strip()}")
        return None
    return p.stdout


def git_files(*prefixes: str) -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files", "--", *prefixes], capture_output=True, text=True, check=True, cwd=REPO_ROOT
    ).stdout
    return [REPO_ROOT / p for p in out.splitlines()]


def is_yaml(p: Path) -> bool:
    return p.suffix in (".yaml", ".yml")


def load_docs(path: Path) -> list[dict]:
    return [d for d in yaml.safe_load_all(path.read_text()) if isinstance(d, dict)]


def clone(url: str, rev: str, cache: Path) -> Path | None:
    dest = cache / f"{url.rstrip('/').split('/')[-1].removesuffix('.git')}@{rev}"
    if not dest.exists():
        if run(["git", "clone", "--quiet", "--depth", "1", "--branch", rev, url, str(dest)]) is None:
            return None
    return dest


def helm_template(app: str, src: dict, namespace: str, refs: dict, tmp: Path, cache: Path) -> str | None:
    helm = src.get("helm") or {}
    release = helm.get("releaseName", app)
    cmd = ["helm", "template", release]
    chart_dir = None  # set for git-hosted charts, where relative valueFiles resolve

    if "chart" in src:
        cmd += [src["chart"], "--repo", src["repoURL"], "--version", str(src["targetRevision"])]
    else:
        checkout = clone(src["repoURL"], str(src["targetRevision"]), cache)
        if checkout is None:
            return None
        chart_dir = checkout / src.get("path", "")
        if not (chart_dir / "Chart.yaml").exists():
            error(f"{app}: {src['repoURL']}@{src['targetRevision']}:{src.get('path', '')} has no Chart.yaml "
                  "(only Helm charts are supported for external git sources)")
            return None
        if yaml.safe_load((chart_dir / "Chart.yaml").read_text()).get("dependencies"):
            if run(["helm", "dependency", "build", str(chart_dir)]) is None:
                return None
        cmd.append(str(chart_dir))

    # No --include-crds: kubeconform skips CustomResourceDefinitions anyway (no
    # upstream schema for them), and some charts' crds/ dirs aren't even
    # strictly valid YAML (SigNoz's bundled ClickHouse operator CRDs repeat
    # keys). CRDs a chart renders from templates/ still come through, and are
    # skipped the same way.
    cmd += ["--namespace", namespace, "--kube-version", KUBE_VERSION]
    for api in API_VERSIONS:
        cmd += ["--api-versions", api]

    for vf in helm.get("valueFiles", []):
        if vf.startswith("$"):
            ref, _, rel = vf[1:].partition("/")
            if ref not in refs:
                error(f"{app}: valueFile {vf} uses unknown ref ${ref}")
                return None
            vf_path = REPO_ROOT / rel
        else:
            if chart_dir is None:
                error(f"{app}: relative valueFile {vf} on a chart-repo source isn't supported here")
                return None
            vf_path = chart_dir / vf
        if not vf_path.exists():
            error(f"{app}: valueFile {vf} not found ({vf_path})")
            return None
        cmd += ["-f", str(vf_path)]

    # Same precedence as ArgoCD: valueFiles < values < valuesObject.
    for key in ("values", "valuesObject"):
        if key in helm:
            f = tmp / f"{app}-{key}.yaml"
            f.write_text(helm[key] if isinstance(helm[key], str) else yaml.safe_dump(helm[key]))
            cmd += ["-f", str(f)]

    return run(cmd)


def render_application(doc: dict, source_file: Path, out: Path, tmp: Path, cache: Path) -> None:
    app = doc["metadata"]["name"]
    spec = doc["spec"]
    namespace = spec.get("destination", {}).get("namespace", "default")
    sources = spec.get("sources") or [spec["source"]]
    refs = {s["ref"]: s for s in sources if "ref" in s}

    for bad in (r for r in refs.values() if r["repoURL"] not in THIS_REPO_URLS):
        error(f"{app}: ref source {bad['repoURL']} isn't this repo; only this repo is supported for $refs")
        return

    for i, src in enumerate(sources):
        if "ref" in src and "chart" not in src and "path" not in src:
            continue
        if src["repoURL"] in THIS_REPO_URLS and "chart" not in src:
            if not (REPO_ROOT / src.get("path", "")).is_dir():
                error(f"{app} ({source_file.relative_to(REPO_ROOT)}): path {src.get('path')} doesn't exist in this repo")
            continue
        rendered = helm_template(app, src, namespace, refs, tmp, cache)
        if rendered is not None:
            (out / f"app-{app}-{i}.yaml").write_text(rendered)
            print(f"rendered Application {app} (source {i})", flush=True)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    out = Path(sys.argv[1]).resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        cache = tmp / "git"
        cache.mkdir()

        for f in filter(is_yaml, git_files("argocd/apps")):
            rel = f.relative_to(REPO_ROOT)
            shutil.copy(f, out / ("argocd-" + "-".join(rel.parts[2:])))
            for doc in load_docs(f):
                if doc.get("kind") == "Application":
                    render_application(doc, f, out, tmp, cache)

        dirs = sorted({f.parent for f in git_files("manifests") if f.parent != REPO_ROOT / "manifests"})
        for d in dirs:
            name = "manifests-" + "-".join(d.relative_to(REPO_ROOT / "manifests").parts)
            if (d / "kustomization.yaml").exists():
                rendered = run(["kubectl", "kustomize", str(d)])
                if rendered is not None:
                    (out / f"{name}-kustomize.yaml").write_text(rendered)
            else:
                for f in filter(is_yaml, sorted(d.iterdir())):
                    shutil.copy(f, out / f"{name}-{f.name}")

    print(f"Rendered into {out}: {len(list(out.iterdir()))} file(s), {len(errors)} error(s).")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
