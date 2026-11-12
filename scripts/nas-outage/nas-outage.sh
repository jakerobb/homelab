#!/usr/bin/env bash
# Keeps restock-radar and ntfy running while HexOS (the NAS) is down, on throwaway
# emptyDir storage, and hands them back afterwards. Used by phase 3 of
# docs/studio-worker-and-ram-upgrade.md; read "The restock-radar and ntfy carve-out"
# there first. Run it on the jump box (rpi5-1), where kubectl and jq are:
#
#   plan                     read-only checks, plus a server-side dry run of everything `start` creates
#   start                    move ntfy, then restock-radar, onto temporary storage (NAS still up)
#   status                   what is running where, and how long ago restock-radar last finished a poll cycle
#   reseed [file]            re-seed a stand-in whose pod was lost (default: the copy `start` saved)
#   finish --nas-up          move both back onto their real volumes (NAS up again, iSCSI verified)
#
# How it works. Both stand-ins are separate Deployments generated at run time from the live
# ones (so they always have the same image digest, config and probes), with every PVC swapped
# for an emptyDir and pinned to a node that stays up (the Studio). The real Deployments are
# only scaled to 0 and back, so ArgoCD's git state is never touched; ArgoCD itself must be
# stopped (runbook step 3.2) or its self-heal would scale the real ones straight back up.
#
# restock-radar's database (SQLite, a few MB) moves as a tar stream through `kubectl exec`.
# Its poller waits interval +/- jitter (5m +/- 1m) *after* a cycle finishes, so there is
# always a quiet gap of at least 4 minutes after `restock_radar_last_cycle_timestamp_seconds`
# changes. Both hand-overs wait for that moment, then stop one copy and start the other
# inside the gap, so no poll interval is skipped. The stand-in pod is created ahead of time
# with an init container that blocks until the database arrives, so the critical path is
# only: stop, copy a few MB, release the init container.
#
# Nothing here mounts a PVC across the NAS outage: the helper pods that read and write the
# NAS volumes exist only while the NAS is up, and are deleted before step 3.4.
set -euo pipefail

RR_NS=restock-radar
RR_DEP=restock-radar
RR_PVC=restock-radar-data
RR_DB=restock-radar.db
NTFY_NS=ntfy
NTFY_DEP=ntfy
STANDBY_SUFFIX=-standby
STANDBY_LABEL=homelab.jakerobb.org/standby
HELPER_LABEL=homelab.jakerobb.org/nas-helper
HELPER=restock-radar-nas-helper

# A node that stays up through the outage. Never talos-worker-1: that's the MS-A2 worker, and
# draining it (step 3.3) evicts emptyDir pods and their data with them.
NODE="${STANDBY_NODE:-talos-worker-studio}"
# Pinned by digest like every other image here (busybox 1.38.0 multi-arch index).
BUSYBOX='docker.io/library/busybox:1.38.0@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4'
STATE="${OUTAGE_STATE:-$HOME/nas-outage}"

# If the last cycle finished this recently, we're already inside the quiet gap: go now.
GRACE="${CYCLE_GRACE_SECONDS:-45}"
# Give up waiting for a cycle to finish after this long (the poller backs off up to 8x if
# the store is rate limiting, so a cycle can be much further apart than 5 minutes).
CYCLE_WAIT_MAX="${CYCLE_WAIT_MAX_SECONDS:-1800}"
# Warn if the stop-to-running hand-over takes longer than this. The gap is at least 240s.
BUDGET="${HANDOVER_BUDGET_SECONDS:-150}"

