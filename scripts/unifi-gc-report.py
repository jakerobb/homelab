#!/usr/bin/env python3
"""Email digest of the UniFi Network app's (CGFiber) GC behavior, live JVM
heap config, and system memory -- run in two modes from cron:

  --window-hours 24                          (daily, always sends)
  --window-hours 1 --min-full-gc-per-hour 200  (hourly, only sends if tripped)

Runs from rpi5-1, not the gateway itself, so the only thing that can break
across a UniFi OS/Network app upgrade is the one authorized_keys line on the
gateway -- everything else (scheduling, parsing, mail delivery) lives here.

Data is pulled read-only over SSH using a dedicated key
(~/.ssh/unifi_gc_report_ed25519) that is restricted on the gateway side to a
single forced command (see docs/unifi-gc-report.md for the exact
authorized_keys entry and setup/teardown instructions). That command prints,
in order: the running unifi process's own argv (the actual live JVM flags,
not /etc/default/unifi -- config file precedence has bitten us before), its
elapsed uptime in seconds, its RSS in KB, /proc/meminfo, gc.log.1, then
gc.log.

GC log lines carry a JVM-relative uptime timestamp (e.g. "[70152.068s]"),
not a wall-clock one, and a unifi restart resets that counter to ~0 while
gc.log itself keeps accumulating (StandardOutput=append). So "last N hours"
is computed by: finding the most recent point where the relative timestamp
decreases (a restart boundary) and keeping only lines after it, then taking
whatever trailing window (up to N hours) of that current process's lifetime
is available.
"""
import argparse
import re
import subprocess
import sys
from datetime import datetime, timezone
from email.mime.text import MIMEText

SSH_KEY = "/home/jakerobb/.ssh/unifi_gc_report_ed25519"
GATEWAY = "root@47Net.lan"
MAIL_FROM = "noreply@jakerobb.org"
MAIL_TO = "jakerobb@gmail.com"
MSMTP_ACCOUNT = "brevo"

GC_LINE_RE = re.compile(
    r"^\[(\d+(?:\.\d+)?)s\]\s+GC\(\d+\)\s+Pause\s+(Full|Incremental)\s+GC"
)
MEMINFO_LINE_RE = re.compile(r"^(\w+):\s+(\d+)\s*kB", re.M)

# Reference points from prior profiling (see docs/unifi-gc-report.md).
REFERENCE_LINES = [
    ("Healthy/locked-heap steady state", "24-42 Full GCs/hour"),
    ("Stock/unlocked thrashing baseline", "47-73 Full GCs/hour"),
    ("This box just before the 2026-09-18 hang", "~332 Full GCs/hour"),
]


