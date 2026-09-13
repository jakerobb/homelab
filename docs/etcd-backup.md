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

Deliberately local-only for now rather than also shipped off-box (e.g. to
Backblaze B2, the pattern used for the P3 Plus backup) — cloud copy is a
known follow-up, tracked in [`TODO.md`](../TODO.md), not an oversight.

The script itself is versioned here, but it's **deployed manually** to
rpi5-1 (not something Terraform manages) and run via cron there.

## Restore

Not yet exercised. Restoring means bootstrapping a fresh etcd cluster from
the snapshot (`talosctl bootstrap --recover-from=<snapshot> -n <one CP
node>`), which fully replaces existing etcd state on that node. Test this
somewhere non-production before relying on it in a real incident.

## Deploying the script + cron job (on rpi5-1)

```bash
# Copy scripts/etcd-snapshot-backup.sh from this repo to ~/bin/ on rpi5-1:
mkdir -p ~/bin
# (scp or paste the file content in)
chmod 700 ~/bin/etcd-snapshot-backup.sh

# Test it once by hand before trusting it to cron
~/bin/etcd-snapshot-backup.sh
ls -la ~/backups/etcd/

# Install the daily cron job (03:15 — offset from the Proxmox config backup
# at 03:00 on a different host, so there's no real reason they'd collide,
# just kept them visually distinct)
crontab -l 2>/dev/null | { cat; echo "15 3 * * * \$HOME/bin/etcd-snapshot-backup.sh"; } | crontab -
```
