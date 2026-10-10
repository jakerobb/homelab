# READY

Cluster-readiness backlog — each of these is its own effort, meant to be tackled separately rather than all at once.
This list is in roughly priority order.

## Dual-stack cluster (IPv4 + IPv6)

The cluster is IPv4-only: pods (`10.244.0.0/16`), Services and the Cilium LB pool (`192.168.102.128/26`) have no
IPv6, and the nodes have no IPv6 addresses. That was fine until the in-cluster Unbound
([`../argocd/README.md`](../argocd/README.md#unbound-in-cluster-copy-deployed-2026-09-29)) needed an IPv6 address to
hand out. Its VIP is IPv4 only (`192.168.102.130`), so for now DHCPv6/RA on the Server and Trusted VLANs should keep
advertising only the jump box's `fd3d:b17d:9f8e:102::2` as an IPv6 resolver.

Dual-stack is a project of its own, not a side effect of Unbound: it touches every workload and needs a maintenance
window. Rough steps:

- Add an IPv6 pod CIDR and service CIDR (from the `fd3d:b17d:9f8e::/48` ULA space) to the control-plane config, and
  enable IPv6 in Cilium (`talos/cilium/values.yaml`). Cilium's pod CIDR allocation has to match the Talos
  `podSubnets`, same as for IPv4.
- Give every node a stable IPv6 address (SLAAC or a reservation), including the MBP's UTM VM.
- Add an IPv6 block to the `homelab-pool` LB pool, and set `ipFamilyPolicy: PreferDualStack` on the Gateway's and the
  Unbound Service, with a pinned IPv6 address for Unbound.
- **Check first:** whether Cilium's L2 announcements answer IPv6 neighbor discovery (NDP) on the version we run. If
  they don't, an IPv6 LB IP can't be announced on the LAN, and the alternatives (BGP, a different approach) change the
  plan.
- Check every workload that hard-codes an address family or a `0.0.0.0` bind, and the UniFi firewall rules between
  VLANs, which need IPv6 equivalents for anything the cluster serves.
- On the UniFi side, DHCPv6 only hands out DNS servers to clients that speak DHCPv6. SLAAC with RDNSS reaches more
  devices (Android in particular ignores DHCPv6), so switch the Server and Trusted VLANs to SLAAC when adding the
  Unbound IPv6 address, as some of the other dual-stack VLANs already are.

Then add the IPv6 VIP to the Server and Trusted VLANs' IPv6 DNS servers next to the jump box's.

## Secrets rotation (external systems)

The goal is peace of mind and following best practice, not a compliance regime. Nothing has ever been rotated, and
there's no inventory. The scope is deliberately narrow: credentials issued by an *external* system (a provider's API
token, a service account), because those are the ones that grant access beyond this cluster and that a leak would
make worst. Out of scope: Authelia's internal keys and OIDC client secrets, the SOPS age key, the Talos secrets
bundle, and the Zigbee and Z-Wave network keys. Rotating those is invasive (re-pairing devices, re-encrypting the
Authelia database, re-keying every SOPS file) for little gain at this scale.

Rotating one of these is mostly small: create a new credential at the provider, put it in the `homelab-k8s` vault (or
re-encrypt the SOPS file), force-sync and restart the consumer (see "Adding or rotating a secret" in
[`../argocd/README.md`](../argocd/README.md#adding-or-rotating-a-secret)), confirm it works, then revoke the old one.
The old credential should be revoked last, so nothing breaks in between.

Rough inventory, to be checked against the repo, 1Password and each provider before trusting it:

- **Cloudflare:** the cluster's API token (cert-manager and external-dns, from the `homelab-k8s` vault) and Terraform's
  separate token (`terraform/cloudflare/secrets/`).
- **TrueNAS:** API keys for democratic-csi (two drivers), `truenas-exporter` and Homepage. democratic-csi's key is
  already due for replacement with a least-privilege user; see [`FUTURE.md`](FUTURE.md#democratic-csi-on-truenass-json-rpc-api-hold-hexostruenas-below-26x),
  and rotate it as part of that.
- **UniFi:** Homepage's API key, Unpoller's login, and `UNIFI_TOKEN` in the Compose `.env`.
- **Proxmox:** the token Homepage uses and Terraform's token (`terraform/proxmox/secrets/`).
- **GitHub:** the Renovate token, and the self-hosted runner's registration.
- **Backblaze B2:** the Terraform state key, the etcd-backup key, and the P3 Plus backup key. All three should already
  be scoped to one bucket each; confirm that, and that none is the master key.
- **Brevo:** the SMTP login in `scripts/secrets/msmtprc.sops.yaml`.
- **1Password:** the `homelab-external-secrets` service account token, which can be replaced as documented under
  [ESO bootstrap](../argocd/README.md#eso-bootstrap-one-time-manual). It's the least risky one to practice on.
- **Not in the repo:** account logins (Cloudflare, B2, GitHub, UniFi, HexOS/TrueNAS admin, Hover). Passwords and 2FA are
  1Password's job; just check each account for long-lived API tokens nobody remembers creating.

Suggested approach:

1. The Compose migration is finished (only Unbound, Telegraf, Vector and `nut-upsd` remain), so the list is as short as it will get; check whether `UNIFI_TOKEN` and the NUT passwords are still needed.
2. Write a runbook under `docs/` (and add it to `docs-site/mkdocs.yml`'s `nav:`): for each credential, which provider
   issued it, its scopes, where it's stored, and how to rotate it. Note any that are over-privileged and replace them
   with narrower or per-consumer credentials as you go, which is the bigger win than the rotation itself.
3. Do one rotation of everything as a dry run, noting where it hurt.
4. Set an expiry wherever the provider allows one, and otherwise a yearly calendar reminder to rotate. Rotate
   immediately if a credential might have leaked (pasted somewhere, a laptop lost).

## Security hardening (from the 2026-10-04 review)

A read-only review of the repo, the cluster and rpi5-1 found a solid baseline (Authelia default-deny with two-factor,
pinned image tags, key-only SSH, protected `main`) and the gaps below. Each is its own small effort. What the review
did *not* cover (UniFi's inter-VLAN firewall and any WAN port forwards, what Cloudflare exposes to the internet,
Proxmox and TrueNAS/HexOS API exposure, and 2FA on the GitHub, 1Password, Cloudflare and UniFi accounts) still needs a
separate look.

### Scope Headlamp's ServiceAccount

The `headlamp` ClusterRoleBinding gives Headlamp's own ServiceAccount `cluster-admin`
([`manifests/headlamp/clusterrolebinding.yaml`](../manifests/headlamp/clusterrolebinding.yaml)), so a compromised
Headlamp pod would own the cluster. That was a deliberate 2026-09-21 call, because Headlamp ran in `-in-cluster` mode and
used the SA's token for every request. Since then kube-apiserver was wired to Authelia's OIDC
([`talos/patches/control-plane/oidc.yaml`](../talos/patches/control-plane/oidc.yaml)) with an `oidc-admin` binding for
`jakerobb@gmail.com`, and the comment on that binding says the SA is for Headlamp's backend only, not for requests that
carry a user's token. **Find out which is true now** before changing anything: bind the SA to `view` (or a narrower
role) and check that Headlamp still works for you, including writes, since those should then be authorized by your own
`oidc-admin` identity. If writes break, Headlamp is still using the SA's token, and the answer is a smaller custom role
instead of `view`. Update the "RBAC" bullet in the Headlamp section of `argocd/README.md` either way.

### Harden SSH and the host firewall on rpi5-1

`sshd` is already key-only. Still to do: `PermitRootLogin` is `without-password`, so set it to `no`, and set
`X11Forwarding no`. `3493` (the NUT data port for the UPS) is reachable from the LAN without authentication; it's
read-only data, but consider limiting it to the hosts that need it. A first look at the nftables ruleset showed only
Docker's NAT chains, so confirm what, if anything, filters INPUT, and settle on a default-deny baseline (SSH from the
LAN, DNS on `:53`, `:3493` from where it's needed, and whatever the two entries above leave open) so that new
host-network containers aren't exposed by default. Jump-box OS upgrade (Debian 12 to 13) is tracked in `FUTURE.md`.

### Turn on the remaining free GitHub security features

Code scanning's default setup with the `actions` language (CodeQL looks for script injection in workflow files, which
matters with self-hosted runners on a public repo; Settings, Advanced Security). Dependabot malware alerts (Dependabot
alerts are already on). A `SECURITY.md`, plus private vulnerability reporting if you ever want outside reports.

### Pin container images by digest

Images are pinned by tag, which a registry can repoint (only restock-radar is pinned by digest today, by hand; the
GitHub "require SHA pinning" setting covers Actions, not container images). Add `docker:pinDigests` to Renovate's `extends` so it adds
`@sha256:` digests and updates them with the tag. Expect a one-time PR touching most manifests, and review it as you
would a bulk change; the `# renovate:` annotated pins in custom managers may need their regexes widened to cope with a
digest after the tag.

### Gate the jump-box Terraform jobs with an Environment

Deferred 2026-10-04. The Terraform plan and apply jobs run on rpi5-1, which holds Terraform's SOPS age key, for any PR
from a branch in this repo. Renovate's token now has the Workflows permission, so a stolen token could push a branch
that changes a workflow and runs on that runner. Putting those jobs behind a GitHub Environment with you as a required
reviewer closes that, at the cost of approving each Terraform PR (including Renovate's provider bumps) before it runs.
Revisit if the token's scope widens, a second person gets write access, or the jump box gains more access.

## Go apps: loose ends from the 2026-10-09 CI and Renovate work

The four Go apps (`restock-radar`, `nut-relay`, `truenas-exporter`, `modbus-eth-controller`) now share the same `ci.yml`
and `docker-publish.yml`, have required PR checks and signed commits, and are covered by this repo's Renovate CronJob
(see [`DONE.md`](DONE.md#go-apps-shared-ci-required-checks-and-renovate-coverage)). Each item below is small and
independent.

### Prove modbus's signed Swagger commit

The publish workflow regenerates Swagger docs and commits them back to `main` with the `jakerobb-apps-bot` GitHub App's
token, through the GraphQL `createCommitOnBranch` call, so GitHub signs it. The app bypasses `main pr` and not
`main integrity`. Every publish so far found no docs changes, so that path has never actually pushed. Next time a PR
changes the API annotations, check the publish run after merge: "Commit and push changes" should succeed, and a new
`chore: auto-update swagger docs` commit should appear on `main` as verified, authored by the app. If it's rejected, the
error names the rule that blocked it.

### Make the four repos' rulesets agree

They drifted while being set up. restock-radar, nut-relay and truenas-exporter each have one `main` ruleset (deletion,
force-push, signatures, PR and checks, no bypass). modbus has two: `main integrity` (no bypass) and `main pr` (the app
can bypass). "Require branches to be up to date" is on for nut-relay and truenas-exporter and off for restock-radar and
modbus. restock-radar also requires `ui`, which the others don't have. Pick the settings you want, apply them everywhere
and write them down. Only modbus needs the split form, because it's the only one with a bot that pushes to `main`.

### A read-only Docker Hub token for CI

CI's `docker` job logs in with the same `DOCKERHUB_TOKEN` that publishes images, and any branch in these repos can read
it during a CI run. Create a second, read-only (public repositories) token, store it as a separate secret, and use that
one in `ci.yml`. Leave the write token to `docker-publish.yml`.

### Let Renovate read vulnerability alerts

Renovate logs "Cannot access vulnerability alerts" for homelab and restock-radar. Add **Dependabot alerts: Read-only**
to its token, so security-driven updates can be flagged as such. Optional.

### Clean up merged branches

The app repos have a pile of merged branches on the remote (`unique-image-tags`, `go-1.27.2-and-ci`, `ci-docker-login`,
`renovate-git-author` and so on, plus restock-radar's old `renovate/golang-1.27.1`). Delete them, and turn on
"Automatically delete head branches" in the three repos that don't have it (nut-relay already does).

### Quote `$GITHUB_OUTPUT`

`actionlint` flags `echo "tag=$(date ...)" >> $GITHUB_OUTPUT` (SC2086, info level) in all four `docker-publish.yml`
files. Quote it, in all four at once so they stay identical.

### Stop copying the workflows

`ci.yml` and `docker-publish.yml` are now copies in four repos, kept in sync by hand, and the last round showed how easily
they drift. A reusable workflow in one repo (called with the image name and whether there's a UI) would turn the
next change into one PR. The catch is that every repo then depends on one repo, and modbus's Swagger step is a special
case. Worth it if a fifth Go app turns up, or the next shared change is as big as this one was.

## VolumeSnapshots for the iSCSI volumes

Nothing here can take a VolumeSnapshot today. The external-snapshotter CRDs are installed
([`../manifests/external-snapshotter/`](../manifests/external-snapshotter)) but not the snapshot-controller or its
validating webhook (`../argocd/README.md`, "external-snapshotter CRDs"), there's no `VolumeSnapshotClass`, and
democratic-csi has `volumeSnapshotClasses: []` in
[`../argocd/apps/democratic-csi/application.yaml`](../argocd/apps/democratic-csi/application.yaml). Turning them on
means installing the controller, defining a class for the driver (which makes ZFS snapshots on HexOS through the
TrueNAS API), proving a snapshot and a restore on a throwaway PVC, and adding something to take them on a schedule
and prune them. That touches the storage path every PVC shares, so it's a project of its own. Services that need a
backup today do it themselves onto `hexos-nfs` (Home Assistant, Scrypted and restock-radar all do), which keeps
working whatever happens to snapshots. Worth doing if a service turns up that can't copy its own data, or for
Prometheus and ClickHouse, whose volumes are too big to copy.

## Let ArgoCD manage its own Helm chart

ArgoCD's own chart is the one recurring manual `helm upgrade`
([`argocd/README.md`](../argocd/README.md#upgrading-argocd-itself)). Everything else, Cilium included, is an
Application. Make ArgoCD adopt itself so a merged Renovate PR is the whole deploy, with no cron job or runner. (A cron on
rpi5-1 like [compose-deploy](../docs/compose-deploy.md) would work but means parsing the version out of a README code
block. A GitHub Actions deploy is out: the only runner is on rpi5-1, which holds the Talos secrets.)

1. Add an `argocd` Application for `argo/argo-cd` with the values from
   [`argocd/install/values.yaml`](../argocd/install/values.yaml) (multi-source with a `$values` ref, or `valuesObject`).
   Renovate tracks its `targetRevision`.
2. Start with manual sync, like Cilium, and flip to automated after watching a couple of upgrades. A bad version can break
   the controller that's applying it; recovery is `helm install` against the same values from rpi5-1.
3. One-time adoption: sync the Application over the live resources, then delete the stale Helm release Secrets
   (`sh.helm.release.v1.argocd.*` in the `argocd` namespace) without uninstalling, so nobody runs `helm upgrade` against
   stale state.
4. Expect to need `ignoreDifferences` or sync options for `argocd-initial-admin-secret` and the redis secret-init job, so
   Argo doesn't fight them. The chart's CRDs need the same treatment as kube-prometheus-stack's: the `applicationsets`
   CRD is ~377KB, over the client-side-apply annotation cap, so the Application needs `ServerSideApply=true` plus the
   `argocd.argoproj.io/compare-options: ServerSideDiff=true` annotation (see the CRD item below). Also protect the CRDs
   from `prune` (`Prune=false`): ArgoCD's own CRDs vanishing would take every Application with them.
5. Update "Upgrading ArgoCD itself" and the "Bootstrap pattern" section of `argocd/README.md` (the "manual permanently"
   claim), and move the Renovate comment off the `helm install` block.

## Move the remaining hand-applied CRDs under ArgoCD

kube-prometheus-stack's CRDs have been ArgoCD-managed since 2026-10-02, using `ServerSideApply=true` plus the
`argocd.argoproj.io/compare-options: ServerSideDiff=true` annotation on the Application (no `Replace`). See the
`crds.enabled` bullet in [`argocd/README.md`](../argocd/README.md) for why both settings matter and the retest that proved
it. Three CRD sets are still applied by hand and drift on every chart bump (the Prometheus ones had fallen a patch
release behind before the move):

- **External Secrets Operator** (`clustersecretstores`/`secretstores` are ~724KB as rendered; chart CRDs are installed
  with `installCRDs: false`, see `argocd/apps/external-secrets/application.yaml`).
- **external-snapshotter** (the "external-snapshotter CRDs" section of `argocd/README.md`).
- **SigNoz's clickhouse-operator** (3 CRDs shipped in the chart's `crds/`, see the SigNoz section of `argocd/README.md`).

The same recipe should work for each, but it's untested on these charts. For each one: render the chart's CRDs and run
`kubectl diff --server-side --force-conflicts` against the cluster first (the dry run is what showed the Prometheus
version drift), then flip the chart to ship CRDs (or add a small Application for the raw manifests), add the SSA and
ServerSideDiff settings, and confirm `argocd-controller/Apply` shows up in the live CRDs' managed fields. Weigh the
prune risk before enabling: with `prune: true`, removing a CRD from the source deletes every custom resource of that
kind. Adding `argocd.argoproj.io/sync-options: Prune=false` to each CRD, where the chart lets you, is the safeguard.
When a set moves, delete its manual-apply section from the README in the same PR.