log()  { printf '%s  %s\n' "$(date +%T)" "$*" | tee -a "$STATE/nas-outage.log" >&2; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

# ---- helpers -----------------------------------------------------------------------------

need() { command -v "$1" >/dev/null || die "$1 not found"; }

# Pod names. The real pods and the stand-ins share app.kubernetes.io/name, so the Service and
# the NetworkPolicies see both; these selectors tell them apart.
real_sel()    { echo "app.kubernetes.io/name=$1,!$STANDBY_LABEL"; }
standby_sel() { echo "app.kubernetes.io/name=$1,$STANDBY_LABEL=true"; }
pod_of()      { kubectl -n "$1" get pods -l "$2" --field-selector=status.phase!=Succeeded,status.phase!=Failed \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true; }

# Waits until no pod matches the selector.
wait_gone() {
  local ns=$1 sel=$2 timeout=${3:-90} t=0
  while [[ -n "$(kubectl -n "$ns" get pods -l "$sel" -o name 2>/dev/null)" ]]; do
    (( t >= timeout )) && die "pods matching '$sel' in $ns still exist after ${timeout}s"
    sleep 1; t=$((t + 1))
  done
}

# replicas KIND NS NAME. Fails (and prints nothing) if the lookup fails, so that a safety check
# built on it fails closed instead of reading a missing object as "0 replicas".
replicas() { local n; n=$(kubectl -n "$2" get "$1" "$3" -o jsonpath='{.spec.replicas}') || return 1; echo "${n:-0}"; }

# restock-radar's own metrics, read straight from a pod through the API server proxy (the
# restock-radar CiliumNetworkPolicy allows the API server's `remote-node`/`host` identity on :8080).
metrics() { kubectl get --raw "/api/v1/namespaces/$RR_NS/pods/$1:8080/proxy/metrics"; }
metric()  { awk -v n="$2" '$1 == n { printf "%.0f", $2; exit }' <<<"$1"; }       # $1 = metrics text
msum()    { awk -v p="$2" 'index($1, p) == 1 { s += $2 } END { printf "%.0f", s }' <<<"$1"; }

cycle_ts() { local m; m=$(metrics "$1") || return 1; metric "$m" restock_radar_last_cycle_timestamp_seconds; }

# Blocks until the poller in pod $1 has just finished a cycle, i.e. we're at the start of the
# 4-to-6 minute quiet gap before its next one.
wait_cycle_end() {
  local pod=$1 first now age cur deadline
  first=$(cycle_ts "$pod") || die "can't read metrics from $pod"
  first=${first:-0}; now=$(date +%s); age=$(( now - first ))
  if (( first > 0 && age >= 0 && age <= GRACE )); then
    log "last poll cycle ended ${age}s ago: already inside the quiet gap"
    return
  fi
  log "last poll cycle ended ${age}s ago; waiting for the next one to finish (up to 6 min, longer if the store is backing us off)"
  deadline=$(( now + CYCLE_WAIT_MAX ))
  while :; do
    sleep 2
    cur=$(cycle_ts "$pod" 2>/dev/null || echo "$first")
    [[ "$cur" != "$first" ]] && break
    (( $(date +%s) > deadline )) && die "no poll cycle finished within ${CYCLE_WAIT_MAX}s; is the store blocking us? Check the pod's logs"
  done
  log "poll cycle finished: starting the hand-over now"
}

# What we compare before and after a hand-over, to prove the database arrived intact.
snapshot() { # $1 = pod
  local m; m=$(metrics "$1") || return 1
  echo "watched=$(metric "$m" restock_radar_watched_items) variants=$(msum "$m" 'restock_radar_variants{')"
}

# ---- manifest generation -----------------------------------------------------------------

# A busybox container that mounts the data volume. $1 = name, $2 = JSON array of volumeMounts,
# $3 = JSON array command.
SC='{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"runAsNonRoot":true,"runAsUser":65532,"runAsGroup":65532,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}'
# Idles but exits at once on SIGTERM (a bare `sleep` as PID 1 ignores it and costs a 30s grace period).
IDLE='trap "exit 0" TERM; while :; do sleep 3600 & wait $!; done'

# Turns a live Deployment (stdin) into its stand-in: same spec, every PVC volume swapped for an
# emptyDir, pinned to $NODE, selector made distinct, no Argo tracking. $1 = "seed" adds the
# init container that waits for the database plus an idle sidecar to export it from later.
standby_json() {
  jq --arg suffix "$STANDBY_SUFFIX" --arg lbl "$STANDBY_LABEL" --arg node "$NODE" \
     --arg bb "$BUSYBOX" --argjson sc "$SC" --arg idle "$IDLE" --arg seed "${1:-}" '
    def res: {requests: {cpu: "5m", memory: "8Mi"}, limits: {memory: "32Mi"}};
    .metadata.name as $name |
    {
      apiVersion: "apps/v1", kind: "Deployment",
      metadata: {name: ($name + $suffix), namespace: .metadata.namespace, labels: {($lbl): "true"}},
      spec: {
        replicas: 1, revisionHistoryLimit: 1, strategy: {type: "Recreate"},
        progressDeadlineSeconds: 600,
        selector: {matchLabels: (.spec.selector.matchLabels + {($lbl): "true"})},
        template: (.spec.template
          | .metadata.labels += {($lbl): "true"}
          | .spec.nodeSelector = {"kubernetes.io/hostname": $node}
          | del(.spec.nodeName)
          | .spec.volumes |= map(if .persistentVolumeClaim then {name: .name, emptyDir: {sizeLimit: "256Mi"}} else . end)
          | if $seed == "seed" then
              .spec.volumes += [{name: "ctl", emptyDir: {sizeLimit: "1Mi"}}]
              | .spec.initContainers = [{
                  name: "seed", image: $bb, securityContext: $sc, resources: res,
                  command: ["sh", "-c", "until [ -f /ctl/seeded ]; do sleep 1; done"],
                  volumeMounts: [{name: "data", mountPath: "/data"}, {name: "ctl", mountPath: "/ctl"}]}]
              | .spec.containers += [{
                  name: "shell", image: $bb, securityContext: $sc, resources: res,
                  command: ["sh", "-c", $idle],
                  volumeMounts: [{name: "data", mountPath: "/data", readOnly: true}]}]
            else . end)
      }
    }
    | if any(.spec.template.spec.volumes[]?; has("persistentVolumeClaim")) then error("a PVC volume survived") else . end'
}

# A pod that mounts the real restock-radar PVC, for copying the database in or out. Its labels
# deliberately don't include app.kubernetes.io/name, so no Service or policy ever selects it.
# $1 = ro|rw, $2 = optional node to pin it to (same node as the running pod, so that a
# ReadWriteOnce volume that pod holds can be shared).
helper_yaml() {
  local ro=false; [[ $1 == ro ]] && ro=true
  local pin=""; [[ -n ${2:-} ]] && pin="nodeName: $2"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $HELPER
  namespace: $RR_NS
  labels: {$HELPER_LABEL: "true"}
spec:
  $pin
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: shell
      image: $BUSYBOX
      command: ["sh", "-c", '$IDLE']
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {memory: 32Mi}}
      volumeMounts: [{name: data, mountPath: /data, readOnly: $ro}]
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: $RR_PVC}
EOF
}

