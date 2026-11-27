#!/bin/sh
# Installs the talos-vm-kick restart helper and its passwordless-sudo rule on a Mac that runs a Talos VM under QEMU.
# Run as your normal user (sudo is used where needed): ./install.sh. Safe to re-run; it never restarts the VM.
set -eu
[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root." >&2; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="$(id -un)"
RECORD=/usr/local/share/homelab/talos-vm-kick.sudoers.sha256

sudo install -d -m 755 /usr/local/sbin /usr/local/share/homelab
sudo install -m 755 -o root -g wheel "$DIR/talos-vm-kick.sh" /usr/local/sbin/talos-vm-kick

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
sed "s/@USER@/$USER_NAME/g" "$DIR/talos-vm-kick.sudoers" > "$TMP"
sudo visudo -cf "$TMP" >/dev/null || { echo "sudoers rule failed validation; not installed." >&2; exit 1; }
sudo install -m 440 -o root -g wheel "$TMP" /etc/sudoers.d/talos-vm-kick

# /etc/sudoers.d is root-only, so host-deploy can't compare it with the repo. It compares this record instead.
shasum -a 256 "$DIR/talos-vm-kick.sudoers" | awk '{print $1}' | sudo tee "$RECORD" >/dev/null
sudo chmod 644 "$RECORD"
echo "Installed. Test (restarts the VM; drain the node first): sudo -n /usr/local/sbin/talos-vm-kick"
