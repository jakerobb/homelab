#!/usr/bin/env python3
"""Restarts the External Secrets Operator when its 1Password client is wedged.

Why: ESO's onepasswordsdk provider keeps one WASM client per process. After
about 20 failed requests (a DNS blip is enough) the SDK's guest stack is
exhausted, and from then on every call fails with `wasm error: out of bounds
memory access` until the pod restarts. See todo/FUTURE.md ("Follow up on the
1Password SDK stack-leak reports") and manifests/eso-restarter/README.md.

The error text isn't in the ExternalSecret's status (ESO keeps provider errors
out of conditions); it's only in the Warning event (reason UpdateFailed) ESO
emits on every failed reconcile. So that's what this reads.

Each run (every 5 minutes):
1. Find the newest ESO controller pod and its start time.
2. Look for UpdateFailed events on ExternalSecrets whose message has the
   wedge signature, newer than that pod's start and no older than
   EVENT_WINDOW_MINUTES. A wedge never clears by itself, so one is enough.
3. If found, and the pod is at least MIN_POD_AGE_MINUTES old (so a wedge that
   comes back right after a restart can't make a restart loop), notify,
   restart the Deployment the way `kubectl rollout restart` does, wait for the
   rollout, give the ExternalSecrets a minute to resync, then update the same
   ntfy notification (sequence id) with the outcome.

Only the wedge signature triggers a restart. A rate limit, a revoked token or
a plain network error are not fixed by restarting, and a restart makes ESO
re-read everything from 1Password, which would burn more of the daily request
budget.

Stdlib only, talking to the API server with the pod's service account.
"""
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

NAMESPACE = os.environ.get("ESO_NAMESPACE", "external-secrets")
DEPLOYMENT = os.environ.get("ESO_DEPLOYMENT", "external-secrets")
POD_SELECTOR = os.environ.get(
    "ESO_POD_SELECTOR",
    "app.kubernetes.io/name=external-secrets,app.kubernetes.io/instance=external-secrets",
)
SIGNATURE = os.environ.get("WEDGE_SIGNATURE", "out of bounds memory access")
EVENT_WINDOW = timedelta(minutes=int(os.environ.get("EVENT_WINDOW_MINUTES", "20")))
MIN_POD_AGE = timedelta(minutes=int(os.environ.get("MIN_POD_AGE_MINUTES", "15")))
ROLLOUT_TIMEOUT = int(os.environ.get("ROLLOUT_TIMEOUT_SECONDS", "300"))
SETTLE_SECONDS = int(os.environ.get("SETTLE_SECONDS", "60"))
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
NTFY_URL = os.environ["NTFY_URL"]

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
API = "https://kubernetes.default.svc"


def now():
    return datetime.now(timezone.utc)


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def api(method, path, body=None, params=None):
    with open(f"{SA_DIR}/token") as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    url = f"{API}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/merge-patch+json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
        return json.load(resp)


def notify(sequence, title, message, priority="default", tags=""):
    """Publish to ntfy. Reusing `sequence` replaces the earlier notification."""
    if DRY_RUN:
        print(f"  [dry run] would notify ({sequence}): {title}")
        return
    try:
        req = urllib.request.Request(
            f"{NTFY_URL}/{sequence}",
            data=message.encode(),
            method="POST",
            headers={"Title": title, "Priority": priority, "Tags": tags},
        )
        urllib.request.urlopen(req, timeout=15).close()
    except Exception as e:  # a failed notification must not stop the restart
        print(f"  ntfy failed: {e}", file=sys.stderr)


def newest_pod(pods):
    running = [p for p in pods if p.get("status", {}).get("startTime")]
    return max(running, key=lambda p: p["status"]["startTime"], default=None)


def event_time(ev):
    series = (ev.get("series") or {}).get("lastObservedTime")
    return parse_time(series or ev.get("lastTimestamp") or ev.get("eventTime") or ev["metadata"]["creationTimestamp"])


def wedge_events(events, pod_start, at):
    """UpdateFailed events with the wedge signature, from this pod, still current."""
    found = []
    for ev in events:
        if SIGNATURE not in ev.get("message", ""):
            continue
        t = event_time(ev)
        if t >= pod_start and at - t <= EVENT_WINDOW:
            found.append(ev)
    return found