wait_pod_ready() { kubectl -n "$1" wait --for=condition=Ready "pod/$2" --timeout="${3:-120s}" >/dev/null || die "pod $2 in $1 didn't become Ready"; }

# Checksums of the database files in a container, minus -shm (which SQLite rebuilds), for comparing both ends of a copy.
sums() { # ns pod container dir
  kubectl -n "$1" exec "$2" -c "$3" -- sh -c "cd $4 && sha256sum $RR_DB $RR_DB-wal 2>/dev/null; true"
}

# ---- preflight ---------------------------------------------------------------------------

preflight() {
  need kubectl; need jq; need awk; need sha256sum
  mkdir -p "$STATE"
  kubectl version >/dev/null 2>&1 || die "kubectl can't reach the cluster; run this on the jump box"
  local node_ok
  node_ok=$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.spec.unschedulable}' 2>/dev/null) \
    || die "node $NODE not found"
  [[ "$node_ok" == "True " ]] || die "node $NODE is not Ready and schedulable (got: '$node_ok')"
  [[ "$NODE" != talos-worker-1 ]] || die "STANDBY_NODE must not be talos-worker-1: the drain in step 3.3 would delete the data"
}

argo_off() {
  local n; n=$(replicas sts argocd argocd-application-controller) || die "can't read the ArgoCD application controller's replicas"
  [[ "$n" == 0 ]] || die "the ArgoCD application controller has $n replica(s). Stop it first (runbook step 3.2), or its self-heal will scale the real apps straight back up"
}

