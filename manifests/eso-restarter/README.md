# eso-restarter

A CronJob (every 5 minutes) that restarts the External Secrets Operator when
its 1Password client is wedged, and tells you through ntfy. Added 2026-10-07.

## Why

ESO's `onepasswordsdk` provider keeps one WASM client for the whole process.
Each time a request fails inside the SDK's HTTP host function (a DNS blip, a
dropped connection, a deadline), the client's guest stack leaks about 51KiB of
its 1MiB. After about 20 such failures every call fails with
`wasm error: out of bounds memory access`, permanently, until the pod restarts.
A DNS blip did this on 2026-09-30 and it lasted about 8 hours. Nothing breaks
immediately (the Kubernetes Secrets keep their last values), but nothing
syncs, which is why there's an alert for it. The root cause and the upstream
reports are in [`../../todo/FUTURE.md`](../../todo/FUTURE.md) ("Follow up on
the 1Password SDK stack-leak reports"): this job is the stopgap until a
fixed SDK reaches the ESO chart we run.

## What it does

Every run:

1. Finds the newest ESO controller pod and when it started.
2. Looks for Warning events (reason `UpdateFailed`) on ExternalSecrets whose
   message contains `out of bounds memory access`, newer than that pod's start
   and no older than 20 minutes. The error text is only in events: ESO keeps
   provider errors out of the ExternalSecret's status conditions.
3. If there is one and the pod is at least 15 minutes old, it:
   1. publishes an ntfy notice, "ESO's 1Password client is wedged; restarting
      it", with a per-incident sequence id,
   2. sets `kubectl.kubernetes.io/restartedAt` on the Deployment's pod template
      (what `kubectl rollout restart` does),
   3. waits up to 5 minutes for the rollout, then 60 seconds for the
      ExternalSecrets to resync (ESO reconciles all of them at startup),
   4. publishes to the same sequence id again: "ESO is back; ExternalSecrets
      are syncing again" if every ExternalSecret is Ready, otherwise a
      high-priority "ESO was restarted, but it may not have recovered" listing
      what isn't Ready. In that case the job also exits 1, so `KubeJobFailed`
      fires.

Publishing to the same ntfy sequence id replaces the earlier notification on
phones and in the web app, so the "restarting" notice turns into the "back"
notice instead of leaving two messages. (ntfy v2.14+; we run v2.28.)

Only that one error triggers a restart. A rate limit, a revoked token or a
network error aren't fixed by restarting, and a restart makes ESO re-read
everything from 1Password, which spends more of the daily request budget
(see the 2026-10-02 incident in [`../../argocd/README.md`](../../argocd/README.md)).
The 15-minute minimum pod age means a wedge that returns right after a restart
can't cause a restart loop; it just leaves `ExternalSecretNotSynced` firing
for a human, and its description says what to check.

It's stateless: no annotations or ConfigMaps to track, only the pod's start
time and the events.

## Settings

Env vars in [`cronjob.yaml`](cronjob.yaml) (the rest are defaults in the
script): `DRY_RUN` and `NTFY_URL`. Defaults: events no older than 20 minutes
(`EVENT_WINDOW_MINUTES`), pod at least 15 minutes old
(`MIN_POD_AGE_MINUTES`), rollout timeout 300 seconds, settle 60 seconds.

## Trying it

A manual run is safe on a healthy cluster: it only acts on the wedge
signature, so it just logs that there's nothing to do. On rpi5-1:

```bash
kubectl -n eso-restarter create job --from=cronjob/eso-restarter manual-test
kubectl -n eso-restarter logs -f job/manual-test
kubectl -n eso-restarter delete job manual-test
```

On a healthy cluster the log says
`none (no wedge events since the current pod started)`. To see what it would do
during a wedge without restarting anything, set `DRY_RUN` to `"true"` in
[`cronjob.yaml`](cronjob.yaml) for a run.

The detection logic was checked against synthetic events (no events, other
errors, leftovers from before a restart, stale events, a pod younger than the
minimum age). It has not been exercised by a real wedge, since that can't be
caused on purpose without breaking ESO for real. The first real one is the
test; read the job's log and the notification afterwards.

## RBAC

- Cluster-wide, read-only: list Events and ExternalSecrets.
- In `external-secrets` only: list pods, and get/patch the `external-secrets`
  Deployment.

Network access: DNS, the API server and ntfy
([`networkpolicy.yaml`](networkpolicy.yaml); the ntfy side is in
[`../ntfy/networkpolicy.yaml`](../ntfy/networkpolicy.yaml)).
