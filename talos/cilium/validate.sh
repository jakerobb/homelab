#!/usr/bin/env bash
# Functional Cilium check — goes beyond "is the DaemonSet Ready", which
# stayed green through two real incidents where external traffic was
# silently broken: the BGP routing bug and the L2-announcement interface
# regex miss (see talos/README.md). Curls every LoadBalancer IP and
# HTTPRoute hostname from outside the cluster (run this from rpi5-1, or
# anywhere on the LAN with kubectl access — running it from inside the
# cluster defeats the point) and checks each agent's own datapath mode
# instead of assuming it from config intent.
#
# Run after any Cilium change, and always before trusting an ArgoCD Sync of
# argocd/apps/cilium/ — that Application is deliberately manual-sync only
# because its resource-health check alone can't see this class of failure.
#
# Read-only, makes no changes. Prints OK/FAIL per check; exits non-zero if
# anything failed.
set -uo pipefail

NAMESPACE="kube-system"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-30s}"
CURL_TIMEOUT="${CURL_TIMEOUT:-5}"
FAILED=0

ok()  { printf '  OK    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; FAILED=1; }

echo "== Workload rollout status =="
for res in daemonset/cilium daemonset/cilium-envoy deployment/cilium-operator; do
  if kubectl -n "$NAMESPACE" rollout status "$res" --timeout="$ROLLOUT_TIMEOUT" >/dev/null 2>&1; then
    ok "$res rolled out and ready"
  else
    bad "$res not fully rolled out/ready (kubectl -n $NAMESPACE get $res)"
  fi
done

echo "== Per-agent datapath status =="
AGENT_PODS=$(kubectl -n "$NAMESPACE" get pods -l k8s-app=cilium -o jsonpath='{.items[*].metadata.name}')
for pod in $AGENT_PODS; do
  brief=$(kubectl -n "$NAMESPACE" exec "$pod" -c cilium-agent -- cilium-dbg status --brief 2>&1)
  if [[ "$brief" == "OK" ]]; then
    ok "$pod: cilium-dbg status OK"
  else
    bad "$pod: cilium-dbg status: $brief"
    continue
  fi

  verbose=$(kubectl -n "$NAMESPACE" exec "$pod" -c cilium-agent -- cilium-dbg status --verbose 2>&1)

  if grep -qE '^KubeProxyReplacement:\s+True' <<<"$verbose"; then
    ok "$pod: KubeProxyReplacement enabled"
  else
    bad "$pod: KubeProxyReplacement not enabled"
  fi

  # e.g. "Routing:  Network: Tunnel [vxlan]   Host: BPF" — Host: Legacy means
  # bpf.masquerade silently fell back to iptables (see talos/README.md).
  if grep -qE '^Routing:.*Host:\s*BPF' <<<"$verbose"; then
    ok "$pod: host routing is BPF (not Legacy)"
  else
    bad "$pod: host routing is NOT BPF — check bpf.masquerade (talos/README.md gotcha)"
  fi
done

echo "== LoadBalancer Services: IP assignment + external reachability =="
while IFS=$'\t' read -r ns name ip; do
  [[ -z "$ns" ]] && continue
  if [[ -z "$ip" ]]; then
    bad "$ns/$name: no external IP assigned"
    continue
  fi
  ok "$ns/$name: external IP $ip assigned"

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" "http://$ip/" 2>/dev/null)
  if [[ "$code" != "000" ]]; then
    ok "$ns/$name: http://$ip/ got a response (HTTP $code) — not a timeout/refusal"
  else
    bad "$ns/$name: http://$ip/ got NO response within ${CURL_TIMEOUT}s — check L2 announcements (talos/README.md)"
  fi
done < <(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}')

echo "== Gateway API objects =="
while IFS=$'\t' read -r name accepted; do
  [[ -z "$name" ]] && continue
  if [[ "$accepted" == "True" ]]; then
    ok "GatewayClass/$name Accepted"
  else
    bad "GatewayClass/$name not Accepted (status: ${accepted:-unknown})"
  fi
done < <(kubectl get gatewayclass -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Accepted")].status}{"\n"}{end}')

while IFS=$'\t' read -r ns name programmed; do
  [[ -z "$ns" ]] && continue
  if [[ "$programmed" == "True" ]]; then
    ok "Gateway $ns/$name Programmed"
  else
    bad "Gateway $ns/$name not Programmed (status: ${programmed:-unknown})"
  fi
done < <(kubectl get gateway -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Programmed")].status}{"\n"}{end}')

echo "== HTTPRoute hostnames: end-to-end reachability =="
while IFS=$'\t' read -r ns name hostname; do
  [[ -z "$hostname" ]] && continue
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" "http://$hostname/" 2>/dev/null)
  if [[ "$code" != "000" ]]; then
    ok "HTTPRoute $ns/$name: http://$hostname/ got a response (HTTP $code)"
  else
    bad "HTTPRoute $ns/$name: http://$hostname/ got NO response within ${CURL_TIMEOUT}s"
  fi
done < <(kubectl get httproute -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.hostnames[0]}{"\n"}{end}')

echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "All checks passed."
else
  echo "One or more checks FAILED — see above." >&2
fi
exit "$FAILED"
