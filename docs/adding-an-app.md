# Adding a new app to the cluster

Checklist/standards doc for onboarding a new workload into the Talos/ArgoCD
cluster — whether that's a brand-new app or a migration off `rpi5-1`'s
Docker Compose stack (see [`todo/READY.md`](../todo/READY.md#compose-workload-migration)
for that list). Each numbered section below is a decision this repo has
already made once; don't re-litigate it per app, just follow it. The
worked example throughout is Headlamp
([`argocd/apps/headlamp/`](../argocd/apps/headlamp/application.yaml),
[`manifests/headlamp/`](../manifests/headlamp/)) — added 2026-09-21, and
about as representative a case as exists (bare manifests, native OIDC,
custom RBAC, Homepage discovery, a secret).

For the deeper "why" behind any of this, see
[`argocd/README.md`](../argocd/README.md) — that file is the per-app
decision log; this doc is the distilled, repeatable process.

## 1. File layout: `apps/<name>/` + `manifests/<name>/`

**Settled 2026-09-17, see `argocd/README.md`'s app-of-apps section.**

- `argocd/apps/<name>/application.yaml` holds *only* the ArgoCD
  `Application` CRD — a thin pointer, nothing else. The root `Application`
  ([`argocd/bootstrap/root-app.yaml`](../argocd/bootstrap/root-app.yaml))
  recurses `argocd/apps/`, so dropping a new `application.yaml` anywhere
  under there is all that's needed to get it picked up.
- The app's actual Kubernetes resources (Deployment, Service, Namespace,
  HTTPRoute, RBAC, ConfigMaps, ...) live in a sibling directory,
  `manifests/<name>/`, referenced by that `Application`'s
  `spec.source.path`.
- Never put real resources directly under `apps/<name>/` — early on a
  couple of simple apps did this, and it made their health/sync status
  inseparable from root's own. The one narrow exception: a single small
  resource tightly coupled to its parent app's bootstrap (e.g.
  `apps/authelia/referencegrant.yaml`) isn't worth a whole extra
  `Application`.
- Namespace: **one per app, named identically to the app**, as an
  explicit committed `manifests/<name>/namespace.yaml` — not
  `CreateNamespace=true` on the sync policy. (`kube-prometheus-stack`'s
  shared `monitoring` namespace is the one deliberate exception, for
  ecosystem-standard-name reasons.)
