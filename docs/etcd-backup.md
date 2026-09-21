# etcd / control-plane backup

Protects the Talos control plane's own state (etcd) — the source of truth
for every live Kubernetes object (Secrets, RBAC, current resource state),
not just what's committed to this repo. Without this, losing enough of the
3-node control plane (or etcd corruption) means rebuilding from scratch: the
Talos node identity/PKI is already recoverable from
[`talos/secrets.sops.yaml`](../talos/secrets.sops.yaml), and ArgoCD's
app-of-apps will re-reconcile everything it manages once the cluster is back
— but anything created dynamically in-cluster and never pushed to git
(ArgoCD's own admin secret, Authelia's session/OIDC signing keys,
cert-manager-issued TLS certs) is not recovered by either of those.

## How it works

`scripts/etcd-snapshot-backup.sh` runs `talosctl etcd snapshot` against the
control plane using the talosconfig already on rpi5-1
(`~/talos/homelab/talosconfig`), storing snapshots locally under
`~/backups/etcd` on that same host and pruning anything older than 30 days.

**Shipped off-box to B2 as of 2026-09-21.** After the local snapshot + prune
step, the script runs `b2 sync` to mirror `~/backups/etcd` up to a
dedicated, private B2 bucket (`jakerobb-homelab-etcd-backups`) — separate
from the temporary `p3plus-archive-temp` bucket used for the HexOS restore,
since that one is short-lived and this one isn't. The bucket has its own
30-day lifecycle rule (`daysFromUploadingToHiding: 30`,
`daysFromHidingToDeleting: 1`) mirroring `KEEP_DAYS` above, so nothing in
the script needs to manage remote deletion.

Auth is a B2 application key scoped to *only* this bucket
(`listBuckets,listFiles,readFiles,writeFiles` — no `deleteFiles`, since the
lifecycle rule handles expiry server-side) — a leak of this key can't touch
the P3 Plus bucket or anything else in the account. The key is
SOPS-encrypted at [`scripts/secrets/b2-etcd-backup.sops.yaml`](../scripts/secrets/b2-etcd-backup.sops.yaml)
(new `.sops.yaml` rule for `scripts/secrets/*.sops.(yaml|json|env)`, same
age recipient as everything else) and deployed to rpi5-1 at
`~/bin/secrets/b2-etcd-backup.sops.yaml` (`chmod 600`) — not committed to
git as plaintext, obviously. Unlike `msmtprc`/`nut-upsd-password` (which
decrypt once to a persistent config file), this one is injected at run time
via `sops exec-env "$B2_SECRETS" "$B2_BIN sync ..."`, so the decrypted
`B2_APPLICATION_KEY`/`B2_APPLICATION_KEY_ID` only ever exist in that one
command's environment, never written to disk.

The B2 CLI itself is installed on rpi5-1 via `pipx install b2` (v5.0.0,
`~/.local/bin/b2`) — **not** the `backblaze-b2` apt package, which is a
stale v1.3.8 build with old command syntax (`authorize-account`/
`create-bucket`/`create-key` instead of `account authorize`/`bucket
create`/`key create`). Worth noting for troubleshooting: that old package
was initially suspected as the cause of a persistent `unauthorized` error
during setup, but switching to the current CLI hit the exact same error —
the real cause turned out to be a stale copy of the B2 master application
key's secret (regenerating the master key in the B2 console fixed it
immediately). The apt package was still worth replacing regardless, just
not because it was the culprit here.

The script itself is versioned here, but it's **deployed manually** to
rpi5-1 (not something Terraform manages) and run via cron there.

## Restore

**Confirmed working 2026-09-21** — a full live disaster-recovery drill
against the production cluster itself (not a sandbox), including
downloading the snapshot back *from* B2 rather than reusing the local file,
to actually validate the offsite copy rather than just its presence.

### Procedure

