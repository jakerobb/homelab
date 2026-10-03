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
  ArgoCD's management yet — see [`../todo/DONE.md`](../todo/DONE.md#hexos-storage) — so
  prune's main hazard (deleting real stateful data that's missing from a
  manifest) doesn't apply yet. **Revisit this once storage-backed workloads
  (e.g. an NFS-backed `StorageClass` from the HexOS TODO) go under ArgoCD's
  management** — prune deleting a PVC can delete the underlying data,
  depending on the storage class's reclaim policy. Also worth remembering
  day-to-day: self-heal reverts manual `kubectl edit`/`kubectl scale` fixes on
  the next sync (~3 min) unless you pause auto-sync first.
- **Sync waves only order creation; retries do the rest (2026-09-25).**
  Root applies child `Application`s in `sync-wave` order, but it doesn't wait
  for one wave to be Healthy before the next. That needs a Lua health check
  for `argoproj.io/Application` in `argocd-cm`, which Argo CD dropped from its
  defaults in 1.8, and we deliberately don't add it. With it, one app stuck
  Degraded (democratic-csi whenever TrueNAS is down, say) would stall root's
  sync, so changes to later-wave Application manifests, like Renovate's chart
  bumps, would pile up behind it. So a dependent can come up before its
  dependency on a cold bootstrap: a webhook not answering yet, a namespace or
  Secret not there yet, cert-manager's CRDs (it installs its own) not
  registered yet. Auto-sync never re-attempts a failed sync of the same
  commit by itself (`selfHeal` only reacts to drift after a successful sync),
  so every automated Application carries the same `retry` block: 10 attempts,
  backing off from 30s up to 10m, about an hour in total. The waves still set
  a sensible order, which means fewer retries. The exceptions: `cilium`
  (manual sync only), and root itself, which only creates `Application`
  objects.
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
  which need cert-manager's CRDs to already exist) is wave `1`. Waves only
  order creation (see "Sync waves only order creation" above). On a cold
  bootstrap, `cert-manager-config` can fail until the CRDs register, and its
  retry policy covers that.
- **Cloudflare API token:** scoped to `Zone:DNS:Edit` on the `jakerobb.org`
  zone only (Cloudflare's built-in "Edit zone DNS" token template, restricted
  to that one zone). Needed by both cert-manager (DNS-01 solver) and
  external-dns, in their respective namespaces. **Not committed in plaintext
  anywhere** — it lives in 1Password (`homelab-k8s` vault, item
  `cloudflare-api-token`), and External Secrets Operator syncs the same item
  into both namespaces. See "Cloudflare token setup" below and "External
  Secrets Operator".

### Cloudflare token setup (one-time, manual)

1. Cloudflare dashboard → My Profile → API Tokens → Create Token → **Edit
   zone DNS** template → Zone Resources: restrict to the specific
   `jakerobb.org` zone → Create → copy the token (shown once).
2. Paste it into the `api-token` field of the `cloudflare-api-token` item in
   the `homelab-k8s` 1Password vault. ESO updates both namespaces' Secrets
   within 24 hours; see "Adding or rotating a secret" under "External
   Secrets Operator" to sync sooner.

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
  [HexOS storage TODO](../todo/DONE.md#hexos-storage) provides a real NFS/SMB
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
  (alongside `cert-manager`); `authelia` is wave `1`, so it's created after
  both. It doesn't wait for them to be healthy; retries cover that (see
  "Sync waves only order creation" above).
