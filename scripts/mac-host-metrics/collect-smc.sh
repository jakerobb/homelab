#!/bin/sh
# CPU/GPU die temp + fan RPM via powermetrics's SMC sampler.
#
# `sudo -n` (non-interactive) instead of plain `sudo`: if the NOPASSWD
# sudoers rule in telegraf-powermetrics.sudoers is ever missing or drifts,
# this fails closed (silently exits with no output) instead of Telegraf's
# exec input hanging on a password prompt it can never answer. A missing
# metric is easy to notice; a hung exec input is not.
set -eu

out="$(sudo -n /usr/bin/powermetrics --samplers smc -n1 -i1000 2>/dev/null)" || exit 0

# split(...)[1] rather than stripping a fixed " C" suffix: found live that
# this machine's temperature lines carry extra trailing annotation (e.g.
# "93.60 C (fan)", not just "93.60 C"), so gsub(" C","",$2) left the
# annotation behind in the value. Taking just the first whitespace-
# delimited token of the field is robust to whatever trails it.
cpu_temp="$(printf '%s\n' "$out" | awk -F': ' '/CPU die temperature/{split($2,a," "); print a[1]; exit}')"
gpu_temp="$(printf '%s\n' "$out" | awk -F': ' '/GPU die temperature/{split($2,a," "); print a[1]; exit}')"
fan_rpm="$(printf '%s\n' "$out" | awk -F'[: ]+' '/^Fan/{print $2; exit}')"

[ -n "${cpu_temp:-}" ] && printf 'smc_temperature,sensor=cpu_die value=%s\n' "$cpu_temp"
[ -n "${gpu_temp:-}" ] && printf 'smc_temperature,sensor=gpu_die value=%s\n' "$gpu_temp"
[ -n "${fan_rpm:-}" ] && printf 'smc_fan rpm=%s\n' "$fan_rpm"

exit 0
