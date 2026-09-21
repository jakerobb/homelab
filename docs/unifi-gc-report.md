# UniFi GC report (daily + threshold-alert email)

Email digest of the UniFi Network app's (CGFiber, `47Net.lan`) GC behavior,
live JVM heap config, and system memory, run in two modes:

- **Daily** (7am, always sends): 24h window, a routine digest.
- **Hourly** (always runs, only sends if tripped): 1h window, emails
  immediately if the Full GC rate exceeds 150/hour, so a regression is
  caught same-day instead of waiting for the next daily digest.

Background: watching for a repeat of a 2026-09-18 JVM GC hang on this box,
fixed at the time by locking the heap (`-Xms == -Xmx`, currently 640M/640M)
instead of leaving it to the JVM's default sizing.

Runs from rpi5-1, not the gateway itself. UniFi OS/Network upgrades reset
the gateway's overlay filesystem for things like `/etc/default/unifi` and
custom boot scripts, so putting the scheduling and mail logic there would
mean it silently stops working after every upgrade. Running from rpi5-1
means the only gateway-side dependency is a single `authorized_keys` line
restricted to a read-only forced command.

## What it reports

- The running `unifi` process's own `-Xms`/`-Xmx`/etc, read from its live
  `argv` (`/proc/<pid>/cmdline`) -- **not** `/etc/default/unifi` or the
  systemd unit, since we've already been burned once by config-precedence
  assumptions (the unit says 128M/512M by default; the actual runtime value
  came from `/etc/default/unifi` overriding it).
- Full GC count and rate over the trailing window (24h for the daily run, 1h
  for the hourly check), or less if `unifi` was restarted more recently than
  that -- the report says so explicitly rather than silently drawing from a
  shorter window.
- Total GC event count/rate over the same window.
- System memory (`MemTotal`/`MemAvailable`/`SwapTotal`/`SwapUsed`, from
  `/proc/meminfo`) and the `unifi` process's own RSS -- added 2026-09-19 to
  watch for any creep from locking the heap at 640M/640M, given how little
  headroom this box has generally.
