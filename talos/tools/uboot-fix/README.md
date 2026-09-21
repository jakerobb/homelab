# Pi 5 U-Boot firmware fix — custom installer tooling

Full background: [`talos/README.md`](../README.md), "Talos v1.14.1 upgrade
blocked by Pi5 EFI-variable firmware bug". Short version: the 3 Pi5 control
planes ship a U-Boot that doesn't support writable EFI variables, which
blocks every normal `talosctl upgrade`. The fix is a community `hive`-branch
U-Boot build, delivered by a custom `/bin/installer` that bypasses Talos's
own (blocked) EFI-variable-writing code entirely and just swaps the file
directly on the ESP.

Two images, both invoked via `talosctl upgrade -n <cp-ip> --image <tag>`
exactly like a real Talos image — `machined` doesn't know or care that
they're not:

- **`Dockerfile.dryrun`** (`installer-dryrun.sh`) — mounts the ESP
  **read-only**, verifies `config.txt`/`u-boot.bin` are present, prints the
  current `u-boot.bin` checksum, and always exits `1` (so `machined` reports
  "upgrade failed" and never reboots the node). Zero risk — run this first
  against any node before trusting the write version's partition-detection
  logic.
- **`Dockerfile.write`** (`installer-write.sh`) — the real fix. Mounts the
  ESP read-write, verifies the staged payload's hash *before* touching
  anything, backs up the original `u-boot.bin` on the same partition, swaps
  it in, verifies the final result, and only then exits `0` — which is what
  lets `machined`'s normal cordon/drain/reboot sequence proceed even though
  the Talos OS itself never changed.

## Before reusing this for a future Talos bump

Both scripts have two values baked in from the 2026-09-18 run — **update
both before rebuilding**:

- `NEW_HASH` in `installer-write.sh` — the expected sha256 of the patched
  `u-boot.bin`. Re-verify against whatever `hive`-branch release you're
  using; don't assume the old hash is still current.
- `BACKUP_NAME` in `installer-write.sh` — date-stamped
  (`u-boot.bin.orig-backup-20260918`) so a rerun can't silently clobber a
  prior backup. Bump the date.

## Usage (per node, one at a time — etcd quorum tolerates one down)

```bash
# 1. Build natively on rpi5-1 (arm64, matches the hardware)
docker build -f Dockerfile.dryrun -t ttl.sh/<name>-dryrun:24h .
docker build -f Dockerfile.write -t ttl.sh/<name>-write:24h .   # needs u-boot.bin alongside it (see main README for source/checksum)
docker push ttl.sh/<name>-dryrun:24h
docker push ttl.sh/<name>-write:24h

# 2. Fresh etcd snapshot, then dry-run to confirm partition detection
talosctl upgrade -n <cp-ip> --image ttl.sh/<name>-dryrun:24h   # expect exit 1, no reboot

# 3. The real write
talosctl upgrade -n <cp-ip> --image ttl.sh/<name>-write:24h    # exit 0, node reboots via normal machined sequence

# 4. Genuine PoE power cycle -- no software-triggered reboot reinitializes
#    U-Boot on this hardware, not even `talosctl reboot --mode powercycle`.

# 5. Then the real Talos version bump, using a combined image (see main
#    README's "Full sequence per node" section) -- NOT the stock tag,
#    or its overlay install step silently reverts u-boot.bin.
```
