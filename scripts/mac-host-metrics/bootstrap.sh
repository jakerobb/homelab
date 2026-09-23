#!/bin/bash
# Single entry point for ../../docs/mac-host-metrics.md's setup steps --
# run this instead of copy-pasting those steps one at a time over a
# remote/KVM session. Safe to re-run: every step below either overwrites
# in place or explicitly undoes its own prior state first.
#
# Usage: ./bootstrap.sh [--homebrew] <node-host-name>
#   e.g. ./bootstrap.sh talos-worker-mbp-host
#   e.g. ./bootstrap.sh --homebrew talos-worker-macstudio-host
#
# Defaults to the manual binary + LaunchDaemon install path -- pass
# --homebrew only once you've confirmed Homebrew actually works on this
# particular Mac. There's no reliable way to auto-detect that: `brew
# --prefix` (this script's first attempt) succeeds even on hardware where
# `brew install <formula>` then fails, because the macOS-version gate only
# bites during an actual install/build, not on basic queries -- found live
# on the 2018 MacBook Pro, whose Sequoia ceiling is one release short of
# what Homebrew currently needs. A hardcoded macOS-version check would
# just be a second, differently-stale way to get this wrong (Homebrew's
# own minimum floor moves over time -- see the doc's Gotchas), so this
# asks you instead.
#
# Auto-detects: CPU architecture (uname -m, picks the matching Telegraf
# build + pinned checksum). Doesn't auto-detect: the host name (SigNoz's
# host.name; would collide across Macs if guessed from e.g. `hostname`,
# since this repo's node-naming convention isn't derivable from that) --
# hence the required argument.
set -euo pipefail

if [ "$EUID" -eq 0 ]; then
  echo "Run this as your normal user, not with sudo -- it calls sudo internally only where actually needed." >&2
  echo "(Running the whole thing as root would also make Telegraf/the sudoers rule apply to the wrong account.)" >&2
  exit 1
fi

USE_HOMEBREW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --homebrew) USE_HOMEBREW=1; shift ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

NODE_HOST_NAME="${1:-}"
if [ -z "$NODE_HOST_NAME" ]; then
  echo "Usage: $0 [--homebrew] <node-host-name>" >&2
  echo "  e.g.: $0 talos-worker-mbp-host" >&2
  echo "  e.g.: $0 --homebrew talos-worker-macstudio-host" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_USERNAME="$(whoami)"

# Bump after checking https://github.com/influxdata/telegraf/releases --
# don't assume this is still current. Both checksums below were verified
# live (downloaded and re-hashed, not just copied from the release notes)
# as of 2026-09-22.
TELEGRAF_VERSION=1.40.1

for f in collect-therm.sh collect-power.sh collect-smc.sh telegraf.conf telegraf-powermetrics.sudoers com.jakerobb.telegraf.plist; do
  if [ ! -f "${SCRIPT_DIR}/${f}" ]; then
    echo "Missing ${SCRIPT_DIR}/${f} -- run this from a checkout of the homelab repo (scripts/mac-host-metrics/), not a copied-out single file." >&2
    exit 1
  fi
done

echo "==> Caching sudo credentials (you'll be prompted once)"
sudo -v

case "$(uname -m)" in
  x86_64) GOARCH=amd64; TARBALL_SHA256="19b7886b3507d99f49b6459f892955ad60d4c367035887e2aa77c05d8fd0467a" ;;
  arm64)  GOARCH=arm64; TARBALL_SHA256="0b7094777deb982d4f36291478035e6c146cb52436fc4b3ad200d4e71e2dc217" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
echo "==> Detected architecture: $(uname -m) (telegraf ${GOARCH})"

if [ "$USE_HOMEBREW" -eq 1 ]; then
  INSTALL_METHOD=homebrew
  TELEGRAF_PREFIX="$(brew --prefix)"
  echo "==> --homebrew passed -- using Homebrew (prefix: ${TELEGRAF_PREFIX})"
else
  INSTALL_METHOD=manual
  TELEGRAF_PREFIX=/usr/local
  echo "==> Installing Telegraf ${TELEGRAF_VERSION} manually to ${TELEGRAF_PREFIX} (pass --homebrew if you've confirmed Homebrew works on this Mac)"
fi

if [ "$INSTALL_METHOD" = "homebrew" ]; then
  echo "==> brew install telegraf"
  brew install telegraf
else
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  TARBALL="telegraf-${TELEGRAF_VERSION}_darwin_${GOARCH}.tar.gz"
  echo "==> Downloading ${TARBALL}"
  curl -fsSL -o "${TMP_DIR}/${TARBALL}" "https://dl.influxdata.com/telegraf/releases/${TARBALL}"
  echo "==> Verifying checksum"
  (cd "$TMP_DIR" && echo "${TARBALL_SHA256}  ${TARBALL}" | shasum -a 256 -c -)
  echo "==> Extracting and installing binary to ${TELEGRAF_PREFIX}/bin/telegraf"
  tar xzf "${TMP_DIR}/${TARBALL}" -C "$TMP_DIR"
  sudo mkdir -p "${TELEGRAF_PREFIX}/bin" "${TELEGRAF_PREFIX}/var/log"
  sudo cp "${TMP_DIR}/telegraf-${TELEGRAF_VERSION}/usr/bin/telegraf" "${TELEGRAF_PREFIX}/bin/telegraf"
  sudo chmod 755 "${TELEGRAF_PREFIX}/bin/telegraf"
