# UniFi gateway: port of unpoller's "USG Insights" dashboard (grafana.com
# 11313). Works for any gateway type (UCG/UDM/USG/UXG); there's one here, the
# Cloud Gateway Fiber. Rendered by unifi-dashboards.tf.

locals {
  unifi_gateway = {
    title       = "UniFi: Gateway"
    description = "Gateway health, WAN and LAN throughput, packets, errors and drops, from unpoller."
    variables = [
      {
        name        = "gateway"
        label       = "Gateway"
        description = "UniFi gateways (device types udm, usg, uxg, ugw)."
        sql         = "SELECT DISTINCT JSONExtractString(labels, 'name') AS name FROM signoz_metrics.distributed_time_series_v4_1day WHERE metric_name = 'unpoller_device_info' AND JSONExtractString(labels, 'type') IN ('udm', 'usg', 'uxg', 'ugw') ORDER BY name"
      },
    ]
    sections = [
      {
        title = "Gateway"
        rows = [
          {
            h = 3
            panels = [
              { id = "uptime", w = 2, type = "number", unit = "s", title = "Uptime", queries = [{ q = "max(unpoller_device_uptime_seconds{name=~\"$gateway\"})" }] },
              { id = "cpu", w = 2, type = "number", unit = "percentunit", title = "CPU", queries = [{ q = "max(unpoller_device_cpu_utilization_ratio{name=~\"$gateway\"})" }] },
              { id = "memory", w = 2, type = "number", unit = "percentunit", title = "Memory", queries = [{ q = "max(unpoller_device_memory_utilization_ratio{name=~\"$gateway\"})" }] },
              { id = "download", w = 2, type = "number", unit = "Mbit/s", title = "Speed test down", queries = [{ q = "max(unpoller_device_speedtest_download{name=~\"$gateway\"})" }] },
              { id = "upload", w = 2, type = "number", unit = "Mbit/s", title = "Speed test up", queries = [{ q = "max(unpoller_device_speedtest_upload{name=~\"$gateway\"})" }] },
              { id = "clients", w = 2, type = "number", unit = "1", title = "Clients", queries = [{ q = "sum(unpoller_site_stations)" }] },
            ]
          },
          {
            h = 3
            panels = [
              {
                id      = "details", w = 12, type = "table", unit = "1", title = "Details"
                queries = [{ q = "max by (name, model, version, ip, mac, serial) (unpoller_device_info{name=~\"$gateway\"})" }]
              },
            ]
          },
        ]
      },
      {
        title = "WAN"
        rows = [
          {
            h = 6
            panels = [
              {
                id = "wan-throughput", w = 6, type = "ts", unit = "By/s", title = "WAN throughput"
                queries = [
                  { q = "sum by (name, port) (rate(unpoller_device_wan_receive_bytes_total{name=~\"$gateway\"}[5m]))", legend = "{{port}} Rx" },
                  { q = "sum by (name, port) (rate(unpoller_device_wan_transmit_bytes_total{name=~\"$gateway\"}[5m]))", legend = "{{port}} Tx" },
                ]
              },
              {
                id = "wan-packets", w = 6, type = "ts", unit = "pps", title = "WAN packets"
                queries = [
                  { q = "sum by (name, port) (rate(unpoller_device_wan_receive_packets_total{name=~\"$gateway\"}[5m]))", legend = "{{port}} Rx" },
                  { q = "sum by (name, port) (rate(unpoller_device_wan_transmit_packets_total{name=~\"$gateway\"}[5m]))", legend = "{{port}} Tx" },
                ]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id = "wan-errors", w = 6, type = "ts", unit = "pps", title = "WAN drops and errors"
                queries = [
                  { q = "sum by (name, port) (rate(unpoller_device_wan_receive_dropped_total{name=~\"$gateway\"}[5m]))", legend = "{{port}} drops Rx" },
                  { q = "sum by (name, port) (rate(unpoller_device_wan_transmit_dropped_total{name=~\"$gateway\"}[5m]))", legend = "{{port}} drops Tx" },
                  { q = "sum by (name, port) (rate(unpoller_device_wan_receive_errors_total{name=~\"$gateway\"}[5m]))", legend = "{{port}} errors Rx" },
                  { q = "sum by (name, port) (rate(unpoller_device_wan_transmit_errors_total{name=~\"$gateway\"}[5m]))", legend = "{{port}} errors Tx" },
                ]
              },
              {
                id = "wan-broadcast", w = 6, type = "ts", unit = "pps", title = "WAN multicast and broadcast"
                queries = [
                  { q = "sum by (name, port) (rate(unpoller_device_wan_receive_broadcast_total{name=~\"$gateway\"}[5m]))", legend = "{{port}} broadcast Rx" },
                  { q = "sum by (name, port) (rate(unpoller_device_wan_transmit_broadcast_total{name=~\"$gateway\"}[5m]))", legend = "{{port}} broadcast Tx" },
                  { q = "sum by (name, port) (rate(unpoller_device_wan_receive_multicast_total{name=~\"$gateway\"}[5m]))", legend = "{{port}} multicast Rx" },
                  { q = "sum by (name, port) (rate(unpoller_device_wan_transmit_multicast_total{name=~\"$gateway\"}[5m]))", legend = "{{port}} multicast Tx" },
                ]
              },
            ]
          },
        ]
      },
      {
        title = "LAN"
        rows = [
          {
            h = 6
            panels = [
              {
                id = "lan-throughput", w = 4, type = "ts", unit = "By/s", title = "LAN throughput"
                queries = [
                  { q = "sum by (name) (rate(unpoller_device_lan_receive_bytes_total{name=~\"$gateway\"}[5m]))", legend = "Rx" },
                  { q = "sum by (name) (rate(unpoller_device_lan_transmit_bytes_total{name=~\"$gateway\"}[5m]))", legend = "Tx" },
                ]
              },
              {
                id = "lan-packets", w = 4, type = "ts", unit = "pps", title = "LAN packets"
                queries = [
                  { q = "sum by (name) (rate(unpoller_device_lan_receive_packets_total{name=~\"$gateway\"}[5m]))", legend = "Rx" },
                  { q = "sum by (name) (rate(unpoller_device_lan_transmit_packets_total{name=~\"$gateway\"}[5m]))", legend = "Tx" },
                ]
              },
              {
                id = "lan-drops", w = 4, type = "ts", unit = "pps", title = "LAN drops"
                queries = [
                  { q = "sum by (name) (rate(unpoller_device_lan_receive_dropped_total{name=~\"$gateway\"}[5m]))", legend = "Rx" },
                ]
              },
            ]
          },
        ]
      },
      {
        title = "System"
        rows = [
          {
            h = 6
            panels = [
              {
                id = "cpu-memory", w = 4, type = "ts", unit = "percentunit", title = "CPU and memory", soft_max = 1
                queries = [
                  { q = "max by (name) (unpoller_device_cpu_utilization_ratio{name=~\"$gateway\"})", legend = "CPU" },
                  { q = "max by (name) (unpoller_device_memory_utilization_ratio{name=~\"$gateway\"})", legend = "Memory" },
                ]
              },
              {
                id = "load", w = 4, type = "ts", unit = "1", title = "Load average"
                queries = [
                  { q = "max by (name) (unpoller_device_load_average_1{name=~\"$gateway\"})", legend = "1m" },
                  { q = "max by (name) (unpoller_device_load_average_5{name=~\"$gateway\"})", legend = "5m" },
                  { q = "max by (name) (unpoller_device_load_average_15{name=~\"$gateway\"})", legend = "15m" },
                ]
              },
              {
                id = "temperature", w = 4, type = "ts", unit = "celsius", title = "Temperatures"
                queries = [
                  { q = "max by (name, temp_area) (unpoller_device_temperature_celsius{name=~\"$gateway\"})", legend = "{{temp_area}}" },
                ]
              },
            ]
          },
        ]
      },
    ]
  }
}
