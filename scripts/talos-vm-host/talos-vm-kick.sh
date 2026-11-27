#!/bin/sh
# Restarts this Mac's Talos VM daemon (com.jakerobb.talos-worker-*), and SIGKILLs QEMU if it won't exit. Takes no
# arguments. Installed as /usr/local/sbin/talos-vm-kick by install.sh in this directory, which also adds a sudoers
# rule letting the installing user run exactly this file, with no arguments, without a password.
#
# Why it exists: after a guest reboot QEMU has hung under Hypervisor.framework (2026-11-25), ignoring SIGTERM, so
# `launchctl kickstart -k` blocked and only `kill -9` helped. This does both steps, touching only the VM's own QEMU.
#
# Host-agnostic: it finds the daemon and QEMU by pattern, so the Mac Studio and the MacBook Pro share it. A restart
# powers the node off, so cordon and drain it first.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
GRACE=110   # seconds QEMU gets to exit gracefully; keep under the daemon's ExitTimeOut (120) so we SIGKILL before launchd relaunches
[ $# -eq 0 ] || { echo "talos-vm-kick takes no arguments" >&2; exit 64; }
[ "$(id -u)" -eq 0 ] || { echo "talos-vm-kick must run as root (via sudo)" >&2; exit 77; }

LABELS=$(find /Library/LaunchDaemons -maxdepth 1 -name 'com.jakerobb.talos-worker-*.plist' 2>/dev/null | sed 's|.*/||; s|\.plist$||')
[ "$(printf '%s\n' "$LABELS" | grep -c .)" -eq 1 ] || { echo "expected exactly one com.jakerobb.talos-worker-* daemon, found: ${LABELS:-none}" >&2; exit 1; }
TARGET="system/$LABELS"

vm_pids() { pgrep -u root -f 'qemu-system-.*/talos-vm/disk\.qcow2'; }
# Prints those of the space-separated pids in $1 that are still running.
alive() { for p in $1; do kill -0 "$p" 2>/dev/null && echo "$p"; done; }

BEFORE=$(vm_pids | tr '\n' ' ')
echo "restarting $TARGET (QEMU: ${BEFORE:-not running})"
launchctl kickstart -k "$TARGET" &
KICK=$!

i=0
while [ -n "$BEFORE" ] && [ -n "$(alive "$BEFORE")" ] && [ "$i" -lt "$GRACE" ]; do sleep 1; i=$((i + 1)); done
STUCK=$([ -n "$BEFORE" ] && alive "$BEFORE" | tr '\n' ' ')
if [ -n "$STUCK" ]; then
  echo "QEMU ($STUCK) still running after ${GRACE}s; sending SIGKILL"
  for p in $STUCK; do kill -9 "$p"; done
fi
i=0; while kill -0 "$KICK" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
kill -0 "$KICK" 2>/dev/null && kill "$KICK"

i=0; AFTER=""
while [ -z "$AFTER" ] && [ "$i" -lt 120 ]; do sleep 1; i=$((i + 1)); AFTER=$(vm_pids | tr '\n' ' '); done
[ -n "$AFTER" ] || { echo "launchd hasn't restarted QEMU after 120s; check: launchctl print $TARGET" >&2; exit 1; }
echo "QEMU restarted: $AFTER"