# ---- plan --------------------------------------------------------------------------------

cmd_plan() {
  preflight
  local d="$STATE/plan"; mkdir -p "$d"
  kubectl -n "$RR_NS" get deploy "$RR_DEP" -o json | standby_json seed > "$d/restock-radar-standby.json"
  kubectl -n "$NTFY_NS" get deploy "$NTFY_DEP" -o json | standby_json > "$d/ntfy-standby.json"
  # The helper shares the real pod's node (its iSCSI volume is ReadWriteOnce and mounted there).
  helper_yaml ro "$(kubectl -n "$RR_NS" get pod "$(pod_of "$RR_NS" "$(real_sel $RR_DEP)")" -o jsonpath='{.spec.nodeName}')" > "$d/helper-ro.yaml"
  helper_yaml rw > "$d/helper-rw.yaml"
  for f in restock-radar-standby.json ntfy-standby.json helper-ro.yaml helper-rw.yaml; do
    kubectl apply --dry-run=server -f "$d/$f" >/dev/null && log "dry run OK: $f"
  done
  local a; a=$(replicas sts argocd argocd-application-controller || echo '?')
  log "ArgoCD application controller replicas: $a (must be 0 before \`start\`)"
  log "restock-radar real pod: $(pod_of "$RR_NS" "$(real_sel $RR_DEP)") on $(kubectl -n "$RR_NS" get pod "$(pod_of "$RR_NS" "$(real_sel $RR_DEP)")" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
  log "stand-ins would run on: $NODE. Generated manifests are in $d"
}

# ---- start -------------------------------------------------------------------------------

PHASE=""
rollback() {
  # Only safe while the NAS is up, which is the case for the whole of `start`.
  log "start failed during '$PHASE'; rolling back (the NAS is still up)"
  set +e
  kubectl -n "$RR_NS" delete pod "$HELPER" --ignore-not-found --wait=false >/dev/null
  if [[ "$PHASE" == restock-radar* ]]; then
    kubectl -n "$RR_NS" scale deploy "$RR_DEP" --replicas=1 >/dev/null
    kubectl -n "$RR_NS" delete deploy "$RR_DEP$STANDBY_SUFFIX" --ignore-not-found --wait=false >/dev/null
    log "restock-radar scaled back to 1 on its real volume"
  fi
  kubectl -n "$NTFY_NS" scale deploy "$NTFY_DEP" --replicas=1 >/dev/null
  kubectl -n "$NTFY_NS" delete deploy "$NTFY_DEP$STANDBY_SUFFIX" --ignore-not-found --wait=false >/dev/null
  log "ntfy scaled back to 1 on its real volume. Check both with: $0 status"
}
# `die` calls exit, which an ERR trap never sees, so this is an EXIT trap.
on_exit() { local rc=$?; if (( rc != 0 )) && [[ -n "$PHASE" ]]; then rollback; fi; }

