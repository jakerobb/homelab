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
  manual, non-GitOps step — same chicken-and-egg reasoning as Cilium's
  *initial* install (nothing has pod networking, including ArgoCD's own
  pods, until Cilium is already running; nothing can run ArgoCD's own
  Helm chart until ArgoCD is already running). Cilium's *ongoing* lifecycle
  is GitOps'd like everything else as of 2026-09-15
  ([`apps/cilium/`](apps/cilium/application.yaml)) — manual sync policy
  only, unlike the rest of `apps/`, see [`talos/README.md`](../talos/README.md#now-managed-by-argocd-2026-09-15)
  for why. ArgoCD's own install stays manual permanently, since it can never
  bootstrap itself. Everything else — starting
  with ArgoCD's own ingress route — is reconciled from
  [`apps/`](apps/) by the root `Application` in
  [`bootstrap/root-app.yaml`](bootstrap/root-app.yaml), which is the second
  and last manual step. Add new apps by dropping an `Application` manifest
  anywhere under `apps/` — the root app recurses.
  - **Convention (settled 2026-09-17): `apps/` holds only `Application`
    manifests, never an app's actual resources.** Early on, a few simple
    apps (`homepage`, `renovate`) were added as raw manifests directly under
    `apps/<name>/` instead of getting their own `Application` — meaning
    root owned their Deployments/CronJobs/etc. directly, alongside its
    real job of owning the `Application` objects themselves. Downside:
    those apps' health/sync status was inseparable from root's own (a
    broken `homepage` Deployment made root itself show `Degraded`), and
    they couldn't have their own sync policy. Fixed by moving each app's
    actual manifests to `manifests/<name>/` (sibling to `apps/`, outside
    root's recursion — same place [`manifests/cert-manager-config/`](../manifests/cert-manager-config/)
    already lived) and adding a thin `apps/<name>/application.yaml`
    pointing at that path — same shape as
    [`apps/local-path-provisioner/application.yaml`](apps/local-path-provisioner/application.yaml),
    just with a git path instead of an external Helm chart as the source.
    `apps/argocd-ingress/httproute.yaml` and `apps/authelia/referencegrant.yaml`
    are the one deliberate exception each — a single small resource
    tightly coupled to its parent app's own bootstrap, not worth a whole
    extra `Application` for.
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
  hostname `argocd.jakerobb.org`. `server.insecure: true` in the Helm values
  makes ArgoCD serve plain HTTP internally instead of redirecting to its own
  self-signed HTTPS — TLS is terminated at the Gateway instead (see "DNS +
  TLS" below), so this isn't a downgrade.
- **Auth:** SSO via Authelia (`dex.enabled: false` — using ArgoCD's native
  OIDC support directly, not Dex). See "Authelia SSO" below. The local
  `admin` account (password in `argocd-initial-admin-secret`, see "Bootstrap"
  below) still exists as a break-glass fallback if Authelia is ever down.
- **`revisionHistoryLimit: 2`** set on every app's Deployment/StatefulSet
  where the chart exposes the knob (chart defaults are usually 10) — enough
  to roll back one step, not a growing pile of dead ReplicaSets. Rancher's
  `local-path-provisioner` chart doesn't template this field at all, so it's
  stuck at the Kubernetes default (10) until that's patched upstream or
  vendored; low-value to chase for a single-replica, rarely-redeployed
  provisioner.

## DNS + TLS (decided 2026-09-13)

Real, publicly-trusted certs and automatic DNS — no custom root CA to trust
on every device, no manually-added DNS entries per app:

- **DNS:** [`external-dns`](apps/external-dns/application.yaml) (Cloudflare
  provider) watches `HTTPRoute`s cluster-wide and creates/updates DNS-only
  (not proxied — these point at a private LAN IP, so Cloudflare's edge proxy
  would just break) `A` records in the `jakerobb.org` zone automatically.
  Same zone Caddy's Caddyfile-managed records already live in — a **flat,
  shared namespace**, chosen deliberately even though it means external-dns
  needs zone-wide write access, since most/all of Caddy's names are expected
  to migrate into the cluster over time anyway. The TXT ownership registry
  (`registry: txt`, `txtOwnerId: homelab-k8s`) still means external-dns will
  only ever touch/prune records carrying its own marker — it won't adopt or
  delete Caddy's existing records just because a hostname collides.
- **Unbound rebinding protection (gotcha, fixed 2026-09-13):** the LAN's
  Unbound resolver (`~/docker/unbound/custom.conf.d/local.conf` on rpi5-1)
  ships a DNS-rebinding-protection default from its Docker image
  (`private-address: 192.168.0.0/16`) that silently strips any answer
  resolving a non-allowlisted hostname to a private IP — returning `NOERROR`
  with zero records, not a cache/propagation-delay symptom. Every hostname
  external-dns creates under `jakerobb.org` resolves to a private LAN IP by
  design, so this blocked `argocd.jakerobb.org` (and would have blocked every
  future one, e.g. `auth.jakerobb.org` for Authelia) until `jakerobb.org` was
  added to Unbound's `private-domain` allowlist alongside the existing `lan`
  entry. **If a newly-added `HTTPRoute` hostname mysteriously won't resolve
  from LAN clients** (even though `dig @1.1.1.1` shows the correct record),
  check this first — it's already fixed for the `jakerobb.org` zone as a
  whole, so it shouldn't recur, but it's the first thing to suspect if it
  does.
- **TLS:** [`cert-manager`](apps/cert-manager/application.yaml) with a
  `ClusterIssuer` doing **Let's Encrypt via DNS-01 challenges against
  Cloudflare** ([`manifests/cert-manager-config/`](../manifests/cert-manager-config/)) —
  DNS-01 is required for wildcards anyway, and it means the ACME challenge
  never needs anything publicly reachable. One wildcard `Certificate` for
  `*.jakerobb.org` covers every app's `HTTPRoute` automatically; the Gateway's
  new `https`/443 listener ([`talos/cilium/gateway.yaml`](../talos/cilium/gateway.yaml))
  references the resulting Secret directly, so no per-app cert-manager
  objects are needed going forward.
- **Bootstrap ordering:** the `cert-manager` Application (chart + CRDs) is
  sync-wave `0`; `cert-manager-config` (the `ClusterIssuer` + `Certificate`,
  which need cert-manager's CRDs to already exist) is wave `1`. Root waits
  for wave 0 to be Healthy before applying wave 1.
- **Cloudflare API token:** scoped to `Zone:DNS:Edit` on the `jakerobb.org`
  zone only (Cloudflare's built-in "Edit zone DNS" token template, restricted
  to that one zone). Needed by both cert-manager (DNS-01 solver) and
  external-dns, in their respective namespaces. **Not committed in plaintext
  anywhere** — see "Cloudflare token setup" below. ArgoCD has no SOPS/KSOPS
  decryption wired up, so these two secrets are applied directly to the
  cluster out of band rather than through GitOps sync; the encrypted files
  are still committed to `argocd/secrets/` (excluded from the root app's
  `argocd/apps` recursion) purely for durability/versioning.

### Cloudflare token setup (one-time, manual)

1. Cloudflare dashboard → My Profile → API Tokens → Create Token → **Edit
   zone DNS** template → Zone Resources: restrict to the specific
   `jakerobb.org` zone → Create → copy the token (shown once).
2. Locally, from the repo root (this keeps the plaintext token out of any
   chat/session transcript — only the encrypted result is ever shared):

   ```bash
   read -rsp "Cloudflare API token: " CF_TOKEN; echo
   for ns in cert-manager external-dns; do
     cat > argocd/secrets/cloudflare-api-token.${ns}.sops.yaml <<EOF
   apiVersion: v1
   kind: Secret
   metadata:
     name: cloudflare-api-token
     namespace: ${ns}
   stringData:
     api-token: ${CF_TOKEN}
   EOF
     sops -e -i argocd/secrets/cloudflare-api-token.${ns}.sops.yaml
   done
   unset CF_TOKEN
   ```
3. Apply both directly to the cluster (bypasses git/ArgoCD entirely, same as
   any other SOPS-encrypted file in this repo):

   ```bash
   export KUBECONFIG=~/.kube/config
   sops -d argocd/secrets/cloudflare-api-token.cert-manager.sops.yaml | kubectl apply -f -
   sops -d argocd/secrets/cloudflare-api-token.external-dns.sops.yaml | kubectl apply -f -
   ```
4. `git add argocd/secrets/` and commit — safe, they're encrypted.

## Authelia SSO (decided 2026-09-13)

Fronting **ArgoCD only** for now — see [`../TODO.md`](../TODO.md) for the
per-workload plan to migrate everything currently on the RPi5 16GB's Docker
Compose stack (Grafana, NetworkOptimizer, etc.) into the cluster one at a
time; those get added to Authelia's `access_control` as they land, not now.

- **Authelia, not Authentik:** Authentik needs Postgres + Redis, real
  overkill for what's currently one protected app. Authelia runs as a single
  pod with file-based config: SQLite (`storage.local`) instead of Postgres,
  in-memory sessions instead of Redis. Trade-off: no admin web UI (users and
  OIDC clients are YAML, redeployed via this repo — arguably a better fit
  for this repo's IaC-first approach anyway) and no SMTP configured, so
  password-reset/notification links land in a file inside the pod
  (`kubectl exec -n authelia authelia-0 -- cat /config/notification.txt`)
  instead of being emailed.
- **Storage:** [`local-path-provisioner`](apps/local-path-provisioner/application.yaml)
  is the cluster's first `StorageClass` — nothing provided PVCs before this.
  It's a deliberate bridge, not a long-term answer: PVs are backed by a
  directory on whichever single node the pod lands on, no redundancy. Fine
  for Authelia's small SQLite file; superseded once the
  [HexOS storage TODO](../TODO.md#hexos-storage) provides a real NFS/SMB
  `StorageClass`. `reclaimPolicy: Retain` (not the chart's `Delete` default)
  since this is also the first PVC-backed workload under ArgoCD's
  fully-automated `prune: true` — see the "Sync policy" bullet above.
- **ArgoCD gets real OIDC, not Gateway forward-auth:** ArgoCD has native
  OIDC-client support (`configs.cm.oidc.config` in
  [`install/values.yaml`](install/values.yaml)), so there's no need for
  Cilium's Gateway API `ExternalAuth` HTTPRoute filter — which isn't
  available yet anyway at the cluster's current Cilium version (1.19.5 vs.
  the 1.20+ it needs; see [`../TODO.md`](../TODO.md)). That filter only
  becomes relevant once a Compose app that *doesn't* speak OIDC natively
  (NetworkOptimizer, change-detection, etc.) actually migrates in.
- **Exposure:** `HTTPRoute` on `homelab-gateway` (auto-created by the
  Authelia chart's `ingress.gatewayAPI` option), hostname
  `auth.jakerobb.org`.
- **Bootstrap ordering:** `local-path-provisioner` is sync-wave `0`
  (alongside `cert-manager` — independent, both need to be healthy before
  anything that depends on either); `authelia` is wave `1`.
- **Secrets:** same out-of-band pattern as the Cloudflare token above — no
  SOPS/KSOPS wired into ArgoCD sync yet, so these are applied directly with
  `kubectl` rather than through GitOps. Three secrets already
  generated and committed encrypted:
  - `argocd/secrets/authelia.sops.yaml` → Secret `authelia-secrets` in the
    `authelia` namespace (session/storage encryption keys, OIDC HMAC secret,
    password-reset JWT secret — all randomly generated, not
    human-memorable).
  - `argocd/secrets/authelia-users-database.sops.yaml` → Secret
    `users-database` in `authelia` (the `users_database.yml` file itself,
    one `jake` account, argon2id-hashed password).
  - `argocd/secrets/authelia-oidc-jwk.sops.yaml` → Secret `oidc-jwk` in
    `authelia` (RSA-4096 private key Authelia uses to sign OIDC tokens).
  - `argocd/secrets/argocd-oidc-client-secret.sops.yaml` — **not** a k8s
    Secret manifest, a Helm *values fragment* (`configs.secret.extra`)
    layered onto ArgoCD's own install at `helm upgrade` time, same as
    `install/values.yaml` itself. Holds the plaintext OIDC client secret
    ArgoCD needs; Authelia's own config only ever holds a one-way
    pbkdf2-sha512 hash of it (inline in
    [`apps/authelia/application.yaml`](apps/authelia/application.yaml),
    safe to commit since it's not reversible).

  Apply the three real Secrets once Authelia's namespace exists (after
  `root-app.yaml` has synced at least once):

  ```bash
  export KUBECONFIG=~/.kube/config
  for f in authelia authelia-users-database authelia-oidc-jwk; do
    sops -d argocd/secrets/${f}.sops.yaml | kubectl apply -f -
  done
  ```

  Then layer the OIDC client secret onto ArgoCD's own Helm install (this is
  why it's a separate `-f`, not baked into `install/values.yaml` — see
  "Upgrading ArgoCD itself" below):

  ```bash
  helm upgrade argocd argo/argo-cd --version 10.9.1 -n argocd \
    -f argocd/install/values.yaml \
    -f <(sops -d argocd/secrets/argocd-oidc-client-secret.sops.yaml)
  ```
- **First login:** browse to `https://argocd.jakerobb.org`, click the SSO
  login option, authenticate as `jake` against Authelia. Since ArgoCD's
  `access_control` policy is `two_factor` and this is a brand-new Authelia
  instance, the first login prompts TOTP registration (scan a QR code) —
  there's no SMTP for email-based recovery, so don't lose that TOTP secret.
- **RBAC (added 2026-09-16):** ArgoCD's RBAC subject defaults to the OIDC
  `sub` claim, which Authelia fills with an opaque per-user UUID — not
  something a `policy.csv` rule could sensibly target, and with no matching
  rule a freshly-SSO'd user gets no role and no app access at all. Fixed via
  `configs.rbac` in [`install/values.yaml`](install/values.yaml):
  `scopes: '[groups, email]'` tells ArgoCD to also check the `email` claim
  (already in the ID token — it's in `requestedScopes` above) as a policy
  subject, then `policy.csv: g, jakerobb@gmail.com, role:admin` grants that
  address admin. `policy.default` is left unset, which the chart renders as
  an **empty** `policy.default` — ArgoCD treats that as "no access at all"
  for anyone not matched by a `policy.csv` rule, not `role:readonly` as
  might be assumed. Fine for now (single user), but worth setting
  `configs.rbac.policy.default: 'role:readonly'` explicitly if a second
  Authelia user ever shows up and should get *some* default access instead
  of silently seeing nothing.

## Renovate (dependency updates, decided and deployed 2026-09-16)

Kubernetes/GitOps equivalent of the Docker Compose stack's Watchtower
(`docker-compose/docker-compose.yml`) — see the
[`TODO.md`](../TODO.md#compose-workload-migration) note this replaces.

- **PR-based, not in-place patching.** Watchtower silently swaps running
  containers; that model fights GitOps (git is supposed to be the source of
  truth for what's running). Instead, [Renovate](https://docs.renovatebot.com/)
  runs as a `CronJob` ([`apps/renovate/`](apps/renovate/cronjob.yaml)) that
  scans this repo and opens PRs bumping container image tags, ArgoCD Helm
  chart versions (`argocd/apps/**/application.yaml`), docker-compose image
  tags, and Terraform provider versions. Merging a PR is what actually
  changes anything — ArgoCD's existing auto-sync then picks it up like any
  other commit. Config lives in [`renovate.json`](../renovate.json) at the
  repo root; the `kubernetes` and `argocd` managers are off by default
  upstream (no reliable way to auto-detect which YAML is which) and are
  explicitly scoped there to `argocd/apps/**`.
- **Self-hosted CLI image, not the GitHub App** — keeps this entirely
  in-cluster/GitOps'd like everything else here, at the cost of one manual
  bootstrap step (the GitHub token below).
- **Schedule:** daily, 4:17am America/Detroit — same off-peak slot Watchtower
  used to run in.
- **Image tag is pinned, not `:latest`** — deliberately, so the `kubernetes`
  manager picks it up and Renovate ends up opening a PR against its own
  CronJob when a new version ships.
- **GitHub token (one-time, manual):** Renovate needs a token that can push
  branches and open PRs against this repo. Create a **fine-grained personal
  access token** at GitHub → Settings → Developer settings → Fine-grained
  tokens, scoped to just `jakerobb/homelab`, with **Contents: Read and
  write** and **Pull requests: Read and write** repository permissions (add
  **Workflows: Read and write** too if `.github/workflows/` ever shows up).
  Then, same out-of-band pattern as the Cloudflare/Authelia secrets above (no
  SOPS/KSOPS wired into ArgoCD sync yet):

  ```bash
  read -rsp "Renovate GitHub token: " RENOVATE_TOKEN; echo
  cat > argocd/secrets/renovate-github-token.sops.yaml <<EOF
  apiVersion: v1
  kind: Secret
  metadata:
    name: renovate-github-token
    namespace: renovate
  stringData:
    token: ${RENOVATE_TOKEN}
  EOF
  sops -e -i argocd/secrets/renovate-github-token.sops.yaml
  unset RENOVATE_TOKEN
  ```

  Apply once the `renovate` namespace exists (after `root-app.yaml` has
  synced at least once):

  ```bash
  export KUBECONFIG=~/.kube/config
  sops -d argocd/secrets/renovate-github-token.sops.yaml | kubectl apply -f -
  ```

  `git add argocd/secrets/renovate-github-token.sops.yaml` and commit —
  safe, it's encrypted.
- **First run:** trigger it on demand instead of waiting for 4:17am —
  `kubectl create job --from=cronjob/renovate -n renovate renovate-manual-1`
  — then `kubectl logs -n renovate job/renovate-manual-1 -f`. Check the logs
  against current [Renovate docs](https://docs.renovatebot.com/) if
  `kubernetes`/`argocd` manager config keys have moved on again
  (`managerFilePatterns` itself replaced the older `fileMatch` at some point)
  or if it isn't picking up files you expected it to.

## metrics-server (decided and deployed 2026-09-17)

Cluster/node/pod live resource metrics — specifically so OpenLens's graphs
and `kubectl top` populate. Deployed as
[`apps/metrics-server/`](apps/metrics-server/application.yaml), same
external-Helm-chart pattern as `cert-manager`/`external-dns`. This only
covers *live* metrics (metrics-server keeps no history); the historical/
Prometheus half of [`TODO.md`](../TODO.md#metrics-prometheus--timeseries-db)
is still open.

- **`--kubelet-insecure-tls` set deliberately.** Talos's kubelet serving
  certs are self-signed per-node, not signed by the cluster CA (confirmed via
  `openssl s_client` against a control-plane node's :10250 — issuer is a
  per-node `talos-cp-N-ca`, not the cluster CA), so metrics-server can't
  verify them out of the box. The "proper" fix — `rotate-server-certificates`
  in Talos's kubelet config plus a CSR auto-approver
  ([`kubelet-csr-approver`](https://github.com/postfinance/kubelet-csr-approver),
  since Kubernetes doesn't auto-approve `kubelet-serving` CSRs) — was
  considered and skipped: that's a standing 2-replica controller
  (~128Mi/200m requested continuously, and its chart's default toleration
  would let it land on the control-plane nodes, which are the tighter of the
  two node classes at ~2.3-2.5Gi available on these 4GB Pi 5s) to approve on
  the order of 5 CSRs/year. TLS is still encrypted either way —
  `--kubelet-insecure-tls` only skips chain/hostname verification, a
  non-issue on this cluster's private LAN. Worth reconsidering only if
  another kubelet-scraping workload shows up that can't tolerate insecure
  TLS (most, like a future Prometheus's kubelet `ServiceMonitor`, ship
  `insecureSkipVerify: true` by default for exactly this reason) or if
  multiple such consumers make the standing approver cost worth it.
- **Namespace:** own `metrics-server` namespace (`CreateNamespace=true`),
  consistent with `cert-manager`/`external-dns`/etc. rather than
  `kube-system`.

## Bootstrap (one-time, manual)

From a machine with `helm`/`kubectl` pointed at the cluster
(`KUBECONFIG=~/.kube/config`, the default path — no need to export it):

<!-- renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm -->
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm install argocd argo/argo-cd \
  --version 10.9.1 \
  --namespace argocd --create-namespace \
  -f argocd/install/values.yaml
kubectl apply -f argocd/bootstrap/root-app.yaml
```

Get the initial admin password (rotate or replace with SSO later):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Once external-dns and cert-manager have synced and issued the wildcard cert
(see "DNS + TLS" above), browse to `https://argocd.jakerobb.org` and log in
as `admin`. Before that's up, `http://192.168.102.128` with a
`Host: argocd.jakerobb.org` header will hit the same backend over plain HTTP.

## Upgrading ArgoCD itself

Bump the chart version in the `helm install` command above (now that it's
already installed, `helm upgrade` instead) and re-run with the same
`-f argocd/install/values.yaml`. This is the one recurring manual step, by
design — see "Bootstrap pattern" above.