- **Secrets:** all from 1Password via External Secrets Operator
  ([`manifests/external-secrets-config/authelia.yaml`](../manifests/external-secrets-config/authelia.yaml)),
  items in the `homelab-k8s` vault:
  - `authelia-secrets` → Secret `authelia-secrets` in the `authelia`
    namespace (session/storage encryption keys, OIDC HMAC secret,
    password-reset JWT secret — all randomly generated, not
    human-memorable).
  - `authelia-users-database` → Secret `users-database` (the
    `users_database.yml` file itself, in the item's notes: one `jake`
    account, argon2id-hashed password).
  - `authelia-oidc-jwk` → Secret `oidc-jwk` (RSA-4096 private key Authelia
    uses to sign OIDC tokens, in the item's notes).
  - `argocd-oidc-client-secret` → Secret `argocd-oidc-authelia` in the
    `argocd` namespace: the plaintext OIDC client secret ArgoCD needs,
    referenced from `oidc.config` in [`install/values.yaml`](install/values.yaml)
    as `$argocd-oidc-authelia:clientSecret`. Authelia's own config only
    ever holds a one-way pbkdf2-sha512 hash of it (inline in
    [`apps/authelia/application.yaml`](apps/authelia/application.yaml),
    safe to commit since it's not reversible). Until 2026-09-24 this was a
    SOPS-encrypted Helm values fragment layered onto every ArgoCD
    `helm upgrade`; plain `-f argocd/install/values.yaml` is all it takes now.
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

Replaced the Docker Compose stack's Watchtower (removed 2026-09-28; every
image in `docker-compose/docker-compose.yml` is now pinned and bumped by
Renovate PRs like everything else) — see the
[`READY.md`](../todo/READY.md#compose-workload-migration) note this replaces.

- **PR-based, not in-place patching.** Watchtower silently swaps running
  containers; that model fights GitOps (git is supposed to be the source of
  truth for what's running). Instead, [Renovate](https://docs.renovatebot.com/)
  runs as a `CronJob` ([`manifests/renovate/`](../manifests/renovate/cronjob.yaml)) that
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
- **Schedule:** daily, 4:17am America/Detroit — the same off-peak slot
  Watchtower used to run in.
- **Image tag is pinned, not `:latest`** — deliberately, so the `kubernetes`
  manager picks it up and Renovate ends up opening a PR against its own
  CronJob when a new version ships.
- **GitHub token (one-time, manual):** Renovate needs a token that can push
  branches and open PRs against this repo. Create a **fine-grained personal
  access token** at GitHub → Settings → Developer settings → Fine-grained
  tokens, scoped to just `jakerobb/homelab`, with **Contents: Read and
  write** and **Pull requests: Read and write** repository permissions (add
  **Workflows: Read and write** too if `.github/workflows/` ever shows up).
  Save it as the `token` field of the `renovate-github-token` item in the
  `homelab-k8s` 1Password vault; ESO syncs it (see "External Secrets
  Operator").
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
  remote-write yet (see [`DONE.md`](../todo/DONE.md#log-and-metrics-aggregation-signoz)),
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
- **`crds.enabled: true`, applied server-side.** ArgoCD manages this chart's
  CRDs (changed 2026-10-02; they were installed by hand with `kubectl create`
  until then). 6 of the 10 CRDs (`Prometheus`, `Alertmanager`,
  `AlertmanagerConfig`, `ScrapeConfig`, `PrometheusAgent`, `ThanosRuler`) are
  600-900KB as authored, almost entirely OpenAPI schema. Client-side apply
  copies the whole manifest into the `last-applied-configuration` annotation
  and hits Kubernetes' 256KiB annotation cap (`metadata.annotations: Too
  long`). `ServerSideApply=true` avoids that by tracking ownership in
  `managedFields`. Two things are load-bearing, both found by a retest on
  2026-10-02 (ArgoCD v3.5.3, using a throwaway 900KB CRD under a fake API
  group; the real CRDs weren't touched):
  - `ServerSideApply=true` in the Application's `syncOptions`. Without it the
    sync fails with the annotation-too-long error. `Replace=true` isn't needed.
  - The `argocd.argoproj.io/compare-options: ServerSideDiff=true` annotation
    on the Application. Without it the CRDs sync but stay OutOfSync forever,
    because the client-side diff doesn't account for API-server defaulting.
    (An earlier attempt probably misread that OutOfSync as SSA not working.)
  Taking over CRDs created by `kubectl create` worked cleanly.
  **Consequence: CRD changes now ride along with `targetRevision` bumps; no
  manual re-apply.** (The hand-applied CRDs had drifted a patch release behind
  the chart: `operator.prometheus.io/version: 0.94.0` live against 0.94.1.)
  **Danger: this app has `prune: true`.** Removing the CRDs from the chart, or
  flipping `crds.enabled` back to `false`, would delete the CRDs and every
  Prometheus/Alertmanager/ServiceMonitor/PrometheusRule with them. Before ever
  going back to manual CRDs, annotate each live CRD with
  `argocd.argoproj.io/sync-options: Prune=false`, or turn off prune for the app.

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
- **Secrets:** from 1Password via External Secrets Operator, like the rest.
  Two things need generating
  together — the plaintext client secret (goes in the k8s Secret Headlamp
  reads) and its pbkdf2-sha512 hash (goes in Authelia's client config, safe
  to commit since it's one-way, same as ArgoCD's own client above):

  ```bash
  docker run --rm authelia/authelia:4.39.28 authelia crypto hash generate pbkdf2 --variant sha512 --random
  ```

  This prints a `Random Password:` and a `Digest:` line. Paste the `Digest`
  value over the `CHANGEME-see-argocd/README.md#headlamp` placeholder in
  [`apps/authelia/application.yaml`](apps/authelia/application.yaml)'s
  `headlamp` client — safe to commit, it's a one-way hash. Put the
  `Random Password` in the `client-secret` field of the
  `headlamp-oidc-client-secret` item in the `homelab-k8s` 1Password vault,
  and nowhere else. Until both are done, Headlamp's pod runs fine but its
  OIDC login will fail (`invalid_client` from Authelia).

## External Secrets Operator (decided and deployed 2026-09-24)

Every Secret a cluster workload needs comes from 1Password through
[External Secrets Operator](https://external-secrets.io/) (ESO). This
replaced hand-applying SOPS files (`sops -d argocd/secrets/... | kubectl
apply -f -`), which ArgoCD had no way to do itself.

- **Why ESO + 1Password:** considered KSOPS (SOPS decryption inside
  ArgoCD's repo-server), sops-secrets-operator, Sealed Secrets, and running
  Vault/OpenBao. The SOPS-based options all need the age private key inside
  the cluster, and KSOPS also needs Kustomize. Vault is a stateful HA service
  with unsealing and its own bootstrap problem, which is too much for one
  user. 1Password already holds the age key, so it adds no new system to
  trust. The cluster gets a revocable, read-only token for one vault, and
  rotating a value is an edit in 1Password with no re-encrypting or
  committing.
- **Vault:** `homelab-k8s`, holding only what the cluster reads. A
  1Password service account (`homelab-external-secrets`) has `read_items` on
  that vault and nothing else, so a leaked token exposes nothing the cluster
  doesn't already have. Service accounts can't be granted Personal/Private
  vaults at all.
- **Item convention:** one Secure Note per Kubernetes Secret, titled after
  the Secret (the Cloudflare token is one item that feeds two namespaces).
  Each Secret key is a concealed field with the same label. Multi-line
  values (Authelia's users database and JWK) go in the note's own notes
  field instead, referenced as `<item>/notesPlain`.
- **Manifests:** the operator is [`apps/external-secrets/`](apps/external-secrets/application.yaml)
  (sync-wave -1). The `ClusterSecretStore` and every `ExternalSecret` are in
  [`manifests/external-secrets-config/`](../manifests/external-secrets-config/),
  one file per consuming app, synced by
  [`apps/external-secrets-config/`](apps/external-secrets-config/application.yaml)
  (wave 0). They're centralized because most consumers are Helm-only
  Applications with no `manifests/` directory of their own.
- **Refresh:** `refreshInterval: 24h` on every `ExternalSecret` (was `1h` until
  2026-10-02). The binding limit is 1Password's *daily* cap of 1,000 combined
  requests (Individual/Families; rolling 24h window, shared by every service
  account). The 1Password SDK provider costs more than one request per field,
  so hourly refreshes of 18 ExternalSecrets used about 1,000 a day. On
  2026-10-02 the store hit the cap at 03:04 EDT and every ExternalSecret
  failed with `rate limit exceeded` until 10:06, exactly 24h after the ESO pod
  started at 10:04 the day before (the restart re-reads everything at once).
  Failed retries (~150/hour) probably kept it pegged. Nothing broke, since the
  last synced Secrets stayed in place. Cost of the longer interval: a rotated
  value can take up to 24h to land, so force a sync (below) when it matters,
  and note that every ESO restart re-reads all ExternalSecrets in one burst.
- **1Password outages:** ESO copies values into ordinary Secrets in etcd, and
  pods read those, never 1Password. During an outage, running pods, restarts,
  reschedules and node reboots all keep working. Only new or changed values
  wait. A failed refresh leaves the existing Secret untouched, and
  `ExternalSecretNotSynced` fires after 30 minutes
  ([`prometheusrule.yaml`](../manifests/external-secrets-config/prometheusrule.yaml)).
- **Deleting an `ExternalSecret` deletes its Secret** (the default
  `creationPolicy: Owner`). Removing an entry from git, or a careless prune,
  takes the Secret with it. Putting it back recreates the Secret from
  1Password on the next sync.
- **Changes don't restart pods.** Anything reading a Secret through an env
  var (most of these) keeps the old value until the pod restarts. Restart
  the Deployment after rotating a value. Files mounted from a Secret update
  in place, but only apps that re-read them notice.
- **democratic-csi's driver config** is an ESO template: the whole file is in
  [`democratic-csi.yaml`](../manifests/external-secrets-config/democratic-csi.yaml),
  and only the TrueNAS API key comes from 1Password. Edit it there.

### Adding or rotating a secret

To rotate a value, edit the field in the `homelab-k8s` vault. To add one,
create a Secure Note there (one concealed field per Secret key) and add an
`ExternalSecret` to `manifests/external-secrets-config/<app>.yaml`. Either
way, sync now instead of waiting up to 24 hours (on rpi5-1):

```bash
kubectl -n <namespace> annotate externalsecret <name> force-sync=$(date +%s) --overwrite
```

Then restart whatever reads it, if it reads it through an env var.

### ESO bootstrap (one-time, manual)

Two things ESO can't do for itself. First, its CRDs, installed out-of-band
like every other chart's (see "External Secrets Operator CRDs" below).
Second, the service-account token, which lives SOPS-encrypted at
[`secrets/onepassword-service-account.sops.yaml`](secrets/onepassword-service-account.sops.yaml)
and is the only file left in `argocd/secrets/`. It was created by a one-shot
migration script (`scripts/migrate-to-1password.py`, removed after cutover
along with the old SOPS files it read; see git history).
To apply it (on the Mac, which has the age key):

```bash
sops -d argocd/secrets/onepassword-service-account.sops.yaml | ssh jakerobb@rpi5-1.lan kubectl apply -f -
```

To replace the token (lost, leaked, or expired), create a new service account
with the same vault access. Then save its token to that file with
`sops argocd/secrets/onepassword-service-account.sops.yaml`, re-apply, and
delete the old service account in 1Password.

### External Secrets Operator CRDs (one-time, manual, and again on every chart upgrade)

`installCRDs: false`, same blanket rule as the other charts: CRDs stay out
of ArgoCD's hands. Here it's also forced. `ClusterSecretStore` and
`SecretStore` are ~724KB each as rendered, because every provider's schema is
inlined, and that's far past the 256KiB annotation limit. ESO changes its
CRDs in most minor releases, so **re-apply on every `targetRevision` bump**
(on rpi5-1, with `<version>` from
[`apps/external-secrets/application.yaml`](apps/external-secrets/application.yaml)):

```bash
kubectl apply --server-side -f https://raw.githubusercontent.com/external-secrets/external-secrets/v<version>/deploy/crds/bundle.yaml
```

Server-side apply sidesteps the annotation limit, and unlike `kubectl
create`, it works for both the first install and upgrades.

## Bootstrap (one-time, manual)

From a machine with `helm`/`kubectl` pointed at the cluster
(`KUBECONFIG=~/.kube/config`, the default path — no need to export it):

<!-- renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm -->
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm install argocd argo/argo-cd \
  --version 10.9.6 \
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
8080:8080` and the signup form at `/`; the admin credential is stored in
Jake's own 1Password vault as "SigNoz admin (homelab)" (not the cluster's
`homelab-k8s` vault: no pod consumes it, since SigNoz keeps its own users
in ClickHouse). A `ConfigMap` change also
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
it's earned it" call as Alertmanager) and SigNoz's OTel Collector. (Since
2026-10-01 SigNoz is the only destination; VictoriaLogs was retired.)

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

One exception (2026-09-27): `/api/v2/dashboards` skips Authelia, so
[`terraform/signoz`](../terraform/signoz/README.md) can manage dashboards
with a service-account API key. SigNoz checks the key or session itself on
every route under that path. Only that path is open, since opening all of
`/api/` would put SigNoz's own password login in front of the LAN without
Authelia's 2FA.

### ClickHouse CPU tuning (2026-09-23)

**Symptom:** ClickHouse (`chi-signoz-clickhouse-cluster-0-0-0`) sat at a
steady ~1.7–1.9 cores in `kubectl top`, right at its 2-core limit, putting
`talos-worker-mbp` at ~46–50% CPU for a homelab-sized ingest volume.
(Separately, an SELinux audit flood on the same volume turned out *not* to
be the cause; see `talos/README.md` "SELinux labels on iSCSI volumes".)

**Result** (10-minute windows, from ClickHouse's own `system.metric_log`,
`query_log` and `part_log`, plus `kubectl top`):

| | Before | After |
|---|---|---|
| ClickHouse pod CPU (`kubectl top`) | 1.7–1.9 cores | 0.32–0.41 cores |
| `talos-worker-mbp` node CPU | 2.74 cores (46%) | 1.16 cores (19%) |
| ClickHouse self-reported CPU (`OSCPUVirtualTimeMicroseconds`) | 1.13 cores | 0.19 cores |
| MergeMutate thread CPU (sampled from `/proc/<pid>/task/*/stat`) | 1.48 cores | 0.06 cores |
| Failed merges on `system.metric_log` | ~120 (7,169/hour) | 0 |
| INSERT queries | 8,447 | 1,254 |
| New parts, `logs_v2` / `tag_attributes_v2` / `samples_v4` | 595 / 600 / 146 | 60 / 60 / 59 |
| Merge CPU, `logs_v2` | ~86 CPU-s | ~8 CPU-s |
| INSERT CPU (all tables) | ~46 CPU-s | ~9 CPU-s |
| `system.trace_log` rows written | 1.23M | 0 (table removed) |

Three separate problems, found in this order:

1. **ClickHouse profiling itself.** The chart enables `trace_log` (plus
   `zookeeper_log`, `processors_profile_log` and `query_thread_log`), and
   ClickHouse 25.x's global profiler samples every thread every 10s. Across
   a 512-thread background schedule pool, plus merge memory-profiler stack
   traces, that came to ~2,000 trace rows/sec. `trace_log` had grown to
   **3.16 GiB / 114M rows**, bigger than all the real SigNoz data combined
   (~350 MiB), and merging it cost ~88 CPU-s per 10 minutes.
2. **No batching on ingest.** The chart's otel-collector `batch` processor is
   `send_batch_size: 50000, timeout: 1s`. Homelab volume never gets near
   50k, so it flushed every second: one INSERT/sec into each of `logs_v2`,
   `tag_attributes_v2`, the resource/key tables, metadata, and so on. Each
   INSERT is a new part, and `logs_v2`'s skip indexes make its merges
   expensive.
3. **The actual bulk of the CPU: a `system.metric_log` merge failure loop.**
   Fixing 1 and 2 only moved ClickHouse's own number from 1.13 to 0.93
   cores. Per-thread `/proc` sampling then showed the MergeMutate threads
   alone at ~1.5 cores, far more than `part_log`'s successful-merge
   accounting explained. The cause: `metric_log` has **~1,550 columns** and
   small row counts, so ClickHouse chose *horizontal* merges, which buffer
   every column of every source part at once. Merging 8–14 parts wanted
   more than the 5.4 GiB server memory cap, so every attempt died with
   `MEMORY_LIMIT_EXCEEDED` (error 241) after doing most of the work, then
   retried: about 2 failures/sec, 67k in total, going back to 2026-09-22
   19:01, i.e. essentially since SigNoz was deployed. The only visible trace
   was `part_log` rows with `error = 241`, which is worth checking first if
   ClickHouse CPU looks high again:
   ```sql
   SELECT table, error, count() FROM system.part_log
   WHERE event_time > now() - INTERVAL 1 HOUR AND error != 0 GROUP BY ALL
   ```
   (Error 389, "part was deduplicated", also shows up there for
   `tag_attributes_v2`. That's normal insert deduplication, not a failure.)

**Fix** (all in [`apps/signoz/application.yaml`](apps/signoz/application.yaml)):
- `clickhouse.files."config.d/zz-homelab-tuning.xml"`:
  - global profiler off
  - `trace_log`, `zookeeper_log`, `processors_profile_log` and
    `query_thread_log` removed (`remove="1"`)
  - `metric_log` redefined with the operator's same engine/TTL/flush plus
    `SETTINGS vertical_merge_algorithm_min_rows_to_activate = 1,
    vertical_merge_algorithm_min_columns_to_activate = 1`, forcing vertical
    (column-at-a-time) merges

  The `zz-` prefix sorts it after the operator's `01-clickhouse-*.xml`
  system-log definitions, so it wins. `query_log`, `part_log`,
  `metric_log`, `text_log`, `error_log` and `asynchronous_metric_log` are
  kept: they're cheap and are exactly what this diagnosis ran on.
- `clickhouse.profiles`: per-query profilers off and
  `log_processors_profiles: 0` for the `default` profile, which the
  collector's `admin` user also uses.
- `otelCollector.config.processors.batch.timeout: 10s`: ~10x fewer
  inserts/parts. Logs can take up to 10s longer to appear in SigNoz.
- **Not done: `async_insert`.** Collector-side batching already gets
  "fewer, bigger inserts" without a second buffering layer with its own
  flush and durability semantics.
- **Not done: `metric_log`'s `<schema_type>transposed</schema_type>`**
  (ClickHouse 25.x's narrow metric/value layout). It would also fix the wide
  merges, but it's a bigger change than the merge setting, and the setting
  was enough.

The metric_log fix was verified live first with `ALTER TABLE
system.metric_log MODIFY SETTING ...` (same two settings) before being put
in config. When ClickHouse sees a system log table whose definition doesn't
match config, it renames the old one to `metric_log_0` and creates a new
one. That happened on 2026-09-23; `metric_log_0` held only 09-22 to 09-23
data and was dropped by hand on 2026-09-27.
The old `system.trace_log` and `system.zookeeper_log` (~4 GiB together)
were dropped by hand, since removing a system log from config doesn't drop
its existing table.

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

## Glance (trial, deployed 2026-09-23)

A second dashboard running alongside Homepage (not replacing it), as a
declarative trial of [Glance](https://github.com/glanceapp/glance). Homarr
was ruled out because its config lives in a database rather than files.
Deployed as [`apps/glance/`](apps/glance/application.yaml) →
[`manifests/glance/`](../manifests/glance/), at `glance.jakerobb.org`.

- **Kustomize, not a plain manifest directory** (the first app here to use
  it) — solely for `configMapGenerator`. Glance's file-watch auto-reload
  doesn't survive a ConfigMap volume update (the atomic symlink swap
  deletes the watched file, which Glance's docs say stops the watch for
  good), so without a hash-suffixed ConfigMap name, config edits would
  never reach a running pod. `glance.yml` and `custom.css` live as real
  files in that directory; any edit rolls the pod on sync. See the
  comment in [`kustomization.yaml`](../manifests/glance/kustomization.yaml).
- **Auth: Gateway forward-auth** (same `ExternalAuth` filter as
  homepage/searxng/signoz), Glance's own built-in login left off. Needed
  the `access_control` rule in [`apps/authelia/application.yaml`](apps/authelia/application.yaml)
  and a `glance` entry in [`apps/authelia/referencegrant.yaml`](apps/authelia/referencegrant.yaml).
- **Kubernetes widget via Prometheus, not the Kubernetes API.** Glance has
  no native Kubernetes widget; it's a `custom-api` widget querying
  kube-prometheus-stack's Prometheus in-cluster (node-exporter +
  kube-state-metrics). The Metrics API (what Homepage's widget uses)
  returns quantity strings (`123456789n`, `1234Ki`) that Glance's template
  language can't parse into numbers. Upshot: no ServiceAccount/RBAC for
  this pod at all.
- **Weather:** Glance's built-in `weather` widget (hourly bars) plus a
  `custom-api` widget over Open-Meteo's daily forecast for today's
  high/low and a 5-day view, which the built-in one lacks.
- **App links are a static `bookmarks` list** mirroring Homepage's
  (manual entries + annotation-discovered ones). Glance has no service
  discovery, so a new app needs a line in `glance.yml` as well as its
  `gethomepage.dev/*` annotations for as long as both dashboards run.
- **Font:** Helvetica via `custom.css`, with `tabular-nums` so changing
  numbers don't shift width (the stock JetBrains Mono gets that for free).

## truenas-exporter (deployed 2026-09-24)

Pool capacity/health for Glance's Storage widget, via Prometheus. Our own
exporter, [`jakerobb/truenas-exporter`](https://github.com/jakerobb/truenas-exporter)
(Go, `FROM scratch`, published to Docker Hub by that repo's GHA workflow),
deployed as [`apps/truenas-exporter/`](apps/truenas-exporter/application.yaml) →
[`manifests/truenas-exporter/`](../manifests/truenas-exporter/).

- **Why not TrueNAS's built-in Graphite export + `graphite_exporter`:**
  TrueNAS 25.10's generated `netdata.conf` sets `diskspace = no`, so the
  export carries no pool-space metrics at all. Re-enabling it means
  hand-editing `/etc/netdata/netdata.conf` on the HexOS host and redoing
  that after every update — not declarative, and HexOS may not allow it.
- **Why not REST from Glance directly:** TrueNAS 25.x answers the API key
  with `403` on the (deprecated) REST API. It works only over the JSON-RPC
  websocket API, which Glance's `custom-api` widget can't speak.
- **Why our own exporter:** the existing community ones had 0–5 stars and a
  single maintainer each, which is a poor fit for a code path holding a
  TrueNAS API key. Ours is about 300 lines with one dependency.
- **TLS:** `wss://` only (TrueNAS 25.04+ revokes API keys used over plain
  `ws://`). TrueNAS still has its factory self-signed cert (CN=localhost),
  so the exporter pins its SHA-256 fingerprint (`TRUENAS_TLS_FINGERPRINT` in
  the Deployment) rather than skipping verification. If the cert is ever
  regenerated, `truenas_up` goes to 0 and the pod logs the new fingerprint.
- **Scraping:** a `ServiceMonitor` (first one in this repo outside
  kube-prometheus-stack's own bundle), 60s interval. Each scrape opens a
  fresh websocket session; there's no background polling.
- **Metrics:** `truenas_pool_used_bytes`/`truenas_pool_available_bytes`
  (usable space from the pool's root dataset, matching the TrueNAS UI) and
  `truenas_pool_raw_*_bytes` (vdev capacity including parity), plus
  `truenas_pool_healthy`, `truenas_pool_status`, `truenas_up`. See the
  exporter's README for the full list.
- **Secret:** a dedicated API key (not Homepage's, so retiring Homepage
  doesn't break this): the `truenas-exporter-api-key` item in the
  `homelab-k8s` 1Password vault, synced by External Secrets Operator.

## unpoller (migrated from Docker Compose, 2026-09-28)

UniFi controller metrics (devices, clients, DPI, sites), polled from the
Cloud Gateway Fiber by [unpoller](https://github.com/unpoller/unpoller).
The first service moved under the "Compose workload migration" plan in
[`../todo/READY.md`](../todo/READY.md) (ntfy went earlier, on its own). Deployed as
[`apps/unpoller/`](apps/unpoller/application.yaml) →
[`manifests/unpoller/`](../manifests/unpoller/).

- **InfluxDB → Prometheus.** On Compose it wrote to InfluxDB's `unifi`
  bucket. Here it serves `/metrics` (unpoller's native Prometheus output),
  scraped by a `ServiceMonitor` every 30s, the same as truenas-exporter. The
  UniFi controller only updates traffic stats about every 30s, so
  `UP_PROMETHEUS_INTERVAL` (unpoller's cache refresh) matches that.
- **Long-term history lives in SigNoz.** Prometheus keeps only 10 days, so
  `{job="unpoller"}` was added to SigNoz's `/federate` selectors
  ([`apps/signoz/application.yaml`](apps/signoz/application.yaml)). Measured
  before enabling it: about 4.6k series and 1.1MB per scrape with DPI on
  (49 clients, 10 devices), roughly a tenth of the rest of the federated set.
  The InfluxDB `unifi` history was not migrated; unpoller's Influx and
  Prometheus schemas differ enough that it's not worth converting.
- **No PVC, no UI, no Authelia.** Unpoller is stateless and only exposes
  `/metrics` inside the cluster (no `HTTPRoute`), so there's nothing to put
  behind forward-auth.
- **Credentials:** the same read-only local UniFi account Compose used,
  from the `unpoller-unifi-credentials` item (`username`, `password`) in the
  `homelab-k8s` 1Password vault, synced by External Secrets Operator
  ([`../manifests/external-secrets-config/unpoller.yaml`](../manifests/external-secrets-config/unpoller.yaml)).
  Kept over a UniFi API key because those carry the creating admin's full
  permissions. The password is read with unpoller's `file://` prefix from
  the mounted Secret, so it doesn't show in `kubectl describe pod`.
- **Controller URL** is `https://gateway.lan` (same as Homepage's widget),
  not the `47Net.lan` name Compose used, which also resolves to three IPv6
  addresses.
- **Hardened pod.** The image is `distroless/static`, which defaults to
  root; the pod runs as 65532 with a read-only root filesystem and all
  capabilities dropped.
- **Dashboards** are in SigNoz, managed by Terraform
  ([`../terraform/signoz/unifi-dashboards.tf`](../terraform/signoz/unifi-dashboards.tf)):
  ports of unpoller's six stock Grafana dashboards, plus a UniFi Power
  dashboard for PoE, the PDU and the UPS Tower. They replace the InfluxDB
  versions in the Compose Grafana, which stopped getting data with this
  migration. They're PromQL, because federation delivers every series as an
  untyped gauge and SigNoz's query builder only offers `rate` on counters.

## nut-exporter (replaced Compose's NUT relay and web UI, 2026-09-29)

UPS metrics for both UPSes, the rack CyberPower CP1500PFCRM2U and the
office UniFi UPS Tower, from
[nut-relay](https://github.com/jakerobb/nut-relay).
Deployed as [`apps/nut-exporter/`](apps/nut-exporter/application.yaml) →
[`manifests/nut-exporter/`](../manifests/nut-exporter/). It replaced two
Compose services rather than moving them: `nut-influx-relay` (which wrote to
InfluxDB) and `nut-webui` (webnut).

- **Our own exporter.** nut-relay *is* nut-influx-relay, renamed and
  reworked the same day to add a Prometheus output alongside the InfluxDB
  one (one per process, picked by `output:` in its config; the InfluxDB
  mode is unchanged). In Prometheus mode it exports every numeric NUT variable as
  `nut_<variable>` with a `ups` label, `ups.status` as one 0/1 series per
  flag, and `nut_up` per UPS. Values from a failed poll are dropped after
  three missed polls rather than repeated. Details are in its README.
- **Why not DRuggeri/nut_exporter,** the usual choice (tried first): its
  NUT client library (`go.nut`, unchanged since 2024) sends `LIST CLIENT`
  and `GET NUMLOGINS` before reading anything. The Tower's NUT server
  answers both with `ERR INVALID-ARGUMENT`, and `go.nut` then waits for an
  end-of-list line that never comes. Our exporter only sends `LIST VAR`.
- **nut-upsd stays on rpi5-1.** The rack UPS is plugged into it over USB,
  and rpi5-1's own `nut-monitor` shuts it down on low battery. The exporter
  reads upsd over the LAN (`192.168.102.2:3493`) and the Tower directly
  (`192.168.0.9:3493`). Neither needs a login to read variables, so there's
  no credential.
- **Plain NUT to the Tower.** It also offers STARTTLS (which the old relay
  used), but plain reads work from every worker, and with a self-signed
  certificate TLS wouldn't be verified anyway.
- **Config** is `config.yaml`, turned into a ConfigMap by kustomize's
  `configMapGenerator` (same as Glance), so an edit rolls the pod.
- **Long-term history in SigNoz.** `{job="nut-exporter"}` was added to
  SigNoz's `/federate` selectors, about 100 series. The InfluxDB `upsd`
  history was not migrated.
- **Dashboard:** a section per UPS on SigNoz's Power dashboard (formerly
  "UniFi: Power",
  [`../terraform/signoz/dashboard-unifi-power.tf`](../terraform/signoz/dashboard-unifi-power.tf)).
  The Tower's section replaced the one built on unpoller's metrics, so both
  UPSes show the same panels.
- **Alerts** (new; nothing alerted on the UPSes before), per UPS:
  `UPSOnBattery` (1m), `UPSBatteryLow` (critical), `UPSOverloaded` (over
  80% of rated real power for 15m) and `UPSNotReporting` (`nut_up` 0 for
  5m), in
  [`../manifests/nut-exporter/prometheusrule.yaml`](../manifests/nut-exporter/prometheusrule.yaml).
- **Removed:** `nut.jakerobb.org` (its LAN route and Authelia rule), the
  Homepage and Glance tiles, and the relay's InfluxDB token from
  `docker-compose/.env.sops.env`.

## NetworkOptimizer (migrated from Docker Compose, 2026-09-28)

[NetworkOptimizer](https://github.com/Ozark-Connect/NetworkOptimizer) (UniFi
config auditing, LAN/WAN speed tests, path analysis). It replaces the
Compose `optimizer` and `network-optimizer-speedtest` services. Deployed as
[`apps/network-optimizer/`](apps/network-optimizer/application.yaml) →
[`manifests/network-optimizer/`](../manifests/network-optimizer/).

- **One pod, two containers.** The .NET app (`:8042` UI/API, `:5201` iperf3
  server) and the OpenSpeedTest nginx (`:3000`) share a pod so they always
  sit behind the same LoadBalancer IP on the same node.
- **Two ways in.**
  - `https://optimizer.jakerobb.org`: UI and API through the Gateway.
    `TRUSTED_PROXIES=10.244.0.0/16` (the pod CIDR Envoy connects from) makes
    the app honor `X-Forwarded-For`.
  - `http://speedtest.jakerobb.org:3005` and iperf3 on `:5201`: a dedicated
    L2 LoadBalancer IP, `192.168.102.129`. It's pinned so the address
    stays stable, and its DNS record comes from external-dns's new
    `service` source. The Gateway is skipped on purpose: upstream warns that
    proxies, and HTTP/2 multiplexing in particular, distort speed test
    results, and iperf3 isn't HTTP anyway. Plain HTTP on :3005 is how it
    worked on Compose too.
- **Networking trade-off (evaluated and kept, 2026-09-28).** Compose used
  `network_mode: host` on rpi5-1. Jake chose a LoadBalancer IP over
  `hostNetwork` pinned to one node, and after testing (see "Measured
  throughput" below) it stays:
  - The pod *prefers* nodes with `homelab.jakerobb.org/nic-speed-mbps` above
    9999 (the MS-A2 workers; see
    [`../talos/README.md`](../talos/README.md#node-nic-speed-labels-added-2026-09-28)),
    then above 1999. It can still fall back to any worker.
  - Only 10GbE workers may announce the IP
    ([`../talos/cilium/l2-announcement-policy-10g.yaml`](../talos/cilium/l2-announcement-policy-10g.yaml)),
    so the MBP's 2.5GbE link never carries test traffic even when it isn't
    running the pod.
  - Cilium's L2 announcements don't support `externalTrafficPolicy: Local`,
    so the lease holder may be the *other* MS-A2 worker. Traffic then takes
    an extra hop and is SNATed, and the app sees that node's IP instead of
    the client's. Browser speed test results aren't affected, since they're
    POSTed through the Gateway with `X-Forwarded-For`. iperf3 client
    attribution and path analysis may be. Check which node holds the lease
    with `kubectl -n kube-system get lease cilium-l2announce-network-optimizer-network-optimizer-lb`.
  - If this proves too lossy, the fallback is `hostNetwork` on one node,
    which needs a `privileged` PodSecurity label on the namespace.
  - **Path analysis uses the node's IP (changed 2026-09-28).** The app
    container's `HOST_IP` was `.129` at first, and every result failed with
    "Could not determine server position in network". The app looks
    `HOST_IP` up in UniFi's client list, and UniFi never sees a
    LoadBalancer IP as a client. It now comes from the downward API
    (`status.hostIP`), so it follows the pod to whichever worker it runs on,
    with no pinning. UniFi knows each worker's IP (the VM's own network
    adapter, on the MS-A2's switch port). Tests the app starts itself leave
    from that IP anyway, because pod egress is masqueraded to the node.
  - **Known upstream bug: VMs behind a hypervisor.** UniFi reports the
    MS-A2 VMs' uplink as the `proxmox` client (`192.168.102.21`) on port 25,
    not as the USW Pro HD 24. The app logs `Server position: ... on unknown
    port 25` and, for gateway tests, drops the switch hop and assumes 1 Gbps.
    That makes the "max" and efficiency grades wrong (e.g. 453%). Browser
    test paths from clients come out right (10 Gbps). Host networking
    wouldn't change this, since UniFi would still see the VM behind the
    Proxmox host. To be reported upstream (drafted 2026-09-28).
- **Measured throughput (2026-09-28)**, iperf3 with 6 streams from a 10GbE
  Mac on another VLAN, so routed by the gateway:
  - to the pod via `.129`: about 9.0 Gbps up and 9.3 Gbps down, which is
    line rate
  - worker-to-worker, pod networking vs host networking: the same within
    noise (about 63–68 Gbps)

  Tests that terminate *on* the gateway top out around 4.4 / 2.5 Gbps from
  the Mac directly, too: that's the gateway's CPU, not the cluster. The
  browser speed test's upload half (about 5.7 Gbps) is the browser's limit,
  since iperf3 moves 9 Gbps the same way.
- **Storage:** a 5Gi `hexos-iscsi` PVC at `/app/data` (SQLite + WAL,
  `.credential_key`, license, reports), seeded from rpi5-1's `~/docker/data`
  before the first sync. It's block storage because upstream documents SQLite
  WAL problems on NFS. `/app/logs` is an `emptyDir`, since it only mirrors
  stdout.
- **Auth: in-app OIDC against Authelia**, not the `ExternalAuth` filter.
  Forward-auth would block the speed test page's unauthenticated POST to
  `/api/public/speedtest/results` from arbitrary LAN devices, and the app
  has its own federated login anyway. The Authelia client is
  `network-optimizer` in [`apps/authelia/application.yaml`](apps/authelia/application.yaml)
  (`two_factor`, `client_secret_post`, PKCE S256). The provider itself is
  configured in the app and stored in its db, so it's a one-time GUI step:
  **Settings > Identity**, add an OIDC provider with
  - the generic OIDC preset, whose fixed scheme `oidc` gives the redirect
    URI `https://optimizer.jakerobb.org/signin-oidc/oidc`
  - issuer/authority `https://auth.jakerobb.org`
  - client ID `network-optimizer`
  - client secret from the 1Password item `network-optimizer-oidc-client-secret`
  - PKCE on
  - scopes `openid profile email`

  SSO is linked to Jake's account via Authelia's `sub` for user `jake`
  (`authelia storage user identifiers export` in the Authelia pod shows it).
  The built-in `admin` account stays enabled on purpose as an emergency
  fallback. If SSO ever locks you out anyway, set `NETOPT_RECOVERY=1` on the
  container for one boot (see upstream's `docker/DEPLOYMENT.md`).
- **In-app InfluxDB target (gotcha found at cutover).** The app's
  monitoring feature was configured in its own UI (stored in the db, not in
  any env var) to write to InfluxDB at `http://localhost:8086`. That worked
  under host networking on rpi5-1 and fails from the pod with `Connection
  refused`. Fixed in the UI (Settings, InfluxDB URL) by pointing it at
  `http://rpi5-1.lan:8086`, the Compose InfluxDB, which is published on the
  host. Superseded on 2026-09-29 by the app's own InfluxDB; see below.
- **Version:** stable `2.9.0` for both containers (on `2.9.0-preview2` to
  `-preview7` from 2026-09-24 to 2026-10-01, to test a feature the developer
  asked for). The migrated db was last opened with 2.9.0, so don't drop back to
  2.8.x. Renovate tracks the tags from here.
- **Pod security:** `baseline`, not hardened like unpoller/ntfy. The image's
  entrypoint starts as root to set the timezone and chown the data dir, then
  drops to UID 1654 with `gosu`, and traceroute/ping rely on `NET_RAW`. The
  two TCP buffer sysctls from upstream's compose file are on Kubernetes'
  safe list; `tcp_mtu_probing` isn't, so it's omitted.
- **Homepage:** discovered via `gethomepage.dev/*` annotations on the
  HTTPRoute, replacing the manual `services.yaml` entry. No Cloudflare DNS
  cleanup is needed: `optimizer.jakerobb.org` only ever matched the
  `*.jakerobb.org → caddy.lan` wildcard CNAME, which the external-dns record
  overrides. The `optimizer.lan` UniFi DNS entry has been deleted, and so has
  the old Compose data on rpi5-1.

### Its own InfluxDB (added 2026-09-29)

The app's time-series monitoring used the shared Compose InfluxDB on rpi5-1
until 2026-09-29, when a burst of its Flux queries grew `influxd` to 12.9G
RSS, exhausted the Pi's RAM and swap, and took LAN DNS down with it.
NetworkOptimizer is also the only InfluxDB user left once the Compose
observability stack retires, so it now has its own:
`influxdb-{deployment,pvc,service,httproute}.yaml` in
[`../manifests/network-optimizer/`](../manifests/network-optimizer/).

- **Why InfluxDB at all.** The app doesn't just write: every chart, Live
  View playback, ISP Health scoring and its hourly/daily rollups run Flux
  queries (76 of them, all in upstream's `MonitoringInfluxClient.cs`).
  Swapping in Prometheus would be a multi-week upstream rewrite, so it
  wasn't pursued.
- **Pinned to 2.x.** InfluxDB 3 has no Flux, so `renovate.json` holds the
  image below 3.0. See [`../todo/FUTURE.md`](../todo/FUTURE.md#influxdb-2x-pin--3x).
- **Memory.** 4Gi limit. Flux queries are capped at 1GiB each and 2.5GiB
  in total, with up to 8 running at once and 100 queued, so a runaway query
  fails on its own instead of getting the pod OOM-killed. If charts start
  failing with memory-limit errors, raise those env vars and the limit
  together. It prefers the MS-A2 workers over the MBP.
- **Storage.** 30Gi `hexos-iscsi`. The primary bucket was 12GB at
  migration with 79 of its 90 retention days filled (~155MB/day). The
  long-term bucket (365 days) is tiny.
- **No secrets in the manifests.** The metadata (org `home`, the `admin`
  user and token, the app's bucket-scoped token, bucket IDs) came from a
  `--full` restore of the Compose instance's backup, so the `admin`
  password is still the old `INFLUXDB_ADMIN_PASSWORD` from
  `docker-compose/.env.sops.env` (deleted from that file on 2026-10-01; it's
  in git history), and the app's stored token kept working. On an empty PVC the pod starts
  un-onboarded. Onboard it with `influx setup`, then either restore a
  backup the same way or re-run the app's InfluxDB setup wizard.
- **UI.** `https://influxdb.jakerobb.org`, moved here from
  `manifests/lan-routes/` and still behind Authelia. The Compose InfluxDB
  was retired 2026-10-01; its data directory stays on rpi5-1 (see below).

**Migration (2026-09-29).**

1. Onboarded the new pod with a throwaway admin (`influx setup`), took a
   full `influx backup` of the Compose instance (T0 = 02:36 UTC, 11GB
   gzipped, 14 minutes on the Pi), and ran `influx restore --full` into the
   new pod through `kubectl port-forward` from rpi5-1.
   - **Gotcha:** the restore replaces the metadata first, which revokes the
     throwaway token, so its next step fails with `401 Unauthorized`.
     Re-running the same restore with the Compose `admin` token works,
     and took 2 minutes.
2. Checked record counts per measurement against Compose over the same
   window. They matched exactly, e.g. 1,945,060,043 `interface_counters`
   values.
3. Deleted the buckets and tokens that came along but belong to the
   Compose stack: the `telegraf` and `unifi` buckets, and the unpoller and
   nut-influx-relay tokens. That left 12GB.
4. Changed the app's InfluxDB URL (Settings) to `http://influxdb:8086`.
   It switched at 03:28 UTC, and Compose got nothing after that.
5. Copied the points the app wrote to Compose between T0 and the switch:
   `influxd inspect export-lp --start 02:30Z` in the Compose container for
   both buckets (about 1.2M lines), then `influx write` into the new
   instance. Rewriting a point with the same series and timestamp
   overwrites it, so the overlap is harmless. Counts for that window
   matched too.

The app's buckets stayed in the Compose InfluxDB, untouched, as a
fallback. That InfluxDB was retired 2026-10-01, but its data directory
(`~/docker/influxdb/` on rpi5-1, about 17GB) was left in place, so the
fallback still exists on disk; delete it when you're sure.

## modbus-controller (migrated from Docker Compose, 2026-09-30)

[jakerobb/modbus-eth-controller](https://github.com/jakerobb/modbus-eth-controller), the HTTP front end that runs relay
programs against the Waveshare board at `modbus.lan:4196`. Deployed as
[`apps/modbus-controller/`](apps/modbus-controller/application.yaml) →
[`manifests/modbus-controller/`](../manifests/modbus-controller/).

- **Stateless.** The program files (`manifests/modbus-controller/programs/*.json`) are loaded once at startup, so
  `kustomization.yaml` generates a hash-named ConfigMap from them and an edit rolls the pod. The `Recreate` strategy and
  single replica keep two pods from driving the board at once.
- **No host networking.** Compose used `network_mode: host` to dodge its DNS problem (fixed 2026-09-28). In the
  cluster the pod uses the pod network, and `modbus.lan` resolves through CoreDNS's forward to the node's resolver.
  Traffic to the IoT VLAN depends on the UniFi rule described under
  [LAN routes](#lan-routes-replacing-caddy-added-2026-09-29).
- **Auth.** Forward-auth through Authelia, like the other non-OIDC apps. The `modbus.jakerobb.org` access-control rule
  already existed for the `lan-routes` version; the `modbus-controller` namespace was added to the Authelia
  `ReferenceGrant`.
- **Doorbell webhook bypass (2026-10-01).** UniFi Protect rings the doorbell with
  `GET https://modbus.jakerobb.org/run?program=doorbell&ignoreBody=true` and can't log in, so Authelia has a `bypass`
  rule for exactly that method, path and query, above the host's `two_factor` rule. Anything else on the host,
  including a different program or an extra query parameter, still needs a login. Checked offline with
  `authelia access-control check-policy` against a patched copy of the live config. If Protect's URL changes, the rule's
  regex in `apps/authelia/application.yaml` has to change with it.
- **Cutover.** Merging replaces the `lan-routes` HTTPRoute for `modbus.jakerobb.org` with the new one. Afterward, stop
  the Compose container on rpi5-1 and delete the stale `~/docker/modbus-programs/` copy.

## zwave-js-ui (migrated from Docker Compose, 2026-10-01)

Z-Wave JS UI, the Z-Wave controller's web UI and the Z-Wave JS WebSocket server Home Assistant connects to. The
controller is a network radio at `tcp://192.168.102.20:6638`, so nothing is hardware-pinned. Deployed as
[`apps/zwave-js-ui/`](apps/zwave-js-ui/application.yaml) →
[`manifests/zwave-js-ui/`](../manifests/zwave-js-ui/).

- **State is a PVC (`hexos-iscsi`, 1Gi).** The "store" holds the driver's node cache (`<homeId>.jsonl`,
  `.metadata.jsonl`, `.values.jsonl`), `nodes.json` (node names and locations) and `settings.json`. Losing the cache
  doesn't lose the network (the controller keeps that), but every node gets re-interviewed and the names are gone.
- **Restore gate.** The `restore` init container waits for `/store/.restored` before the app starts, so a fresh PVC
  can't start against an empty cache and trigger a re-interview of every node. The cutover below fills it. For a
  brand-new install with no old store, `kubectl exec ... -c restore -- touch /store/.restored` skips the wait.
- **Config ownership: seeded once, then the app's.** `settings.json` is copied in from the `zwave-js-ui-seed`
  ConfigMap only if the store has none. After that, UI changes persist on the PVC and git is not authoritative. Editing
  the ConfigMap later does nothing to a seeded store. (The reasoning is in `todo/READY.md`'s home automation entry.)
- **Security keys are env vars, not file contents.** The S0/S2 and Long Range keys come from the
  `zwave-js-ui-security-keys` ExternalSecret (1Password item of the same name in `homelab-k8s`) as `KEY_*` env vars. The
  seed's key objects are empty on purpose: the app crashes at startup (`parseSecurityKeys`, `Cannot set properties of
  undefined`) if `securityKeys`/`securityKeysLongRange` are missing entirely, even with the env vars set. Tested on
  rpi5-1 with a scratch store before writing the manifest. Whether the env keys are actually applied could only be
  confirmed against the real controller, which is the first thing the cutover checks.
- **Non-root.** Runs as uid 1000 with all capabilities dropped (the image defaults to root; tested working as 1000).
- **Two Services.** `zwave-js-ui` (8091) sits behind the Gateway. The WebSocket server on 3000 is raw TCP and gets its
  own LoadBalancer VIP, `192.168.102.132`, published as `zwave-ws.jakerobb.org`. It has no authentication, same as
  before, and is LAN-only.
- **Auth.** Forward-auth through Authelia. The `zwave.jakerobb.org` rule already existed for the `lan-routes` version;
  the `zwave-js-ui` namespace was added to the Authelia `ReferenceGrant`. The app's own login (`gateway.authEnabled`)
  was already off, so the old `users.json` isn't carried over.

### Cutover

Before merging:

1. Create the 1Password Secure Note `zwave-js-ui-security-keys` in the `homelab-k8s` vault with six concealed fields:
   `S0_Legacy`, `S2_Unauthenticated`, `S2_Authenticated`, `S2_AccessControl`, `LR_S2_Authenticated`,
   `LR_S2_AccessControl`. The values are in the old Compose settings (the SOPS file this PR deletes, still in git
   history). In your own terminal, so they never land in a chat or log:

   ```bash
   git show origin/main:docker-compose/zwave-js-ui/settings.sops.json | sops -d --input-type json --output-type json /dev/stdin | python3 -c 'import json,sys; z=json.load(sys.stdin)["zwave"]; [print(k, v) for k, v in {**z["securityKeys"], **{"LR_"+k: v for k, v in z["securityKeysLongRange"].items()}}.items()]'
   ```

After merging (ArgoCD syncs; the pod sits at `Init:0/1` waiting for the restore):

2. compose-deploy removes the Compose container within about 5 minutes (`--remove-orphans`). Home Assistant's Z-Wave
   devices are unavailable from then until step 5. Confirm it's gone before copying, since the old container keeps
   writing to the store until it stops:

   ```bash
   docker ps -a --format '{{.Names}}' | grep -c zwave-js-ui
   ```

3. Copy the store in, from rpi5-1. This leaves the old store untouched, and skips settings (seeded fresh), logs, the
   re-downloadable config DB and the stale `*.lock` directories:

   ```bash
   sudo tar -C ~/docker/zwave-js-ui --exclude=./settings.json --exclude=./users.json --exclude=./logs --exclude=./.config-db --exclude=./sessions --exclude=./.session-secret --exclude='*.lock' -cf - . | kubectl -n zwave-js-ui exec -i deploy/zwave-js-ui -c restore -- sh -c 'tar -C /store -xof - && touch /store/.restored'
   ```

4. The pod starts. Check the log for a clean connect to the controller, that the nodes show alive in
   `https://zwave.jakerobb.org`, and that a **secure** device (a lock, if there is one) still responds. That's the
   check that the env-var keys were applied. If secure nodes don't respond, compare the 1Password values with the old
   file. A wrong key doesn't harm the controller.
5. In Home Assistant, reconfigure the Z-Wave JS integration's server URL to `ws://zwave-ws.jakerobb.org:3000` (it was
   the Pi's `:3010`).
6. After a few days of everything behaving, delete `~/docker/zwave-js-ui/` on rpi5-1. It holds the old store and the
   keys in `settings.json`, and is root-owned (`sudo rm -rf`). Until then it's the rollback: revert the PR and restore
   the Compose service.

## zigbee2mqtt (migrated from Docker Compose, 2026-10-01)

Zigbee2MQTT, the Zigbee network's brain and web UI. The coordinator is a network radio at `tcp://192.168.102.4:6638`, so
nothing is hardware-pinned. Deployed as [`apps/zigbee2mqtt/`](apps/zigbee2mqtt/application.yaml) →
[`manifests/zigbee2mqtt/`](../manifests/zigbee2mqtt/). It talks to the in-cluster Mosquitto at
`mosquitto.mosquitto.svc.cluster.local:1883`, not through the VIP.

- **State is a PVC (`hexos-iscsi`, 1Gi).** `database.db` (the paired devices) and `coordinator_backup.json` are the
  parts that matter: losing them means re-pairing every Zigbee device. `configuration.yaml` also lives only here now: it
  holds the device and group friendly names, which stayed out of this public repo, so there's no seed ConfigMap and
  changes made in the UI persist on the PVC. Git is not authoritative for it.
- **The restore gate is a safety interlock, not a convenience.** If Zigbee2MQTT starts without a config it writes a
  default one with `network_key: GENERATE`, which forms a new network on the coordinator and orphans every paired
  device. The `restore` init container holds the pod until `scripts/zigbee2mqtt-cutover/restore.sh` has copied the data
  in and verified the key.
- **Network key: `!secret`, not an env var.** The obvious `ZIGBEE2MQTT_CONFIG_ADVANCED_NETWORK_KEY` doesn't keep the key
  out of the PVC: Zigbee2MQTT's `write()` persists whatever env overrides are applied, so the first device rename would
  copy the key into `configuration.yaml`. A `!secret` reference does survive writes. `configuration.yaml` says
  `network_key: '!secret network_key'` and the key sits in `secret.yaml`, mounted read-only from the
  `zigbee2mqtt-network-key` ExternalSecret (1Password item of the same name in `homelab-k8s`, one `network_key` field
  holding a JSON array). Tested on rpi5-1 with dummy values: the reference resolves, a device or channel write leaves
  it intact, and a read-only `secret.yaml` is tolerated. The PAN ID and extended PAN ID stay in the PVC's
  `configuration.yaml`. They're broadcast over the air, so they aren't secret the way the key is.
- **Non-root.** Runs as uid 1000 with all capabilities dropped (the image defaults to root; tested working as 1000).
- **Auth.** Forward-auth through Authelia. The `zigbee.jakerobb.org` rule already existed for the `lan-routes` version;
  the `zigbee2mqtt` namespace was added to the Authelia `ReferenceGrant`.

### Cutover

Before merging:

1. Create the 1Password Secure Note `zigbee2mqtt-network-key` in the `homelab-k8s` vault with one concealed field,
   `network_key`, holding the key as a JSON array of 16 numbers. In your own terminal, so the value never lands in a
   chat or log:

   ```bash
   sops -d docker-compose/zigbee2mqtt/configuration.sops.yaml | python3 -c 'import sys, yaml, json; print(json.dumps(yaml.safe_load(sys.stdin)["advanced"]["network_key"], separators=(",", ":")))'
   ```

After merging (ArgoCD syncs; the pod sits at `Init:0/1` waiting for the restore):

2. compose-deploy removes the Compose container within about 5 minutes (`--remove-orphans`). Zigbee devices that depend
   on the coordinator are unavailable from then until step 3 finishes. Mains-powered routers keep routing meanwhile.
3. On rpi5-1, dry-run the safety checks, then run it for real. The checks refuse to continue if the old container is
   still up, the pod isn't waiting, the PVC was already restored, or the network key in the cluster Secret differs from
   the one in the old config. The script prints only MATCH or MISMATCH, never the key. It copies the database, state
   and coordinator backup, writes a `configuration.yaml` with the key swapped for the `!secret` reference and MQTT
   pointed at the in-cluster broker, and creates the marker last:

   ```bash
   ~/dev/homelab/scripts/zigbee2mqtt-cutover/restore.sh --check
   ```

   ```bash
   ~/dev/homelab/scripts/zigbee2mqtt-cutover/restore.sh
   ```

4. Check the pod's log for a connection to the MQTT server, the 14 joined devices, and no "Configuration is not
   consistent" error. Toggle a Zigbee device from Home Assistant. Then confirm the key didn't get written into the
   PVC's config (this should print `1`):

   ```bash
   kubectl -n zigbee2mqtt exec deploy/zigbee2mqtt -- grep -c "network_key: '!secret network_key'" /app/data/configuration.yaml
   ```

   Home Assistant needs no change, since it only talks to MQTT.
5. After a few days of everything behaving, delete `~/docker/zigbee2mqtt/` on rpi5-1. It holds the old data and the
   network key in plaintext. Until then it's the rollback: revert the PR and restore the Compose service (the restore
   script never modifies it).

## matter-server (migrated from Docker Compose, 2026-10-01)

python-matter-server, the Matter controller Home Assistant's Matter integration talks to. Deployed as
[`apps/matter-server/`](apps/matter-server/application.yaml) → [`manifests/matter-server/`](../manifests/matter-server/).

- **Host network.** Matter discovers devices with mDNS multicast and talks to them over IPv6, and neither crosses the
  pod network, so the pod runs with `hostNetwork: true` (the Compose version used `network_mode: host`). The namespace is
  labeled `pod-security.kubernetes.io/enforce: privileged` because Talos enforces `baseline`, which blocks host
  networking. The container itself runs non-root with all capabilities dropped.
- **What it relies on.** The UniFi gateway's mDNS proxy reflects the IoT and Cloud IoT VLANs to the Server VLAN (all
  VLANs, all services, as of the migration). The workers each have a SLAAC ULA address (`fd3d:b17d:9f8e:102::/64`) on the
  Server VLAN, which is enough for Wi-Fi Matter devices. Thread devices would additionally need the node sysctl
  `net.ipv6.conf.*.accept_ra=2` (Linux ignores router advertisements on forwarding hosts otherwise) and IPv6 firewall
  rules between the Thread border routers' VLAN and Server. There are none today (the only commissioned device is a Wi-Fi
  Nest thermostat).
- **Any worker.** A shell wrapper reads the node's IPv4 default route at start and passes that interface as
  `--primary-interface`, so the pod works on a Proxmox VM (`ens18`), the mbp (`enp0s1`) or the future Pi
  worker without per-node configuration. Without the flag it binds every interface on the host, including the Cilium
  ones.
- **State is a PVC (`hexos-iscsi`, 1Gi):** the fabric JSON (commissioned nodes and the controller's identity),
  `chip_*.ini`, and the PAA certificate cache. Losing the fabric means re-commissioning every Matter device. The
  `restore` init container holds the pod until `scripts/matter-server-cutover/restore.sh` has copied the old data in,
  because starting on an empty directory would create a second, empty fabric.
- **Home Assistant** is still in Compose on rpi5-1, so it can't reach a ClusterIP. The Service is a LoadBalancer pinned to
  `192.168.102.133`, published as `matter.jakerobb.org`. The server has no authentication, LAN only, like Z-Wave JS.
- **No Bluetooth.** `/run/dbus` and `apparmor=unconfined` are gone. BLE commissioning isn't available from the pod; commission
  new devices from the Home Assistant phone app, or share them from another ecosystem with a multi-admin pairing code.

### Cutover

After merging (ArgoCD syncs; the pod sits at `Init:0/1` waiting for the restore):

1. compose-deploy removes the Compose container within about 5 minutes. The thermostat is unavailable in Home Assistant
   from then until step 3 finishes.
2. On rpi5-1, dry-run the checks, then run it for real. The checks refuse to continue if the old container is still
   up, the pod isn't waiting, or the PVC was already restored. The marker that releases the pod is created last:

   ```bash
   ~/dev/homelab/scripts/matter-server-cutover/restore.sh --check
   ```

   ```bash
   ~/dev/homelab/scripts/matter-server-cutover/restore.sh
   ```

3. Check the pod log: it should print `using primary interface <name>` and load the one node. If the container fails
   to start as non-root (a permissions error on `/data` or the mDNS socket), set `runAsUser: 0` on the container and
   note why here.
4. In Home Assistant, open the Matter integration and change the server URL from `ws://localhost:5580/ws` to
   `ws://matter.jakerobb.org:5580/ws`. The thermostat should come back as available. If it stays unavailable, check
   mDNS first: `kubectl -n matter-server logs deploy/matter-server`, and that the node holding the pod is on the
   Server VLAN's `ens18`/equivalent interface.
5. After a few days of everything behaving, delete `~/docker/matter-server/` on rpi5-1. Until then it's the rollback:
   revert the PR and restore the Compose service (the restore script never modifies it). Then Bluetooth and avahi on
   rpi5-1 can go once Home Assistant has moved too.

## homeassistant (migrated from Docker Compose, 2026-10-01)

Home Assistant Core, 2026.9.4 (the version Compose ran; bump it after the move, not during). Deployed as
[`apps/homeassistant/`](apps/homeassistant/application.yaml) → [`manifests/homeassistant/`](../manifests/homeassistant/).

- **Host network.** HomeKit bridges (about nine, ports 21064–21076, advertised over mDNS), and discovery of Apple TV,
  HEOS, Denon (SSDP), Lutron, ESPHome, WLED, Nanoleaf, SMLIGHT and the printer all use LAN multicast, which doesn't cross
  the pod network. The namespace is labeled `pod-security.kubernetes.io/enforce: privileged` for the same reason as
  matter-server. The gateway's mDNS proxy doesn't necessarily cover SSDP, so check the Denon after the move.
- **Any worker.** No node affinity. HomeKit controllers find bridges by mDNS service name, not IP, so a reschedule should
  cost a few minutes of "No Response" in Apple Home. Not tested yet; if it turns out to be a problem, add an affinity.
- **Root, default capabilities.** The official image's s6 init needs root (Compose ran it that way). `privileged`,
  `/dev/ttyAMA0` and `/dev/serial0` (the Pi's UART, for an integration that never worked), and `/run/dbus` (Bluetooth,
  unused) are gone. So is the `OFFICE_UPS_NUT_PASSWORD` variable: the NUT integration keeps its credentials in
  `.storage/core.config_entries`, and nothing in the YAML reads it.
- **Config is a PVC (`hexos-iscsi`, 5Gi), seeded once** from the Pi's `~/docker/homeassistant`, like Z-Wave JS UI and
  Zigbee2MQTT. Home Assistant owns `automations.yaml`, `scenes.yaml`, `scripts.yaml` and `.storage` from then on, so git is
  no longer authoritative for them (`docker-compose/homeassistant/` goes stale; see `todo/FUTURE.md`). The seed includes
  the recorder database (~225Mi), `custom_components/` (HACS), and the Lutron key. The `restore` init container holds the
  pod until `scripts/homeassistant-cutover/restore.sh` has copied everything in, because starting on an empty `/config`
  would onboard a brand-new instance and mint new HomeKit bridge identities.
- **Backups.** A nightly CronJob (03:17) tars `/config` (minus the database, logs and caches) to a `hexos-nfs` PVC and keeps 14
  days. `.storage` is the part that matters (integration entries, HomeKit pairing identities). The job runs on the same
  node as the pod, because the config volume is ReadWriteOnce. Nothing alerts if the job fails yet. To restore: scale the
  Deployment to 0, extract a backup over `/config` from a throwaway pod, scale back up.
- **Ingress.** The route is now a normal Service → pod (`homeassistant.jakerobb.org`, still not behind Authelia: the
  companion app can't log in through it). Envoy reaches Home Assistant from a pod address instead of a node address, and
  Home Assistant answers 400 to `X-Forwarded-For` from an untrusted proxy, so the restore script adds `10.244.0.0/16` to
  `trusted_proxies` in `.storage/http` (the setting lives there, not in `configuration.yaml`).
- **Database on iSCSI.** After a HexOS outage the volume can go read-only (delete the pod). If the recorder database gets
  corrupted, delete `home-assistant_v2.db*` from the volume; it's only history.

### Cutover

Home Assistant is off from the moment the old container is removed until the new pod passes its startup probe, probably
5–10 minutes. Devices keep their last state (lights, locks, Z-Wave/Zigbee, garage door), but no automation runs in the
meantime, so don't do it with a timer-based automation mid-run. Pick a quiet daytime window.

1. Merge. ArgoCD syncs and the pod sits at `Init:0/1`. `homeassistant.jakerobb.org` returns 503 from now until the pod
   is ready (the old Home Assistant is still reachable at `http://192.168.102.2:8123`).
2. compose-deploy removes the Compose container within about 5 minutes. On rpi5-1, dry-run the checks, then run it for
   real. `--wait` polls (up to 10 minutes) until the container is gone and the pod is waiting. The marker that releases
   the pod is created last:

   ```bash
   ~/dev/homelab/scripts/homeassistant-cutover/restore.sh --check
   ```

   ```bash
   ~/dev/homelab/scripts/homeassistant-cutover/restore.sh --wait
   ```

3. Watch the pod: `kubectl -n homeassistant logs -f deploy/homeassistant`. Startup takes a few minutes. If the container
   fails on permissions or s6 init, that's the `securityContext` (see the comments in `deployment.yaml`).
4. Verify:
   - `https://homeassistant.jakerobb.org` loads and logs in (a 400 means `trusted_proxies` didn't take).
   - The integrations with credentials or pairing come back: Matter (thermostat), Z-Wave JS, MQTT, NUT (`nut.lan`
     must resolve from the pod), Lutron, UniFi Protect, TP-Link, AC Infinity, HEOS, Denon (SSDP), the three Apple TVs.
   - Every HomeKit bridge shows up in Apple Home without re-pairing. If Home Assistant advertises on `cilium_host`
     or `lxc*` addresses, pick the right adapter in Settings → System → Network.
   - The companion app reconnects, and one automation fires.
   - Run the backup once: `kubectl -n homeassistant create job --from=cronjob/homeassistant-backup ha-backup-test`.
5. After a week of stable behavior, delete `~/docker/homeassistant/` on rpi5-1 (see `todo/FUTURE.md`). Until then it's
   the rollback: revert the PR and restore the Compose service (the restore script never modifies the old directory).
   Anything changed in the new instance since the cutover is lost on rollback.

## scrypted (migrated from Docker Compose, 2026-10-01)

Scrypted, v0.147.0-noble-full (the version Compose ran; bump it after the move, not during). It exposes two UniFi
cameras (Doorbell, Garage) to HomeKit, with HomeKit Secure Video, through the `unifi-protect`, `prebuffer-mixin`,
`snapshot`, `webrtc` and `homekit` plugins. HKSV is a requirement, which is why this wasn't replaced by Home
Assistant's UniFi Protect + HomeKit Bridge (that streams through ffmpeg and has no HKSV). Deployed as
[`apps/scrypted/`](apps/scrypted/application.yaml) → [`manifests/scrypted/`](../manifests/scrypted/).

- **Host network.** Each camera is a HomeKit accessory on its own port, advertised over mDNS by Scrypted's built-in
  advertiser (`SCRYPTED_DOCKER_AVAHI` isn't set, so no avahi or dbus). That doesn't cross the pod network. The namespace is
  labeled `pod-security.kubernetes.io/enforce: privileged` for the same reason as Home Assistant and matter-server. Home
  Assistant is the precedent: it also runs `hostNetwork`.
- **Any worker.** No node affinity. HomeKit controllers find accessories by mDNS service name, not IP, so a reschedule
  should cost a few minutes of "No Response" in Apple Home. Not tested yet.
- **Root, default capabilities.** Same as Compose (it wasn't privileged there either). No hardware acceleration is used.
  Requests 1Gi, limit 2.5Gi; the container used about 850Mi on the Pi.
- **Data is a PVC (`hexos-iscsi`, 5Gi), seeded once** from the Pi's `~/docker/scrypted` (72Mi: `scrypted.db`, a LevelDB
  directory holding device settings, plugin state and the HomeKit pairing identities, and `plugins/`). The `restore` init
  container holds the pod until `scripts/scrypted-cutover/restore.sh` has copied it in, because an empty volume would mint
  new HomeKit identities and need both cameras re-added to Apple Home.
- **Backups.** A nightly CronJob (03:27) tars the volume to a `hexos-nfs` PVC and keeps 14 days. `scrypted.db` is open while
  the pod runs, so a live copy could be torn; treat it as a safety net. The job runs on the same node as the pod, because
  the data volume is ReadWriteOnce. Nothing alerts if the job fails yet. To restore: scale the Deployment to 0, extract a
  backup over `/server/volume` from a throwaway pod, scale back up.
- **Ingress.** `scrypted.jakerobb.org` is now a normal Service → pod route, still not behind Authelia (the app has its own
  login). Its old `lan-routes` file is gone.

### Cutover

HomeKit live view and recording for the two cameras stop from the moment the old container is removed until the new pod is
ready, probably 5 minutes. The UniFi cameras themselves keep recording to Protect. Pick a quiet window.

1. Merge. ArgoCD syncs and the pod sits at `Init:0/1`. `scrypted.jakerobb.org` returns 503 from now until the pod is
   ready (the old Scrypted is still reachable at `http://192.168.102.2:11080`).
2. compose-deploy removes the Compose container within about 5 minutes. On rpi5-1, dry-run the checks, then run it for
   real. `--wait` polls (up to 10 minutes) until the container is gone and the pod is waiting. The marker that releases
   the pod is created last:

   ```bash
   ~/dev/homelab/scripts/scrypted-cutover/restore.sh --check
   ```

   ```bash
   ~/dev/homelab/scripts/scrypted-cutover/restore.sh --wait
   ```

3. Watch the pod: `kubectl -n scrypted logs -f deploy/scrypted`.
4. Verify:
   - `https://scrypted.jakerobb.org` loads and logs in.
   - The UniFi Protect plugin reconnects and both cameras show video. Check the plugin's and the HomeKit plugin's
     settings for anything holding the Pi's address (an address override, a bind address, or a selected network
     interface); with several interfaces on a Cilium node, mDNS may need the right one pinned.
   - Both cameras appear in Apple Home without re-pairing, live view starts, and an HKSV recording is made (trigger motion
     and check Apple Home's recorded clips).
   - Run the backup once: `kubectl -n scrypted create job --from=cronjob/scrypted-backup scrypted-backup-test`.
   - If a camera's live view won't load and the log says "video codec must be h264 but is h265", set its encoding to
     Standard in UniFi Protect (Enhanced is H.265, which HomeKit can't play). That was the Garage camera's problem.
5. After a week of stable behavior, delete `~/docker/scrypted/` on rpi5-1 (see `todo/FUTURE.md`). Until then it's the
   rollback: revert the PR and restore the Compose service (the restore script never modifies the old directory). Anything
   changed in the new instance since the cutover is lost on rollback.

## Unbound (in-cluster copy, deployed 2026-09-29)

A second Unbound, running in the cluster alongside the Compose one on rpi5-1.
Compose's stays, and DHCP can point at both while they run in parallel.
Deployed as [`apps/unbound/`](apps/unbound/application.yaml) →
[`manifests/unbound/`](../manifests/unbound/).

- **Two replicas on different workers.** A hard (`required`) pod
  anti-affinity on `kubernetes.io/hostname`, plus a PodDisruptionBudget of
  `minAvailable: 1`. With required anti-affinity a rolling update can't surge
  a third pod, so the strategy is `maxSurge: 0, maxUnavailable: 1`. If only
  one worker is up, the second replica stays Pending rather than doubling up.
- **The address to hand out is `192.168.102.130`.** A LoadBalancer Service
  with the IP pinned via `lbipam.cilium.io/ips`, on both UDP and TCP 53, and
  announced by the catch-all L2 policy (either worker can hold it). `.128` is
  the Gateway and `.129` is NetworkOptimizer.
- **Clients appear as node IPs.** L2 announcements can't do
  `externalTrafficPolicy: Local`, so a query that lands on a node without a
  local pod is SNATed on its way to the other one. `local.conf` allows all of
  `192.168.0.0/16`, so nothing breaks, but Unbound's own logs can't say which
  client asked.
- **One config, two copies.** `manifests/unbound/local.conf` is a copy of
  `docker-compose/unbound/custom.conf.d/local.conf`, since ArgoCD can't read
  files outside the app's directory. Both files say so in a header comment.
  Clients don't reliably fail over in DHCP-list order, so the two resolvers
  must answer identically. Change both together. The copy goes away when
  Compose's Unbound retires or is replaced with a generated file.
- **Capabilities.** The image starts as root, binds :53, chroots to
  `/var/unbound` and drops to its `unbound` user. The pod drops ALL
  capabilities and adds back `NET_BIND_SERVICE`, `SETUID`, `SETGID`,
  `SYS_CHROOT` and `DAC_OVERRIDE`. The first deploy omitted `DAC_OVERRIDE`
  and crash-looped with `Cannot bind local socket /var/unbound/unbound.ctl
  (Permission denied)`, because `/var/unbound` belongs to the `unbound` user
  and root can't write there without it.
- **Not done yet:** the Talos nodes' own resolvers must stay off this IP
  (they need DNS to pull the Unbound image), per the jump box swap checklist
  in [`../todo/HARDWARE.md`](../todo/HARDWARE.md).

## Docs site (added 2026-09-28)

`docs.jakerobb.org` renders this repo's Markdown as a searchable site with
[MkDocs Material](https://squidfunk.github.io/mkdocs-material/). Deployed as
[`apps/docs/`](apps/docs/application.yaml) →
[`manifests/docs/`](../manifests/docs/). The site config is in
[`docs-site/`](../docs-site/mkdocs.yml).

- **Content comes from all over the repo.** Every `*.md` file is a page, where
  it already lives (`README.md`, `argocd/README.md`, `docs/*.md`,
  `todo/*.md`, ...). A small MkDocs hook
  ([`docs-site/hooks/repo_docs.py`](../docs-site/hooks/repo_docs.py)) adds them
  to the build, since MkDocs otherwise only reads a single `docs_dir`. The
  same hook adapts GitHub-flavored Markdown for Python-Markdown: links to
  YAML, scripts and directories become GitHub links, and 2-space nested lists
  are re-indented. Nothing had to change in the existing docs for them to
  render. Heading anchors use GitHub's rules, so `#section` links work on
  both GitHub and the site.
- **Built in the pod, not in CI.** One pod has two containers sharing an
  `emptyDir`. The builder (the official `squidfunk/mkdocs-material` image)
  clones the repo, builds, and polls `main` every 5 minutes. nginx
  (`nginx-unprivileged`) serves the result. A new build is swapped in with an
  atomic symlink rename, and a failed build leaves the previous one in place.
  The alternative, an image built by GitHub Actions and pushed to a
  registry, needs a registry, push credentials, and something to bump the
  image tag in git after every docs change. Here, the only moving parts are
  two pinned public images.
- **CI checks every PR.** The `Docs site` step in
  [`lint.yml`](../.github/workflows/lint.yml) runs the same build with
  `--strict`, so a broken link, a bad `#anchor`, or a new Markdown file
  missing from `nav:` in `mkdocs.yml` fails the PR. CI builds with the PyPI
  package pinned in `docs-site/requirements.txt`. Renovate groups it with the
  builder image so the two stay on the same version.
- **Auth:** Authelia forward-auth (`ExternalAuth` filter), like SearXNG.
  MkDocs output is static and has no login of its own. The content is public
  on GitHub anyway, but the site follows the same rule as the other
  browser-facing `*.jakerobb.org` apps.
- **No persistent storage.** A new pod clones and builds from scratch in
  about 10 seconds, and isn't Ready until `/index.html` exists.
- **Adding a page:** write the Markdown file anywhere in the repo and add it
  to `nav:` in `docs-site/mkdocs.yml`. To preview locally, see
  [`docs-site/README.md`](../docs-site/README.md).

## LAN routes: replacing Caddy (added 2026-09-29)

Caddy on rpi5-1 used to serve every `*.jakerobb.org` name for things outside
the cluster: the Compose apps and a few LAN devices. Those names now go
through `homelab-gateway` like everything else. Deployed as
[`apps/lan-routes/`](apps/lan-routes/application.yaml) →
[`manifests/lan-routes/`](../manifests/lan-routes/), one file per hostname.

- **Backends by IP.** Each file is a Service with no selector, a hand-written
  EndpointSlice holding the backend's fixed IP, and the HTTPRoute. Cilium's
  Gateway doesn't support `ExternalName` Services as backends, and all the
  IPs are DHCP reservations, so hard-coding them is fine. The Compose apps all
  use host networking on rpi5-1 (`192.168.102.2`).
- **ArgoCD had to stop excluding EndpointSlices.** The chart's default
  `resource.exclusions` skips `Endpoints` and `EndpointSlice`, so on the first
  sync ArgoCD created the Services and HTTPRoutes, never applied the slices,
  and still reported Synced/Healthy. Every route returned 503 ("no healthy
  upstream"). [`install/values.yaml`](install/values.yaml) now sets the
  default list minus `EndpointSlice`. It's a Helm value, so it took a manual
  `helm upgrade` (see "Upgrading ArgoCD itself"). The slices also spell out
  `protocol: TCP` and `conditions.ready: true`: the API server fills those
  in, and ArgoCD compares list items whole, so leaving them out keeps the app
  OutOfSync forever.
- **Home Assistant needs `trusted_proxies`.** Envoy sends `X-Forwarded-For`
  from a node IP, and HA answers 400 to that from an untrusted proxy. HA
  (2026.9) no longer reads `http:` from `configuration.yaml`: it migrated
  those settings into `.storage/http` (`yaml_migration_done: true`), which
  isn't captured in this repo, and a YAML `http:` block is silently ignored.
  Change it in HA's UI instead. The trusted proxies include
  `192.168.102.0/24` (the Server VLAN), replacing the old
  `192.168.102.2/32` that only covered Caddy.
- **The KVM is reached over HTTPS.** On port 80 it redirects everything to
  `https://<Host>/` and ignores `X-Forwarded-Proto`, so proxying plain HTTP
  loops (it did through Caddy too). Its factory certificate is self-signed
  for `localhost` and expired in 1979, and `BackendTLSPolicy` has no "skip
  verification" option. So the KVM serves a certificate for
  `kvm.jakerobb.org` (valid until 2036), uploaded through its UI and signed
  by a private CA made just for it. The CA's public certificate is
  [`kvm-backend-ca.yaml`](../manifests/lan-routes/kvm-backend-ca.yaml); its
  private key was deleted after signing. The KVM's certificate and key are in
  1Password. To replace the certificate, make a new CA, sign a new
  certificate, upload it, and replace the ConfigMap.
- **Auth.** Home Assistant, Scrypted, the UniFi gateway and the KVM keep their
  own logins and skip forward-auth. Home Assistant has to, since its phone
  app can't do an Authelia login. Everything else gets the `ExternalAuth`
  filter. Grafana's and VictoriaLogs' routes were here too until 2026-10-01,
  when the Compose observability stack was retired. InfluxDB's route was here
  until 2026-09-29, when it moved to NetworkOptimizer's own instance.
- **IoT VLAN firewall.** `kvm`, `rack-led` and `modbus-relay` are on the IoT
  VLAN (`192.168.62.0/24`). UniFi's firewall allowed rpi5-1 in but not the
  cluster nodes: a test pod on every node (2026-09-29) timed out on all three,
  while rpi5-1 reached them. Envoy's upstream connections leave through the
  node's IP (masquerade), so the UniFi rule has to allow the node IPs
  (`.11`–`.13`, `.31`, `.32`, `.34`), not just rpi5-1.
- **DNS cutover.** Cloudflare had a wildcard `*.jakerobb.org` → `caddy.lan`
  CNAME, plus explicit `caddy.lan` CNAMEs for `gateway`, `homeassistant`,
  `modbus`, `modbus-relay`, `nut` and `scrypted`. Names that only matched the
  wildcard moved to the Gateway as soon as external-dns created their `A`
  records. The explicit CNAMEs had to be deleted by hand first, because
  external-dns won't touch records it doesn't own. Caddy was removed from
  Compose the same day, and the wildcard, `caddy.jakerobb.org` and the UniFi
  `caddy.lan` entry were deleted by hand after that.
- **When an app migrates** into the cluster, delete its file here in the same
  PR. Its own HTTPRoute takes over the hostname, and its `access_control`
  rule may move or change.