cmd_start() {
  preflight; argo_off
  kubectl -n "$RR_NS" get deploy "$RR_DEP$STANDBY_SUFFIX" >/dev/null 2>&1 && die "$RR_DEP$STANDBY_SUFFIX already exists (run finish, or delete it)"
  kubectl -n "$NTFY_NS" get deploy "$NTFY_DEP$STANDBY_SUFFIX" >/dev/null 2>&1 && die "$NTFY_DEP$STANDBY_SUFFIX already exists"
  [[ "$(replicas deploy "$RR_NS" "$RR_DEP")" == 1 && "$(replicas deploy "$NTFY_NS" "$NTFY_DEP")" == 1 ]] \
    || die "expected the real restock-radar and ntfy Deployments at 1 replica"
  local rr_pod rr_node
  rr_pod=$(pod_of "$RR_NS" "$(real_sel $RR_DEP)"); [[ -n "$rr_pod" ]] || die "no running restock-radar pod"
  rr_node=$(kubectl -n "$RR_NS" get pod "$rr_pod" -o jsonpath='{.spec.nodeName}')
  log "restock-radar is running as $rr_pod on $rr_node; stand-ins will run on $NODE"
  trap on_exit EXIT

  # --- ntfy: its cache is disposable (12h of recent messages for offline clients). The stand-in
  # is up and Ready before the real one stops, so alerts never have nowhere to go.
  PHASE=ntfy
  kubectl -n "$NTFY_NS" get deploy "$NTFY_DEP" -o json | standby_json | tee "$STATE/ntfy-standby.json" | kubectl apply -f - >/dev/null
  kubectl -n "$NTFY_NS" rollout status "deploy/$NTFY_DEP$STANDBY_SUFFIX" --timeout=180s >/dev/null
  kubectl -n "$NTFY_NS" scale deploy "$NTFY_DEP" --replicas=0 >/dev/null
  wait_gone "$NTFY_NS" "$(real_sel $NTFY_DEP)"
  log "ntfy now runs as $NTFY_DEP$STANDBY_SUFFIX on $NODE (empty cache)"

  # --- restock-radar: get everything ready first, so that the hand-over itself is only a stop, a copy and a release.
  PHASE=restock-radar-prep
  kubectl -n "$RR_NS" get deploy "$RR_DEP" -o json | standby_json seed | tee "$STATE/restock-radar-standby.json" | kubectl apply -f - >/dev/null
  helper_yaml ro "$rr_node" | kubectl apply -f - >/dev/null
  wait_pod_ready "$RR_NS" "$HELPER"
  local sb_pod
  for _ in $(seq 1 120); do
    sb_pod=$(pod_of "$RR_NS" "$(standby_sel $RR_DEP)")
    [[ -n "$sb_pod" && "$(kubectl -n "$RR_NS" get pod "$sb_pod" -o jsonpath='{.status.initContainerStatuses[?(@.name=="seed")].state.running.startedAt}' 2>/dev/null)" != "" ]] && break
    sleep 1
  done
  [[ -n "${sb_pod:-}" ]] || die "the stand-in's seed container never started"
  local before; before=$(snapshot "$rr_pod")
  log "stand-in $sb_pod is waiting for its database. Before: $before"

  PHASE=restock-radar-handover
  wait_cycle_end "$rr_pod"
  SECONDS=0
  kubectl -n "$RR_NS" scale deploy "$RR_DEP" --replicas=0 >/dev/null
  wait_gone "$RR_NS" "$(real_sel $RR_DEP)"
  log "real restock-radar stopped cleanly (${SECONDS}s); copying its database"
  kubectl -n "$RR_NS" exec "$HELPER" -c shell -- sh -c "cd /data && tar cf - \$(ls $RR_DB $RR_DB-wal 2>/dev/null)" \
    | tee "$STATE/seed.tar" \
    | kubectl -n "$RR_NS" exec -i "$sb_pod" -c seed -- tar xf - -C /data
  local a b
  a=$(sums "$RR_NS" "$HELPER" shell /data); b=$(sums "$RR_NS" "$sb_pod" seed /data)
  [[ -n "$a" && "$a" == "$b" ]] || die "database checksums differ after the copy (source: '$a', copy: '$b')"
  kubectl -n "$RR_NS" exec "$sb_pod" -c seed -- touch /ctl/seeded
  kubectl -n "$RR_NS" rollout status "deploy/$RR_DEP$STANDBY_SUFFIX" --timeout=120s >/dev/null
  log "stand-in is running; hand-over took ${SECONDS}s"
  (( SECONDS > BUDGET )) && warn "hand-over took ${SECONDS}s, over the ${BUDGET}s budget (the quiet gap is at least 240s)"

  PHASE=""; trap - EXIT
  kubectl -n "$RR_NS" delete pod "$HELPER" --wait=false >/dev/null
  # The new pod's name differs only if it restarted; read it again.
  sb_pod=$(pod_of "$RR_NS" "$(standby_sel $RR_DEP)")
  local after=""
  for _ in $(seq 1 30); do after=$(snapshot "$sb_pod" 2>/dev/null) && break; sleep 2; done
  log "After:  $after"
  [[ "$after" == "$before" ]] || warn "the before/after snapshots differ; check restock-radar's UI/metrics before trusting the stand-in"
  log "Done. No pod in $RR_NS or $NTFY_NS mounts a PVC now:"
  kubectl get pods -A -o json | jq -r --arg a "$RR_NS" --arg b "$NTFY_NS" \
    '.items[] | select(.metadata.namespace == $a or .metadata.namespace == $b) | select(.spec.volumes[]?.persistentVolumeClaim) | "  STILL MOUNTS A PVC: \(.metadata.namespace)/\(.metadata.name)"'
  log "A copy of the database as handed over is in $STATE/seed.tar"
}