Official Sidero procedure (verified current against the v1.9, v1.14, and
`latest` docs — identical across all three as of 2026-09-21:
[source](https://docs.siderolabs.com/talos/latest/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery)):

```bash
# 1. Take a fresh snapshot right before recovering, to minimize drift
#    between what's restored and what was actually running.
~/bin/etcd-snapshot-backup.sh

# 2. Wipe etcd on EVERY control-plane node — not just one. This is not
#    optional (see "Why this doesn't split-brain" below): if any node keeps
#    its old etcd data, it (or a majority of surviving nodes) will just keep
#    running as the old cluster, oblivious to or actively conflicting with
#    whatever gets bootstrapped elsewhere. --graceful=false skips Talos's
#    normal cordon/drain/etcd-leave dance, which is what makes this an
#    actual disaster simulation rather than a clean member replacement.
talosctl -n <cp-node-IP> reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL
# (repeat for all control-plane nodes — safe to run in parallel/backgrounded,
#  see the exact loop used in the 2026-09-21 test below)

# 3. Wait until every control-plane node's etcd service shows `Preparing`
#    (talosctl service etcd -n <IP>) — this is Talos's documented
#    prerequisite state before recovery. Reaching it takes under a minute;
#    you do NOT need to poll dozens of times to "confirm stability" the way
#    the 2026-09-21 test did out of caution — see timeline below.

# 4. Bootstrap ONE node — any one, it does not need to have been the
#    pre-wipe leader — from the snapshot. Never run this against more than
#    one node (see below for why).
talosctl -n <any-one-cp-node-IP> bootstrap --recover-from=<snapshot-path>
# add --recover-skip-hash-check only if the snapshot was copied out of the
# etcd data directory directly rather than via `talosctl etcd snapshot`

# 5. Verify: `talosctl etcd members` shows all members back as full voters
#    (not stuck as learners), `kubectl get nodes` shows everyone Ready,
#    ArgoCD apps are Synced/Healthy, and PVC-backed workloads (Authelia is
#    the one that matters today) have reattached to their existing
#    hexos-iscsi volumes.
```

### Why this doesn't split-brain

Wiping EPHEMERAL erases *all* Raft state on that node, including cluster
membership — a wiped node isn't "a node that lost an election," it isn't a
member of any Raft group at all anymore, and can't vote or contest
leadership in one. `bootstrap --recover-from` creates a **brand-new**
single-member cluster (fresh cluster ID and member ID, not a resurrection
of the old one) seeded with the snapshot's key-value data. The other wiped
nodes, having zero local state, get pointed at this new cluster via Talos's
own discovery and join it the standard way any new member joins an existing
Raft group: first as a non-voting **learner** (receiving a snapshot
transfer, unable to affect quorum while catching up), then promoted to a
full voting member once caught up. There is only ever one cluster, growing
from 1 to 3 members — never two competing ones, so there's nothing to
"fight."

The actual hazard this depends on avoiding: wiping fewer than all
control-plane nodes, or running `bootstrap --recover-from` against more
than one. Either of those would leave (or create) a second real cluster
identity that could genuinely conflict with the one being recovered — which
is exactly why step 2 above is not optional and step 4 is a single node.

Confirmed empirically in the 2026-09-21 test: the pre-wipe leader was
`talos-cp-3` (`etcd status` showed leader ID `8a4fa5d9faa6ab2e`, which
`etcd members` mapped to cp-3), but the recovery was bootstrapped on
`talos-cp-1` instead — a non-leader — with no issue whatsoever. Which node
you pick genuinely doesn't matter.

### What actually happened (2026-09-21 test)

| Elapsed | Event |
|---|---|
| T+0:00 | Fresh snapshot taken + synced to B2 (5s) |
| T+0:11 | Snapshot downloaded back *from* B2; SHA-256 matched the local original |
| T+0:35 | `reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL` fired at all 3 CP nodes in parallel |
| T+2:12 | All 3 resets returned (68–96s each); nodes rebooting |
| T+2:20 | All 3 nodes back up, etcd in `Preparing` |
| T+5:56 | `bootstrap --recover-from` issued (using the B2-downloaded copy) — reported the exact same hash/revision the snapshot was taken with |
| T+6:16 | etcd quorum reformed, 3/3 full voting members |
| T+6:26 | `kubectl` responding again, all 5 nodes Ready |
| T+7:33–8:50 | Image re-pulls across all 3 CP nodes (Cilium, CoreDNS, node-exporter, etc. — EPHEMERAL wipe also clears the local containerd image cache, kubelet state, and CNI state, not just etcd) |
| T+7:37–8:08 | Brief ~30s NotReady blip on the 3 CP nodes, coincident with the image pulls; self-healed |
| T+9:48 | Full health confirmed: all pods healthy (2 unrelated pre-existing `CrashLoopBackOff` pods aside — `cert-manager-cainjector`, `kube-state-metrics`, both already broken for 2+ days before this test), Authelia's PVC reattached cleanly to the same `hexos-iscsi` volume, all 15 ArgoCD apps Synced/Healthy |

**~3.5 minutes of that total (the `Preparing`-state wait) was self-imposed
caution** — polling repeatedly to confirm stability before bootstrapping,
which the procedure doesn't actually require. A real incident, bootstrapped
as soon as `Preparing` first appears, should land closer to **~2 minutes**
from reset to a responding API server, with cluster-wide fault tolerance
(3/3 members) restored within seconds after that.

### Testing cadence

**Quarterly**, plus an extra drill after any Talos version upgrade that
touches control-plane nodes (the recovery procedure is version-sensitive
enough — see the Pi5 EFI firmware saga in
[`talos/README.md`](../talos/README.md) — that it's worth reconfirming
rather than assuming). A backup that's never restored isn't really a
backup — this drill is what turns "we have snapshots" into "we know they
work." Next one due **~2026-12-21**.

## Deploying the script + cron job (on rpi5-1)

```bash
# Copy scripts/etcd-snapshot-backup.sh from this repo to ~/bin/ on rpi5-1:
mkdir -p ~/bin
# (scp or paste the file content in)
chmod 700 ~/bin/etcd-snapshot-backup.sh

# Copy the SOPS-encrypted B2 key alongside it (safe to scp as-is, it's ciphertext):
mkdir -p ~/bin/secrets && chmod 700 ~/bin/secrets
# scp scripts/secrets/b2-etcd-backup.sops.yaml jakerobb@rpi5-1.lan:~/bin/secrets/
chmod 600 ~/bin/secrets/b2-etcd-backup.sops.yaml

# Test it once by hand before trusting it to cron
~/bin/etcd-snapshot-backup.sh
ls -la ~/backups/etcd/

# Install the daily cron job (03:15 — offset from the Proxmox config backup
# at 03:00 on a different host, so there's no real reason they'd collide,
# just kept them visually distinct). MAILTO must already be set in this
# crontab (see email-alerts.md) and stdout must be redirected away, so cron
# only mails on a real failure (stderr) rather than on every successful run.
crontab -l 2>/dev/null | { cat; echo "15 3 * * * \$HOME/bin/etcd-snapshot-backup.sh > /dev/null"; } | crontab -
```
