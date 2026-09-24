#!/usr/bin/env bash
# Installs and registers the GitHub Actions self-hosted runner on the jump box,
# as a dedicated unprivileged user with its own age key — see
# docs/gha-terraform.md for the full setup (B2 bucket, .sops.yaml recipient,
# repo settings).
#
# Idempotent: safe to re-run. Skips install/registration when the runner is
# already configured (it auto-updates itself after that), and never
# regenerates an existing age key.
#
# Usage (on the jump box, from a checkout of this repo):
#   sudo ./scripts/gha-runner/setup-runner.sh
# Prompts for a registration token (valid 1 hour) when registration is needed;
# get one with:
#   gh api -X POST repos/jakerobb/homelab/actions/runners/registration-token --jq .token
set -euo pipefail

REPO_URL="https://github.com/jakerobb/homelab"
RUNNER_USER="gha-runner"
RUNNER_DIR="/opt/actions-runner"
RUNNER_NAME="${RUNNER_NAME:-$(hostname -s)}"
RUNNER_LABELS="homelab-jumpbox"

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"

# The workflow uses the host's terraform/sops (see the workflow header), so
# they must already be installed system-wide, same as for manual tf.sh runs.
for bin in terraform sops curl jq flock; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not found on PATH"
done

if ! command -v age-keygen >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq age
fi

case "$(uname -m)" in
  aarch64) RUNNER_ARCH=arm64 ;;
  x86_64) RUNNER_ARCH=x64 ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac

# Deliberately not in sudo/docker/adm: a job on this runner should reach the
# Proxmox API and B2, and nothing else on this host (jakerobb's home is 0700,
# so talosconfig/kubeconfig/the master age key stay out of reach).
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin "$RUNNER_USER"
fi
RUNNER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
as_runner() { sudo -u "$RUNNER_USER" -H "$@"; }

# Runner-only age key. Its public key is a second recipient on just the
# terraform/**/secrets rule in .sops.yaml, so this user can decrypt the
# Proxmox token and B2 state key but none of the cluster/app secrets.
AGE_KEY="${RUNNER_HOME}/.config/sops/age/keys.txt"
if [ ! -f "$AGE_KEY" ]; then
  as_runner mkdir -p "$(dirname "$AGE_KEY")"
  as_runner age-keygen -o "$AGE_KEY" 2>/dev/null
  chmod 600 "$AGE_KEY"
  echo "Generated new runner age key."
fi

if [ ! -f "${RUNNER_DIR}/.runner" ]; then
  release="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)"
  version="$(jq -r .tag_name <<<"$release" | sed 's/^v//')"
  tarball="actions-runner-linux-${RUNNER_ARCH}-${version}.tar.gz"
  # Release notes carry each tarball's SHA-256 between these markers.
  expected_sha="$(jq -r .body <<<"$release" |
    sed -n "s/.*<!-- BEGIN SHA linux-${RUNNER_ARCH} -->\([0-9a-f]\{64\}\)<!-- END SHA linux-${RUNNER_ARCH} -->.*/\1/p")"
  [ -n "$expected_sha" ] || die "couldn't find SHA-256 for $tarball in release notes"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "${tmp}/${tarball}" \
    "https://github.com/actions/runner/releases/download/v${version}/${tarball}"
  echo "${expected_sha}  ${tmp}/${tarball}" | sha256sum -c --quiet - || die "checksum mismatch for $tarball"

  mkdir -p "$RUNNER_DIR"
  tar -xzf "${tmp}/${tarball}" -C "$RUNNER_DIR"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"
  "${RUNNER_DIR}/bin/installdependencies.sh"

  read -rsp "Runner registration token: " token
  echo
  [ -n "$token" ] || die "no registration token given"
  (cd "$RUNNER_DIR" && as_runner ./config.sh --unattended \
    --url "$REPO_URL" --token "$token" \
    --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" \
    --work _work --replace)
  echo "Registered runner ${RUNNER_NAME} (actions/runner v${version})."
else
  echo "Runner already configured in ${RUNNER_DIR}; skipping install/registration."
fi

# Shared provider cache across runs, so each job doesn't re-download bpg/proxmox.
# The runner loads .env into every job's environment.
PLUGIN_CACHE="${RUNNER_HOME}/.terraform.d/plugin-cache"
as_runner mkdir -p "$PLUGIN_CACHE"
touch "${RUNNER_DIR}/.env"
chown "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}/.env"
grep -q '^TF_PLUGIN_CACHE_DIR=' "${RUNNER_DIR}/.env" ||
  echo "TF_PLUGIN_CACHE_DIR=${PLUGIN_CACHE}" >>"${RUNNER_DIR}/.env"

cd "$RUNNER_DIR"
# svc.sh records the systemd unit name in .service once installed.
[ -f .service ] || ./svc.sh install "$RUNNER_USER"
./svc.sh start >/dev/null
./svc.sh status | grep -E 'Active:' || true

echo
echo "Runner age public key (add to .sops.yaml's terraform rule if not already there):"
age-keygen -y "$AGE_KEY"
