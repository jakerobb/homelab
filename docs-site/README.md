# docs-site

MkDocs Material config for [docs.jakerobb.org](https://docs.jakerobb.org). The
pages themselves are the Markdown files throughout the repo, and this
directory holds only the config, the hook that pulls them in, and site-only
assets. This README isn't published on the site.

How it's built and deployed: the "Docs site" section of
[`argocd/README.md`](../argocd/README.md#docs-site-added-2026-09-28).

## Adding a page

Write the Markdown file wherever it belongs in the repo, then add it to `nav:`
in [`mkdocs.yml`](mkdocs.yml). CI fails any PR that adds a Markdown file
without a nav entry. `CLAUDE.md` is the one file deliberately left out (see
`SKIP_FILES` in [`hooks/repo_docs.py`](hooks/repo_docs.py)).

Write links the way GitHub expects them: relative paths, with `#anchors`
from GitHub's heading slugs. They work in both places.

## Previewing locally

From the repo root:

```bash
python3 -m venv .venv && .venv/bin/pip install -r docs-site/requirements.txt
```

```bash
NO_MKDOCS_2_WARNING=1 .venv/bin/mkdocs serve -f docs-site/mkdocs.yml
```

Then open <http://127.0.0.1:8000>. `serve` only watches `docs-site/` itself
for changes, so restart it after editing a page elsewhere in the repo. To run
the same check CI does:

```bash
DOCS_GIT_DATES=false NO_MKDOCS_2_WARNING=1 .venv/bin/mkdocs build --strict -f docs-site/mkdocs.yml
```