- `Application` template (copy this, don't hand-roll):

  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: <name>
    namespace: argocd
  spec:
    project: default
    source:
      repoURL: https://github.com/jakerobb/homelab.git
      targetRevision: main
      path: manifests/<name>
    destination:
      server: https://kubernetes.default.svc
      namespace: <name>
    syncPolicy:
      automated:
        selfHeal: true
        prune: true
      retry:
        limit: 10
        backoff:
          duration: 30s
          factor: 2
          maxDuration: 10m
  ```

  `selfHeal`/`prune` are on for everything today because nothing
  stateful is under ArgoCD's management yet — **revisit once a
  PVC-backed app is added** (prune deleting a PVC can delete real data,
  depending on the StorageClass's reclaim policy). Keep the `retry` block
  too. Auto-sync never re-attempts a failed sync of the same commit, and
  sync waves don't wait for a dependency to be healthy, so a sync that
  fails for an ordering reason would otherwise stay failed. See
  argocd/README.md's "Sync waves only order creation".

## 2. Bare manifests vs. an external Helm chart

Two patterns coexist; pick based on whether a real upstream chart exists
and is trustworthy:

- **External Helm chart** (Authelia, cert-manager, external-dns,
  metrics-server, kube-prometheus-stack, local-path-provisioner): set
  `source.chart` + `source.repoURL` to the chart repo, `targetRevision` to
  a pinned chart version, and `helm.valuesObject` inline for overrides.
- **Bare manifests** (searxng, ntfy, homepage, Headlamp): write the
  Deployment/Service/etc. by hand under `manifests/<name>/`. Use this
  when there's no official chart, or when the official chart has real
  problems for your use case — Headlamp's chart has open upstream bugs in
  its OIDC-secret wiring (kubernetes-sigs/headlamp#2022, #2485, #4080),
  so bare manifests plus setting its documented env vars directly was
  more reliable than fighting the chart. **Actually check an official
  chart exists before assuming bare manifests** — searxng's own comment
  in `manifests/searxng/deployment.yaml` notes a prior web search
  hallucinated a chart that didn't exist; verify by hitting the claimed
  repo URL yourself.
- Either way: `revisionHistoryLimit: 2` on every Deployment/StatefulSet
  where the field is available (chart defaults are usually 10 — this
  repo intentionally keeps less history, just enough to roll back one
  step).
- Pin dependency versions explicitly (chart `targetRevision`, image
  tags) — never track `latest`, so Renovate's `kubernetes`/`argocd`
  managers (see [`renovate.json`](../renovate.json)) can detect and PR
  version bumps. Add a `# renovate: datasource=... depName=...` comment
  above the field when the manager can't infer the datasource on its own
  (see `argocd/apps/authelia/application.yaml`'s `image.tag` or
  `manifests/headlamp/deployment.yaml`'s image line for the pattern).
  Per global convention, pick the latest *stable* release when first
  adding a dependency, not whatever's already in use elsewhere in the
  repo.

## 3. Exposure: Gateway API, not Ingress

This cluster is **Gateway-API-only** — no Ingress controller, no
Traefik/nginx, no `IngressRoute` CRDs.

- One shared `Gateway` (`homelab-gateway` in `gateway-system`,
  [`talos/cilium/gateway.yaml`](../talos/cilium/gateway.yaml)) handles
  everything. Point every new app's `HTTPRoute` at it:

  ```yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: <name>
    namespace: <name>
  spec:
    parentRefs:
      - name: homelab-gateway
        namespace: gateway-system
    hostnames:
      - <name>.jakerobb.org
    rules:
      - backendRefs:
          - name: <name>
            port: <service-port>
  ```
- **DNS is automatic:** `external-dns` (Cloudflare provider) watches
  `HTTPRoute`s cluster-wide and creates/updates the `A` record itself —
  no manual DNS step for a genuinely new hostname.
  - **Gotcha:** if the hostname already existed as a Cloudflare record
    from the old Caddy setup (`docker-compose/caddy/Caddyfile`),
    external-dns won't adopt/overwrite it (no TXT ownership marker) —
    delete that record by hand in the Cloudflare dashboard once the new
    `HTTPRoute` has synced. Check this on every Compose→cluster
    migration; it's bitten before (`ntfy.jakerobb.org`).
  - **Gotcha:** the LAN's Unbound resolver strips DNS answers that
    resolve an unrecognized hostname to a private IP
    (rebinding-protection default). `jakerobb.org` is already
    allowlisted (`~/docker/unbound/custom.conf.d/local.conf` on
    `rpi5-1`), so this shouldn't recur — but it's the first thing to
    check if a brand-new `*.jakerobb.org` hostname mysteriously won't
    resolve from LAN clients even though `dig @1.1.1.1` shows the
    correct record.
- **TLS is automatic:** one wildcard `Certificate` for `*.jakerobb.org`
  already backs the Gateway's `https` listener. **No per-app
  cert-manager objects needed, ever.**

## 4. Auth: Authelia, and which pattern

Every publicly-reachable hostname needs an entry in Authelia's
`access_control` in
[`argocd/apps/authelia/application.yaml`](../argocd/apps/authelia/application.yaml)
(default policy is `deny` — an app with no rule is unreachable). There are
two ways to actually gate it:

- **Native OIDC client (preferred whenever the app supports it):** one
  login, cleanest UX. Add an entry to `identity_providers.oidc.clients`
  in the same file (copy the `argocd` or `headlamp` client as a
  template — `client_id`, a fresh `client_secret` hash, `redirect_uris`
  pointed at the app's own callback path, `scopes`/`grant_types` matched
  to what the app actually requests). The app itself needs the
  *plaintext* secret (see "Secrets" below) — Authelia's config only ever
  holds the one-way pbkdf2-sha512 hash, safe to commit.
- **Gateway-level forward-auth (`ExternalAuth` HTTPRoute filter):** for
  apps with no OIDC support of their own (searxng, and — before it moved
  to annotation-based Homepage discovery — homepage). Requires:
  - The filter block on the app's own `HTTPRoute` (copy
    `manifests/searxng/httproute.yaml`'s `filters` section).
  - A `ReferenceGrant` in the `authelia` namespace if one doesn't already
    cover the app's namespace (see
    `argocd/apps/authelia/referencegrant.yaml`).
  - The matching `access_control` rule, same as the OIDC path.

Either way, don't do both — stacking forward-auth in front of an app that
also wants its own OIDC login means authenticating against the same
Authelia twice.

## 5. Secrets: 1Password + External Secrets Operator

Every secret an app needs lives in the `homelab-k8s` 1Password vault and
reaches the cluster through an `ExternalSecret`. No plaintext in git, and
no SOPS files applied by hand. Full background is in
[`argocd/README.md`](../argocd/README.md#external-secrets-operator-decided-and-deployed-2026-09-24).

1. In 1Password, create a **Secure Note** in `homelab-k8s`, titled the same
   as the Kubernetes Secret. Add one concealed field per Secret key,
   labeled exactly like the key. A multi-line value (a whole config file,
   a PEM key) goes in the note's own notes field instead.
2. Add an `ExternalSecret` to
   `manifests/external-secrets-config/<name>.yaml`, copying an existing
   one. Point each `remoteRef.key` at `<item>/<field>`, or
   `<item>/notesPlain` for the notes. If only part of a config file is
   secret, template the rest into the `ExternalSecret` (see
   `democratic-csi.yaml`) so the non-secret part stays reviewable in git.
3. Reference the Secret from the app's manifests by name as usual. ESO
   creates it on its next sync after merge, or retries until the target
   namespace exists.

Generate secret values in a real terminal or in 1Password's own generator.
**Never paste a raw secret value into a chat session.** Only a one-way hash
is safe to share, like the pbkdf2 OIDC client-secret hash that goes into
Authelia's config.

## 6. Homepage discovery

Prefer **annotation-based discovery** over hand-editing
`manifests/homepage/configmap.yaml`'s `services.yaml` — it's
self-maintaining (the tile lives and dies with the `HTTPRoute`, no
separate file to keep in sync). Add to the app's own `HTTPRoute`:

```yaml
metadata:
  annotations:
    gethomepage.dev/enabled: "true"
    gethomepage.dev/name: <Display Name>
    gethomepage.dev/description: <short description>
    gethomepage.dev/icon: <icon>.png
    gethomepage.dev/group: <Apps|Services|Monitoring|Infrastructure>
```

- `group` must be one of the four existing tabs defined in
  `settings.yaml` (`kubernetes.yaml`'s `mode: cluster` + `gateway: true`
  is what turns this on cluster-wide — already configured, nothing to
  touch there).
- Icon: check
  [homarr-labs/dashboard-icons](https://github.com/homarr-labs/dashboard-icons)
  first (`icon: <slug>.png`). If the app isn't in that set, add a real
  icon (sourced from the app's own project) to
  [`manifests/homepage/icons-configmap.yaml`](../manifests/homepage/icons-configmap.yaml)
  and reference it as `icon: /icons/<name>.png`.
- **Fall back to a manual `services.yaml` entry only if the tile needs a
  live `widget:`** (API-polling stat tiles like the HexOS/Proxmox/UniFi
  ones in the `Infrastructure` group) — annotation-based discovery
  doesn't support widgets today.

## 7. CRDs stay out of ArgoCD's hands

If a chart ships CRDs, install them manually (`kubectl create -f ...`,
never `apply`), as a one-time step, and again on any CRD-schema-affecting
upgrade — regardless of CRD size. (Originally this was only for
oversized CRDs that broke ArgoCD's diffing, per
`kube-prometheus-stack`'s writeup in `argocd/README.md`, but it's since
been made a blanket rule matching Helm's own upgrade convention, not a
case-by-case judgment call — see the `external-snapshotter` note there.)
Vendor the CRD manifests under `manifests/<name>/` if there's no chart to
`helm pull` them from.

## Checklist

1. `argocd/apps/<name>/application.yaml` — thin `Application`, pointing
   at `manifests/<name>/`.
2. `manifests/<name>/namespace.yaml`.
3. `manifests/<name>/` — Deployment/chart values, Service, any RBAC
   (ServiceAccount + ClusterRole/ClusterRoleBinding if the app needs
   cluster access).
4. `manifests/<name>/httproute.yaml` — `homelab-gateway` parentRef,
   `<name>.jakerobb.org` hostname, `gethomepage.dev/*` annotations.
5. Decide OIDC vs. forward-auth; wire up
   `argocd/apps/authelia/application.yaml` (`access_control` rule, plus
   an OIDC client if applicable) and any needed `ReferenceGrant`.
6. Any secret the app needs: a Secure Note in the `homelab-k8s`
   1Password vault plus an `ExternalSecret` in
   `manifests/external-secrets-config/<name>.yaml` (section 5).
7. Add a dated section to `argocd/README.md` documenting what was
   decided and why (chart vs. bare manifests, auth choice, RBAC scope,
   anything non-obvious) — that file is the durable record; this doc is
   just the checklist.
8. `git add` the new files (`apps/<name>/`, `manifests/<name>/`) —
   leave modified shared files (`authelia/application.yaml`,
   `argocd/README.md`) unstaged for review.