- Reference points from the 2026-09-18 investigation and the
  [Ozark-Connect/unifi-perf-tweaks](https://github.com/Ozark-Connect/unifi-perf-tweaks)
  profiling data, for context on whether a given day's numbers are healthy:
  - Healthy/locked-heap steady state: ~24-42 Full GCs/hour
  - Stock/unlocked thrashing baseline: ~47-73 Full GCs/hour
  - This box just before the hang: ~332 Full GCs/hour

## Why the 24h window isn't a simple log grep

GC log lines carry a JVM-relative uptime timestamp (`[70152.068s]`), not a
wall-clock one, and `unifi.service` sets `StandardOutput=append:.../gc.log`,
so a restart resets the relative counter to ~0 while the *file* keeps
accumulating -- old and new process data can sit in the same file. The
script finds the most recent point where the timestamp decreases (a restart
boundary) and only counts lines after it.

## Files

- [`scripts/unifi-gc-report.py`](../scripts/unifi-gc-report.py) -- the
  script itself (source of truth; deployed manually, same as
  `etcd-snapshot-backup.sh`)
- Deployed to `rpi5-1:~/bin/unifi-gc-report.py`
- Log of each run: `rpi5-1:~/.unifi-gc-report.log`

## Gateway-side setup: the forced-command SSH key

A dedicated key, generated on rpi5-1 and restricted on the gateway to
exactly the read-only data the script needs -- it cannot be used for a
general shell, regardless of what the client requests.

Generate (already done, 2026-09-19):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/unifi_gc_report_ed25519 -N '' \
  -C 'rpi5-1 unifi-gc-report (read-only, forced-command)'
```

`/root/.ssh/authorized_keys` on the gateway (appended, not replacing the
existing entry for interactive admin access):

```
command="PID=$(pgrep -x unifi); tr '\0' '\n' < /proc/$PID/cmdline; echo '===UPTIME==='; ps -o etimes= -p $PID; echo '===RSSKB==='; ps -o rss= -p $PID; echo '===MEMINFO==='; cat /proc/meminfo; echo '===GCLOG1==='; cat /data/unifi/logs/gc.log.1 2>/dev/null; echo '===GCLOG==='; cat /data/unifi/logs/gc.log",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-user-rc ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAk6Z5I3pxA8rz1R5ZG3yES8oaewOG857sajP97KyxJh rpi5-1 unifi-gc-report (read-only, forced-command)
```

(Updated 2026-09-19 to add `RSSKB`/`MEMINFO` -- same key, command replaced
in place rather than appended, to avoid a duplicate/stale entry.)

**Important:** build this line with something that won't reinterpret the
`\0`/`\n` escapes (e.g. write it to a file and `cat file | ssh ... "cat >>
/root/.ssh/authorized_keys"`), not `echo "$LINE"` under zsh -- zsh's builtin
`echo` interprets backslash escapes by default and will silently corrupt
the command into literal NUL/newline bytes. Bit us once during setup.

This line, like `/etc/default/unifi`, lives on the gateway's persistent
overlay -- it survives normal reboots and UniFi Network app upgrades, and
is only wiped by a full UniFi OS upgrade. After an OS upgrade, re-append it
(the command above) and the daily report will start working again; nothing
else needs to change.

## Cron (rpi5-1)

```
MAILTO=jakerobb@gmail.com
0 7 * * * /usr/bin/python3 /home/jakerobb/bin/unifi-gc-report.py --window-hours 24 >> /home/jakerobb/.unifi-gc-report.log 2>&1
0 * * * * /usr/bin/python3 /home/jakerobb/bin/unifi-gc-report.py --window-hours 1 --min-full-gc-per-hour 150 >> /home/jakerobb/.unifi-gc-report.log 2>&1
```

Unlike `etcd-snapshot-backup.sh` (silent on success, mails on failure via
cron's own `MAILTO` + stderr), the daily job sends its own email every day
via `msmtp` directly (account `brevo`, see
[`email-alerts.md`](email-alerts.md)) regardless of outcome -- that's the
point, it's a routine digest, not a failure alert. The hourly job runs every
hour but only emails when `--min-full-gc-per-hour` is exceeded (`main()`
prints "Skipped: ..." and returns without sending otherwise) -- that output
still lands in the log, so a healthy hour is visible there even though no
email goes out. Cron's own stdout/stderr are appended to the same local log
for debugging; if a run fails before reaching `send_mail()`, no report goes
out that cycle and the failure is only visible in the log, not by email.
Acceptable for a non-critical diagnostic digest; revisit if that gap ever
matters in practice.

The threshold is a judgment call, not a hard boundary, and has already moved
once: started at 200/hour (prior profiling put the stock/unlocked thrashing
baseline at 47-73/hour and the locked-heap healthy steady state at
24-42/hour, so 200 seemed well above normal noise in either state while
staying well below the ~332/hour seen right before the 2026-09-18 hang).

Lowered to **150/hour on 2026-09-20** after a real data point: the dashboard
was noticeably slow (a single check took over a minute; ~3-4s to load
afterward, still sluggish) while this box's current-process Full GC rate was
~109-125/hour -- elevated well above the healthy 24-42/hour range, but under
the original 200 threshold, so no alert fired despite a real, user-visible
problem. `unifi-core` and CPU were otherwise healthy at the time (89% idle),
pointing at GC pause frequency itself as the likely contributor. 150 sits
just above that observed "degraded but not critical" band, still comfortably
below the actual thrashing range. Adjust the `--min-full-gc-per-hour` value
in the crontab line again if 150 turns out to be too sensitive (noisy false
positives during normal operation) or not sensitive enough (another
slow-dashboard episode that doesn't trip it).

## Testing / redeploying

```bash
scp scripts/unifi-gc-report.py jakerobb@rpi5-1.lan:~/bin/unifi-gc-report.py
ssh jakerobb@rpi5-1.lan "chmod 700 ~/bin/unifi-gc-report.py"

# Daily mode (always sends)
ssh jakerobb@rpi5-1.lan "python3 ~/bin/unifi-gc-report.py --window-hours 24"

# Hourly alert mode -- force a send to verify wiring, with a deliberately low threshold
ssh jakerobb@rpi5-1.lan "python3 ~/bin/unifi-gc-report.py --window-hours 1 --min-full-gc-per-hour 5"

# Hourly alert mode at the real threshold -- should print "Skipped: ..." and not email, under normal conditions
ssh jakerobb@rpi5-1.lan "python3 ~/bin/unifi-gc-report.py --window-hours 1 --min-full-gc-per-hour 150"
```

Verified end-to-end 2026-09-19: all three modes above run and behave as
expected (daily send, forced alert send, real-threshold skip).

## Reverting

```bash
# rpi5-1: remove the cron line and script
ssh jakerobb@rpi5-1.lan "crontab -l | grep -v unifi-gc-report.py | crontab -"
ssh jakerobb@rpi5-1.lan "rm ~/bin/unifi-gc-report.py ~/.ssh/unifi_gc_report_ed25519*"

# gateway: remove the forced-command line from authorized_keys, e.g.
ssh root@47Net.lan "grep -v unifi-gc-report /root/.ssh/authorized_keys > /tmp/ak && mv /tmp/ak /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
```
