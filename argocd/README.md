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
  only, unlike the rest of `apps/`, see [`talos/README.md`](../talos/README.md#cilium-version-management)
  for why. ArgoCD's own install stays manual permanently, since it can never
  bootstrap itself. Everything else — starting
  with ArgoCD's own ingress route — is reconciled from
  [`apps/`](apps/) by the root `Application` in
  [`bootstrap/root-app.yaml`](bootstrap/root-app.yaml), which is the second
  and last manual step. Add new apps by dropping an `Application` manifest
  anywhere under `apps/` — the root app recurses. See
  [`docs/adding-an-app.md`](../docs/adding-an-app.md) for the full
  checklist (file layout, exposure, auth, secrets, Homepage discovery).
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
  ArgoCD's management yet — see [`../todo/READY.md`](../todo/READY.md#hexos-storage) — so
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

Fronting **ArgoCD only** for now — see [`../todo/READY.md`](../todo/READY.md) for the
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
  [HexOS storage TODO](../todo/READY.md#hexos-storage) provides a real NFS/SMB
  `StorageClass`. `reclaimPolicy: Retain` (not the chart's `Delete` default)
  since this is also the first PVC-backed workload under ArgoCD's
  fully-automated `prune: true` — see the "Sync policy" bullet above.
- **ArgoCD gets real OIDC, not Gateway forward-auth:** ArgoCD has native
  OIDC-client support (`configs.cm.oidc.config` in
  [`install/values.yaml`](install/values.yaml)), so there's no need for
  Cilium's Gateway API `ExternalAuth` HTTPRoute filter — which isn't
  available yet anyway at the cluster's current Cilium version (1.19.5 vs.
  the 1.20+ it needs; see [`../todo/DONE.md`](../todo/DONE.md#gateway-api-forward-auth-cilium-externalauth-filter)). That filter only
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
  helm upgrade argocd argo/argo-cd --version <currently-deployed chart version> -n argocd \
    -f argocd/install/values.yaml \
    -f <(sops -d argocd/secrets/argocd-oidc-client-secret.sops.yaml)
  ```
  (Check `helm list -n argocd` for the version actually running rather than assuming — don't hardcode a version here
  that can silently drift from the "Bootstrap" section below.)
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
[`READY.md`](../todo/READY.md#compose-workload-migration) note this replaces.

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

Cluster/node/pod live resource metrics via the Kubernetes Metrics API —
`kubectl top`. Deployed as
[`apps/metrics-server/`](apps/metrics-server/application.yaml), same
external-Helm-chart pattern as `cert-manager`/`external-dns`. Turns out this
alone does *not* populate OpenLens's own graphs/usage bars — those are
Prometheus-backed specifically (confirmed directly by OpenLens itself), so
[`kube-prometheus-stack`](#kube-prometheus-stack-decided-and-deployed-2026-09-17)
was added separately for that. This app only covers *live* Metrics-API
values (metrics-server keeps no history) either way.

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

## kube-prometheus-stack (decided and deployed 2026-09-17)

The other half of the metrics-server decision above: metrics-server only
gives current-instant values (`kubectl top`, OpenLens's Metrics API-backed
bits), but OpenLens's own visual metrics — the "Cluster" dashboard's
CPU/Memory graphs, and even the plain usage bars on the Nodes list — need a
Prometheus it can run PromQL queries against, confirmed directly by OpenLens
itself ("Metrics are not available due to missing or invalid Prometheus
configuration"). Deployed as
[`apps/kube-prometheus-stack/`](apps/kube-prometheus-stack/application.yaml),
chart `kube-prometheus-stack` from `prometheus-community`.

- **Grafana still disabled.** Today's actual goal is just feeding OpenLens,
  and the existing Compose-stack Grafana on the 16GB Pi already covers
  dashboarding until that workload migrates in (see
  [`READY.md`](../todo/READY.md#compose-workload-migration)).
- **Alertmanager enabled 2026-09-20** (was disabled at initial deploy — no
  notification receiver was wired up yet, see git history for this section's
  original wording). Surfaced by a scheduled health check: Prometheus had
  real alerts firing silently for ~2 days (`TargetDown`/
  `KubeSchedulerInstanceUnreachable`/`KubeControllerManagerInstanceUnreachable`
  — see the metrics-bind-address fix in
  [`talos/README.md`](../talos/README.md#kube-scheduler--kube-controller-manager-metrics-bind-address-fixed-2026-09-20)
  for that one's own root cause) with nowhere to send them, confirmed by
  Prometheus's own `PrometheusNotConnectedToAlertmanagers` alert. Once
  [`ntfy`](apps/ntfy/application.yaml) actually landed in the cluster (see
  its own section below), the original blocker was gone.
  - **Routes through [`ntfy-alertmanager`](apps/ntfy-alertmanager/application.yaml),
    not a raw webhook straight to ntfy** — Alertmanager's `webhook_configs`
    always POSTs its own fixed JSON schema with no templating support, and
    ntfy's publish endpoint expects its own different JSON shape (or a
    plain-text body); pointed directly at each other, ntfy would just reject
    Alertmanager's payload. `ntfy-alertmanager` (xenrox, see
    [source](https://git.xenrox.net/~xenrox/ntfy-alertmanager)) is a small,
    purpose-built bridge for exactly this — maps alert labels
    (`severity` today) to ntfy priority/tags via its `scfg` config
    ([`manifests/ntfy-alertmanager/configmap.yaml`](../manifests/ntfy-alertmanager/configmap.yaml)).
    Publishes to ntfy's `homelab-alerts` topic — subscribe to
    `https://ntfy.jakerobb.org/homelab-alerts` (web/app) to actually receive
    these.
  - **Single replica, no HA gossip, 4h `repeat_interval`** — this is a
    best-effort home-notification path, not a paged on-call system; no need
    for Alertmanager's usual multi-replica dedup/gossip setup.
  - **`Watchdog` routed to a `null` receiver**, not dropped as a rule — it's
    the chart's always-firing canary alert (proves the Prometheus→
    Alertmanager pipeline itself is alive), which would otherwise re-notify
    every `repeat_interval` forever. Routing to `null` keeps it visible in
    the Prometheus/Alertmanager UI for a manual check without spamming a
    notification for it.
  - **`KubeProxyDown`/the whole `kubeProxy` rule group disabled**
    (`defaultRules.rules.kubeProxy: false`, `kubeProxy.enabled: false`) — a
    permanent false positive on this cluster: Cilium runs in
    kube-proxy-replacement mode (see "Ingress: Gateway API" in
    [`talos/README.md`](../talos/README.md)), so there's no kube-proxy
    DaemonSet to ever be up or scrape. Found firing, unnoticed, since this
    chart was first deployed on 2026-09-17.
- **Namespace:** `monitoring`, breaking from this repo's usual one-app-one-
  namespace convention — this is the ecosystem-standard name, and what
  OpenLens's own "Prometheus Operator" auto-detect option looks for.
- **Storage:** `hexos-iscsi` (already the cluster default StorageClass, with
  `reclaimPolicy: Retain` — see [`democratic-csi`](apps/democratic-csi/application.yaml)),
  10Gi, 10-day retention. Deliberately modest — no VictoriaMetrics
  remote-write yet (see [`READY.md`](../todo/READY.md#log-and-metrics-aggregation)),
  so this is a bridge, not the long-term store.
- **Kubelet scrape TLS:** `insecureSkipVerify` is already the chart default
  for the kubelet `ServiceMonitor` — same call already made for
  metrics-server (self-signed per-node kubelet certs on Talos), nothing to
  override.
- **`serviceMonitorSelectorNilUsesHelmValues: false`** (and the Pod-
  monitor/rule equivalents) — the chart defaults to `true`, which restricts
  the operator to its own bundled ServiceMonitors. Set `false` for
  cluster-wide discovery, so a future app's own ServiceMonitor gets picked
  up automatically instead of silently ignored.
- **node-exporter tolerations:** the chart's default tolerations are empty,
  so its DaemonSet wouldn't otherwise run on the tainted control-plane
  nodes — added an explicit toleration for full-cluster host metrics
  coverage.
- **No exposure needed.** OpenLens talks to Prometheus through the
  Kubernetes API server's proxy subresource, the same path it uses for pod
  logs/exec — no HTTPRoute/Gateway/Authelia route required just for
  OpenLens to work. (A route for browsing the Prometheus UI directly is a
  separate, optional later addition.)
- **`monitoring` namespace gets a PodSecurity `privileged` override**
  (`syncPolicy.managedNamespaceMetadata.labels`). Talos's cluster-wide
  `PodSecurity` admission default enforces `baseline` on every namespace
  except `kube-system` (confirmed via `talosctl get admissioncontrolconfig`
  — this is a Talos default, not something this repo configured), which
  blocks node-exporter's `hostNetwork`/`hostPID`/`hostPath`/`hostPort`
  needs outright. First workload in this cluster to actually need
  host-level access, so nothing else had hit this default before.
  Overridden per-namespace rather than touching the cluster-wide
  exemptions list.
- **`crds.enabled: false` — this chart's CRDs are installed manually,
  out-of-band, once** (see "kube-prometheus-stack CRDs" below), same
  one-time-step pattern as the Cloudflare tokens/Authelia secrets above.
  6 of the 10 CRDs (`Prometheus`, `Alertmanager`, `AlertmanagerConfig`,
  `ScrapeConfig`, `PrometheusAgent`, `ThanosRuler`) are 600-860KB as
  authored — almost entirely their OpenAPI schema, not
  `metadata.annotations` (checked directly: `crd-prometheuses.yaml`'s own
  authored annotations are 80 bytes). ArgoCD's diffing pipeline duplicates
  the *entire* manifest into a `metadata.annotations` value somewhere in
  that process and hits Kubernetes' 256KiB total-annotations limit —
  confirmed neither `ServerSideApply=true` nor `Replace=true` sync options
  avoid this (tried both, identical failure each time), while a plain
  `kubectl create` outside ArgoCD entirely works instantly. Matches Helm's
  own general convention of not touching CRDs on upgrade anyway.
  **Consequence: bumping `targetRevision` needs a manual CRD re-apply if
  that release changed any CRD schemas** — check the chart's release notes,
  and re-run the step below against the new chart version if so.

### kube-prometheus-stack CRDs (one-time, manual, and again on any CRD-affecting upgrade)

```bash
export KUBECONFIG=~/.kube/config
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community
helm pull prometheus-community/kube-prometheus-stack \
  --version <targetRevision from argocd/apps/kube-prometheus-stack/application.yaml> \
  --untar --untardir /tmp/kps-chart
kubectl create -f /tmp/kps-chart/kube-prometheus-stack/charts/crds/crds/
```

(`kubectl create`, not `apply` — same reasoning as above. If a CRD already
exists this errors harmlessly on that one; re-run per-file with `kubectl
replace -f` for just the changed ones on an upgrade instead of blanket
re-creating.)

### external-snapshotter CRDs (one-time, manual, and again on any schema-affecting upgrade)

`VolumeSnapshotClass`/`VolumeSnapshotContent`/`VolumeSnapshot`, installed
2026-09-19 so democratic-csi's controller stops spamming failed watches for
CRDs that didn't exist yet (see talos/README.md's health-check runbook).
These particular CRDs are small enough (well under the 256KiB annotation
limit above) that ArgoCD could technically manage them without hitting that
bug — but CRDs stay out of ArgoCD's hands here as a blanket rule, not a
case-by-case one, matching Helm's own convention. An `argocd/apps/
external-snapshotter` Application briefly existed on 2026-09-20 and was
removed for exactly this reason.

Manifests are vendored at
[`manifests/external-snapshotter/`](../manifests/external-snapshotter),
pulled from the [external-snapshotter](https://github.com/kubernetes-csi/external-snapshotter)
`client/config/crd/` directory at the release tag below:

```bash
kubectl create -f manifests/external-snapshotter/
```

Installed from `v8.6.0`. This only registers the CRDs — actually reconciling
a `VolumeSnapshot` into a `VolumeSnapshotContent` still needs the
snapshot-controller + validating webhook, not installed here (CRDs-only was
the actual ask; add the controller separately if snapshots are wanted for
real).

## ntfy (migrated from docker-compose, 2026-09-20)

Moved off rpi5-1's docker-compose stack into the cluster — the blocker noted
in the original kube-prometheus-stack Alertmanager decision ("revisit once
something like ntfy actually lands in the cluster") is what triggered this,
not the other way around. Deployed as
[`apps/ntfy/`](apps/ntfy/application.yaml), bare manifests (no official
chart) at [`manifests/ntfy/`](../manifests/ntfy/), same "bare Deployment"
call as homepage/searxng.

- **Config carried over as-is** from the pre-migration
  `docker/ntfy/conf/server.yml` on rpi5-1 (`base-url`, `upstream-base-url`)
  — see [`manifests/ntfy/configmap.yaml`](../manifests/ntfy/configmap.yaml).
  No `auth-file` was configured before, and none is configured now — this
  migration doesn't change ntfy's security posture, just where it runs (see
  the HTTPRoute's own comment for why it's deliberately *not* gated by
  Authelia's `ExternalAuth` filter, unlike homepage/searxng).
- **1Gi PVC** (`hexos-iscsi`) for the message cache (`cache.db`) so recent
  notification history survives a pod restart — the pre-migration cache.db
  was 258KB, so this is generous headroom, not a tight budget. The old
  compose service's cache/conf directories on rpi5-1 are **not** migrated
  into this PVC; ntfy's cache is short-lived by design (12h default
  retention) and not worth the extra migration step.
- **DNS gotcha, real and hit for the first time by this migration:**
  `ntfy.jakerobb.org` already existed as a Cloudflare DNS record from the
  pre-migration Caddy setup (`docker-compose/caddy/Caddyfile`, now removed),
  created outside external-dns and carrying no TXT ownership marker. Per
  external-dns's documented behavior (see "DNS + TLS" above — "won't adopt
  or delete Caddy's existing records just because a hostname collides"),
  syncing this app's `HTTPRoute` will **not** make external-dns take over or
  overwrite that record automatically. **Manual step required:** delete the
  existing `ntfy.jakerobb.org` A record in the Cloudflare dashboard once
  this app has synced, so external-dns creates its own owned record pointing
  at the Gateway's LB IP. Every previous app that moved from Caddy into the
  cluster (`home`, `search`, `argocd`) used a hostname Caddy never served,
  so this is the first time this specific collision has actually come up —
  worth checking for the same gotcha on the next Caddy→k8s migration.
- **`ntfy.lan` (the UniFi local-DNS entry Caddy used internally to reach the
  compose container on rpi5-1) is no longer needed by anything** once the
  Caddyfile block is gone — safe to delete outright, not repoint. Any
  device/integration that was talking to `ntfy.lan` directly (bypassing
  Caddy) rather than `ntfy.jakerobb.org` needs to be repointed by hand;
  nothing in this repo can enumerate those (Home Assistant's own notify
  config, for one, isn't tracked here).
- **Homepage entry converted to `gethomepage.dev/*` annotation-based
  discovery** (on the new `HTTPRoute`), replacing the manual `services.yaml`
  entry it had before — same pattern searxng's `httproute.yaml` established
  first.

## Headlamp (decided and deployed 2026-09-21)

Kubernetes GUI, replacing OpenLens (unmaintained upstream). Chosen over
FreeLens/Portainer/Rancher specifically for OIDC: it's the only one of the
four with free, native (non-proxy, non-paid-tier) OIDC login support, and
it's the official Kubernetes SIG-UI-recommended successor to the now-archived
Kubernetes Dashboard. Deployed as [`apps/headlamp/`](apps/headlamp/application.yaml),
bare manifests (no official chart — see the reasoning at the top of
[`manifests/headlamp/deployment.yaml`](../manifests/headlamp/deployment.yaml))
at [`manifests/headlamp/`](../manifests/headlamp/).

- **Auth: real OIDC, not Gateway forward-auth** — same call already made for
  ArgoCD (see "Authelia SSO" above), for the same reason: Headlamp supports
  OIDC login natively, so stacking Cilium's `ExternalAuth` filter in front
  would just mean logging into Authelia twice against the same IdP.
- **RBAC: cluster-admin, no per-user distinction** (decided with Jake
  2026-09-21) — see the comment on
  [`manifests/headlamp/clusterrolebinding.yaml`](../manifests/headlamp/clusterrolebinding.yaml).
  Headlamp runs in `-in-cluster` mode using its own ServiceAccount's token
  for every API call; OIDC only gates who can reach the UI, not what they
  can do once in. Fine for a single-admin homelab; revisit (real
  kube-apiserver OIDC + per-user RBAC) if a second, less-trusted user ever
  gets an Authelia account.
- **Exposure:** `HTTPRoute` on `homelab-gateway`
  ([`manifests/headlamp/httproute.yaml`](../manifests/headlamp/httproute.yaml)),
  hostname `headlamp.jakerobb.org`, discovered by Homepage via
  `gethomepage.dev/*` annotations into the Infrastructure tab.
- **Secrets:** same out-of-band pattern as Cloudflare/Authelia/Renovate above
  (no SOPS/KSOPS wired into ArgoCD sync yet). Two things need generating
  together — the plaintext client secret (goes in the k8s Secret Headlamp
  reads) and its pbkdf2-sha512 hash (goes in Authelia's client config, safe
  to commit since it's one-way, same as ArgoCD's own client above):

  ```bash
  docker run --rm authelia/authelia:4.39.28 authelia crypto hash generate pbkdf2 --variant sha512 --random
  ```

  This prints a `Random Password:` and a `Digest:` line. Paste the `Digest`
  value over the `CHANGEME-see-argocd/README.md#headlamp` placeholder in
  [`apps/authelia/application.yaml`](apps/authelia/application.yaml)'s
  `headlamp` client — safe to commit, it's a one-way hash. Keep the
  `Random Password` value for the next step only; it's the real secret and
  shouldn't be pasted anywhere else:

  ```bash
  read -rsp "Headlamp OIDC client secret (the Random Password from above): " SECRET; echo
  cat > argocd/secrets/headlamp-oidc-client-secret.sops.yaml <<EOF
  apiVersion: v1
  kind: Secret
  metadata:
    name: headlamp-oidc-client-secret
    namespace: headlamp
  stringData:
    client-secret: ${SECRET}
  EOF
  sops -e -i argocd/secrets/headlamp-oidc-client-secret.sops.yaml
  unset SECRET
  ```

  Apply once the `headlamp` namespace exists (after `root-app.yaml` has
  synced at least once):

  ```bash
  export KUBECONFIG=~/.kube/config
  sops -d argocd/secrets/headlamp-oidc-client-secret.sops.yaml | kubectl apply -f -
  ```

  `git add argocd/secrets/headlamp-oidc-client-secret.sops.yaml` and
  commit — safe, it's encrypted. Until both this and the `Digest` edit
  above are done, Headlamp's pod runs fine but its OIDC login will fail
  (`invalid_client` from Authelia).

## Bootstrap (one-time, manual)

From a machine with `helm`/`kubectl` pointed at the cluster
(`KUBECONFIG=~/.kube/config`, the default path — no need to export it):

<!-- renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm -->
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm install argocd argo/argo-cd \
  --version 10.9.2 \
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

## SigNoz (decided and deployed 2026-09-22)

Cluster observability (logs/metrics/traces in one stack) — closes out
`todo/READY.md`'s "Log and Metrics aggregation" item. Runs on
`talos-worker-mbp` (see
[`talos/README.md`](../talos/README.md#additional-worker-talos-worker-mbp-added-2026-09-22)),
a deliberately temporary node — every stateful piece is on `hexos-iscsi`
specifically so retiring that node later needs no data migration.

**Chart:** `signoz/signoz` from `https://charts.signoz.io`, `0.142.1` —
verified live (`helm show values`), not assumed. Architecture is heavier
than older docs suggest: ClickHouse deploys via a bundled Altinity
`clickhouse-operator` (CRD-based `ClickHouseInstallation`), with ZooKeeper
still in the mix. PostgreSQL and Redpanda (a Kafka-style queue) are real
chart components but default **off** — redpanda alone defaults to 3
replicas × 7 CPU / 28GB RAM each, never enable without deliberately
revisiting the node's resource budget first.

**CRDs:** the clickhouse-operator's 3 CRDs (shipped in the chart's `crds/`
folder, which ArgoCD's Helm source never processes — same reasoning as
`kube-prometheus-stack`) were installed once, out-of-band:
```bash
helm pull signoz/signoz --version 0.142.1 --untar --untardir /tmp/signoz-chart
kubectl create -f /tmp/signoz-chart/signoz/charts/clickhouse/crds/
```
Re-run against any future chart bump that touches ClickHouse's CRD schema.

**Storage:** `global.storageClass: hexos-iscsi`, set again explicitly per
component (`clickhouse.persistence`, `clickhouse.zookeeper.persistence`,
`signoz.persistence`) rather than trusting only the global default — cheap
insurance, confirmed live via `helm template` that all three actually
resolve to `hexos-iscsi` before ever applying. ClickHouse PVC bumped to
`30Gi` (chart default `20Gi`).

**Storage validated before trusting it** (per the task's own requirement —
first real database-shaped, latency-sensitive small-random-I/O workload on
`hexos-iscsi`; everything else there today, like Authelia's SQLite file, is
much lighter): a throwaway `fio` 4K random read/write benchmark
(`iodepth=8`, `direct=1`) pinned to `talos-worker-mbp` via `nodeSelector`
against a fresh `hexos-iscsi` PVC —

```
READ:  IOPS=2997, BW=11.7MiB/s, avg latency=1.27ms, p99=2.8ms, p99.9=5.4ms
WRITE: IOPS=2988, BW=11.7MiB/s, avg latency=1.34ms, p99=3.2ms, p99.9=6.8ms
```

Good enough for ClickHouse's needs on a homelab-scale deployment — sub-2ms
average latency at ~3000 IOPS/direction, comparable to a reasonable
consumer SSD despite being network-attached iSCSI.

**Resource budget** (chart defaults are token-sized — 100m/200Mi requests,
*no limits at all* — fine for a toy install, not for real use):

| Component | Requests | Limits |
|---|---|---|
| ClickHouse | 500m / 2Gi | 2 / 6Gi |
| ZooKeeper | 100m / 256Mi | 500m / 512Mi |
| SigNoz core | 100m / 256Mi | 500m / 1Gi |
| otel-collector | 100m / 256Mi | 1 / 1Gi |

Comfortably under the VM's 24GB even with Cilium/node-exporter/kubelet
overhead on the same node.

### Gotcha: nothing works until first-run signup is completed

The otel-collector's baked-in `ConfigMap` is only a *bootstrap* config — the
real running pipeline is activated dynamically via OpAmp, which requires an
org to exist. Every agent-registration attempt fails
(`"cannot create agent without orgId"`, logged repeatedly by `signoz-0`)
until SigNoz's own first-run signup (creating the initial admin
account/org) is completed through its web UI. Until that happens, the
collector's extensions/healthcheck report `ready` — looking healthy — while
literally zero receivers/exporters/pipelines are actually running, silently
dropping everything. Completed via `kubectl port-forward svc/signoz
8080:8080` and the signup form at `/`; the admin credential is stored
encrypted at
[`argocd/secrets/signoz-admin-credentials.sops.yaml`](secrets/signoz-admin-credentials.sops.yaml)
(not a Kubernetes `Secret` consumed by any pod — SigNoz keeps its own users
in ClickHouse — this file exists purely as a durable encrypted record, same
SOPS+age convention as everything else here). A `ConfigMap` change also
doesn't hot-reload into the collector Deployment — `kubectl rollout
restart` is needed after any `otelCollector.config` edit for it to actually
take effect.

### Metrics: federation, not remote_write (task assumption corrected)

The task's original plan assumed SigNoz accepts Prometheus `remote_write`
directly. **Confirmed false** — checked rather than configured blind:
this chart's otel-collector metrics pipeline only takes an `otlp` receiver
by default (no `prometheusremotewrite` receiver anywhere), and a SigNoz
maintainer directly confirmed "No" to both a remote_write endpoint and
direct Prometheus scraping
([SigNoz/signoz#9489](https://github.com/SigNoz/signoz/discussions/9489)) —
SigNoz wants OTLP, with Prometheus-format metrics going through an OTel
Collector `prometheus` receiver first.

Fix: `otelCollector.config` in
[`apps/signoz/application.yaml`](apps/signoz/application.yaml) adds a real
`prometheus` receiver scraping `kube-prometheus-stack`'s Prometheus via its
`/federate` endpoint — `kube-prometheus-stack` itself is completely
untouched, SigNoz just becomes another read-only consumer of the same data.
(Considered and rejected: switching `kube-prometheus-stack`'s Prometheus to
Agent mode — it only *outputs* via remote_write, so it wouldn't have solved
the receiving-side gap either, and Agent mode drops local storage/rule
evaluation entirely, which the existing Alertmanager/ntfy alerting depends
on. Federation leaves that completely undisturbed.)

**Second gotcha, found live:** a catch-all `match[]={__name__=~".+"}`
silently returns **zero bytes** (`HTTP 200`, empty body) against this
Prometheus's `/federate` endpoint — confirmed via direct `curl` from inside
the cluster. Prometheus's own docs discourage replicating the whole dataset
via federation anyway. Fixed with curated per-job selectors matching
exactly what the task asked for:
```
match[]:
  - '{job="kube-state-metrics"}'
  - '{job="node-exporter"}'
  - '{job="kube-scheduler"}'
  - '{job="kube-controller-manager"}'
  - 'up'
```
Deliberately **excludes** `kubelet`/cadvisor and `apiserver` — confirmed
live that including `kubelet` alone balloons a single scrape from 11.6MB to
67MB, from per-container-per-node cardinality that isn't part of what was
actually requested. `scrape_interval: 60s` (not the receiver's usual `30s`)
given the payload size. Verified end-to-end: `kube_pod_info`,
`node_cpu_seconds_total`, `up`, `node_memory_MemAvailable_bytes`,
`kube_deployment_status_replicas` all present in
`signoz_metrics.distributed_time_series_v4` after a scrape cycle.

### Logs + host metrics: signoz/k8s-infra, not the main chart

The main `signoz` chart has no DaemonSet of its own and doesn't tail
container logs at all — confirmed by rendering it (`kind: DaemonSet`
appears zero times). SigNoz's actual answer is a separate chart,
`signoz/k8s-infra` (0.17.1,
[`apps/signoz-k8s-infra/application.yaml`](apps/signoz-k8s-infra/application.yaml)),
deployed into the same `signoz` namespace as its own `Application` (same
pattern as `cert-manager-config` sharing `cert-manager`'s namespace) — a
DaemonSet (`otelAgent`) tailing `/var/log/pods/*/*/*.log` by default plus a
small cluster-level `Deployment` (`otelDeployment`) for K8s object/event
metrics. This is the piece that actually closes the "ship pod and node
logs" half of `todo/READY.md`, not just the metrics side. Runs on all 6
nodes including the tainted arm64 Pi5 control planes (default tolerations
`- operator: Exists`, confirmed multi-arch image support live).

**Same PodSecurity gap `kube-prometheus-stack`'s `node-exporter` hit
first:** `otelAgent`'s hostPath mounts + hostPorts violate Talos's
cluster-wide `baseline` PodSecurity default (every namespace except
`kube-system`). Fixed identically — `managedNamespaceMetadata` on the main
`signoz` app (which owns the shared namespace via `CreateNamespace=true`):
```yaml
managedNamespaceMetadata:
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
```
**Gotcha:** the DaemonSet controller doesn't proactively retry
`FailedCreate` pods once the namespace is relabeled — it sat at
`CURRENT: 0` indefinitely even minutes after the fix. `kubectl rollout
restart daemonset` forced an immediate retry, which then succeeded cleanly.

**Gotcha, `k8s-infra`'s own OTLP exporter:** the chart's default is the
`otlphttp` exporter (`presets.otlphttpExporter.enabled: true`), not `otlp`
(grpc) — pointing `otelCollectorEndpoint` at `<host>:4317` (the grpc port,
bare `host:port`) against the *HTTP* exporter fails outright
(`"unsupported protocol scheme"`, since there's no `http://` prefix and the
wrong port besides). Fixed by explicitly switching to the grpc exporter
(`presets.otlpExporter.enabled: true`, `presets.otlphttpExporter.enabled:
false`) rather than prefixing `http://` and pointing at `4318` — one fewer
moving part, matches `signoz-otel-collector`'s plain `otlp.protocols.grpc`
endpoint.

**Done (2026-09-22): rpi5-1's own Compose-host logs, dual-shipped.** Vector
(`docker-compose/vector/vector.yaml`) now sends every source (`docker`,
UniFi CEF syslog, journald) to both VictoriaLogs (unchanged, kept as the
proven fallback during SigNoz's trial period — same "don't tear down until
it's earned it" call as Alertmanager) and SigNoz's OTel Collector.

- **Ingestion path:** a second, dedicated `HTTPRoute`
  ([`apps/signoz/httproute-otel.yaml`](apps/signoz/httproute-otel.yaml)),
  `otel.jakerobb.org`, deliberately separate from the UI's
  Authelia-gated route — an interactive login filter would just break
  Vector's plain OTLP/HTTP POSTs, and mixing an authenticated human route
  with an unauthenticated machine one under the same hostname is easy to
  get wrong later. Same trust model as everything else on this Gateway (LB
  pool IP is LAN-only regardless of the public DNS record).
- **Gotcha, real leftover DNS:** `otel.jakerobb.org` already existed as a
  stale Cloudflare CNAME (`→ caddy.lan → rpi5-1.lan`) from the old Caddy
  setup, predating this repo's Compose capture. external-dns still created
  the new `A` record cleanly (Cloudflare allowed the replacement), but
  rpi5-1's own Unbound resolver kept serving the old cached CNAME chain
  until manually flushed (`unbound-control flush otel.jakerobb.org` +
  the two names in the chain) — worth checking for on any future
  Compose→cluster hostname reuse, same as the TXT-ownership gotcha in
  `docs/adding-an-app.md` §3.
- **Gotcha, the `otlp` codec is a passthrough, not a converter:** Vector's
  `opentelemetry` sink refused every event
  (`"Log event does not contain OTLP top-level fields"`) until a `remap`
  transform ahead of it built the actual
  `resourceLogs`/`scopeLogs`/`logRecords` structure by hand — the codec
  only serializes events already shaped that way (e.g. from Vector's own
  `opentelemetry` *source*), it doesn't wrap arbitrary log fields into
  OTLP on its own. One transform per source
  (`docker_otlp`/`unifi_otlp`/`pi_journal_otlp`), each building a minimal
  but valid envelope (timestamp, message body, a handful of attributes
  matching what VictoriaLogs's `_stream_fields` already considered
  important per source) rather than dumping every raw field generically.
- **Gotcha — `to_string(.missing) ??  fallback` doesn't fall through:** UniFi log bodies were landing
  completely empty despite `.message` genuinely having real content one
  field over. Root cause, confirmed via `vector vrl`: VRL's `to_string()`
  returns `""` for a field that doesn't exist at all — **no error** — so
  `to_string(.msg) ?? to_string(.message) ?? to_string(.name)` locks onto
  the first field's empty string and never tries the rest; `??` only ever
  catches genuine errors, and an absent field apparently isn't one for this
  function. Fixed by checking emptiness explicitly
  (`if body == "" { body = to_string(.message) ?? "" }`) instead of
  chaining on error-fallthrough. Same session also caught `docker_otlp`
  tagging every log with the *container's* own hostname (Docker defaults
  that to its short container ID) instead of the host machine — the
  `docker_logs` source's `.host` field was never actually absent, just
  wrong, so the same `?? "rpi5-1"` pattern silently never triggered there
  either. Fixed by hardcoding `"rpi5-1"` outright, same as the other two
  sources already did.
- Verified end-to-end, post-fix: real UniFi message bodies
  (`kernel: [DHCP-SM]...`, `mcad[...]: wireless_agg_stats...`) landing
  correctly, and docker logs consistently tagged `host.name = 'rpi5-1'`
  with zero stray container-ID hostnames across a tight (15s) fresh
  window in `signoz_logs.distributed_logs_v2`.

### Exposure: Gateway + Authelia forward-auth

`signoz.jakerobb.org` via the shared `homelab-gateway`
([`apps/signoz/httproute.yaml`](apps/signoz/httproute.yaml) — sits beside
`application.yaml` rather than under a `manifests/signoz/` dir, since
`signoz` itself sources entirely from the external chart; same "small
resource tightly coupled to its parent app" exception as
`apps/authelia/referencegrant.yaml`, picked up by root's own recursive
directory scan). Gated by Authelia's `ExternalAuth` forward-auth filter
(same pattern as `searxng`), **not** native OIDC — SigNoz Community
Edition's OIDC support is enterprise/cloud-only (checked against SigNoz's
own docs/changelog before assuming otherwise). Needs the matching
`access_control` rule (`apps/authelia/application.yaml`) and
`ReferenceGrant` entry (`apps/authelia/referencegrant.yaml`) — both added.

### ClickHouse CPU tuning (2026-09-23)

**Symptom:** ClickHouse (`chi-signoz-clickhouse-cluster-0-0-0`) sat at a
steady ~1.7–1.9 cores in `kubectl top` against a 2-core limit, putting
`talos-worker-mbp` at ~46–50% CPU, for a homelab-sized ingest volume.
(Separately, an SELinux audit flood on the same volume turned out *not* to
be the cause; see `talos/README.md` "SELinux labels on iSCSI volumes".)

**Where the CPU actually went** (10-minute window, from ClickHouse's own
`system.metric_log`, `query_log`, `part_log` and `trace_log`):

| | Baseline |
|---|---|
| ClickHouse self-reported CPU (`OSCPUVirtualTimeMicroseconds`) | 1.13 cores |
| INSERT queries | 8,447 (~14/sec) |
| New parts, `signoz_logs.logs_v2` / `tag_attributes_v2` | 595 / 600 |
| New parts, `signoz_metrics.samples_v4` | 146 |
| `system.trace_log` rows written | 1.23M |
| Merge CPU: `system.trace_log` | ~88 CPU-s |
| Merge CPU: `signoz_logs.logs_v2` | ~86 CPU-s (re-merging only ~85 MiB) |
| INSERT CPU (all tables) | ~46 CPU-s |

Two separate problems:

1. **ClickHouse profiling itself.** The chart enables `trace_log` (plus
   `zookeeper_log`, `processors_profile_log` and `query_thread_log`), and
   ClickHouse 25.x's global profiler samples every thread every 10s. With
   a 512-thread background schedule pool, that plus merge memory-profiler
   stack traces came to ~2,000 trace rows/sec. `trace_log` had grown to
   **3.16 GiB / 114M rows**, bigger than all the real SigNoz data combined
   (~350 MiB), and merging it cost as much CPU as merging the actual logs.
   On top of that comes the unmeasured cost of capturing stack traces.
2. **No batching on ingest.** The chart's otel-collector `batch` processor is
   `send_batch_size: 50000, timeout: 1s`. Homelab volume never gets near
   50k, so it flushes every second: one INSERT/sec into each of `logs_v2`,
   `tag_attributes_v2`, the logs resource/key tables, metadata, and so on.
   Each INSERT creates a new part, and `logs_v2`'s skip indexes make its
   merges expensive, so the same small amount of data got re-merged
   constantly.

**Fix** (all in [`apps/signoz/application.yaml`](apps/signoz/application.yaml)):
- `clickhouse.files."config.d/zz-homelab-tuning.xml"`: global profiler off,
  and `trace_log`, `zookeeper_log`, `processors_profile_log`,
  `query_thread_log` removed (`remove="1"`). The `zz-` prefix makes it sort
  after the operator's `01-clickhouse-*.xml` system-log definitions.
  `query_log`, `part_log`, `metric_log`, `text_log`, `error_log` and
  `asynchronous_metric_log` are kept, since they're cheap and are exactly
  what this diagnosis ran on.
- `clickhouse.profiles`: per-query profilers off and
  `log_processors_profiles: 0` for the `default` profile, which the
  collector's `admin` user also uses.
- `otelCollector.config.processors.batch.timeout: 10s`: logs can take up
  to 10s longer to appear in SigNoz.
- **Not done: `async_insert`.** Collector-side batching gets the same
  "fewer, bigger inserts" effect without adding a second buffering layer
  with its own flush and durability semantics. Revisit only if part counts
  stay high after the batch change.

Removing a system log from config doesn't drop the existing table, so the
old `system.trace_log` (3+ GiB) and `system.zookeeper_log` stay on disk
until someone drops them by hand
(`DROP TABLE system.trace_log` / `system.zookeeper_log`). ClickHouse won't
recreate them while they're removed from config.

**After:** _pending, measured once the change is synced._

### Headlamp's Prometheus plugin: confirmed viable, not yet switched over

FreeLens is out — Jake is standardizing on Headlamp. Headlamp's *core*
resource-usage display depends on `metrics-server`, not Prometheus at all
(unaffected either way). Separately, Headlamp ships a built-in, manually
enabled Prometheus plugin (Settings → Plugins → Prometheus, auto-detect
off, custom service address) that can point at any Prometheus-API-shaped
endpoint.

**Confirmed live:** SigNoz genuinely exposes a real Prometheus-HTTP-API-
compatible endpoint (`/api/v1/query`, `/api/v1/query_range`) — not just a
custom schema. `curl`'d it directly (via a browser-session JWT for the
test) and got back correctly-shaped Prometheus vector results, including
the federated `up` series. It requires `Authorization: Bearer <token>` —
SigNoz's Settings → API Keys is the durable way to mint one (the JWT used
for this test is a short-lived login-session token, not meant for this).
**Not yet wired into Headlamp** — that's Jake's hands, pointing Headlamp's
plugin at `https://signoz.jakerobb.org` (once exposure is live) with a
real API key, and reporting back whether the plugin's UI actually
round-trips correctly end-to-end. Only remove `kube-prometheus-stack` if
that's a clean yes.
