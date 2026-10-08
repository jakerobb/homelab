# Upgrade checker routine

The instructions for the scheduled `upgrade-checker` task (a Claude Code scheduled task on Jake's Mac). The task's own
prompt in `~/.claude/scheduled-tasks/upgrade-checker/SKILL.md` is a short stub that reads this file from `origin/main`,
so edit the routine here, via PR, not there. The text below is the prompt, addressed to Claude.

---

Evaluate the stack and look for issues. Pick the single most-concerning issue (assuming you find any) and draft a solution. Many real failures here are *silent* -- something reports healthy while quietly not working -- so don't stop at "is anything crash-looping," check these too:

- **Crashlooping pods and concerning K8s events** -- the baseline check.
- **Talos-internal logs**: `talosctl dmesg` on each node for warnings/errors that recur repeatedly (not one-off boot noise). These are internal Talos controller-runtime logs, not Kubernetes objects -- they never show up via kubectl no matter how carefully you check pods/events. A message recurring steadily over time means something is durably broken even if nothing has crashed or gone NotReady.
- **ArgoCD Application sync/health** (`kubectl get application -n argocd`) -- an app can sit OutOfSync or Degraded/Progressing indefinitely without any pod ever crash-looping.
- **cert-manager Certificate readiness** (`kubectl get certificate -A`) for any `Ready=False` -- a renewal can silently fail for weeks before the old cert actually expires.
- **CronJob/Job runs** in-cluster (Renovate's own job, `eso-restarter`) for failures -- each run is a fresh pod, so a failing job never crashloops, it just quietly fails once per run and is easy to miss.
- **Host crons on rpi5-1** (not pods, so the Job reasoning above doesn't apply): `etcd-snapshot-backup.sh`, `proxmox-config-backup.sh`, the P3 Plus B2 backup, the alert-email jobs, and the `compose-deploy` cron (if it breaks, merges to `main` silently stop deploying the Compose side). Check their logs/mail, and confirm the newest backup objects in B2 are recent.
- **ExternalSecrets health**: `kubectl get externalsecret,clustersecretstore -A` for anything not Ready (this is the shape of the 1Password rate-limit failure), and confirm `eso-restarter`'s CronJob is succeeding -- a restarter that fails silently is worse than none.
- **The alerting path itself** (if it's broken, nothing else will tell you): Prometheus and Alertmanager up, the Watchdog alert firing, ntfy-alertmanager and ntfy healthy, and the Prometheus PVC not in one of its known iSCSI write stalls (`ISCSIVolumeIOStall` is blind to its own disk).
- **Storage backend**: HexOS/TrueNAS holds every PV. Check pool capacity via `ssh truenas-ops` (`zfs list`). Also look for silently read-only iSCSI volumes after any HexOS/Proxmox outage -- grep stateful pods' logs for "Read-only file system", or `kubectl exec ... touch` in a few of them.
- **Nodes**: any NotReady, and free disk on the MacBook Pro host (`ssh jakerobb@192.168.102.9 df -h /`) -- a full host disk has already frozen the mbp VM once.
- **DNS probe** (functional, not log-based): `dig` against both resolvers -- in-cluster Unbound `192.168.102.130` and the Compose Unbound on rpi5-1 `192.168.102.2` -- for one `.lan` name and one external name. A hung resolver can log nothing.
- **Silent pod-log errors** (a pod stays Running/healthy while quietly erroring in retries -- same shape as the Talos dmesg issue, one layer up). Don't read full logs: grep the recent window for error-ish keywords (`error|panic|fatal|forbidden|denied|refused|timeout|unauthorized`), strip timestamps so repeated messages collapse together, count occurrences, and only look closer at whatever actually recurs. Apply this to:
  - **Always** (highest blast radius, checked every run): the control-plane static pods (kube-apiserver/scheduler/controller-manager), the in-cluster unbound pods (dns; the Compose copy is covered under rpi5-1 below), democratic-csi (storage), authelia (SSO gate for ArgoCD and other apps -- a silent failure is either a lockout or, worse, a bypass), and cilium-operator (both replicas) plus one cilium agent pod (this cluster has a documented history of two prior *silent* Cilium failures that reported Healthy the whole time while real traffic broke -- see talos/README.md).
  - **Rotation, not random sampling**, for everything else (e.g. external-dns, cert-manager's own pod) -- pure randomness can leave a specific pod unchecked indefinitely by bad luck. Instead: list the remaining *workloads* (Running pods only, with the ReplicaSet/DaemonSet hash suffix stripped so names stay stable across restarts, excluding the always-check list above), sort for a stable order, and pick today's slice via day-of-year (`date +%j`) mod the number of ~3-workload shards. Then check logs for the pods belonging to those workloads. This walks the whole fleet within roughly `workload-count / 3` days with a hard guarantee instead of a probabilistic one, and needs no persisted state since it's recomputed fresh each run. (Adjust the `grep -v` pattern to match the always-check list.)
    ```bash
    kubectl get pods -A --field-selector=status.phase=Running --no-headers \
      | awk '{print $1"/"$2}' \
      | sed -E 's/(-[a-f0-9]{8,10})?-[a-z0-9]{5}$//' \
      | grep -Ev '^(kube-system/(kube-(apiserver|scheduler|controller-manager)|cilium)|unbound/|democratic-csi/|authelia/)' \
      | sort -u > /tmp/pods.txt
    N=$(wc -l < /tmp/pods.txt); SHARD=3
    SHARDS=$(( (N + SHARD - 1) / SHARD ))
    IDX=$(( $(date +%j) % SHARDS ))
    sed -n "$(( IDX*SHARD + 1 )),$(( IDX*SHARD + SHARD ))p" /tmp/pods.txt
    ```
- **Compose stack on rpi5-1** (what's left: `nut-upsd`, `unbound`, `telegraf`, `vector`). `restart: unless-stopped` hides flapping behind an "Up" status, so check `docker inspect -f '{{.Name}} {{.RestartCount}} {{.State.StartedAt}}'` for restarts or recent start times, then skim the logs of anything suspicious. `nut-upsd` is the UPS feed the cluster's `nut-exporter` reads, so if it dies the UPS data vanishes silently. `vector` carries syslog and Talos kernel logs to SigNoz, so confirm recent logs are actually arriving there.

Next, look at the versions of everything -- apps, dependencies, and infrastructure. Determine whether new versions exist, and prepare a report for me. Group into four sections:

1. I have Renovate configured to handle this stuff automatically in most cases. If there is an open PR from Renovate, let me know, and enumerate the updates it will apply. For the remaining four sections, only include things _not_ covered by a Renovate PR.

2. trivial upgrades (e.g. bump a version specifier, maybe trigger a build, and let Argo sync it)

3. updates that require some work (code changes, multi-step updates, etc)

4. updates that require significant work (e.g. tearing down and rebuilding a K8s node)

Finally, review todo/FUTURE.md. Every item gets a real look; do not triage by heading or by date alone.

- **Read the whole file.** It is long enough that a single `cat` gets truncated in the middle. Read it with the Read tool in
  chunks (`offset`/`limit`) until you have seen every `## ` section's body. If any output shows a "truncated" marker,
  re-read that range. In the report, state how many items you reviewed, and list any you could not read.
- **Items with a date** ("on or after YYYY-MM-DD"): unblocked if the date has passed and nothing in the item's own
  conditions says otherwise.
- **Items waiting on something upstream** (a GitHub issue, PR, or release, e.g. external-secrets#6941, onepassword-sdk-go#288,
  extism/go-sdk#102, democratic-csi #509, NetworkOptimizer's Flux dependency): extract every issue/PR URL in the item and
  check its current state with `gh issue view <url> --comments` or `gh pr view`, plus latest release where relevant.
  Report new comments, replies, status changes, or fixes since the date the item was written, even if the item isn't
  fully unblocked. Compare against what the item says is already known. Also note whether the version we run contains the fix.
- **Items waiting on a confirmation** ("confirm X landed"): run the check the item describes. If it passes, move it to
  todo/DONE.md (not READY.md), following DONE.md's existing entry style. (Items that need action go to READY.md.)
- **Items waiting on external events** (a second user, a purchase, hardware): leave them unless you see evidence the
  condition has changed.

Move unblocked items to todo/READY.md (done items to DONE.md), and tell me exactly what you moved and why. Separately,
list any upstream activity worth my attention on items that stay in FUTURE.md.

Then run todo/WATCHING.md, the list of fixed problems we're watching for a recurrence. Every `## ` entry gets its check
run, every time, with no sampling and no skipping entries that were fine yesterday.

- **Read the whole file** with the Read tool in chunks (`offset`/`limit`) until you've seen every entry's body, as for
  FUTURE.md. Count the entries.
- **Run each entry's Check** exactly as written, then compare against its Healthy and Trouble criteria. If a check can't be
  run (SSH fails, a command is refused, the output is empty in a way that doesn't mean "healthy"), that is itself
  something to report; don't assume healthy.
- **Entries in trouble** go at the top of the report, with the evidence the entry asks for. If the cause or the next step
  is in the entry, say so.
- **Retire when:** if an entry's retirement condition is met, say so, but leave the entry for me to retire.

In your report, be brief. I don't need to hear about all the things you checked that were fine. Focus on issues and opportunities, but do include the FUTURE.md review summary (items reviewed, moved, and upstream activity) and a one-line WATCHING.md summary (entries checked, and which were in trouble). For the four sections above, exclude them entirely if there's nothing to do.