# ---- status / reseed ---------------------------------------------------------------------

cmd_status() {
  need kubectl
  kubectl -n "$RR_NS" get deploy,pods -o wide 2>&1 | sed 's/^/  /'
  kubectl -n "$NTFY_NS" get deploy,pods -o wide 2>&1 | sed 's/^/  /'
  local p ts
  p=$(pod_of "$RR_NS" "app.kubernetes.io/name=$RR_DEP")
  if [[ -n "$p" ]] && ts=$(cycle_ts "$p" 2>/dev/null); then
    echo "restock-radar ($p): last poll cycle finished $(( $(date +%s) - ts ))s ago; $(snapshot "$p")"
  else
    echo "restock-radar: no pod answering /metrics (is the stand-in waiting for a seed? try: $0 reseed)"
  fi
}

cmd_reseed() {
  need kubectl
  local f="${1:-$STATE/seed.tar}" p
  [[ -f "$f" ]] || die "no such file: $f"
  p=$(pod_of "$RR_NS" "$(standby_sel $RR_DEP)"); [[ -n "$p" ]] || die "no stand-in pod"
  kubectl -n "$RR_NS" get pod "$p" -o jsonpath='{.status.initContainerStatuses[?(@.name=="seed")].state.running.startedAt}' | grep -q . \
    || die "the stand-in's seed container isn't waiting (the pod already has a database). Delete the Deployment's pod first if you really mean to replace it"
  kubectl -n "$RR_NS" exec -i "$p" -c seed -- tar xf - -C /data < "$f"
  kubectl -n "$RR_NS" exec "$p" -c seed -- touch /ctl/seeded
  log "re-seeded $p from $f (state as of the original hand-over; changes since then are lost)"
}

# ---- finish ------------------------------------------------------------------------------

