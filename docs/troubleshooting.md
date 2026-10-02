# Troubleshooting

Problems that have happened before, how to recognize them, and the fix. Each
entry links to the full write-up. Commands run on rpi5-1 unless noted (see
[Getting access](access.md)).

## Where to start

1. **Is it the whole cluster or one app?** From rpi5-1:

```bash
kubectl get nodes
kubectl get pods -A | grep -v -E 'Running|Completed'
```

2. **ArgoCD** (<https://argocd.jakerobb.org>) shows every app's sync and
   health status. An app that's `Degraded` or failing to sync is usually the
   quickest pointer to the problem.
3. **Alerts** arrive on ntfy, topic `homelab-alerts`. **Logs** for any pod
   are searchable in SigNoz (<https://signoz.jakerobb.org>).

"All pods Running" doesn't always mean healthy. Several of the problems
below leave pods Running while they quietly fail.

## A node is NotReady

### talos-worker-mbp

This worker is a VM on the 2018 MacBook Pro, so check the Mac first:

- **The Mac's disk filled up.** QEMU pauses the VM, and UTM shows a
  disk-full dialog. Free space on the Mac (`ssh jakerobb@192.168.102.9`,
  then `df -h`), and resume the VM in UTM. The `MacHostDiskSpaceLow` alert
  warns below 40 GiB free.
- **It rebooted into the Talos installer.** If the install ISO is still
  attached as a CD drive and comes first in the boot order, the VM boots the
  installer, which halts because Talos is already installed. Remove the CD
  drive in UTM and boot again.
- **Images fail with `exec format error` afterwards.** A disk-full pause can
  corrupt containerd's image store. Wipe the node's EPHEMERAL partition. See
  [Recovering from a corrupted image store](utm-talos-worker.md#recovering-from-a-corrupted-image-store).

### A control-plane Pi

The cluster keeps working with one of the three down, and the API address
(`192.168.102.10`) moves to a healthy node. If a Pi won't come back, power
cycle it by cycling its PoE port on the rack switch in UniFi. See
[Talos cluster](../talos/README.md) for the Pi-specific issues found so far
(NIC watchdog, U-Boot firmware).

After any reboot or power cycle, check that the node really restarted
(`talosctl -n <ip> read /proc/uptime`), not just that its API answers.

## Apps fail after Proxmox or HexOS went down

HexOS provides every persistent volume. If it goes away (a Proxmox reboot
takes it down too), volumes on the workers that stayed up can turn read-only
and stay that way after HexOS comes back. Some pods crash-loop, but others
(ClickHouse, SigNoz) stay Running and silently fail every write.

Look for aborted journals, then delete each affected pod, one at a time:

```bash
talosctl -n 192.168.102.34 dmesg | grep -E "EXT4-fs.*(aborted journal|read-only)"
```

Full procedure: [After a reboot: read-only iSCSI volumes](proxmox-os-updates.md#after-a-reboot-read-only-iscsi-volumes).

## A `*.jakerobb.org` app won't load

- **Only works at home.** The DNS records point at a LAN address, so these
  apps don't load from outside. A work VPN that overrides DNS can break `.lan`
  and `jakerobb.org` lookups too; try the IP directly.
- **The name doesn't resolve on the LAN, but `dig @1.1.1.1` works.** Unbound
  on rpi5-1 drops public names that resolve to private addresses unless the
  domain is allowed. `jakerobb.org` is already allowed in
  `docker-compose/unbound/custom.conf.d/local.conf`, so check that Unbound is
  running.
- **Authelia says access is denied, or the page never loads.** Every hostname
  needs its own `access_control` rule in
  `argocd/apps/authelia/application.yaml`. Apps using the Gateway's
  `ExternalAuth` filter also need their namespace in
  `argocd/apps/authelia/referencegrant.yaml`, or Cilium won't set up the
  route at all. See [Adding an app](adding-an-app.md#4-auth-authelia-and-which-pattern).
- **A freshly migrated app still points at the old server.** external-dns
  won't overwrite a Cloudflare record it didn't create, such as one left over
  from Caddy. Delete the old record in Cloudflare by hand. See
  [Adding an app](adding-an-app.md#3-exposure-gateway-api-not-ingress).

## ntfy notifications arrive with no message

The title shows but the body never loads. So far the server has always had
the full message, and the phone couldn't reach it:

- **The phone is on the wrong network.** A new phone joined the Guest VLAN,
  which can't reach the servers. Move it to the Trusted VLAN in UniFi.
- **ntfy was restarting.** Heavy storage load during big deployments has
  failed ntfy's health check and restarted it. Check for restarts with
  `kubectl -n ntfy get pods`.

## The UniFi controller is slow or unresponsive

The UniFi Network app on the Cloud Gateway Fiber hung on 2026-09-18 from
Java garbage collection. The fix locks its memory at 640 MB in
`/etc/default/unifi` on the gateway. A daily email from rpi5-1 reports on it,
and an hourly check emails if it gets bad.

**A full UniFi OS upgrade wipes that fix and the report's SSH key.** After
one, reapply both. See [UniFi GC report](unifi-gc-report.md).

## The UPS Tower is stuck "Adopting" in UniFi

A known UniFi UPS firmware bug. The outlets keep supplying power the whole
time; only management is lost. What fixed it last time (2026-09-20): factory
reset, adopt again, then upgrade to firmware 1.6.4 or later (no recurrence
through 2026-10-01). Discussion:
[UniFi UPS 1.6.4 release thread](https://community.ui.com/releases/UniFi-UPS-1-6-4/3170942e-7d0e-48b6-81c0-a8bb5d3edd78).

## An ArgoCD app won't sync

- ArgoCD retries a failed sync 10 times with backoff. It won't try the same
  commit again after that, so press **Sync** in the UI or push a new commit.
- If the error mentions a missing CRD, install CRDs by hand. See
  [CRDs stay out of ArgoCD's hands](adding-an-app.md#7-crds-stay-out-of-argocds-hands).
- If the error is about a Secret, check that the ExternalSecret has synced:
  `kubectl get externalsecret -A`.

## These docs didn't update after a merge

The site rebuilds within 5 minutes of a merge to `main`. If a build fails,
the site keeps serving the previous one. The builder's log says what broke:

```bash
kubectl -n docs logs deploy/docs -c builder
```

CI runs the same build on every PR, so a failure here usually means
something outside the repo changed, like GitHub being unreachable.

## Worst case: the cluster is gone

etcd is backed up daily to rpi5-1 and Backblaze B2, and the restore has
been tested against the live cluster. See [etcd backups](etcd-backup.md#restore).
