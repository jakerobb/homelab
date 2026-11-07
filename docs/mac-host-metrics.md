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

## Where the data goes

Two copies of the same metrics, for two different jobs:

- **SigNoz, for graphs.** Telegraf's `outputs.opentelemetry` pushes to `otel.jakerobb.org` → `signoz-otel-collector` →
  ClickHouse. Browse it in SigNoz's Metrics Explorer by `host.name`.
- **Prometheus, for alerts** (added 2026-09-24). Telegraf's `outputs.prometheus_client` serves `/metrics` on port
  `9273`, and kube-prometheus-stack's Prometheus scrapes it as the `mac-hosts` job (a static target in
  [`argocd/apps/kube-prometheus-stack/application.yaml`](../argocd/apps/kube-prometheus-stack/application.yaml)). The
  `MacHostDiskSpaceLow` rule in that file fires through Alertmanager → ntfy like every other alert: warning below 40GiB
  free, critical below 15GiB. SigNoz has no alerting wired up (see `todo/FUTURE.md`), which is why this second path
  exists. A failed scrape (Mac off, Telegraf stopped, firewall) shows up as the chart's default `TargetDown` alert.

Why the disk alert matters: the UTM VM's disk file only takes up space on the Mac as the VM writes to it. If the Mac
fills up, QEMU pauses the VM ("No space left on device") and its Talos node goes NotReady. Kubelet's own image
cleanup can't prevent it, because it only sees the VM's virtual disk size. This happened on 2026-09-24. The SigNoz copy
had shown the Mac at 99.8% used for hours beforehand, but nothing was alerting on it.

**Each Mac needs a DHCP reservation** so the scrape target stays put (the MacBook Pro's is `192.168.102.9` and the Mac Studio's is `192.168.102.22`). Adding a
Mac means a new reservation plus a new entry under the `mac-hosts` job's `targets`, **and** the same IP in the
`prometheus-scrape` CiliumNetworkPolicy in
[`manifests/network-policies/monitoring.yaml`](../manifests/network-policies/monitoring.yaml). Prometheus's egress is
restricted to listed addresses, so without that entry the target shows `context deadline exceeded` (a 10-second
timeout) even though `curl` from the jump box or from a pod in another namespace works. Found 2026-11-06 on the Mac
Studio, after PR 565 added only the scrape target.

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
./bootstrap.sh talos-worker-studio-host                    # the Mac Studio (installed 2026-11)
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
   NODE_HOST_NAME=talos-worker-mbp-host   # or e.g. talos-worker-studio-host
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
   the script's `awk` patterns to match. **On Apple Silicon this is a dead
   end:** there is no `smc` sampler at all (see the first Gotcha below), so
   `collect-smc.sh` prints nothing no matter what the sudoers rule says.

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

8. **Verify the Prometheus endpoint.** From rpi5-1 (not from the Mac itself, which would bypass the firewall):
   ```bash
   curl -s http://<mac-ip>:9273/metrics | grep '^disk_free'
   ```
   Give it a minute after a (re)start first: the endpoint has nothing to serve until Telegraf's first 60s flush.
   `bootstrap.sh` already handles the macOS Application Firewall (see the Gotcha below): it ad-hoc signs the binary
   and allows it through. If this still fails with `Empty reply from server` while the same `curl` against
   `localhost` on the Mac works, the firewall is blocking it. Check `codesign -v <prefix>/bin/telegraf` (it must be
   signed) and `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getappblocked <prefix>/bin/telegraf`. Then add
   the Mac's reserved IP to the `mac-hosts` scrape job (see "Where the data goes" above) and check that Prometheus
   shows the target as up.

## Gotchas found

- **`powermetrics` has no `smc` sampler on Apple Silicon, so `collect-smc.sh` collects nothing there.** Found live
  2026-11-06 on the Mac Studio (M5 Ultra, macOS 27.2): `sudo -n /usr/bin/powermetrics --samplers smc -n1 -i1000`, the
  script's exact command line, answers `powermetrics: unrecognized sampler: smc`. The script's `|| exit 0` hides the
  error, so the Studio simply has no `smc_temperature` or `smc_fan` series. `collect-therm.sh` also comes up empty:
  `pmset -g therm` reports no thermal warning level recorded, and the script only prints a line when it finds one. The
  Intel MacBook Pro is unaffected. `powermetrics` still has a `thermal` sampler, but it reports pressure notifications,
  not die temperatures or fan speeds.
