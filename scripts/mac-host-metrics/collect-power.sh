#!/bin/sh
# Whether this host is currently running on battery. For a laptop acting
# as a K8s node with no UPS of its own, a flip to battery is effectively a
# power-loss event worth alerting on -- distinct from a thermal issue.
# No sudo needed.
set -eu

out="$(/usr/bin/pmset -g batt)"
if printf '%s\n' "$out" | grep -q "AC Power"; then
  on_battery=0
else
  on_battery=1
fi

printf 'power on_battery=%ii\n' "$on_battery"

exit 0
