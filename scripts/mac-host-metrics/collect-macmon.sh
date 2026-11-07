#!/bin/sh
# Apple Silicon temperatures, fan speeds, power draw and clocks via macmon
# (https://github.com/vladkens/macmon, `brew install macmon`). powermetrics
# on Apple Silicon has no `smc` sampler, so collect-smc.sh produces nothing
# there; macmon reads the same data through private IOReport/SMC APIs and
# needs no sudo. See ../../docs/mac-host-metrics.md.
#
# Exits quietly with no output when macmon isn't installed (every Intel Mac,
# and any Apple Silicon Mac that hasn't had the brew install yet), so the
# same telegraf.conf works everywhere. A missing metric is easy to notice;
# a failing exec input is noisy in the Telegraf log.
set -eu

macmon=""
for p in /opt/homebrew/bin/macmon /usr/local/bin/macmon; do
  [ -x "$p" ] && macmon="$p" && break
done
[ -n "$macmon" ] || exit 0

# One 1s sample. jq builds InfluxDB line protocol; `// empty` skips fields
# macmon doesn't report on a given chip instead of emitting nulls.
"$macmon" pipe -s 1 -i 1000 2>/dev/null | /usr/bin/jq -r '
  (if .temp then "macmon_temperature cpu_avg=\(.temp.cpu_temp_avg),gpu_avg=\(.temp.gpu_temp_avg)" else empty end),
  (.fans[]? | "macmon_fan,name=\(.name) rpm=\(.rpm),max_rpm=\(.max_rpm)"),
  "macmon_power_watts cpu=\(.cpu_power // 0),gpu=\(.gpu_power // 0),ane=\(.ane_power // 0),ram=\(.ram_power // 0),gpu_ram=\(.gpu_ram_power // 0),all=\(.all_power // 0),sys=\(.sys_power // 0)",
  "macmon_freq_mhz ecpu=\(.ecpu_freq_mhz // 0)i,pcpu=\(.pcpu_freq_mhz // 0)i,gpu=\(.gpu_freq_mhz // 0)i",
  "macmon_usage_ratio ecpu=\(.ecpu_scaled_ratio // 0),pcpu=\(.pcpu_scaled_ratio // 0),cpu=\(.cpu_scaled_ratio // 0),gpu=\(.gpu_scaled_ratio // 0)"
' || exit 0

exit 0
