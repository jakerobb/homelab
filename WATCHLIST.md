# WATCHLIST

Things we can't act on yet because they're waiting on something outside our
control — an upstream release, a stability/time window, or a precondition
that hasn't happened. Distinct from [TODO.md](TODO.md), which is work we
could pick up right now. Check back here periodically; once an item's
dependency clears, move it back into TODO.md as regular actionable work.

## Homepage TrueNAS widget — needs JSON-RPC API support
**Waiting on:** a Homepage release whose `truenas` widget type
(`argocd/apps/homepage/`) supports HexOS/TrueNAS's new JSON-RPC 2.0/
WebSocket API. The REST API it authenticates against today is deprecated
and slated for **removal in HexOS v26.04**. Not urgent — HexOS isn't on
that version yet — but the widget will silently break whenever it does
update, so check for Homepage support before upgrading HexOS past 26.04.

## HexOS B2 backup bucket deletion
**Waiting on:** enough elapsed time to trust the new non-redundant
(striped, no AnyRaid) HexOS pool before deleting the B2 safety copy of the
restored P3 Plus data. The restore itself is done and `rclone
check`-verified (0 differences, 318821 files) as of 2026-09-20 — this is
pure insurance against early pool failure, not active work. **Consider the
pool stable, and the bucket safe to delete, on or after 2026-10-20** (one
month from the verified restore), assuming no issues surface before then.

## Cilium `upgradeCompatibility` flag removal
**Waiting on:** the Cilium 1.20 line (1.20.1 upgraded 2026-09-15, patch-
bumped to the currently-running **1.20.2** on 2026-09-16) running stable for
a meaningful stretch before removing the `upgradeCompatibility: "1.19"` key
from `talos/cilium/values.yaml` and syncing. That key currently keeps
`envoy-xds-mode` on its legacy-safe default instead of 1.20+'s new `"ads"`
default — a low-risk, one-key change once the wait's over. See
[`talos/README.md`](talos/README.md#cilium-upgrade-119120-2026-09-15).
**Consider 1.20.x stable, and the flag safe to remove, on or after
2026-10-15** (one month from the 1.20.1 upgrade — the 1.20.2 patch bump the
next day doesn't reset this clock), assuming no issues surface before then.

## Authelia RBAC group/role mapping
**Waiting on:** a second real Authelia user. Right now anyone who
authenticates gets whatever ArgoCD's default policy grants, which is fine
with a single user — but worth building real group/role mapping
(`argocd-rbac-cm`) before that stops being true. No target date — this
depends on a new user showing up, not on elapsed time.

## UPS Tower adoption-bug stability
**Waiting on:** the 2026-09-20 fix (factory reset + re-adopt + upgrade to
UniFi UPS firmware 1.6.4.432 RC) proving durable. The UPS Tower
(192.168.0.236) has repeatedly gotten stuck in the UniFi controller's
"Adopting" state before — previous resets looked fully fixed for weeks
before recurring, so a clean state alone isn't enough evidence yet.
**Consider it stable on or after 2026-10-01**, assuming no recurrence
before then. Todo once stable: post the accumulated diagnostic
write-up (timeline, symptoms, fix) to the UniFi community thread —
<https://community.ui.com/releases/UniFi-UPS-1-6-4/3170942e-7d0e-48b6-81c0-a8bb5d3edd78>
— since Ubiquiti's UI-Team is actively engaging there.

## Alertmanager label-based routing
**Waiting on:** enough real alert volume/noise to know what routing is
actually worth building. Only `severity` maps to ntfy priority/tags today
([`manifests/ntfy-alertmanager/configmap.yaml`](manifests/ntfy-alertmanager/configmap.yaml));
per-namespace topics or similar are premature until there's a track record
to design against. **Consider there to be enough of a track record to
design against on or after 2026-10-20** (one month from Alertmanager going
live), assuming no issues surface before then.
