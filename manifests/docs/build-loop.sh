#!/bin/sh
# Builder sidecar for docs.jakerobb.org. Clones the repo, builds the MkDocs
# site into /site/builds/<sha>, and points the /site/current symlink (what
# nginx serves) at it. Then polls main and rebuilds on every new commit.
# A failed build is logged and skipped: nginx keeps serving the last good
# one, and the next commit gets a fresh try.
set -eu

: "${REPO_URL:?}" "${BRANCH:?}" "${POLL_SECONDS:?}"
repo=/work/repo
built=""

if [ ! -d "$repo/.git" ]; then
  # Full clone, not shallow: the git-revision-date plugin reads each page's
  # history for its "last updated" date. The repo is small.
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$repo"
fi

while :; do
  if git -C "$repo" fetch --quiet origin "$BRANCH" &&
    git -C "$repo" reset --quiet --hard FETCH_HEAD; then
    sha=$(git -C "$repo" rev-parse HEAD)
    if [ "$sha" != "$built" ]; then
      echo "building $sha"
      if mkdocs build --quiet -f "$repo/docs-site/mkdocs.yml" -d "/site/builds/$sha"; then
        # Swap the symlink atomically (rename over the old one), so nginx
        # never sees a missing or half-written site.
        python3 -c 'import os, sys; os.symlink(sys.argv[1], "/site/current.tmp"); os.replace("/site/current.tmp", "/site/current")' "builds/$sha"
        for old in /site/builds/*; do
          [ "$old" = "/site/builds/$sha" ] || rm -rf "$old"
        done
        echo "serving $sha"
      else
        rm -rf "/site/builds/$sha"
        echo "build of $sha failed; still serving the previous build" >&2
      fi
      built=$sha
    fi
  else
    echo "fetch failed; retrying in ${POLL_SECONDS}s" >&2
  fi
  sleep "$POLL_SECONDS"
done
