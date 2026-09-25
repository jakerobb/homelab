#!/usr/bin/env python3
"""Fail if Renovate's argocd manager would silently skip an Application file.

Renovate strips `{{ ... }}`, `{% ... %}` and `{# ... #}` templates from
argocd Application files *before* parsing them as YAML (removeTemplates in
lib/modules/manager/argocd/schema.ts). A template at the start of a line in a
folded/literal block scalar (e.g. a PrometheusRule description in a chart's
valuesObject) leaves that line with different indentation from the rest of
the block. The file then fails to parse, and Renovate drops it with only a
debug-level log line. Nothing in that file gets updates again, and the
Dependency Dashboard just leaves it out. That happened to kube-prometheus-stack
on 2026-09-24 (e983889).

This mirrors Renovate's stripTemplates() and checks each file still parses
and still has an Application spec with a chart/repo source.

Needs PyYAML:
    scripts/ci/check-renovate-parse.py            # argocd/apps/*/application.yaml
    scripts/ci/check-renovate-parse.py FILE...    # specific files
"""

import sys
from pathlib import Path

import yaml

OPENERS = {"{%`": "`%}", "{%": "%}", "{{`": "`}}", "{{": "}}", "{#": "#}"}


def strip_templates(content: str) -> str:
    """Port of renovate's lib/util/string.ts stripTemplates()."""
    out, idx, last = [], 0, 0
    while idx < len(content):
        if content[idx] == "{":
            for opener in ("{%`", "{{`", "{%", "{{", "{#"):
                if content.startswith(opener, idx):
                    end = content.find(OPENERS[opener], idx + len(opener))
                    if end != -1:
                        out.append(content[last:idx])
                        idx = last = end + len(OPENERS[opener])
                        break
            else:
                idx += 1
            continue
        idx += 1
    out.append(content[last:])
    return "".join(out)


def check(path: Path) -> str | None:
    try:
        docs = list(yaml.safe_load_all(strip_templates(path.read_text())))
    except yaml.YAMLError as e:
        return f"doesn't parse once templates are stripped:\n{e}"
    apps = [d for d in docs if isinstance(d, dict) and d.get("kind") == "Application"]
    if not apps:
        return "no Application document found"
    for app in apps:
        spec = app.get("spec") or {}
        if not (spec.get("source") or spec.get("sources")):
            return f"Application {app.get('metadata', {}).get('name')} has no source(s)"
    return None


def main() -> int:
    files = [Path(f) for f in sys.argv[1:]] or sorted(Path("argocd/apps").glob("*/application.yaml"))
    failed = False
    for f in files:
        if err := check(f):
            failed = True
            print(f"::error file={f}::Renovate would silently skip this file: {err}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
