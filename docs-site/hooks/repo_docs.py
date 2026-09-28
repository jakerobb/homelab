"""MkDocs hook: publish the whole repo's Markdown, not just one docs_dir.

The docs are spread across the repo (README.md, argocd/README.md,
talos/README.md, docs/*.md, todo/*.md, ...) and cross-link each other with
GitHub-style relative paths. MkDocs refuses a docs_dir that contains its own
config file, so instead of copying everything into a staging tree, this hook
adds every repo Markdown file to the build straight from where it lives.

It also adapts GitHub-flavored Markdown to what Python-Markdown expects:

- Relative links to non-Markdown files (YAML, scripts, directories) become
  GitHub URLs. Those files aren't part of the site, so without this every
  link to a manifest would be a broken link.
- Nested list content is re-indented to 4 spaces per level. GitHub nests by
  the parent item's content column (2 spaces under `- `), but
  Python-Markdown needs 4, so the repo's 2-space lists (and code fences
  inside them) would otherwise flatten or fall out of the list.
"""

import os
import posixpath
import re

from mkdocs.structure.files import File

# Repo root, relative to this file (docs-site/hooks/).
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# Directory names never searched for Markdown. Hidden dirs (.git, .github,
# .claude) are skipped separately.
SKIP_DIRS = {"docs-site", "node_modules", "site"}

# Markdown files that aren't documentation.
SKIP_FILES = {"CLAUDE.md"}

INLINE_LINK = re.compile(r"(\]\()(<[^>]+>|[^)\s]+)")
REF_LINK = re.compile(r"^(\s{0,3}\[[^\]]+\]:\s*)(\S+)", re.MULTILINE)
FENCE = re.compile(r"^(\s*)(```|~~~)")
LIST_ITEM = re.compile(r"^( *)([-*+]|\d+[.)])( +)\S")
SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")


def _repo_markdown():
    for dirpath, dirnames, filenames in os.walk(REPO_ROOT):
        dirnames[:] = sorted(
            d for d in dirnames if not d.startswith(".") and d not in SKIP_DIRS
        )
        for name in sorted(filenames):
            if name.endswith(".md") and name not in SKIP_FILES:
                yield os.path.relpath(os.path.join(dirpath, name), REPO_ROOT)


def on_files(files, config):
    for path in _repo_markdown():
        files.append(
            File(
                path.replace(os.sep, "/"),
                src_dir=REPO_ROOT,
                dest_dir=config["site_dir"],
                use_directory_urls=config["use_directory_urls"],
            )
        )
    return files


def _github_url(config, kind, path, fragment):
    url = f"{config['repo_url'].rstrip('/')}/{kind}/main/{path}"
    return url + ("#" + fragment if fragment else "")


def _rewrite(target, page, config, files):
    bracketed = target.startswith("<")
    raw = target[1:-1] if bracketed else target
    if not raw or raw.startswith(("#", "/")) or SCHEME.match(raw):
        return target
    path, _, fragment = raw.partition("#")
    resolved = posixpath.normpath(
        posixpath.join(posixpath.dirname(page.file.src_uri), path)
    )
    if resolved.startswith(".."):
        return target
    if files.get_file_from_path(resolved):
        return target
    abs_path = os.path.join(REPO_ROOT, resolved)
    if os.path.isdir(abs_path):
        readme = posixpath.join(resolved, "README.md")
        if files.get_file_from_path(readme):
            # Point at the directory's README page, keeping the link relative.
            new = posixpath.join(path, "README.md") + ("#" + fragment if fragment else "")
        else:
            new = _github_url(config, "tree", resolved, fragment)
    elif os.path.isfile(abs_path):
        new = _github_url(config, "blob", resolved, fragment)
    else:
        # Genuinely broken. Leave it so MkDocs reports it (and --strict fails).
        return target
    return f"<{new}>" if bracketed else new


def _reindent_lists(lines):
    # Stack of original content columns, one per enclosing list item. Depth
    # in the output is len(stack), at 4 spaces a level.
    stack = []
    fence = None  # (marker, spaces removed or added) while inside a fence
    fence_closed = False
    out = []
    for line in lines:
        # GitHub ends a fence at its closing line; Python-Markdown reads a
        # list item straight after one as paragraph text, so separate them.
        if fence_closed and line.strip():
            out.append("")
        fence_closed = False
        if fence:
            marker, shift = fence
            if shift >= 0:
                line = " " * shift + line
            else:
                line = line[min(-shift, len(line) - len(line.lstrip(" "))):]
            if line.strip().startswith(marker):
                fence = None
                fence_closed = True
            out.append(line)
            continue
        if not line.strip():
            out.append(line)
            continue
        indent = len(line) - len(line.lstrip(" "))
        while stack and indent < stack[-1]:
            stack.pop()
        item = LIST_ITEM.match(line)
        # Top-level lines are left alone, list or not.
        new_indent = 4 * len(stack) if stack else indent
        opener = FENCE.match(line)
        if opener:
            fence = (opener.group(2), new_indent - indent)
        if item:
            stack.append(indent + len(item.group(2)) + len(item.group(3)))
        out.append(" " * new_indent + line[indent:])
    return out


def on_page_markdown(markdown, page, config, files):
    out = []
    in_fence = False
    for line in _reindent_lists(markdown.split("\n")):
        if FENCE.match(line):
            in_fence = not in_fence
        elif not in_fence:
            line = INLINE_LINK.sub(
                lambda m: m.group(1) + _rewrite(m.group(2), page, config, files), line
            )
            line = REF_LINK.sub(
                lambda m: m.group(1) + _rewrite(m.group(2), page, config, files), line
            )
        out.append(line)
    return "\n".join(out)
