# Talos cluster config

## Current state

_(as of 2026-09-21)_

- **Talos v1.14.1** on all 5 nodes (control planes and both workers), **Kubernetes v1.37.0**.
  Both already fully upgraded — see "Talos control-plane upgrade" and "Talos v1.14.1 upgrade
  blocked by Pi5 EFI-variable firmware bug" below for how the control planes got there.
- 3-node control plane on Raspberry Pi 5 (4GB), already installed and working.
  Control planes use a **custom installer image**, `ghcr.io/yama6a/talos-raspberry-pi5:v1.14.1-1`,
  since stock Talos doesn't support the Pi5 directly (no NVMe-capable U-Boot in the official
  `rpi_5` overlay — see [siderolabs/sbc-raspberrypi#96](https://github.com/siderolabs/sbc-raspberrypi/issues/96)).
  Previously `ghcr.io/talos-rpi5/installer` (`talos-rpi5/talos-builder`) — switched 2026-09-17
  because that project is inactive (last release 2025-11-08, an 8-month-old PR bumping to v1.12.1
  with zero comments). `yama6a/talos-raspberry-pi5` is a maintained downstream that reuses the
  same `talos-rpi5/sbc-raspberrypi5` overlay and `talos-rpi5/u-boot` fork for the actual NVMe-boot
  fix (credited, not reinvented) while tracking current Talos releases itself — see its own
  [FUTURE_WORK.md](https://github.com/yama6a/talos-raspberry-pi5/blob/main/FUTURE_WORK.md): the
  goal is to retire itself once that U-Boot patch lands upstream.
  **`v1.14.1-1`'s plain tag is not what's actually running on these 3 nodes** — it still ships the
  broken (unpatched) `u-boot.bin` (confirmed 2026-09-21: no EFI-variable fix in the fork's commits
  since), so it's only safe as a *version/architecture reference*, never as a real `talosctl
  upgrade --image` target. See "Talos v1.14.1 upgrade blocked by Pi5 EFI-variable firmware bug"
  and "Machine-config install.image drift" below before touching any control-plane install image.
  **Any amd64 worker (e.g. the MS-A2 Talos VM) must use a Factory schematic image
  (`factory.talos.dev/installer/<schematic-id>:<version>`) — `ghcr.io/siderolabs/installer` doesn't
  exist for recent releases, and the rpi5 installer image must never be reused for amd64 hardware.**
  Currently `factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.14.1`
  (the `iscsi-tools` + `util-linux-tools` schematic — see "iscsi-tools extension" below), confirmed
  against both workers' live `get extensions` output and correctly persisted in machine config as
  of 2026-09-21.
- CNI: Cilium — version tracked in
  [`../argocd/apps/cilium/application.yaml`](../argocd/apps/cilium/application.yaml)'s
  `targetRevision` (see "Cilium: version management" below for how upgrades work), with
  `kubeProxyReplacement` enabled, full eBPF host routing
  (`bpf.masquerade: true`, `Host: BPF` — not the `Legacy`/iptables fallback),
  and **L2 announcements** for LoadBalancer IPs (see `cilium/values.yaml`).
- LoadBalancer IP pool: `192.168.102.128/26` (`.128-.191`), announced via
  `cilium/l2-announcement-policy.yaml` — the pool just responds to ARP
  directly, so it looks like a normal host on the LAN to everything else. Only
  non-control-plane nodes announce (via `node-role.kubernetes.io/control-plane
  DoesNotExist`, not a manual label — new workers need no extra labeling to
  participate).

### Why L2 announcements instead of BGP

BGP was the original design (peering Cilium with the UCG Fiber, `localASN
65001` / UCG `65000`) and mostly worked — sessions established, routes
exchanged correctly — but external LoadBalancer traffic was **broken the
entire time** (confirmed on a service that had been "up" for 67 days with
this bug the whole time; BGP was configured but never actually validated
end-to-end until 2026-09-13). Symptom: TCP handshake completed, then zero
data ever flowed in either direction afterward. A synchronized packet capture
(client, both worker nodes, `cilium monitor`) showed the true pattern: only
the *first* packet of a new flow toward the LB IP got through in each
direction — every packet after that, client→server, silently vanished, while
the server kept retransmitting its SYN-ACK. That's the signature of a
router-side flow-acceleration/fast-path bug (caches the first packet's
forwarding decision, then the cached decision goes stale for the rest of the
flow) — not anything on the Cilium/Talos side. Ruled out, with actual
evidence, before concluding this: BGP session state, FRR config correctness,
ECMP path count (tested both `maximum-paths 3` and `1`), control-plane nodes
participating as peers, Cilium's `Legacy` vs `BPF` host-routing mode, and BPF
masquerade — none of it moved the needle. No fix found in Ubiquiti's or
Cilium's community trackers for this specific pattern on the UCG Fiber, so we
pivoted to L2 announcements, which avoids router-side dynamic routing
entirely. The UCG's BGP peering config (uploaded via Policy Engine > Dynamic
Routing) should be removed there since nothing uses it anymore.

## Where the secrets actually live

The Talos secrets bundle (`secrets.yaml`), the rendered `controlplane.yaml` /
`worker.yaml` machine configs, and `talosconfig` all live on the jump box
**rpi5-1.lan** (`192.168.102.2`, user `jakerobb`) at `~/talos/homelab`. `talosctl`
itself is also installed there. Treat that host as read-only unless a change is
explicitly requested.

These files are **intentionally not committed here** — `controlplane.yaml` /
`worker.yaml` embed real key material (cluster CA, join tokens), not just config.
The `.gitignore` blocks them by filename as a safety net.

## Secrets: SOPS + age (decided 2026-09-08)

The Talos secrets bundle is committed here as `secrets.sops.yaml`, encrypted with
[SOPS](https://github.com/getsops/sops) using an [age](https://github.com/FiloSottile/age)
key (rule in `.sops.yaml` at repo root). This repo is now self-contained for the
secrets bundle — no more hard dependency on rpi5-1 surviving.

- **Age public key:** `age1nqvgqc45f5j9y9ch0lyccdefeazs26xkp732rujp23nqeqmdjefshruqs8`
- **Age private key:** lives at `~/.config/sops/age/keys.txt` on Jake's Mac, and is
  also duplicated in 1Password for durability. Optionally also worth putting in a
  `SOPS_AGE_KEY` GitHub Actions repo secret once a self-hosted runner exists, so CI
  can decrypt too.
- To decrypt/use: `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt` then
  `sops --decrypt talos/secrets.sops.yaml`.

**Scope note:** this brings the *secrets bundle* into the repo; the rendered
per-node machine configs (`controlplane.yaml`/`worker.yaml`) are still
generated directly with `talosctl` on demand (using this decrypted secrets
bundle) rather than committed — see "Talos config: fully reproducible from
committed inputs" below for the exact, now-verified command and why that's
safe. Still not using [Talhelper](https://github.com/budimanjojo/talhelper)'s
declarative `talconfig.yaml` — with every setting in the rendered config now
accounted for by a committed patch (same section below), there's no remaining
correctness reason to adopt it; it'd be a workflow-ergonomics change at this
point, not a reproducibility one.

## Talos config: fully reproducible from committed inputs (2026-09-22)

Confirmed and closed the gap the "Scope note" above used to flag: every
non-secret setting in the live `controlplane.yaml`/`worker.yaml` on rpi5-1
is now accounted for by a committed patch, and a fresh render from
`secrets.sops.yaml` + `talosctl gen config` + `talos/patches/*` reproduces
the live files exactly (modulo node identity and a couple of harmless,
explicitly-noted quirks below). `rpi5-1`'s copies are no longer the only
record of how this cluster is actually configured — they're a regenerable
build artifact again.

**Method** (redoing this after a future config change, or just re-verifying):

1. On rpi5-1, render a patch-free baseline from the real secrets bundle,
   reusing its CA/tokens rather than generating new ones:
   ```bash
   cd ~/talos/homelab
   talosctl gen config homelab https://192.168.102.11:6443 \
     --with-secrets secrets.yaml \
     --install-disk /dev/nvme0n1 \
     --install-image ghcr.io/talos-rpi5/installer:v1.11.5 \
     --additional-sans 192.168.102.11,192.168.102.12,192.168.102.13 \
     --kubernetes-version 1.37.0 \
     --talos-version v1.11 \
     --output-dir /tmp/gen-config-diff
   ```
   `--talos-version v1.11` matters: without it, current `talosctl` (v1.14.1)
   emits the newer multi-document config format (settings like KubePrism,
   the kubelet config, and pod/service subnets split into their own
   `apiVersion: v1alpha1 / kind: Kube*Config` documents) instead of the
   single legacy `v1alpha1 Config` document this cluster was originally
   bootstrapped with and that `talosctl patch machineconfig` targets —
   comparing the two formats directly produces spurious diffs on
   every field, not real gaps. Pin `--kubernetes-version` to the cluster's
   actual running version (`kubectl get nodes`) too, or every component
   image tag (`kube-apiserver`, `kubelet`, etc.) shows as a false diff.
   The cluster name/endpoint/disk/image flags above are the original
   bootstrap invocation (recovered from rpi5-1's shell history) — don't
   guess at them from scratch.
2. Apply every committed patch (all of `talos/patches/control-plane/*.yaml`
   except the per-node hostname patches `cp1.yaml`/`cp2.yaml`/`cp3.yaml`,
   plus `talos/patches/discovery-registry-fix.yaml` and
   `talos/patches/kubelet-log-limits.yaml`, for `controlplane.yaml`; just
   `kubelet-log-limits.yaml` for `worker.yaml` — the per-worker hostname
   *and* iSCSI kernel-module/extraMounts patches
   (`talos/patches/workers/worker-{1,2}.yaml`) are deliberately per-node,
   same as the control-plane hostname patches, and not folded into the
   shared template) with `talosctl machineconfig patch <base> -p @<patch>
   ... -o <out>` (offline, no cluster access needed).
3. Diff **structurally** (parsed YAML, not text) against each live node's
   actual machine config — pull that directly from the node rather than
   trusting the on-disk file, since it can drift (see below):
   `talosctl -e <ip> -n <ip> get machineconfig -o yaml`, extract `.spec`.
   Redact anything secret-shaped (keys, certs, tokens, long base64/PEM
   blobs) before ever printing a diff — several fields here (`certSANs`,
   the discovery `clusterSecret`, etc.) are real key material.

**What this found:** one real, previously-undocumented gap —
`cluster.network.cni.name: none` and `cluster.proxy.disabled: true` were
live on all 3 control planes (Cilium fully replaces both Flannel and
kube-proxy — see "Ingress: Gateway API" and the Cilium values below) but
existed in no committed patch anywhere. Added
[`talos/patches/control-plane/disable-flannel-kubeproxy.yaml`](patches/control-plane/disable-flannel-kubeproxy.yaml)
to close it. Verified as a true no-op before trusting it: `talosctl patch
machineconfig` reported **"Apply was skipped: no changes detected"** on
all 3 control planes (cp1, then cp2, then cp3, checking `kubectl get
nodes` stayed `Ready` and the VIP stayed reachable after each) — not just
"didn't break anything," but confirmation the live setting and the new
patch are byte-identical. Everything else the original investigation
flagged (KubePrism, `disableManifestsDirectory`, pod/service subnets, the
base kubelet config, the disk selector) turned out to already be either a
`talosctl` v1.14.1 default or covered by an existing patch — genuinely
nothing else to add.

**Also found and fixed:** the on-disk `controlplane.yaml`/`worker.yaml`
templates on rpi5-1 had themselves drifted from what several existing
patches (`vip.yaml` in particular — the whole `machine.network` block was
missing) claimed to have been folded into them, most likely from a plain
`talosctl gen config` re-run during the 2026-09-21 install-image-drift
investigation above that overwrote the manually-patched copies. They also
carried a dead `machine.nodeLabels.bgp-speaker: true` — a leftover from
the abandoned BGP approach (see "Why L2 announcements instead of BGP")
that was never actually applied to any live node (confirmed via each
node's real `machineconfig`). Regenerated both files via the method above
(baseline + every non-per-node patch) and replaced the on-disk copies;
backups of the pre-regeneration files are at
`~/talos/backup-2026-09-22/*.bak` on rpi5-1. Per-node hostnames and the
worker iSCSI settings are intentionally *not* in these shared templates —
apply `cp{1,2,3}.yaml` / `worker-{1,2}.yaml` on top when actually
provisioning a specific node, matching how they're applied live today.

**Known, harmless residual diffs** (don't re-investigate these — traced to
their root cause already, both cosmetic):
- **cp1** carries an explicit `cluster.discovery.registries.service.disabled:
  false` where a from-scratch render omits the key (same effective value,
  Talos's default) — cp1 never got `discovery-registry-fix.yaml` applied
  (it didn't need the `kubernetes` half of the fix — see "Kubernetes
  discovery registry" above), so it never picked up the redundant explicit
  `service.disabled: false` either.
- **cp2/cp3** have one fewer duplicate `192.168.102.11` entry in
  `apiServer.certSANs` than a fresh render produces — harmless (duplicate
  SAN entries don't affect TLS validity either way), just an artifact of
  exactly how cp1's original bootstrap `--additional-sans` differed from
  whatever regenerated cp2/cp3's config later.
- **Workers':** `machine.install.image` still (correctly) differs — see
  "Machine-config install.image drift" above for why that field is
  deliberately never persisted to a committed patch for either node type.

## Ingress: Gateway API (decided and deployed 2026-09-13)

Using [Gateway API](https://gateway-api.sigs.k8s.io/) instead of a classic
`Ingress`/ingress-nginx-style controller — `kubernetes/ingress-nginx` is
headed for retirement (maintenance mode now, targeted retirement ~early
2026) with Gateway API as the sanctioned successor, and Cilium already ships
its own Gateway API implementation (embedded Envoy) so it's a Helm flag, not
a second controller/data-plane to operate. The Gateway's LoadBalancer Service
reuses the existing LB pool and L2 announcement policy exactly like any other
`Service` — confirmed working (`curl` to the Gateway IP gets a real `404` from
`server: envoy`, not a connection failure).

**CRDs: experimental channel, not standard** — Cilium 1.19.5's operator hard
-requires the `TLSRoute` CRD to serve `gateway.networking.k8s.io/v1alpha2`
(`failed to setup field indexer... no matches for kind "TLSRoute" in version
"v1alpha2"`, fatal at startup). The *standard* channel's `TLSRoute` CRD no
longer serves that version; only the *experimental* channel does — even
though we're not using TLSRoute today. So:
```
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/experimental-install.yaml
```
Two gotchas applying that one file:
- It's large enough that plain `kubectl apply` blows the
  `last-applied-configuration` annotation's size limit on `BackendTLSPolicy`
  — use `kubectl apply --server-side --force-conflicts` instead.
- The bundle ships its own `safe-upgrades` `ValidatingAdmissionPolicy`, which
  **blocks switching an existing CRD from standard to experimental channel**
  — and since that policy is itself one of the objects in the file, applying
  the whole file in one shot recreates the policy partway through and then
  blocks the rest of the same apply. Fix: apply everything **except** the
  `ValidatingAdmissionPolicy`/`ValidatingAdmissionPolicyBinding` docs first
  (gets every CRD switched to experimental), then apply the full file again
  (now a no-op for the CRDs, restores the safe-upgrades policy for next time).

Apply order after that:

1. CRDs above, before touching Cilium — the operator needs them present at
   startup.
2. `helm upgrade cilium cilium/cilium --version <currently-deployed chart
   version> -n kube-system -f cilium/values.yaml` (as `cilium-values.yaml` on
   rpi5-1 — check `helm list -n kube-system` for the version actually
   running rather than assuming latest; this change didn't bump the chart).
   Cilium's operator then auto-creates the `cilium` GatewayClass — it isn't
   committed here.
3. **Restart, don't just wait** — same failure mode as the `bpf.masquerade`
   rollout: `enable-envoy-config` isn't hot-reloaded, so both `cilium-operator`
   and the `cilium` agent DaemonSet keep running with the old value until
   restarted. Symptoms if you skip this: `cilium-operator` crashloops with
   the TLSRoute error above until it picks up the CRDs on a restart, and even
   after that, `GatewayClass`/`Gateway` show `Accepted`/`Programmed: True`
   but requests get TCP `RST` (`service-no-backend-response: reject`, since
   the agent never actually started Envoy) — check agent logs for `module=
   agent.controlplane.config-drift-checker key=enable-envoy-config
   actual=false` to confirm.  `kubectl -n kube-system rollout restart
   deployment/cilium-operator` then `rollout restart ds/cilium`, verifying
   pods come back healthy after each before moving on.
4. `kubectl apply -f cilium/gateway.yaml` — creates the `gateway-system`
   namespace and a `Gateway` with a plain HTTP (port 80) listener open to
   `HTTPRoute`s from any namespace.

**Deliberately deferred:** TLS/443 (needs cert-manager or a manual cert, plus
a decision on an internal CA vs public DNS-01), and any actual `HTTPRoute`s
— those get added per-app in that app's own namespace as apps move onto the
cluster. ArgoCD's own UI is the likely first one.

**Gotcha found and fixed (2026-09-15):** `argocd.jakerobb.org` stopped
resolving to a working connection from the LAN — DNS was correct, and the
Gateway/Envoy/Authelia chain was confirmed healthy from *inside* the cluster
(`curl` to the Service ClusterIP worked fine), but nothing outside the
cluster could reach the LB IP at all. Root cause, confirmed via `tcpdump`:
`cilium/l2-announcement-policy.yaml` hardcoded `interfaces: [^eth0$]`, but
the MS-A2 Talos worker VMs' real NIC is `ens18` (standard Proxmox
virtio-net naming) — nothing ever matched, so Cilium's L2 responder held the
leader lease and reported "Running" while silently never answering ARP for
the LB IP. No evidence this ever worked correctly for the current worker
VMs; it likely only looked validated because the original "confirmed
working" `curl` test after the initial Gateway API cutover was against the
Service directly, not tested via the external LB IP from the LAN. Fixed by
removing the `interfaces` restriction entirely — an omitted `interfaces`
field announces over all of a node's interfaces (Cilium's documented
default), which is also more robust than hardcoding a NIC name given future
physical workers may use yet another naming scheme. Same "not hot-reloaded"
gotcha as `enable-envoy-config` above: applying the policy change alone
wasn't enough, needed `kubectl -n kube-system rollout restart ds/cilium`
before the L2 responder actually picked it up.

## Cilium: version management

Cilium's ongoing lifecycle is an ArgoCD `Application` —
[`argocd/apps/cilium/application.yaml`](../argocd/apps/cilium/application.yaml) —
sourcing the chart from `helm.cilium.io` with values coming from this same
`cilium/values.yaml` (via a multi-source `$values` ref, so there's one copy
of the config either way). **Never run a manual `helm upgrade cilium`** —
bump `targetRevision` and/or edit `cilium/values.yaml`, then Sync from
ArgoCD.

Deliberately **manual sync policy** (no `automated:` block), unlike every
other app under `argocd/apps/` — the only app where that's true. Cilium is
the CNI: a bad auto-sync has cluster-wide blast radius (breaks networking
for every pod, including ArgoCD's own, leaving nothing able to auto-revert
it), and this cluster has had two *silent* Cilium failures (the BGP outage
and the L2-announcement interface regex bug, both above) where the
DaemonSet reported `Running`/Healthy the whole time traffic was actually
broken — exactly what ArgoCD's resource-status health checks would also
have missed. Treat syncing as a conscious, one-at-a-time action: Sync, then
run [`cilium/validate.sh`](cilium/validate.sh) from rpi5-1 (or anywhere on
the LAN) before trusting it — it curls every LoadBalancer IP and HTTPRoute
hostname from outside the cluster and checks each agent's actual datapath
mode, instead of just asking Kubernetes whether the pods are Ready.

**Before bumping `targetRevision` to a new minor version:** diff the
chart's default `values.yaml` between the current and target versions first
— catches upstream schema changes that might silently affect something
`cilium/values.yaml` actually sets, before they land live. Also worth
running the official `cilium-preflight` release first on Pi-class hardware,
so image pulls happen ahead of the real rollout rather than during it — one
gotcha: `helm install cilium-preflight ... --set preflight.enabled=true`
fails with an ownership conflict on the auto-created `GatewayClass`
(`cilium-preflight` can't own a resource the real `cilium` release already
owns) unless you also pass `--set gatewayAPI.enabled=false` for the
preflight release specifically — the preflight DaemonSet doesn't need
Gateway API to pre-pull images anyway. See [`../todo/FUTURE.md`](../todo/FUTURE.md)
for the still-open `upgradeCompatibility` flag cleanup left over from the
1.19→1.20 migration.

Cilium was originally adopted into ArgoCD from resources that already
existed from earlier manual `helm upgrade` CLI runs, not created by Argo —
the first Sync just relabels them under Argo's tracking (Argo's Helm source
renders and applies manifests directly; it doesn't drive the `helm` CLI or
touch a release object). That left an old, plain `cilium` Helm release
object stale/orphaned in `kube-system` — harmless to ignore, nothing reads
it going forward, but worth knowing about if it's ever noticed and looks
alarming.

## Talos control-plane upgrade: talos-rpi5 → yama6a fork (2026-09-17)

Moving all 3 control planes from `ghcr.io/talos-rpi5/installer:v1.11.5` to
`ghcr.io/yama6a/talos-raspberry-pi5:v1.13.9-9` (see "Current state" above for
why). Command, run once per node from rpi5-1:

```bash
talosctl upgrade --nodes <cp-ip> --image ghcr.io/yama6a/talos-raspberry-pi5:v1.13.9-9
```

**No canary node, and that's correct, not a corner cut.** Every Pi5 in this
cluster is a control plane — the workers are amd64 Proxmox VMs, a different
installer entirely, unaffected by this image. There's no spare Pi5 to test
on first. That's fine: the entire reason this cluster runs 3 control planes
instead of 1 is to make exactly this kind of direct, in-place test on a
live quorum member a non-event — 2-of-3 etcd quorum tolerates a node
misbehaving or going fully dark mid-upgrade without the cluster going down.
Go straight at a control plane, one at a time, and let quorum be the safety
net instead of routing around real hardware with a disposable node that
doesn't exist here.

Sequence: upgrade one control plane, verify it fully, then the next, then
the last. Per node:
1. `talosctl -n <cp-ip> version` — expect the new tag.
2. `talosctl -n <cp-ip> get extensions` — expect `iscsi-tools`,
   `util-linux-tools` (not `gvisor` — dropped by the new image; confirmed
   2026-09-17 that nothing in the cluster references a `gvisor`
   `RuntimeClass`, so this costs nothing).
3. `kubectl get nodes` — the node back to `Ready`.
4. A democratic-csi/hexos-iscsi-backed pod on that node still mounts and
   writes — the new image adds `iscsi-tools` rather than removing anything
   storage-related, but confirm rather than assume.
5. External curl of the LB IP — this cluster has a history of *silent*
   Cilium failures surviving a Healthy status (see "Cilium upgrade" above),
   and a Talos upgrade touches the networking stack too.

**If a node doesn't come back**, that's the known U-Boot failure mode (see
[yama6a/talos-raspberry-pi5's upstream.md](https://github.com/yama6a/talos-raspberry-pi5/blob/main/docs/upstream.md)):
reflash it from the previous release's raw image, rejoin it to the cluster,
and `talosctl etcd remove-member` the stale entry from the two survivors
first if the dead node was still listed. Recoverable, just physical — not
a re-run-the-command fix.

## Talos v1.14.1 upgrade blocked by Pi5 EFI-variable firmware bug (2026-09-18)

**Resolved 2026-09-18 — all 3 Pi5 control planes are on v1.14.1.** The
working fix (a custom `/bin/installer` image, fully remote, no drive-pull
needed) is documented below under "What actually works." Kept the dead
ends documented too so they're not re-investigated next time.

Attempting `talosctl upgrade --image ghcr.io/yama6a/talos-raspberry-pi5:v1.14.1-1`
on any of the 3 Pi5 control planes fails at the bootloader step:

```
updating EFI variables
failed to install bootloader: failed to create efivarfs reader/writer: invalid argument
```

**Root cause:** the stock Raspberry Pi 5 U-Boot doesn't advertise EFI
`SetVariable` support at runtime, so Linux mounts `/sys/firmware/efi/efivars`
read-only (confirmed via `talosctl -n <cp-ip> read /proc/mounts | grep
efivar` → `ro`). systemd-boot's boot-entry bookkeeping
(`LoaderEntryDefault`/`LoaderEntrySelected`/`LoaderEntryOneShot`) is entirely
EFI-variable-based on this platform — there's no config-file fallback in
play — so any upgrade that needs to point the bootloader at a new UKI hits
this. **The attempt fails cleanly before rebooting the node** — no reboot is
attempted, so a failed attempt leaves the node exactly as it was (confirmed
twice on `talos-cp-1`, still `v1.13.9`, `Ready`, etcd quorum untouched both
times).

This is a different U-Boot problem than the NVMe/PCIe one this fork
(`yama6a/talos-raspberry-pi5`) exists to fix — it's not documented in that
project's `docs/upstream.md`, and as of this writing the fork's builds don't
carry a fix for it either.

**The fix exists, just not upstream yet:**
[excavador/u-boot-rpi5](https://github.com/excavador/u-boot-rpi5/releases/tag/v2025.04-rpi5-3-hive.2),
`hive` branch, built with `CONFIG_EFI_RT_VOLATILE_STORE` (published
2026-09-06 — very recent). Ships as a bare `u-boot.bin`:

```bash
curl -fsSLO https://github.com/excavador/u-boot-rpi5/releases/download/v2025.04-rpi5-3-hive.2/u-boot.bin
curl -fsSLO https://github.com/excavador/u-boot-rpi5/releases/download/v2025.04-rpi5-3-hive.2/SHA256SUMS
sha256sum -c SHA256SUMS   # 9aa3c44ab42d181dd3ecf1aa2759f2ee702e019d590110fd41c4a415de311265  u-boot.bin
```

### Where U-Boot actually lives

It's a plain file, `/boot/EFI/u-boot.bin`, on the same FAT32 ESP as
`config.txt`, the DTB/overlays, systemd-boot, and the Talos UKI — not a
separate SPI/EEPROM chip. Confirmed by exporting the real installer image's
filesystem:

```bash
cid=$(docker create ghcr.io/yama6a/talos-raspberry-pi5:v1.14.1-1)
docker export $cid | tar -tvf - | grep u-boot
# overlay/artifacts/arm64/u-boot/rpi5/u-boot.bin
```

Talos's `rpi_5` overlay installer (`siderolabs/sbc-raspberrypi`,
`installers/rpi_5/src/main.go`) copies that path to `/boot/EFI/u-boot.bin`
on **every** install/upgrade, alongside the DTB and `config.txt` — it's not
a one-time, install-only artifact.

### Dead ends, checked against Talos's actual source before giving up on them

Before finding the working approach below, traced several alternatives all
the way to Talos's source code (`siderolabs/talos`) rather than guessing:

- **A same-version "firmware-only" `talosctl upgrade`** (custom image, `FROM
  ghcr.io/yama6a/talos-raspberry-pi5:v1.13.9` with just `u-boot.bin`
  replaced) — fails identically. The "updating EFI variables" step runs
  *before* the overlay copies the new `u-boot.bin` onto disk, and that
  write goes through whatever firmware is *already active this boot
  session*, not whatever's embedded in the target image.
- **PXE/netboot maintenance-mode fresh install** — `efivars.go`'s
  `CreateBootEntry` (called by every sd-boot install *and* upgrade) still
  calls `WriteVariable` even with no prior `BootOrder`
  (`errors.Is(err, fs.ErrNotExist)` just starts from an empty `BootOrder{}`
  and proceeds to write). A from-scratch install hits the identical error.
  Also moot in practice: this fork doesn't publish a netboot-compatible
  artifact at all, only a raw `dd`-able disk image.
- **GRUB instead of sd-boot** — not selectable for this hardware.
  `bootloader.go`'s `NewAuto()` hard-codes sd-boot for any UEFI-booting
  system, and the Pi 5 boots UEFI via U-Boot.
- **Downgrade, then re-upgrade with a patched image** — same call path as
  any other upgrade; version direction/delta is irrelevant.

These all share one root cause: the write depends on whether the
*currently active* firmware supports EFI `SetVariable` — never on how
Talos was invoked or what version is the target. None of them make the
currently-running (broken) firmware capable of the write.

### What actually works: a custom `/bin/installer` that swaps the file directly, no physical access needed

The piece that unlocks a fully remote fix: `machined` doesn't care what's
inside the image passed to `talosctl upgrade --image` — it just execs the
literal path `/bin/installer` inside whatever container that image
describes, and only checks its exit code. Nothing requires that binary to
be Sidero's real installer. So instead of asking Talos's own code to write
the file (which hits the EFI-variable requirement), ship a minimal
container whose `/bin/installer` mounts the ESP directly and copies the
file itself — no EFI variable ever touched:

```sh
#!/bin/sh
set -eu
PART=/dev/nvme0n1p1   # EFI partition, confirmed partition 1 on these nodes
MNT=/mnt/esp
NEW_HASH="9aa3c44ab42d181dd3ecf1aa2759f2ee702e019d590110fd41c4a415de311265"

mount -t vfat -o rw "$PART" "$MNT"
[ -f "$MNT/config.txt" ] && [ -f "$MNT/u-boot.bin" ] || { echo "wrong partition?" >&2; umount "$MNT"; exit 1; }
cp /payload/u-boot.bin "$MNT/u-boot.bin.new"
[ "$(sha256sum "$MNT/u-boot.bin.new" | awk '{print $1}')" = "$NEW_HASH" ] || { echo "payload mismatch" >&2; rm -f "$MNT/u-boot.bin.new"; umount "$MNT"; exit 1; }
cp "$MNT/u-boot.bin" "$MNT/u-boot.bin.orig-backup-20260918"
mv "$MNT/u-boot.bin.new" "$MNT/u-boot.bin"
sync
[ "$(sha256sum "$MNT/u-boot.bin" | awk '{print $1}')" = "$NEW_HASH" ] || { echo "post-write verify failed" >&2; umount "$MNT"; exit 1; }
umount "$MNT"
exit 0
```

```dockerfile
FROM alpine:3.20
COPY installer-write.sh /bin/installer
COPY u-boot.bin /payload/u-boot.bin
RUN chmod +x /bin/installer
ENTRYPOINT ["/bin/installer"]
```

**The actual runnable scripts (this one plus its read-only dry-run sibling)
are committed at [`talos/tools/uboot-fix/`](tools/uboot-fix/)** — that's the
canonical copy to reuse for the next Talos bump, not this inline snippet.
Update `NEW_HASH` and `BACKUP_NAME` there first; see that directory's
`README.md`.

Safety properties worth keeping if reusing this pattern: verify the staged
payload's hash *before* touching the original, keep a backup of the
original on the same partition, verify the final write, and abort (exit
non-zero, leaving the node untouched) on any surprise. Same privileges as
the real installer apply automatically — `machined` sets up the container's
mount/device access identically regardless of image, confirmed by this
script successfully doing real block-device mounts. **Always dry-run first**
(a read-only variant that mounts `-o ro`, prints checksums, and
deliberately exits 1) against a real node before trusting a write-mode
image — costs nothing (exit 1 = "upgrade failed", no reboot, node
untouched) and confirms partition-detection logic before it matters.

`talosctl upgrade -n <cp-ip> --image <that image>` runs this, reports the
exit code, and — because it thinks an upgrade happened — proceeds through
its normal cordon/drain/reboot sequence even though the Talos OS itself
never changed. That reboot is what's needed to load the new firmware.

**One more wrinkle: no software-triggered reboot actually reloads U-Boot on
this hardware**, not even `talosctl upgrade`'s default kexec-avoidance
setting, nor `talosctl reboot --mode powercycle` (its help text says
"bypasses kexec," but empirically it still didn't reinitialize firmware —
confirmed via `efivarfs` staying `ro` and via `read /proc/uptime` proving a
reboot really happened). Only a genuine power interruption
(PoE port cycle) does. After power-cycling: **checking
`/proc/mounts` via `talosctl read` is misleading** — it reflects a stale,
early-boot mount taken from `machined`'s own root namespace and stays `ro`
even after the fix is fully working. The real test is a fresh mount from
within a *container* (any `talosctl upgrade`-invoked one, same as the real
installer uses) — that one correctly reflects current firmware capability.
Confirmed definitively by just re-running the real upgrade afterward and
watching "updating EFI variables" succeed for the first time.

**Also discovered along the way:** the stale variable-store file
`ubootefi.var` (persisted pseudo-NVRAM, since this board has no real EFI
NVRAM hardware) turned out *not* to be the blocker — it was a red herring
investigated in parallel; the power-cycle requirement was the actual fix.
No need to touch `ubootefi.var` for this to work.

### Full sequence per node

1. Build + dry-run-test + write the patched `u-boot.bin` remotely, per
   above. Take an `etcd-snapshot-backup.sh` run first.
2. Power-cycle the node's PoE port for real (software reboots don't count).
3. Run the *real* upgrade with a combined image:
   ```dockerfile
   FROM ghcr.io/yama6a/talos-raspberry-pi5:v1.14.1-1
   COPY u-boot.bin /overlay/artifacts/arm64/u-boot/rpi5/u-boot.bin
   ```
   **Don't use the plain `v1.14.1-1` tag** — its overlay install step would
   silently overwrite the just-fixed `u-boot.bin` with the original broken
   one again (the overlay unconditionally re-copies whatever's embedded in
   whichever image performs the install). Verified end-to-end on `talos-cp-1`
   on 2026-09-18: "updating EFI variables" succeeded, boot entry created,
   `installation of v1.14.1 complete`, full reboot, node Ready, extensions
   (`iscsi-tools`, `util-linux-tools`) intact.
4. Verify per the checklist in "Talos control-plane upgrade" above
   (version, extensions, node Ready, a democratic-csi pod, external LB
   curl). Expect a brief window of cluster-wide pod churn right after
   (Cilium re-establishing on other nodes, `cilium-operator`'s standby
   replica occasionally crash-looping if it hit a flaky-API window during
   the reboot — harmless, `kubectl delete pod` for a clean retry if it
   doesn't self-heal).
5. **Do not patch `.machine.install.image` to the plain tag afterward** —
   see "Machine-config install.image drift" below for why that field can't
   safely be made to look current for these nodes. Leave it stale/unfixed;
   don't paper over it with a value that would be worse if ever used.

Build once on rpi5-1 (arm64, matches the target hardware — no
cross-compilation), push to `ttl.sh` (anonymous, no auth needed; these
nodes have no registry pull-credential configured, so any image used here
must stay public regardless of where it's hosted).

**This patch has to be reapplied on every future Talos OS bump for these 3
Pi5 nodes** — check whether `yama6a/talos-raspberry-pi5` (or upstream
`siderolabs/sbc-raspberrypi`) has merged the `hive`-branch fix itself before
assuming a plain upgrade will work; until it has, always build the same
`FROM <target-tag>` + `u-boot.bin` swap rather than using the tag directly.

The 2 amd64 MS-A2 workers are unaffected (standard UEFI via Proxmox/OVMF, no
`efivarfs` restriction) — they upgraded to v1.14.1 cleanly using the stock
Image Factory schematic image (see the worker-upgrade notes; correct
reference is `factory.talos.dev/installer/<schematic-id>:v1.14.1`, not
`ghcr.io/siderolabs/installer:v1.14.1`, which doesn't exist for recent
releases).

## Machine-config install.image drift found and partially fixed (2026-09-21)

A scheduled cluster health check found all 5 nodes' persisted machine config
(`.machine.install.image`) still pointed at the **original, abandoned**
`ghcr.io/talos-rpi5/installer:v1.11.5` — stale on every node despite the
control-plane fork switch (2026-09-17) and the v1.14.1 upgrades (both above)
having actually happened. `talosctl upgrade --image <x>` does not rewrite
this field as a side effect; only an explicit `talosctl patch machineconfig`
(or a full `apply-config`) does. Harmless day-to-day (nothing currently
running reads this field), but it matters for whatever install action next
consumes it — a wipe/reinstall, or `talosctl apply-config` from a
regenerated config.

**Workers: fixed.** Patched both to
`factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.14.1`
(the confirmed-live `iscsi-tools` + `util-linux-tools` schematic — see
"iscsi-tools extension" above) via `talosctl patch machineconfig`, which
applies without a reboot. Verified both nodes stayed `Ready` throughout.

**Control planes: deliberately left as-is, not a shortcut.** There is no
durable value safe to put here. Setting it to the plain
`ghcr.io/yama6a/talos-raspberry-pi5:v1.14.1-1` tag would look correct but
is exactly the image the section above says never to use directly — it
would silently reintroduce the broken `u-boot.bin` the moment anything
actually installs from it, since the real fix only exists in a one-off
combined image (built fresh, pushed to ephemeral `ttl.sh`, already expired).
Persisting a plausible-looking-but-landmined value felt worse than leaving
the obviously-stale one. If a control plane ever needs a real reinstall,
follow "Full sequence per node" above from scratch — don't trust this field,
and don't skip the U-Boot patch step because the config looks current.

## Kubernetes discovery registry: leave the `kubernetes` one disabled (found/fixed 2026-09-18)

All 3 control planes were repeatedly logging (harmless-looking, but noisy)
warnings:

```
kubernetes registry node watch error ... nodes is forbidden: User
"system:node:talos-cp-X" cannot list resource "nodes" in API group "" at
the cluster scope: node 'talos-cp-X' cannot read all nodes, only its own
Node object
```

**Root cause, upstream:** Kubernetes 1.32+ tightened node RBAC so a
kubelet's own credentials can no longer `list`/`watch` all `Node` objects —
this broke Talos's legacy "Kubernetes discovery registry" (which relies on
exactly that) across the wider Talos community, not just here. Traced to
`internal/app/machined/pkg/controllers/cluster/kubernetes_pull.go` in
`siderolabs/talos`: the `KubernetesPullController` only skips its
watch/list attempt when `cluster.discovery.registries.kubernetes.disabled`
is `true`; otherwise it retries forever, 5-strikes-then-rebuild-client, and
fails identically every cycle.

**Root cause, this cluster:** `talosctl get discoveryconfig` showed cp-1
already correctly configured (`kubernetes` registry disabled, `service`
registry — the working `discovery.talos.dev`-backed one — enabled), but
cp-2 and cp-3 had it backwards (`kubernetes` enabled, `service` disabled)
— not just noisy, but meaning those two nodes had **zero working cluster
discovery** the whole time. The shared `controlplane.yaml` template on
rpi5-1 also had the broken setting, so this wasn't a fluke — cp-1 must have
been individually patched at some point without the fix being propagated
back to the template or the other two nodes.

**Fix applied** (JSON6902 patch, no reboot needed) — committed at
[`talos/patches/discovery-registry-fix.yaml`](patches/discovery-registry-fix.yaml):

```yaml
- op: replace
  path: /cluster/discovery/registries/kubernetes/disabled
  value: true
- op: replace
  path: /cluster/discovery/registries/service/disabled
  value: false
```

```bash
talosctl patch machineconfig -n <cp-ip> -p @discovery-registry-fix.yaml --mode=no-reboot
```

Applied to cp-2 and cp-3 (cp-1 was already correct); verified via
`talosctl get discoveryconfig` showing `registryKubernetesEnabled: false` /
`registryServiceEnabled: true` on all 3, and the warning no longer
recurring in `dmesg` past the in-flight retry counter it was already on.
Also fixed the same setting in the shared `~/talos/homelab/controlplane.yaml`
template on rpi5-1, so a future from-scratch control-plane node won't
reintroduce this.

## Workload isolation (Talos 1.14 feature): not enabled

Considered enabling `SecurityProfileConfig`'s `workloadIsolation: true` (runs
CRI/kubelet/all pods in a dedicated PID+mount namespace that Talos can tear
down and relaunch without a full reboot if it dies). Not enabled — found a
confirmed blocker, not just a theoretical one:

- [siderolabs/talos#14374](https://github.com/siderolabs/talos/issues/14374):
  a startup race between CRI and `sandboxd` causes every node to
  restart-loop (`sandbox namespace not available yet`, kubelet down,
  `NotReady`) for 1–3 minutes on **every boot** with isolation enabled.
  Fixed upstream 2026-09-16 — one day *after* our current `v1.14.1` was
  published (2026-09-15). We're on the affected version, and no `v1.14.2`
  exists yet to upgrade past it (checked — `v1.14.1` is still latest as of
  2026-09-18).
- Softer, unverified risk: `node-exporter` runs `hostPID`/`hostNetwork` and
  mounts `/proc`/`/sys`/`/` from the host to read real host metrics — under
  isolation its process-level metrics may describe the sandbox instead of
  the true host unless specific collector exclusions are configured, which
  ours aren't today.

democratic-csi is *not* at risk from this feature when it does get enabled
— it's a real CSI driver (attach/mount happens in its own privileged node
pod), not the in-tree iSCSI volume plugin that workload isolation is known
to break.

Tracked in [`../todo/FUTURE.md`](../todo/FUTURE.md) — blocked on a Talos
release shipping with the CRI/sandboxd race (#14374) actually fixed; check
the changelog for that issue specifically before assuming a later patch
release includes it.

## Container log size limits (added 2026-09-18)

Kubelet's `containerLogMaxSize`/`containerLogMaxFiles` were previously
unset, relying on kubelet's implicit defaults (`10Mi` × `5` files = 50Mi
ceiling per container). Made that explicit rather than implicit, via
`machine.kubelet.extraConfig` on all 5 nodes — committed at
[`talos/patches/kubelet-log-limits.yaml`](patches/kubelet-log-limits.yaml):

```yaml
- op: add
  path: /machine/kubelet/extraConfig
  value:
    containerLogMaxSize: 10Mi
    containerLogMaxFiles: 5
```

```bash
talosctl patch machineconfig -n <node-ip> -p @kubelet-log-limits.yaml --mode=no-reboot
```

Applied live to all 5 nodes (no reboot needed, no pod disruption). Also
updated in the shared `~/talos/homelab/controlplane.yaml` and `worker.yaml`
templates on rpi5-1 so a future from-scratch node gets this by default
rather than falling back to kubelet's implicit default.

**Why 50Mi/container is comfortable headroom, not a tight budget:** even
the worker with the most containers scheduled to it (30, vs. 64GB disk)
only implies ~1.5GB worst case — under 2.3% of that node's capacity, and
the real worst case is smaller still since several of those are DaemonSets
(`cilium`, `cilium-envoy`, `democratic-csi-node`, `node-exporter`) already
pinned one-per-node and unable to pile up further even if a node went
down. RAM (4GB/worker) is the actual binding constraint on how many
containers these boxes can run, not disk.

## Control-plane VIP (added 2026-09-18)

kubectl/OpenLens previously pointed at a single control-plane IP
(`192.168.102.11`), so any restart of that one node dropped the connection
until manually pointed at another CP. Added a Talos-native Virtual (shared)
IP — `192.168.102.10` — that floats across all 3 control planes via
gratuitous ARP, so any client only ever needs one endpoint. This is Talos's
own built-in VIP feature (`machine.network.interfaces[].vip`), not the
third-party kube-vip project — it works at the OS/network layer below
Kubernetes, so it doesn't depend on the API server already being up (unlike
kube-vip's typical leader-election-via-API-server approach).

Patch (committed at
[`talos/patches/control-plane/vip.yaml`](patches/control-plane/vip.yaml),
same content applied to all 3 CPs since these are cluster-wide settings, not
per-node):

```yaml
machine:
  network:
    interfaces:
      - interface: end0
        dhcp: true
        vip:
          ip: 192.168.102.10
  certSANs:
    - 192.168.102.10
cluster:
  controlPlane:
    endpoint: https://192.168.102.10:6443
  apiServer:
    certSANs:
      - 192.168.102.10
```

```bash
talosctl patch machineconfig -n <cp-ip> -p @vip.yaml --mode=no-reboot
```

Applied live to all 3 control planes (no reboot needed). Also updated in the
shared `~/talos/homelab/controlplane.yaml` template on rpi5-1.
`~/.kube/homelab.yaml`'s `server:` now points at the VIP instead of `.11`
directly.

**Gotcha: `talosctl patch machineconfig` appends to list fields (`certSANs`)
instead of replacing them** — patching with the full existing list plus the
new entry produces duplicates; patch with only the new entry and Talos
merges it in.

**Gotcha: `.10` collided with an existing device** — the first attempt
picked `192.168.102.10` without checking the LAN for existing users, and it
turned out to already be leased to a Zigbee coordinator (a
locally-administered/randomized MAC, so nothing in this repo's IP
conventions would have flagged it). The symptom was confusing: ICMP ping to
the VIP worked fine (the other device answered), but every TCP connection
was refused, and `cilium monitor` on the VIP-holding node showed *zero*
trace of the inbound SYN — proof the packets weren't even reaching the Pi.
Moved the Zigbee coordinator to `192.168.102.4` (see
[`docker-compose/zigbee2mqtt/configuration.sops.yaml`](../docker-compose/zigbee2mqtt/configuration.sops.yaml),
`serial.port`) before re-attempting, and confirmed via `ip neigh` that
`.10` resolved to the control plane's real MAC before proceeding.

Verified failover works: `talosctl -n 192.168.102.11 reboot` while watching
`talosctl -n <ip> get addresses` on the other two control planes — the VIP
moved to `talos-cp-2` within the outage window, and `kubectl` against
`https://192.168.102.10:6443` never dropped.

## Pi 5 NIC watchdog mitigation (added 2026-09-18)

Deployed as a `DaemonSet` on the 3 control-plane Pis
([`patches/control-plane/nic-watchdog-mitigation.yaml`](patches/control-plane/nic-watchdog-mitigation.yaml)),
looping every 30s to disable TSO/GSO offload and EEE (Energy Efficient
Ethernet) on `end0` via `ethtool`:

```
ethtool -K end0 tso off gso off
ethtool --set-eee end0 eee off
```

This is a known Raspberry Pi 5 onboard-NIC issue — the offload/EEE
combination can trigger a kernel `NETDEV WATCHDOG: end0: transmit queue
timed out` hang. Disabling both is the standard community mitigation.

**Why it has to keep running rather than being applied once:** these are
runtime `ethtool` settings, not persistent config — the kernel/driver
resets them to their (broken) defaults on reboot and on link
renegotiation/reset, and Talos being immutable has no native machine-config
knob or `udev`/`ethtool.conf`-equivalent hook to reapply them once at boot.
A `DaemonSet` that continuously re-asserts the settings is the practical
workaround given that constraint. If Talos ever exposes NIC offload/EEE
settings natively, this can likely be replaced with a proper machine-config
patch.

Not yet recorded: the specific symptom (e.g. an actual `NETDEV WATCHDOG` log
line) that prompted adding this, and whether it's been confirmed to prevent
recurrence since. Worth capturing here if/when that's dug up.

## Layout

- `cilium/` — Cilium Helm values, LB/L2-announcement CRDs, and the Gateway
  API `Gateway` (ingress), applied to the existing cluster.
- `patches/control-plane/` — Talos config patches for the existing 3 Pi
  control-plane nodes: per-node hostname patches (`cp1.yaml`/`cp2.yaml`/
  `cp3.yaml`) plus shared patches applied identically to all 3
  (`vip.yaml`, `oidc.yaml`, `metrics-bind-address.yaml`,
  `disable-flannel-kubeproxy.yaml`; `node-tuning-namespace.yaml`/
  `nic-watchdog-mitigation.yaml` are plain Kubernetes manifests applied via
  `kubectl`, not Talos machine-config patches).
- `patches/workers/` — per-node patches for the two MS-A2 worker VMs
  (hostname plus the iSCSI kernel-module/extraMounts settings — see
  "iscsi-tools extension" below).
- `discovery-registry-fix.yaml`, `kubelet-log-limits.yaml` — shared
  Talos machine-config patches applied to all 5 nodes (control planes and
  workers alike).

## MS-A2 workers: decided values (2026-09-11)

Two workers, not one — with only 3 tainted control-plane Pis and a single
worker, upgrading that one worker would leave the cluster with zero
schedulable capacity in the meantime. Two workers (still both VMs on the same
physical MS-A2 for now) means one can be cordoned/upgraded while the other
keeps serving. Naming is deliberately decoupled from "msa2" — more physical
machines are coming later, and a worker's name shouldn't imply which box it
happens to run on today.

IP addressing convention on `192.168.102.0/24` (decided 2026-09-11): `.21-.29`
reserved for physical hosts, `.31+` for VMs — keeps the two cleanly separated
as more of each show up.

| Hostname | IP | MAC (fixed in Terraform) |
|---|---|---|
| `talos-worker-1` | `192.168.102.31` | `02:00:00:00:00:31` |
| `talos-worker-2` | `192.168.102.32` | `02:00:00:00:00:32` |

Both need a DHCP reservation on the UCG (matching the fixed MAC above).

Each: 4 vCPU, 4GB RAM. (Proxmox's `cores` is a vCPU count, not a physical-core
reservation — the host scheduler spreads vCPU threads across all 32 logical
threads/16 physical cores of the 8945HX as needed, so 8 vCPUs total across
both workers leaves comfortable headroom.)

- **Image source:** Talos doesn't publish a plain qcow2 on GitHub releases anymore —
  VM images are built on demand via [Image Factory](https://factory.talos.dev).
  For v1.11.5 with no customizations (the stock/non-Pi5 installer):
  ```
  https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.11.5/nocloud-amd64.qcow2
  ```
  Consumed by the `proxmox_download_file.talos_worker_image` resource in
  `terraform/proxmox/images.tf`, imported into both workers' disks.

## iscsi-tools extension (added 2026-09-15)

Both workers now run a schematic that adds the `siderolabs/iscsi-tools`
system extension, needed for democratic-csi's TrueNAS iSCSI driver to mount
volumes off HexOS. Generated via Image Factory:

```
curl -X POST --data-binary @- https://factory.talos.dev/schematics <<'EOF'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
EOF
```

Schematic ID: `c9078f9419961640c712a8bf2bb9174933dfcf1da383fd8ea2b7dc21493f8bac`.

Applied to both existing workers **in place** via `talosctl upgrade
--nodes <ip> --image factory.talos.dev/installer/c9078f9419961640c712a8bf2bb9174933dfcf1da383fd8ea2b7dc21493f8bac:v1.11.5
--wait` — no VM rebuild needed, Talos swaps the installed image and reboots.
Talos handles cordon/drain automatically as part of the upgrade sequence.
`terraform/proxmox/images.tf` is updated to the same schematic so a
from-scratch worker rebuild matches what's actually running.

Verify with `talosctl -n <worker-ip> get extensions` — expect an
`iscsi-tools` entry alongside the `schematic` entry matching the ID above.

**Schematic ID changed with the v1.14.1 upgrade** — both workers now report
schematic `613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245`
(confirmed 2026-09-21 via `get extensions` on both), which also picked up
`util-linux-tools` alongside `iscsi-tools`; current reference is
`factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.14.1`.
Unlike the control planes, workers have no firmware landmine, so **after any
future worker upgrade, always confirm `talosctl -n <worker-ip> get
machineconfig -o yaml` shows this same `factory.talos.dev/installer/...`
value under `.machine.install.image`** (matching whatever schematic/version
was actually just installed) — `talosctl upgrade --image <x>` does not
rewrite that field on its own, so it silently drifted from `v1.11.5` all the
way through the v1.14.1 bump without anyone noticing until a scheduled
health check caught it (see "Machine-config install.image drift" above). If
it's stale, `talosctl patch machineconfig -n <worker-ip> -p
'[{"op":"replace","path":"/machine/install/image","value":"<correct
factory.talos.dev URL>"}]'` fixes it without a reboot.

## Additional worker: talos-worker-mbp (added 2026-09-22)

A third worker, built from an idle 2018 15" MacBook Pro (32GB RAM, on the
Server VLAN via a Plugable TBT3-UDV dock) running Talos in a UTM VM —
deliberately temporary, a stopgap until a Mac Studio (96GB RAM) joins as a
worker in ~November 2026. Hosts [SigNoz](../argocd/apps/signoz/) for cluster
observability; its persistent storage is entirely on `hexos-iscsi`
specifically so this node stays disposable — retiring it later is just
cordon/drain, no data migration.

**Deliberate exception to the "naming decoupled from hardware" rule** (see
"MS-A2 workers: decided values" above): named `talos-worker-mbp`, not
`talos-worker-3`. That rule exists so a worker's name doesn't imply which box
it runs on *long-term* — doesn't apply here since this node is explicitly
short-lived and hardware-identified on purpose. The Mac Studio's worker,
when it arrives, should get a normal decoupled `talos-worker-N` name instead,
since it isn't a stopgap.

`192.168.102.34` (next free `.31+` slot), MAC `02:00:00:00:00:34`, same
`iscsi-tools`+`util-linux-tools` schematic and version as the Proxmox
workers (see "iscsi-tools extension" above) — same command to check for
drift later: `talosctl -n 192.168.102.34 get machineconfig -o yaml`.

Not Terraform-managed (no Proxmox involved — this is a real physical Mac, out
of `terraform/proxmox/`'s scope) — provisioned by hand per
[`docs/utm-talos-worker.md`](../docs/utm-talos-worker.md), written generically
enough to reuse for the Mac Studio.

**Gotchas found provisioning this node (both fixed, worth knowing for the
Mac Studio's turn):**
- **The Factory `nocloud-amd64.qcow2` image doesn't work for a plain
  UTM/QEMU import the way it does for the Proxmox workers.** Booting it
  directly gets stuck forever at `downloading config {platform: nocloud}` —
  `apid`'s maintenance service never starts (`service[apid](Waiting): Waiting
  for config to be ready`), because the `nocloud` platform variant expects a
  real NoCloud metadata source (cidata ISO or network service) and doesn't
  fall back to interactive maintenance mode the way a bare-metal boot does.
  Fix: boot from the Factory **`metal-amd64.iso`** instead (same
  schematic/version) as a CD-ROM, with the target qcow2 still attached as the
  real boot disk — `metal` platform goes straight into interactive
  maintenance mode, `talosctl apply-config --insecure` installs onto the
  qcow2 disk normally, and the ISO can be detached after.
- **The shared `~/talos/homelab/worker.yaml` template on rpi5-1 had a stale
  `install.image`** (`ghcr.io/talos-rpi5/installer:v1.11.5`, an arm64 Pi5
  image, never updated when the Proxmox workers moved to the Factory
  schematic image) — caught by generating this node's config from that
  template and comparing against the live Proxmox workers' actual
  `install.image` before trusting it. Fixed directly on rpi5-1 (not
  committed — same as the rest of `~/talos/homelab/`, see "Where the secrets
  actually live" above). **`install.disk` was already correct as-is
  (`/dev/nvme0n1`)** and deliberately *not* changed to this node's
  `/dev/sda` — that field is genuinely hypervisor-specific (UTM/QEMU's
  imported disk shows up via SATA/AHCI emulation, not virtio-blk-as-NVMe like
  Proxmox), so it stays a per-node patch override
  ([`patches/workers/worker-mbp.yaml`](patches/workers/worker-mbp.yaml)),
  same pattern as the hostname/iSCSI overrides every worker patch already
  carries.
- The Factory qcow2's default disk size is a few GB, same as the Proxmox
  workers' image before Terraform's `size = 64` grows it on import — UTM
  doesn't grow it automatically, so it needed a manual resize to 64GB before
  installing (see the runbook).

## kube-apiserver OIDC trust for Authelia (added 2026-09-21)

Headlamp ([`argocd/apps/headlamp/`](../argocd/apps/headlamp/application.yaml))
supports native OIDC login, but that turned out to mean something different
than expected: it hands the user's Authelia ID token straight to the
**Kubernetes API server** as the request's bearer credential (the same
pattern as a `kubectl` OIDC auth plugin), not just an app-level login screen
the way ArgoCD's OIDC is. Discovered live — first login attempt got
`invalid_client` (a separate, already-fixed Authelia-side issue), then once
that cleared, "The cluster did not accept your sign-in... Its API server
may not trust this OIDC provider," because nothing had ever told
`kube-apiserver` to trust `auth.jakerobb.org`.

Fix, committed at
[`talos/patches/control-plane/oidc.yaml`](patches/control-plane/oidc.yaml)
(applied to all 3 control planes, no reboot needed — same
`cluster.apiServer.extraArgs` mechanism as the metrics-bind-address fix
below):

```yaml
cluster:
  apiServer:
    extraArgs:
      oidc-issuer-url: https://auth.jakerobb.org
      oidc-client-id: headlamp
      oidc-username-claim: email
      oidc-username-prefix: '-'
```

```bash
talosctl patch machineconfig -e <cp-ip> -n <cp-ip> -p @oidc.yaml --mode=no-reboot
```

- **`oidc-client-id: headlamp`** — reuses the existing `headlamp` OIDC
  client (`argocd/apps/authelia/application.yaml`) as the trusted audience,
  rather than registering a separate client just for Kubernetes. Headlamp
  is the only thing presenting these tokens to the API server today; add a
  distinct client/audience if a second OIDC-native app ever needs direct
  Kubernetes API access.
- **`oidc-username-claim: email`**, same reasoning as ArgoCD's own RBAC
  section above — Authelia's `sub` claim is an opaque per-user UUID, useless
  as an RBAC subject. Kubernetes also skips its usual `<issuer>#` username
  prefix automatically for the `email` claim, confirmed live (the
  ClusterRoleBinding below matches the bare email with no prefix); the
  explicit `-` prefix override is there for clarity, not because the
  implicit skip was in doubt.
- **No `oidc-groups-claim`**: RBAC binds the single email identity directly
  (see below) rather than a group, matching the "cluster-admin, no per-user
  distinction" call already made for Headlamp's own ServiceAccount
  (`manifests/headlamp/clusterrolebinding.yaml`'s comment).
- **No `oidc-ca-file`**: `auth.jakerobb.org` carries a real Let's Encrypt
  cert (cert-manager), already covered by `kube-apiserver`'s default system
  CA trust — confirmed working with no CA override needed. Would only be
  necessary for an internal/private CA.
- **RBAC:** a `ClusterRoleBinding` (`oidc-admin`, committed at
  [`manifests/headlamp/clusterrolebinding-oidc-user.yaml`](../manifests/headlamp/clusterrolebinding-oidc-user.yaml),
  applied directly rather than waiting on a git-push-then-ArgoCD-sync round
  trip during the initial live test) binds Kubernetes username
  `jakerobb@gmail.com` to `cluster-admin` — same subject as ArgoCD's own
  `policy.csv` admin rule, just expressed as native Kubernetes RBAC instead
  of ArgoCD's own RBAC system.
- **Rollout, one control plane at a time:** patched cp1, waited for its
  `kube-apiserver` static pod to pick up the new args (confirmed via its
  live `command` args, not just `Running` status — the pod's reported AGE/
  restart count didn't reliably reset on this kind of update, so checking
  the actual flags was the only trustworthy signal), then cp2, then cp3.
  Each individual node's direct IP (and, briefly, the VIP itself whenever
  it happened to be sitting on the node currently restarting) returned
  connection-refused for a few seconds mid-restart — expected, and why
  Talos's own docs and this repo's other rolling changes check the VIP or
  another node rather than hammering the one that's momentarily down.
- **Also updated** the shared `~/talos/homelab/controlplane.yaml` template
  on rpi5-1 (same `cluster.apiServer.extraArgs` block) so a future
  from-scratch control-plane node gets this by default.

## kube-scheduler / kube-controller-manager metrics bind address (fixed 2026-09-20)

Both components' secure metrics port (`:10259` / `:10257`) defaulted to
Talos's built-in `--bind-address=127.0.0.1` — invisible from outside the
node, so `kube-prometheus-stack`'s Prometheus (running in-cluster, not on
the host network) got `connection refused` scraping either one. This was
**silent**: the pods themselves were `Running`/healthy the whole time, only
their metrics endpoint was unreachable — surfaced by Prometheus's own
`TargetDown`/`KubeSchedulerInstanceUnreachable`/
`KubeControllerManagerInstanceUnreachable` alerts (which nobody saw, since
no Alertmanager existed yet either — see the kube-prometheus-stack section
below).

Fix, committed at
[`talos/patches/control-plane/metrics-bind-address.yaml`](patches/control-plane/metrics-bind-address.yaml)
(applied to all 3 control planes, no reboot needed):

```yaml
cluster:
  controllerManager:
    extraArgs:
      bind-address: 0.0.0.0
  scheduler:
    extraArgs:
      bind-address: 0.0.0.0
```

```bash
talosctl patch machineconfig -n <cp-ip> -p @metrics-bind-address.yaml --mode=no-reboot
```

Safe to expose: both ports serve HTTPS with the same TLS-client-cert/token
auth as the rest of the control plane, not the deprecated insecure port —
binding `0.0.0.0` doesn't remove any auth. Verified via Prometheus's
`/api/v1/targets`: all 6 targets (`kube-scheduler` + `kube-controller-manager`
× 3 nodes) went from `down`/`connection refused` to `up` immediately after
each pod restarted. Also applied to the shared
`~/talos/homelab/controlplane.yaml` template on rpi5-1 so a future
from-scratch control-plane node won't reintroduce this.