def fetch_remote() -> str:
    result = subprocess.run(
        ["ssh", "-i", SSH_KEY, "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", GATEWAY],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        raise RuntimeError(f"SSH to gateway failed (rc={result.returncode}): {result.stderr.strip()}")
    return result.stdout


def parse_sections(raw: str) -> dict:
    parts = re.split(r"^===(\w+)===$", raw, flags=re.M)
    sections = {"CMDLINE": parts[0]}
    for i in range(1, len(parts), 2):
        sections[parts[i]] = parts[i + 1]
    return sections


def parse_heap_args(cmdline_text: str):
    args = [a for a in cmdline_text.strip().splitlines() if a.startswith("-X")]
    heap = {}
    for a in args:
        m = re.match(r"-Xms(\S+)", a)
        if m:
            heap["Xms"] = m.group(1)
        m = re.match(r"-Xmx(\S+)", a)
        if m:
            heap["Xmx"] = m.group(1)
    return heap, args


def parse_gc_lines(text: str):
    out = []
    for line in text.splitlines():
        m = GC_LINE_RE.match(line)
        if m:
            out.append((float(m.group(1)), m.group(2)))
    return out


def current_process_lines(all_lines):
    """Drop everything before the last restart boundary (a decrease in the
    relative timestamp), keeping only the current process's contiguous run."""
    if not all_lines:
        return []
    boundary = 0
    for i in range(1, len(all_lines)):
        if all_lines[i][0] < all_lines[i - 1][0]:
            boundary = i
    return all_lines[boundary:]


def human_kb(kb: float) -> str:
    """Format a kB (KiB) value the way `free -h` does (binary units)."""
    value = float(kb)
    for unit in ("Ki", "Mi", "Gi"):
        if abs(value) < 1024.0 or unit == "Gi":
            return f"{value:.0f}{unit}" if unit == "Ki" else f"{value:.1f}{unit}"
        value /= 1024.0
    return f"{kb:.0f}Ki"


def parse_meminfo(text: str) -> dict:
    return {k: int(v) for k, v in MEMINFO_LINE_RE.findall(text)}


def build_report(sections: dict, window_hours: float):
    heap, raw_args = parse_heap_args(sections.get("CMDLINE", ""))
    uptime_s = int((sections.get("UPTIME", "0") or "0").strip() or 0)
    rss_kb = int((sections.get("RSSKB", "0") or "0").strip() or 0)
    mem = parse_meminfo(sections.get("MEMINFO", ""))

    lookback_seconds = int(window_hours * 3600)

    gc1 = parse_gc_lines(sections.get("GCLOG1", ""))
    gc2 = parse_gc_lines(sections.get("GCLOG", ""))
    all_lines = gc1 + gc2  # gc.log.1 chronologically precedes gc.log

    cur = current_process_lines(all_lines)

    window_s = min(uptime_s, lookback_seconds) if uptime_s else lookback_seconds
    anchor = cur[-1][0] if cur else 0.0
    min_ts = max(0.0, anchor - window_s)
    recent = [line for line in cur if line[0] >= min_ts]

    full_count = sum(1 for _, kind in recent if kind == "Full")
    total_count = len(recent)
    hours = window_s / 3600 if window_s > 0 else 1.0
    full_per_hr = full_count / hours
    total_per_hr = total_count / hours

    partial_note = ""
    if uptime_s < lookback_seconds:
        partial_note = (
            f"\nNote: unifi has only been up {uptime_s / 3600:.1f}h (restarted "
            f"since the last full window) -- the rates below are based on that "
            f"shorter window, not a full {window_hours:g}h.\n"
        )

    reference = "\n".join(f"  - {label}: {value}" for label, value in REFERENCE_LINES)

    swap_total = mem.get("SwapTotal", 0)
    swap_free = mem.get("SwapFree", 0)
    swap_used = swap_total - swap_free

    mem_block = f"""System memory:
  MemTotal:     {human_kb(mem.get("MemTotal", 0))}
  MemAvailable: {human_kb(mem.get("MemAvailable", 0))}
  SwapTotal:    {human_kb(swap_total)}
  SwapUsed:     {human_kb(swap_used)}
unifi process RSS: {human_kb(rss_kb)}
"""

    body = f"""UniFi Network (CGFiber) GC report (window: {window_hours:g}h)
Generated: {datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")}

Live JVM heap config (from the running process's own argv, not a config file):
  -Xms: {heap.get("Xms", "?")}
  -Xmx: {heap.get("Xmx", "?")}
  All -X flags: {" ".join(raw_args) if raw_args else "(none found)"}

Process uptime: {uptime_s / 3600:.1f} hours
{partial_note}
GC activity over the last {hours:.1f}h:
  Full GCs:        {full_count}  ({full_per_hr:.1f}/hour)
  Total GC events: {total_count}  ({total_per_hr:.1f}/hour)

{mem_block}
For reference (from prior profiling -- see docs/unifi-gc-report.md):
{reference}
"""

    return body, heap, full_per_hr


def send_mail(subject: str, body: str) -> None:
    msg = MIMEText(body)
    msg["Subject"] = subject
    msg["From"] = MAIL_FROM
    msg["To"] = MAIL_TO

    result = subprocess.run(
        ["msmtp", "-a", MSMTP_ACCOUNT, "-t"],
        input=msg.as_string(),
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"msmtp failed (rc={result.returncode}): {result.stderr.strip()}")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--window-hours", type=float, default=24.0,
        help="Lookback window for GC rate calculation (default: 24)",
    )
    p.add_argument(
        "--min-full-gc-per-hour", type=float, default=None,
        help="If set, only send an email when the Full GC rate over the "
             "window exceeds this value (alert mode). If unset, always send.",
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()
    raw = fetch_remote()
    sections = parse_sections(raw)
    body, heap, full_per_hr = build_report(sections, args.window_hours)

    if args.min_full_gc_per_hour is not None and full_per_hr <= args.min_full_gc_per_hour:
        print(
            f"Skipped: {full_per_hr:.1f} Full GCs/hr <= threshold "
            f"{args.min_full_gc_per_hour:g}/hr (window {args.window_hours:g}h)"
        )
        return

    if args.min_full_gc_per_hour is not None:
        subject = (
            f"⚠ UniFi GC ALERT: {full_per_hr:.0f} Full GCs/hr "
            f"(>{args.min_full_gc_per_hour:g} threshold)"
        )
    else:
        subject = (
            f"UniFi GC report: {full_per_hr:.0f} Full GCs/hr, "
            f"heap {heap.get('Xms', '?')}/{heap.get('Xmx', '?')}"
        )

    send_mail(subject, body)
    print(f"Sent: {subject}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 - single top-level guard for cron logging
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