fi

echo "==> Installing collector scripts and per-host telegraf.conf (host.name=${NODE_HOST_NAME}, prefix=${TELEGRAF_PREFIX})"
sudo mkdir -p "${TELEGRAF_PREFIX}/etc/telegraf/scripts"
sudo cp "${SCRIPT_DIR}"/collect-*.sh "${TELEGRAF_PREFIX}/etc/telegraf/scripts/"
sudo chmod 755 "${TELEGRAF_PREFIX}"/etc/telegraf/scripts/collect-*.sh
sed -e "s|@@TELEGRAF_PREFIX@@|${TELEGRAF_PREFIX}|g" -e "s|@@NODE_HOST_NAME@@|${NODE_HOST_NAME}|g" \
  "${SCRIPT_DIR}/telegraf.conf" | sudo tee "${TELEGRAF_PREFIX}/etc/telegraf.conf" > /dev/null

echo "==> Installing scoped sudoers rule for collect-smc.sh (account: ${MAC_USERNAME})"
SUDOERS_TMP="$(mktemp)"
sed "s|<mac-username>|${MAC_USERNAME}|g" "${SCRIPT_DIR}/telegraf-powermetrics.sudoers" > "$SUDOERS_TMP"
sudo visudo -cf "$SUDOERS_TMP"
sudo install -m 0440 -o root -g wheel "$SUDOERS_TMP" /etc/sudoers.d/telegraf-powermetrics
rm -f "$SUDOERS_TMP"

echo "==> Smoke-testing each collector script"
for script in collect-therm.sh collect-power.sh collect-smc.sh; do
  echo "--- ${script} ---"
  # Deliberately not fatal (no `set -e` interaction) -- this is diagnostic
  # output, not a precondition for the rest of the run. An empty result
  # from collect-smc.sh specifically usually means the sudoers rule above
  # hasn't taken effect yet, or (on unfamiliar hardware) powermetrics's
  # SMC sensor labels don't match what the script greps for -- see the
  # doc's Gotchas either way.
  out="$("${TELEGRAF_PREFIX}/etc/telegraf/scripts/${script}" 2>&1)" || true
  if [ -z "$out" ]; then
    echo "(no output)"
  else
    echo "$out"
  fi
done

echo "==> Starting Telegraf"
if [ "$INSTALL_METHOD" = "homebrew" ]; then
  brew services start telegraf
else
  PLIST_TMP="${TMP_DIR}/com.jakerobb.telegraf.plist"
  sed "s|@@TELEGRAF_PREFIX@@|${TELEGRAF_PREFIX}|g" \
    "${SCRIPT_DIR}/com.jakerobb.telegraf.plist" > "$PLIST_TMP"
  # Catches a substitution gone wrong (e.g. a value containing a character
  # that broke the XML) before it becomes a much more cryptic launchctl
  # failure.
  plutil -lint "$PLIST_TMP"
  sudo cp "$PLIST_TMP" /Library/LaunchDaemons/com.jakerobb.telegraf.plist
  sudo chown root:wheel /Library/LaunchDaemons/com.jakerobb.telegraf.plist
  sudo chmod 644 /Library/LaunchDaemons/com.jakerobb.telegraf.plist
  # bootout first (ignoring failure) so a re-run after fixing something
  # doesn't just fail on "service already bootstrapped".
  sudo launchctl bootout system/com.jakerobb.telegraf 2>/dev/null || true
  if ! sudo launchctl bootstrap system /Library/LaunchDaemons/com.jakerobb.telegraf.plist; then
    echo "launchctl bootstrap failed. Most likely cause: a leftover copy of this daemon still loaded" >&2
    echo "from an earlier attempt (check: sudo launchctl print system/com.jakerobb.telegraf)." >&2
    exit 1
  fi
fi

echo
echo "==> Done. Check SigNoz (signoz.jakerobb.org) Metrics Explorer for host.name = ${NODE_HOST_NAME}."
if [ "$INSTALL_METHOD" = "manual" ]; then
  echo "    Logs:   ${TELEGRAF_PREFIX}/var/log/telegraf.log (rotates at 10MB, 5 archives)"
  echo "            ${TELEGRAF_PREFIX}/var/log/telegraf-launchd.log (crashes/startup output only)"
  echo "    Status: sudo launchctl print system/com.jakerobb.telegraf"
else
  echo "    Status: brew services info telegraf"
fi
