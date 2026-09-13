# ArgoCD (decided and deployed 2026-09-13)

GitOps controller for cluster workloads, replacing manual `kubectl apply`/`helm
upgrade` from rpi5-1 for anything that isn't ArgoCD's own bootstrap.

## Decisions

- **Repo:** this repo (`jakerobb/homelab`, confirmed **public** on GitHub), not
  a separate GitOps repo. No git credentials needed — ArgoCD clones over plain
  HTTPS anonymously.
- **Install method:** Helm chart `argo/argo-cd` (`https://argoproj.github.io/argo-helm`),
  matching the pattern already used for Cilium (`talos/cilium/values.yaml`).
  Values in [`install/values.yaml`](install/values.yaml) — only deltas from
  chart defaults. Chart defaults are already non-HA (1 replica each), so no
  HA-related overrides were needed.
- **Bootstrap pattern: app-of-apps.** ArgoCD's own Helm install is the one
  manual, non-GitOps step (parallel to how Cilium is installed/upgraded
  directly via `helm`, not GitOps'd onto itself — avoids the chicken-and-egg
  problem of ArgoCD managing its own install). Everything else — starting
  with ArgoCD's own ingress route — is reconciled from
  [`apps/`](apps/) by the root `Application` in
  [`bootstrap/root-app.yaml`](bootstrap/root-app.yaml), which is the second
  and last manual step. Add new apps by dropping an `Application` manifest
  (or, for something simple, raw manifests directly) anywhere under `apps/` —
  the root app recurses.
- **Sync policy: fully automated (`selfHeal: true`, `prune: true`)** on every
  app managed under `apps/`. Chosen deliberately over the safer
  automated-no-prune middle ground: nothing stateful (PVCs etc.) is under
  ArgoCD's management yet — see [`../TODO.md`](../TODO.md#hexos-storage) — so
  prune's main hazard (deleting real stateful data that's missing from a
  manifest) doesn't apply yet. **Revisit this once storage-backed workloads
  (e.g. an NFS-backed `StorageClass` from the HexOS TODO) go under ArgoCD's
  management** — prune deleting a PVC can delete the underlying data,
  depending on the storage class's reclaim policy. Also worth remembering
  day-to-day: self-heal reverts manual `kubectl edit`/`kubectl scale` fixes on
  the next sync (~3 min) unless you pause auto-sync first.
- **Exposure:** `HTTPRoute` on the existing `homelab-gateway`
  ([`apps/argocd-ingress/httproute.yaml`](apps/argocd-ingress/httproute.yaml)),
  plain HTTP — no TLS anywhere in the cluster yet (see
  `talos/README.md#ingress-gateway-api-decided-and-deployed-2026-09-13`).
  `server.insecure: true` in the Helm values makes ArgoCD serve plain HTTP
  instead of redirecting to its own self-signed HTTPS. Hostname-scoped
  (`argocd.lan`) rather than a catch-all, so later routes on the same
  listener don't collide with it.
  - **Manual step required:** add a local DNS record (or `/etc/hosts` entry)
    pointing `argocd.lan` at the Gateway's LB IP, `192.168.102.128`. Not
    IaC'd — this repo has no config for the UCG's local DNS.
- **Auth:** no SSO wired up (`dex.enabled: false`). Local admin only for now;
  password is auto-generated in the `argocd-initial-admin-secret` Secret on
  first install (see below). Revisit if/when there's an SSO provider worth
  integrating with.

## Bootstrap (one-time, manual)

From a machine with `helm`/`kubectl` pointed at the cluster
(`KUBECONFIG=~/.kube/homelab.yaml`):

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm install argocd argo/argo-cd \
  --version 10.9.0 \
  --namespace argocd --create-namespace \
  -f argocd/install/values.yaml
kubectl apply -f argocd/bootstrap/root-app.yaml
```

Get the initial admin password (rotate or replace with SSO later):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Then browse to `http://argocd.lan` (after the DNS record above exists) or
`http://192.168.102.128` with a `Host: argocd.lan` header, and log in as
`admin`.

## Upgrading ArgoCD itself

Bump the chart version in the `helm install` command above (now that it's
already installed, `helm upgrade` instead) and re-run with the same
`-f argocd/install/values.yaml`. This is the one recurring manual step, by
design — see "Bootstrap pattern" above.