def decide(events, pod_start, at):
    """Returns (action, reason): action is 'none', 'restart' or 'too-soon'."""
    hits = wedge_events(events, pod_start, at)
    if not hits:
        return "none", "no wedge events since the current pod started"
    age = at - pod_start
    if age < MIN_POD_AGE:
        return "too-soon", (
            f"wedge events, but the pod is only {int(age.total_seconds() // 60)}m old "
            f"(minimum {int(MIN_POD_AGE.total_seconds() // 60)}m before another restart)"
        )
    return "restart", f"{len(hits)} wedge event(s) on {len({e['involvedObject']['namespace'] + '/' + e['involvedObject']['name'] for e in hits})} ExternalSecret(s)"


def list_events():
    return api(
        "GET",
        "/api/v1/events",
        params={"fieldSelector": "reason=UpdateFailed,involvedObject.kind=ExternalSecret"},
    )["items"]


def list_pods():
    return api("GET", f"/api/v1/namespaces/{NAMESPACE}/pods", params={"labelSelector": POD_SELECTOR})["items"]


def restart_deployment():
    stamp = now().strftime("%Y-%m-%dT%H:%M:%SZ")
    if DRY_RUN:
        print(f"  [dry run] would set restartedAt={stamp} on deployment {DEPLOYMENT}")
        return
    api(
        "PATCH",
        f"/apis/apps/v1/namespaces/{NAMESPACE}/deployments/{DEPLOYMENT}",
        {"spec": {"template": {"metadata": {"annotations": {"kubectl.kubernetes.io/restartedAt": stamp}}}}},
    )


def wait_for_rollout():
    deadline = time.time() + ROLLOUT_TIMEOUT
    while time.time() < deadline:
        d = api("GET", f"/apis/apps/v1/namespaces/{NAMESPACE}/deployments/{DEPLOYMENT}")
        spec, st = d["spec"], d["status"]
        want = spec.get("replicas", 1)
        if (
            st.get("observedGeneration", 0) >= d["metadata"]["generation"]
            and st.get("updatedReplicas", 0) == want
            and st.get("replicas", 0) == want
            and st.get("readyReplicas", 0) == want
        ):
            return True
        time.sleep(5)
    return False


def externalsecret_summary():
    items = api("GET", "/apis/external-secrets.io/v1/externalsecrets")["items"]
    bad = []
    for item in items:
        ready = next((c for c in item.get("status", {}).get("conditions", []) if c["type"] == "Ready"), None)
        if not ready or ready["status"] != "True":
            bad.append(f"{item['metadata']['namespace']}/{item['metadata']['name']}")
    return len(items), bad


def main():
    print(f"eso-restarter{' (DRY RUN)' if DRY_RUN else ''}: signature {SIGNATURE!r}, window {EVENT_WINDOW}")
    pod = newest_pod(list_pods())
    if pod is None:
        print("no running ESO controller pod found; nothing to do")
        return
    pod_start = parse_time(pod["status"]["startTime"])
    at = now()
    action, reason = decide(list_events(), pod_start, at)
    print(f"pod {pod['metadata']['name']} started {pod_start:%Y-%m-%d %H:%M}Z: {action} ({reason})")
    if action != "restart":
        return

    sequence = f"eso-restarter-{at:%Y%m%d%H%M}"
    notify(
        sequence,
        "ESO's 1Password client is wedged; restarting it",
        f"{reason}. The SDK's client never recovers from `{SIGNATURE}` without a restart, "
        f"so the {DEPLOYMENT} deployment in {NAMESPACE} is being restarted now. "
        "This notification updates when it's back.",
        priority="default",
        tags="recycle",
    )
    restart_deployment()
    if DRY_RUN:
        return
    rolled = wait_for_rollout()
    if rolled:
        time.sleep(SETTLE_SECONDS)  # ESO reconciles every ExternalSecret at startup
    total, bad = externalsecret_summary()
    if rolled and not bad:
        notify(
            sequence,
            "ESO is back; ExternalSecrets are syncing again",
            f"Restarted at {at:%H:%M} UTC. All {total} ExternalSecrets are Ready.",
            tags="white_check_mark",
        )
        print("restarted; all ExternalSecrets Ready")
        return
    problem = "the rollout didn't finish in time" if not rolled else f"{len(bad)} of {total} ExternalSecrets aren't Ready yet"
    notify(
        sequence,
        "ESO was restarted, but it may not have recovered",
        f"{problem}.\n" + ("\n".join(bad[:10]) if bad else "")
        + "\nSee the ExternalSecretNotSynced alert and `kubectl -n external-secrets logs deploy/external-secrets`.",
        priority="high",
        tags="warning",
    )
    print(f"restarted, but: {problem}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} from {e.url}: {e.read().decode(errors='replace')}", file=sys.stderr)
        sys.exit(1)
