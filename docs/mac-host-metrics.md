# Host-level metrics from Mac Talos-worker hosts

Manual runbook for shipping macOS host-level stats — CPU die temperature, thermal throttling, fan RPM, power source,
host disk space, host uptime — from the physical Mac hosts running Talos VMs in UTM to SigNoz. This is the **host**
underneath the VM, not the Talos VM itself — Kubernetes-side monitoring
(kube-prometheus-stack/node-exporter, federated into SigNoz per [
`argocd/apps/signoz/application.yaml`](../argocd/apps/signoz/application.yaml)) already covers the VM's own CPU/memory,
and can't see anything below that layer.

Not IaC-able the way `docker-compose/telegraf/` is: that Telegraf runs in Docker on rpi5-1 (Linux) and can't read macOS
SMC sensors. This one has to run natively on the Mac itself, so — like [
`docs/utm-talos-worker.md`](utm-talos-worker.md) — it's a from-scratch manual setup, done on the Mac directly.

Two install paths are covered below, because Homebrew isn't a given here: it currently requires a newer macOS than
some of this hardware can run (the 2018 MacBook Pro's hardware tops out at Sequoia, one release short of what current
Homebrew needs), and that's expected to keep being true for old-but-still-useful hardware this repo picks up. Where
Homebrew does work, use it — it's less to maintain. Where it doesn't, Telegraf's own tar.gz release has no
package-manager dependency at all.

## Why Telegraf, not Vector

Vector already ships rpi5-1's logs to SigNoz over OTLP/HTTP (see `docker-compose/vector/vector.yaml`), but its
`opentelemetry` sink is currently logs-only in practice — Vector's own metric type doesn't convert to OTLP metrics
without hand-building the resourceMetrics/scopeMetrics JSON shape in VRL (the same reshaping the logs pipeline already
has to do, just worse — metrics need real gauge data points, not a body string). Telegraf's `outputs.opentelemetry`
plugin speaks OTLP/HTTP natively and is already a known quantity here (it's what ships rpi5-1's own metrics to
InfluxDB), so it reuses both the tool and the existing external ingest route (`otel.jakerobb.org`, from [
`argocd/apps/signoz/httproute-otel.yaml`](../argocd/apps/signoz/httproute-otel.yaml)) with no new plumbing on the SigNoz
side.

## Privilege model: scoped sudo (Homebrew) vs. root daemon (manual install)

`powermetrics` needs root to read SMC sensors (temperature, fan RPM) — `sudo powermetrics --samplers smc` in the
original ask. `pmset -g therm` (thermal throttling) and `pmset -g batt` (power source) don't need root at all.

- **Option A (Homebrew, `brew services`):** Telegraf runs as your normal user, and only `collect-smc.sh` escalates,
  via a `sudoers.d` rule scoped to that exact command line (see
  `scripts/mac-host-metrics/telegraf-powermetrics.sudoers`) — much less privilege than the task needs root for.
- **Option B (manual LaunchDaemon) runs Telegraf as root.** That's not the preferred design, but it's forced on
  macOS Sequoia and later: Local Network privacy denies non-root third-party processes launched by launchd access
  to LAN addresses (see the Gotchas), and a bare CLI binary has no app identity to grant the permission to. Root
  processes are exempt. The risk is contained by everything Telegraf executes (`collect-*.sh`) living in a
  root-owned directory, so nothing unprivileged can swap in a script. The sudoers rule is still installed, since
  it's harmless (root doesn't need it) and lets the smoke test run `collect-smc.sh` as your user.

## Setup

**Recommended: run the bootstrap script.** All the steps below are also available as a single script,
[`scripts/mac-host-metrics/bootstrap.sh`](../scripts/mac-host-metrics/bootstrap.sh) — copy/pull this repo onto the Mac,
then, on the Mac itself, as your normal user (not via `sudo` — it calls `sudo` internally only where actually needed):

```bash
cd scripts/mac-host-metrics
./bootstrap.sh talos-worker-mbp-host                       # manual install (default)
./bootstrap.sh --homebrew talos-worker-macstudio-host      # once you've confirmed Homebrew works there
```

