"""Relays SigNoz's webhook notifications into Prometheus Alertmanager.

SigNoz's webhook channel POSTs Alertmanager's *notification* schema
({"status", "alerts": [{status, labels, annotations, startsAt, endsAt,
generatorURL, ...}]}). Alertmanager's own intake, POST /api/v2/alerts, takes a
bare list of alerts in nearly the same shape, so this only has to unwrap the
list and settle each alert's endsAt:

  firing   -> endsAt = now + FIRING_TTL_SECONDS. SigNoz re-notifies on its own
              repeat interval, which refreshes it; the TTL only matters if the
              "resolved" notification never arrives (the alert then expires
              instead of showing as active forever).
  resolved -> endsAt = the resolved time SigNoz sent, which Alertmanager treats
              as resolved immediately.

Every relayed alert gets a `source` label (default "signoz") so the two
origins stay distinguishable in Alertmanager, Karma and Glance. Stateless on
purpose: Alertmanager holds all the state, so a restart here loses nothing.
Stdlib only, so it runs from a stock python image with this file mounted.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ALERTMANAGER_URL = os.environ["ALERTMANAGER_URL"].rstrip("/")
FIRING_TTL = timedelta(seconds=int(os.environ.get("FIRING_TTL_SECONDS", "21600")))
SOURCE = os.environ.get("SOURCE_LABEL", "signoz")
LOG_PAYLOADS = os.environ.get("LOG_PAYLOADS") == "1"
MAX_BODY = 1 << 20


def log(msg):
    print(msg, flush=True)


def parse_time(value):
    """RFC 3339 -> aware datetime; None for missing/garbage/Go's zero time."""
    if not isinstance(value, str):
        return None
    # Go emits nanoseconds; fromisoformat wants at most microseconds.
    value = re.sub(r"(\.\d{6})\d+", r"\1", value)
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed if parsed.year > 1 else None


def fmt_time(moment):
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def to_postable(alert, now):
    resolved = alert.get("status") == "resolved"
    labels = {str(k): str(v) for k, v in (alert.get("labels") or {}).items()}
    labels.setdefault("source", SOURCE)
    starts = parse_time(alert.get("startsAt")) or now
    if resolved:
        ends = parse_time(alert.get("endsAt")) or now
    else:
        ends = now + FIRING_TTL
    postable = {
        "labels": labels,
        "annotations": {str(k): str(v) for k, v in (alert.get("annotations") or {}).items()},
        "startsAt": fmt_time(starts),
        "endsAt": fmt_time(ends),
    }
    if alert.get("generatorURL"):
        postable["generatorURL"] = alert["generatorURL"]
    return postable


def post_to_alertmanager(alerts):
    request = urllib.request.Request(
        ALERTMANAGER_URL + "/api/v2/alerts",
        data=json.dumps(alerts).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.status


class Handler(BaseHTTPRequestHandler):
    timeout = 10  # per-connection socket timeout, so a stalled client can't hold a thread

    def reply(self, status, text):
        body = (text + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, "OK")
        else:
            self.reply(404, "not found")

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if not 0 < length <= MAX_BODY:
            self.reply(400, "missing or oversized body")
            return
        raw = self.rfile.read(length)
        if LOG_PAYLOADS:
            log("payload: " + raw.decode(errors="replace"))
        try:
            payload = json.loads(raw)
            incoming = payload["alerts"]
            if not isinstance(incoming, list):
                raise TypeError("alerts is not a list")
            now = datetime.now(timezone.utc)
            outgoing = [to_postable(a, now) for a in incoming]
        except (ValueError, KeyError, TypeError, AttributeError) as err:
            log(f"rejected payload: {err!r}")
            self.reply(400, "not an Alertmanager-style webhook payload")
            return
        if not outgoing:
            self.reply(200, "no alerts")
            return
        try:
            post_to_alertmanager(outgoing)
        except (urllib.error.URLError, OSError) as err:
            # 5xx so the sender's own retry logic gets a chance.
            log(f"alertmanager unreachable or refused: {err!r}")
            self.reply(502, "alertmanager rejected the alerts")
            return
        for src, out in zip(incoming, outgoing):
            log(
                f"relayed {src.get('status', '?')} {out['labels'].get('alertname', '?')} "
                f"startsAt={out['startsAt']} endsAt={out['endsAt']}"
            )
        self.reply(200, f"relayed {len(outgoing)} alert(s)")

    def log_message(self, fmt, *args):
        pass  # per-alert lines above are the useful ones; skip the access log


if __name__ == "__main__":
    log(f"relaying to {ALERTMANAGER_URL}, firing TTL {FIRING_TTL}, source label {SOURCE!r}")
    try:
        ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
