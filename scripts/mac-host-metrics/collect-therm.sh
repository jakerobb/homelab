#!/bin/sh
# CPU thermal throttling, as a percentage of full speed (100 = unthrottled).
# This is the metric that actually explains a workload slowdown -- the raw
# die temperature alone doesn't. No sudo needed.
set -eu

out="$(/usr/bin/pmset -g therm)"
limit="$(printf '%s\n' "$out" | awk -F'= ?' '/CPU_Speed_Limit/{print $2; exit}')"

[ -n "${limit:-}" ] && printf 'thermal cpu_speed_limit_percent=%s\n' "$limit"

exit 0