cmd_finish() {
  [[ "${1:-}" == --nas-up ]] || die "pass --nas-up to confirm HexOS is back and verified (runbook step 3.7)"
  preflight; argo_off
  local sb_dep="$RR_DEP$STANDBY_SUFFIX" sb_pod
  sb_pod=$(pod_of "$RR_NS" "$(standby_sel $RR_DEP)"); [[ -n "$sb_pod" ]] || die "no restock-radar stand-in is running"
  kubectl -n "$RR_NS" exec "$sb_pod" -c shell -- true >/dev/null || die "the stand-in's export sidecar isn't running"
  [[ "$(replicas deploy "$RR_NS" "$RR_DEP")" == 0 ]] || die "the real restock-radar Deployment isn't at 0 replicas"

  # --- ntfy first, since restock-radar's alerts go through it. The real pod needs its iSCSI volume,
  # so this doubles as the first proof that the NAS volumes work. The stand-in stays until it's Ready.
  log "starting the real ntfy"
  kubectl -n "$NTFY_NS" scale deploy "$NTFY_DEP" --replicas=1 >/dev/null
  kubectl -n "$NTFY_NS" rollout status "deploy/$NTFY_DEP" --timeout=180s >/dev/null \
    || die "the real ntfy didn't become Ready (iSCSI problem?). The stand-in is still serving; investigate before going on"
  kubectl -n "$NTFY_NS" delete deploy "$NTFY_DEP$STANDBY_SUFFIX" --ignore-not-found --wait=false >/dev/null
  log "ntfy is back on its real volume"

  # --- restock-radar. Pre-stage a read-write helper on the NAS volume (the slow part: it attaches
  # the iSCSI volume), then wait for the stand-in's next quiet gap.
  helper_yaml rw | kubectl apply -f - >/dev/null
  wait_pod_ready "$RR_NS" "$HELPER" 180s
  log "NAS volume mounted by the helper; current database there: $(sums "$RR_NS" "$HELPER" shell /data | tr '\n' ' ')"
  local before; before=$(snapshot "$sb_pod"); log "Stand-in before: $before"

  wait_cycle_end "$sb_pod"
  SECONDS=0
  # Hot copy: safe because the poller is idle for at least four minutes and the UI is unreachable
  # (Authelia is down). The old database is kept aside in /data/.pre-outage on the NAS volume.
  kubectl -n "$RR_NS" exec "$sb_pod" -c shell -- sh -c "cd /data && tar cf - \$(ls $RR_DB $RR_DB-wal 2>/dev/null)" \
    | tee "$STATE/final.tar" \
    | kubectl -n "$RR_NS" exec -i "$HELPER" -c shell -- sh -c \
        "set -e; cd /data; rm -rf .pre-outage; mkdir .pre-outage; mv $RR_DB* .pre-outage/ || true; tar xf - -C /data"
  local a b
  a=$(sums "$RR_NS" "$sb_pod" shell /data); b=$(sums "$RR_NS" "$HELPER" shell /data)
  if [[ -z "$a" || "$a" != "$b" ]]; then
    kubectl -n "$RR_NS" exec "$HELPER" -c shell -- sh -c "cd /data && rm -f $RR_DB*; mv .pre-outage/* . 2>/dev/null; true" || true
    die "checksums differ after the copy; the old database was restored on the NAS volume and the stand-in is untouched (source: '$a', copy: '$b')"
  fi
  kubectl -n "$RR_NS" scale deploy "$sb_dep" --replicas=0 >/dev/null
  wait_gone "$RR_NS" "$(standby_sel $RR_DEP)"
  kubectl -n "$RR_NS" delete pod "$HELPER" --wait=true >/dev/null
  kubectl -n "$RR_NS" scale deploy "$RR_DEP" --replicas=1 >/dev/null
  kubectl -n "$RR_NS" rollout status "deploy/$RR_DEP" --timeout=180s >/dev/null || die "the real restock-radar didn't become Ready. Database copy is in $STATE/final.tar; the NAS volume has it too"
  log "real restock-radar is running; hand-over took ${SECONDS}s"
  (( SECONDS > BUDGET )) && warn "hand-over took ${SECONDS}s, over the ${BUDGET}s budget (the quiet gap is at least 240s)"

  local p after=""
  p=$(pod_of "$RR_NS" "$(real_sel $RR_DEP)")
  for _ in $(seq 1 30); do after=$(snapshot "$p" 2>/dev/null) && break; sleep 2; done
  log "Real after:  $after"
  [[ "$after" == "$before" ]] || warn "the before/after snapshots differ; check restock-radar before moving on"
  kubectl -n "$RR_NS" delete deploy "$sb_dep" --wait=false >/dev/null
  log "Done. Stand-ins deleted. The pre-outage database is kept at /data/.pre-outage on the restock-radar-data volume; delete it once you're happy."
}

# ---- main --------------------------------------------------------------------------------

mkdir -p "$STATE"
case "${1:-}" in
  plan)    cmd_plan ;;
  start)   cmd_start ;;
  status)  cmd_status ;;
  reseed)  shift; cmd_reseed "${1:-}" ;;
  finish)  shift; cmd_finish "${1:-}" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