- **[macmon](https://github.com/vladkens/macmon) fills that gap, via `collect-macmon.sh`.** Tried
  2026-11-06 (Homebrew `macmon` 0.10.0, installed as a normal user). It needs no sudo and reads its data through
  private macOS APIs. On the Studio, `macmon pipe -s 1` printed one JSON document with CPU and
  GPU average temperatures (`temp.cpu_temp_avg`, `temp.gpu_temp_avg`, about 30 °C at idle), per-fan RPM and max RPM
  (`fans`), CPU, GPU, ANE, RAM and system power in watts, per-cluster and per-core frequencies and utilisation, and
  memory and swap. Because it relies on private Apple
  APIs, a macOS or chip update can break it, so treat it as best effort. `collect-macmon.sh` runs `macmon pipe -s 1`
  once a minute and emits `macmon_temperature` (`cpu_avg`, `gpu_avg`), `macmon_fan` (tag `name`; `rpm`, `max_rpm`),
  `macmon_power_watts`, `macmon_freq_mhz` and `macmon_usage_ratio`. It exits silently when macmon isn't installed, so
  the Intel MacBook Pro just has no `macmon_*` series. On an Apple Silicon Mac, run `brew install macmon` as the
  normal user, then rerun `bootstrap.sh` to install the script and config. macmon's `ecpu`/`pcpu` names don't map to
  efficiency/performance on the M5 (its tiers are labelled P and S), so read them as two core groups, not as E and P.
- **The Mac Studio install itself needed nothing special.** It runs macOS 27.2 on an M5 Ultra (36 cores, 96GB), and
  `bootstrap.sh talos-worker-studio-host` took the default root LaunchDaemon path and the arm64 build. The Prometheus
  endpoint on `:9273` served `disk_free`, `system_uptime` and `power_on_battery`, and `disk_free` was in SigNoz
  within a minute.
- **The macOS firewall silently blocks an unsigned Telegraf, even when it's listed as allowed.** Found live
  2026-09-24: with the Application Firewall on, `socketfilterfw --listapps` showed `/usr/local/bin/telegraf` as
  "Allow incoming connections" and `--getappblocked` said "permitted", yet every connection to `:9273` from another
  host got `Empty reply from server` (TCP connects, then closes). `localhost` worked, because the firewall doesn't
  filter loopback. Turning the firewall off made it work, which pinned it down. Cause: InfluxData's macOS build
  has no code signature at all (`codesign -dv` → "code object is not signed at all"), and the firewall matches apps
  by signature. Fix: an ad-hoc signature (`codesign --force --sign -`), then remove and re-add the firewall entry
  and restart Telegraf so its listening socket is opened under the new rule. `bootstrap.sh` does all of this on
  every run, since each run re-copies the binary and so discards the signature.
- **Telegraf 1.40 exits on an unknown config option instead of ignoring it.** The first version of the
  `prometheus_client` block used `expiration` (the option is `expiration_interval`). Telegraf logged "configuration
  specified the fields ["expiration"], but they were not used" to `telegraf-launchd.log`, not `telegraf.log`, and
  exited; launchd's `KeepAlive` then restarted it every ~10s (`runs = 46`, `last exit code = 1` in
  `launchctl print`). Nothing reached SigNoz either while this was happening. Validate config changes before
  deploying: `telegraf --config <rendered.conf> --input-filter disk --test` with the same Telegraf version catches it.

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
  the same unhelpful error. **Confirmed cause (2026-09-24):** re-running `bootstrap.sh` while Telegraf was already
  running hit it every time, because `launchctl bootout` returns before launchd has finished removing the service.
  The script now waits until `launchctl print` stops finding the service before it bootstraps.
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
