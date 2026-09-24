#!/usr/bin/env python3
"""Fail if any committed *.sops.* file isn't actually SOPS-encrypted.

Catches the classic public-repo mistake: copy foo.yaml.example to
foo.sops.yaml, fill it in, forget `sops -e -i`, commit. GitHub's secret
scanning only knows specific token formats; this knows our naming convention.

Also fails on any file under a secrets/ directory that isn't *.sops.* or an
*.example template, i.e. a secret committed without the naming convention.

Checks each file for SOPS metadata AND that every value outside it is an
ENC[...] blob (keys ending in _unencrypted excepted, per sops's default
unencrypted_suffix) — so it also catches a plaintext value hand-added to an
otherwise-encrypted file.

Stdlib only, so it runs the same locally and in CI:
    scripts/ci/check-sops-encrypted.py            # all tracked *.sops.* files
    scripts/ci/check-sops-encrypted.py FILE...    # specific files
"""

import json
import re
import subprocess
import sys
from pathlib import Path

UNENCRYPTED_SUFFIX = "_unencrypted"


def is_enc(value: str) -> bool:
    return value.startswith("ENC[")


def is_enc_comment(comment: str) -> bool:
    # SOPS encrypts comment text but leaves empty "#" lines alone.
    return comment.startswith("#ENC[") or comment.lstrip("#").strip() == ""


def check_json(text: str) -> list[str]:
    doc = json.loads(text)
    if not isinstance(doc, dict) or "sops" not in doc:
        return ["no top-level \"sops\" metadata"]
    problems = []

    def walk(node, path):
        if isinstance(node, dict):
            for k, v in node.items():
                if not k.endswith(UNENCRYPTED_SUFFIX):
                    walk(v, f"{path}.{k}")
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, f"{path}[{i}]")
        elif not (isinstance(node, str) and (node == "" or is_enc(node))):
            problems.append(f"plaintext value at {path}")

    walk({k: v for k, v in doc.items() if k != "sops"}, "")
    return problems


def check_env(text: str) -> list[str]:
    problems, has_meta = [], False
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        if line.startswith("sops_"):
            has_meta = True
            continue
        if line.lstrip().startswith("#"):
            if not is_enc_comment(line.strip()):
                problems.append(f"line {n}: plaintext comment")
            continue
        key, _, value = line.partition("=")
        if not key.endswith(UNENCRYPTED_SUFFIX) and not is_enc(value):
            problems.append(f"line {n}: plaintext value for {key}")
    if not has_meta:
        problems.insert(0, "no sops_* metadata")
    return problems


# SOPS writes YAML in a very regular shape (block style, one key or list item
# per line, every scalar replaced by ENC[...], comments encrypted as #ENC[...]),
# so a line-based pass is enough — no YAML library needed.
YAML_LINE = re.compile(r"^(?P<indent> *)(?P<dashes>(?:- +)*)(?P<rest>.*)$")


def check_yaml(text: str) -> list[str]:
    problems, has_meta = [], False
    skip_deeper_than = None  # indent of a sops:/_unencrypted key whose children we skip

    for n, raw in enumerate(text.splitlines(), 1):
        if not raw.strip() or raw.strip() == "---":
            continue
        m = YAML_LINE.match(raw)
        indent = len(m["indent"]) + len(m["dashes"])
        rest = m["rest"]

        if skip_deeper_than is not None:
            if indent > skip_deeper_than:
                continue
            skip_deeper_than = None

        if rest.startswith("#"):
            if not is_enc_comment(rest.strip()):
                problems.append(f"line {n}: plaintext comment")
            continue

        key, sep, value = rest.partition(":")
        if sep and (value == "" or value.startswith(" ")) and not is_enc(rest):
            value = value.strip()
            if indent == 0 and key == "sops":
                has_meta = True
                skip_deeper_than = 0
                continue
            if key.endswith(UNENCRYPTED_SUFFIX):
                skip_deeper_than = indent
                continue
        else:
            value = rest.strip()  # bare list item

        if value and not is_enc(value):
            problems.append(f"line {n}: plaintext value" + (f" for {key.strip()}" if sep else ""))

    if not has_meta:
        problems.insert(0, "no top-level sops: metadata")
    return problems


def check(path: Path) -> list[str]:
    text = path.read_text()
    suffix = path.name.rsplit(".sops.", 1)[1]
    if suffix == "json":
        return check_json(text)
    if suffix == "env":
        return check_env(text)
    return check_yaml(text)


SOPS_NAME = re.compile(r"[^/]\.sops\.[^/]+$")  # not ".sops.yaml" itself, the SOPS config


def tracked_files() -> list[str]:
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout
    return out.splitlines()


def misnamed_secrets(paths: list[str]) -> list[str]:
    return [
        p for p in paths
        if re.search(r"(^|/)secrets/", p) and not SOPS_NAME.search(p) and not p.endswith(".example")
    ]


def main() -> int:
    failed = 0
    if sys.argv[1:]:
        files = [Path(a) for a in sys.argv[1:]]
    else:
        tracked = tracked_files()
        files = [Path(p) for p in tracked if SOPS_NAME.search(p)]
        for p in misnamed_secrets(tracked):
            failed += 1
            print(f"::error file={p}::{p}: under secrets/ but not named *.sops.* (or *.example)")
    for path in files:
        try:
            problems = check(path)
        except (ValueError, UnicodeDecodeError) as e:
            problems = [f"unparseable: {e}"]
        if problems:
            failed += 1
            for p in problems[:5]:
                print(f"::error file={path}::{path}: {p}")
            if len(problems) > 5:
                print(f"::error file={path}::{path}: ...and {len(problems) - 5} more")
    print(f"Checked {len(files)} SOPS file(s): {failed} problem file(s).")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
