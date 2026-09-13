# Talos cluster config

## Current state (as of 2026-09-07)

- **Talos v1.11.5**, **Kubernetes v1.34.1**.
- 3-node control plane on Raspberry Pi 5 (4GB), already installed and working.
  Control planes use a **custom installer image**, `ghcr.io/talos-rpi5/installer:v1.11.5`,
  since stock Talos doesn't support the Pi5 directly. **Any amd64 worker (e.g. the MS-A2
  Talos VM) must use the standard `ghcr.io/siderolabs/installer:v1.11.5` / stock qcow2 —
  do not reuse the rpi5 installer image for it.**
- CNI: Cilium, with `kubeProxyReplacement` enabled, full eBPF host routing
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

**Scope note:** this only brings the *secrets bundle* into the repo. The full
per-node machine configs (`controlplane.yaml`/`worker.yaml`) are still generated
directly with `talosctl` on demand (using this decrypted secrets bundle), not
via [Talhelper](https://github.com/budimanjojo/talhelper)'s declarative
`talconfig.yaml`. Adopting Talhelper fully would mean reverse-engineering every
setting already baked into the existing `controlplane.yaml` (KubePrism port,
kube-proxy disablement, disk selectors, kubelet extra args, etc.) — deliberately
deferred rather than guessed at, to avoid drifting the config used to actually
generate a new node away from what's already running. Worth revisiting as a
follow-up once there's time to diff it carefully against the live config.

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

## Layout

- `cilium/` — Cilium Helm values, LB/L2-announcement CRDs, and the Gateway
  API `Gateway` (ingress), applied to the existing cluster.
- `patches/control-plane/` — per-node Talos config patches for the existing 3 Pi
  control-plane nodes (hostname only, currently).
- `patches/workers/` — patches for the two MS-A2 worker VMs (hostname only,
  matching the control-plane patch style — IP addressing is handled via DHCP
  reservation on the UCG, not in Talos config).

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