It defaults to the manual binary + LaunchDaemon path and only uses Homebrew with an explicit `--homebrew` flag — it
does *not* try to auto-detect whether Homebrew will work, because there's no reliable way to (see the Gotchas below;
the obvious-looking check turned out to give a false positive on this exact hardware). It auto-detects CPU
architecture, and is safe to re-run — every step it takes either overwrites in place or explicitly undoes its own
prior state first, so re-running after fixing something won't leave duplicate state behind. The only thing it can't
figure out on its own is the host name, since this repo's node-naming convention isn't derivable from anything on the
machine itself.

The rest of this section is the same setup as a manual walkthrough — useful for troubleshooting a failed bootstrap
run, understanding what it's actually doing, or doing this on a Mac where you'd rather not run an unfamiliar script
unattended.

### Manual walkthrough

All steps below run on the physical Mac itself.

1. **Install Telegraf.**

   **Option A — Homebrew**, if it works on this Mac (check first — don't
   assume; it needs whatever current macOS floor Homebrew requires as of
   whenever you're reading this):
   ```bash
   brew install telegraf
   ```

   **Option B — manual binary + a LaunchDaemon this repo provides**, when
   Homebrew isn't an option (e.g. the 2018 MacBook Pro's Sequoia ceiling).
   Telegraf's tar.gz release is a self-contained Go binary with no
   package-manager dependency, so this works on any reasonably current
   macOS:
   ```bash
   TELEGRAF_VERSION=1.40.1
   curl -LO https://dl.influxdata.com/telegraf/releases/telegraf-${TELEGRAF_VERSION}_darwin_amd64.tar.gz
   echo "19b7886b3507d99f49b6459f892955ad60d4c367035887e2aa77c05d8fd0467a  telegraf-${TELEGRAF_VERSION}_darwin_amd64.tar.gz" | shasum -a 256 -c -
   ```
   That checksum is for the `darwin_amd64` build specifically (this
   MacBook Pro is Intel) — an Apple Silicon Mac needs `darwin_arm64`
   instead, with its own checksum from
   [the release's asset table](https://github.com/influxdata/telegraf/releases/tag/v1.40.1).
   Check [the releases page](https://github.com/influxdata/telegraf/releases)
   for a newer stable version too, rather than assuming `1.40.1` is still
   current — it was verified live as of 2026-09-22. **If `shasum` doesn't
   print `OK`, stop and re-download rather than proceeding** — don't
   extract or run a binary that failed verification.
   ```bash
   tar xzf telegraf-${TELEGRAF_VERSION}_darwin_amd64.tar.gz
   sudo mkdir -p /usr/local/bin /usr/local/var/log
   sudo cp telegraf-${TELEGRAF_VERSION}/usr/bin/telegraf /usr/local/bin/telegraf
   rm -rf telegraf-${TELEGRAF_VERSION} telegraf-${TELEGRAF_VERSION}_darwin_amd64.tar.gz
   ```

2. Capture the install prefix and this Mac's account name in variables —
   these feed into every template substitution below. `NODE_HOST_NAME`
   must be unique per Mac (it becomes SigNoz's `host.name`); reusing the
   same value across hosts makes their metrics collide into one series.

   If you used Homebrew (Option A):
   ```bash
   TELEGRAF_PREFIX=$(brew --prefix)   # /usr/local on Intel, /opt/homebrew on Apple Silicon
   ```
   If you installed manually (Option B):
   ```bash
   TELEGRAF_PREFIX=/usr/local
   ```
   Then, on every Mac:
   ```bash
   MAC_USERNAME=$(whoami)
   NODE_HOST_NAME=talos-worker-mbp-host   # or e.g. talos-worker-macstudio-host
   ```

3. **Copy the scripts and config** from this repo onto the Mac (e.g. via the same `git clone`/pull you'd use for anything else in this repo, or `scp` from wherever you cloned it). `telegraf.conf` is a per-host template (see its own header comment) — substitute both variables into it on the way in rather than plain-copying it:
   ```bash
   sudo mkdir -p ${TELEGRAF_PREFIX}/etc/telegraf/scripts
   sudo cp scripts/mac-host-metrics/collect-*.sh ${TELEGRAF_PREFIX}/etc/telegraf/scripts/
   sudo chmod 755 ${TELEGRAF_PREFIX}/etc/telegraf/scripts/collect-*.sh
   sed -e "s|@@TELEGRAF_PREFIX@@|${TELEGRAF_PREFIX}|g" -e "s|@@NODE_HOST_NAME@@|${NODE_HOST_NAME}|g" \
     scripts/mac-host-metrics/telegraf.conf | sudo tee ${TELEGRAF_PREFIX}/etc/telegraf.conf > /dev/null
   ```

4. **Add the sudoers rule** — scripted rather than hand-edited inside `visudo`'s interactive editor, which is painful over a remote/KVM session. `visudo -cf` still validates syntax before anything gets installed, so a bad substitution can't lock out `sudo` the way skipping that check could:
   ```bash
   sed "s|<mac-username>|${MAC_USERNAME}|g" scripts/mac-host-metrics/telegraf-powermetrics.sudoers > /tmp/telegraf-powermetrics.sudoers
   sudo visudo -cf /tmp/telegraf-powermetrics.sudoers
   sudo install -m 0440 -o root -g wheel /tmp/telegraf-powermetrics.sudoers /etc/sudoers.d/telegraf-powermetrics
   rm /tmp/telegraf-powermetrics.sudoers
   ```

5. **Test each script standalone before wiring it into Telegraf** — much easier to debug a shell script directly than through Telegraf's exec input:
   ```bash
   ${TELEGRAF_PREFIX}/etc/telegraf/scripts/collect-therm.sh
   ${TELEGRAF_PREFIX}/etc/telegraf/scripts/collect-power.sh
   ${TELEGRAF_PREFIX}/etc/telegraf/scripts/collect-smc.sh
   ```
   Each should print one or more InfluxDB line-protocol lines (e.g. `thermal cpu_speed_limit_percent=100`). If `collect-smc.sh` prints nothing, re-check step 4 — `sudo -n` fails silently (by design; see the script's own comment) rather than erroring, so a missing/mismatched sudoers rule just looks like an empty result, not a visible failure.

   **On a new architecture (e.g. the Mac Studio's Apple Silicon, vs. this
   runbook's original Intel MacBook Pro), don't assume `collect-smc.sh`'s
   output carries over unverified** — `powermetrics --samplers smc`'s SMC
   sensor labels are version/hardware-dependent, and `CPU die
   temperature`/`GPU die temperature`/`Fan:` were only confirmed live
   against the Intel Mac. If the script prints nothing even with the
   sudoers rule correctly in place, run `sudo powermetrics --samplers smc
   -n1 -i1000` by hand and check whether the labels changed, then update
   the script's `awk` patterns to match.

6. **Start Telegraf as a service.**

   Option A (Homebrew):
   ```bash
   brew services start telegraf
   ```
   Option B (manual): install the LaunchDaemon this repo provides (runs as root — see the privilege-model section
   above for why), substituting the prefix, then bootstrap it:
   ```bash
   sed "s|@@TELEGRAF_PREFIX@@|${TELEGRAF_PREFIX}|g" \
     scripts/mac-host-metrics/com.jakerobb.telegraf.plist | sudo tee /Library/LaunchDaemons/com.jakerobb.telegraf.plist > /dev/null
   sudo chown root:wheel /Library/LaunchDaemons/com.jakerobb.telegraf.plist
   sudo chmod 644 /Library/LaunchDaemons/com.jakerobb.telegraf.plist
   sudo launchctl bootstrap system /Library/LaunchDaemons/com.jakerobb.telegraf.plist
   ```
   launchd silently refuses to load a LaunchDaemon that isn't owned
   `root:wheel` with mode `644` — the `chown`/`chmod` above aren't
   optional. To restart after a config change: `sudo launchctl kickstart
   -k system/com.jakerobb.telegraf`.

7. **Verify in SigNoz** (signoz.jakerobb.org) — check the Metrics Explorer for `host.name = <the NODE_HOST_NAME you set in step 2>` and confirm `thermal`, `power`, `smc_temperature`, `smc_fan`, `disk`, and `system` series are all arriving.

## Gotchas found

- **`collect-smc.sh`'s temperature values can carry trailing annotation text.** Found live on the 2018 MacBook Pro:
  `powermetrics --samplers smc`'s `CPU die temperature` line reads `93.60 C (fan)`, not just `93.60 C` —
  `gsub(" C","",$2)` only stripped the `" C"` and left `(fan)` stuck to the value (`value=93.60 (fan)`, a broken
  line-protocol field). Fixed by taking just the first whitespace-delimited token of the field
  (`split($2,a," "); print a[1]`) instead of trying to strip a specific fixed suffix — robust to whatever trails the
  number, on any hardware.
- **macOS Sequoia's Local Network privacy reports a permission denial as `no route to host`.** Found live: a
  non-root LaunchDaemon (`UserName` set to the regular account) could never reach `otel.jakerobb.org`
  (`192.168.102.128`, a LAN address) — Telegraf logged `dial tcp 192.168.102.128:443: connect: no route to host`
  every minute — while `nc` and `curl` from an interactive iTerm shell worked fine (terminal
  apps are exempt). There's no prompt and no log line; the kernel just drops the SYN. Root processes are exempt,
  which is why Option B's plist has no `UserName` key. Hours went into ruling out everything else first (cable, sleep,
  stale ARP, Cilium L2-announcement leadership, the L7 LoadBalancer — note `ping` to a Cilium L7 Gateway VIP always
  fails by design, since only TCP 80/443 are forwarded — none of which was the problem). **Tell-tale:** the same
  destination works from an interactive shell but fails from a launchd-started process.
- **Log rotation is done by Telegraf itself (`logfile_rotation_*` in `telegraf.conf`), not `newsyslog`.** launchd
  keeps the `StandardOutPath` file open by file descriptor, so a rename-based rotation would leave Telegraf writing
  into the rotated-away file. Telegraf logs to `telegraf.log` (10MB x 5 archives); launchd's stdout/stderr go to a
  separate `telegraf-launchd.log`, which only catches crashes and startup output. When the network's down Telegraf
  logs an error per minute, so unbounded growth was a real if slow risk.
- **A `launchctl bootstrap` "Bootstrap failed: 5: Input/output error" is maddeningly generic** — it doesn't say what
  actually went wrong. The first attempt hit it with a non-root `UserName` daemon whose log file sat in a root-owned
  directory (a plausible but unconfirmed cause — it stopped happening after pre-creating the log file with the
  daemon user's ownership; that's moot now that the daemon runs as root). `bootstrap.sh` still runs `plutil -lint`
  on the rendered plist before installing it, to rule out a bad template substitution as another possible cause of
  the same unhelpful error.
- **`brew --prefix` succeeding does not mean `brew install <formula>` will work.** `bootstrap.sh`'s first version used
  `command -v brew && brew --prefix` as a "does Homebrew work here" probe, on the theory that Homebrew refuses to run
  at all on an unsupported macOS. Found live on the 2018 MacBook Pro: `brew --prefix` succeeds fine (it's a read-only
  query), but `brew install telegraf` itself failed — the macOS-version gate only bites during an actual
  install/build, not on basic commands. The script no longer tries to auto-detect this at all; it defaults to the
  manual install path and only uses Homebrew when told to with `--homebrew`, since a person who's actually tried it
  once is more reliable here than any command-line probe.
- `bootstrap.sh` refuses to run under `sudo` on purpose: `whoami` inside the script has to resolve to the real account
  (it feeds the sudoers rule), and Homebrew itself refuses to run as root. It calls `sudo` itself wherever that's
  actually needed.
- Homebrew's own minimum-macOS requirement moves forward over time and can outrun what old-but-still-useful hardware
  can run — this 2018 MacBook Pro's Sequoia ceiling was one release short of what Homebrew needed as of 2026-09-22.
  That's the entire reason Option B (manual tar.gz + a hand-rolled LaunchDaemon) exists above, as a real supported
  path here rather than a last resort — Telegraf's own release has no package-manager dependency at all.
- launchd silently ignores a LaunchDaemon plist that isn't owned `root:wheel` with mode `644` — `launchctl bootstrap`
  either fails with an unhelpful error or just does nothing, with no direct pointer back to the ownership/permission
  problem. Confirmed this needs the explicit `chown`/`chmod` step, not just `cp`.
- `sudo -n` (non-interactive) is deliberate in `collect-smc.sh`: a bare `sudo` would hang Telegraf's exec input forever waiting for a password prompt it can never answer, the first time the sudoers rule is missing or drifts out of sync with the script. Failing closed instead just means an absent `smc_temperature`/`smc_fan` series — much easier to notice and diagnose.
- The sudoers rule matches the `powermetrics` invocation **exactly**, arguments included. If `collect-smc.sh`'s command line ever changes, the sudoers file needs the matching update, or it silently stops applying.
- `collect-power.sh`'s `on_battery` reading is a real signal on a laptop but a constant `0` on a Mac with no battery (Mac Studio included) — `pmset -g batt` on those still reports "drawing from 'AC Power'", so the check degrades harmlessly rather than erroring, just not usefully.
