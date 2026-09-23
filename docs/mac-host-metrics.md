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

## Why sudo is scoped instead of running Telegraf as root

`powermetrics` needs root to read SMC sensors (temperature, fan RPM) — `sudo powermetrics --samplers smc` in the
original ask. Running the whole Telegraf agent as root just to get that one reading would be a much bigger privilege
grant than the task needs. Instead, Telegraf runs as your normal user, and only the one `collect-smc.sh` script
escalates, via a `sudoers.d` rule scoped to that exact command line (see
`scripts/mac-host-metrics/telegraf-powermetrics.sudoers`). `pmset -g therm` (thermal throttling) and `pmset -g batt`
(power source) don't need root at all.

## Setup

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
   Option B (manual): install the LaunchDaemon this repo provides,
   substituting the same two variables, then bootstrap it:
   ```bash
   sed -e "s|@@TELEGRAF_PREFIX@@|${TELEGRAF_PREFIX}|g" -e "s|@@MAC_USERNAME@@|${MAC_USERNAME}|g" \
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
