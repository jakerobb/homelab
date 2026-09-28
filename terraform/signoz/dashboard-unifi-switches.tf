# UniFi switches: port of unpoller's "USW Insights" dashboard (grafana.com
# 11312). The Switch list includes the gateway, since its built-in switch
# ports report the same way. Grafana's per-port repeated rows become one
# line per port ("<switch> <port>"); pick switches to narrow it down. Ports
# show as "Port N" unless they're named in UniFi. Rendered by
# unifi-dashboards.tf.

locals {
  unifi_switches = {
    title       = "UniFi: Switches"
    description = "Switch health, per-port traffic, errors, PoE and SFP modules, from unpoller."
    variables = [
      {
        name        = "switch"
        label       = "Switch"
        description = "UniFi switches, plus the gateway's built-in switch."
        sql         = "SELECT DISTINCT JSONExtractString(labels, 'name') AS name FROM signoz_metrics.distributed_time_series_v4_1day WHERE metric_name = 'unpoller_device_info' AND JSONExtractString(labels, 'type') IN ('usw', 'udm') ORDER BY name"
      },
    ]
    sections = [
      {
        title = "Switches"
        rows = [
          {
            h = 4
            panels = [
              {
                id          = "details", w = 12, type = "table", unit = "s", title = "Details"
                description = "The value column is uptime."
                queries     = [{ q = "max by (name, model, version, ip, mac, serial) (unpoller_device_uptime_seconds{name=~\"$switch\"} * on (name) group_left (model, version, ip, mac, serial) max by (name, model, version, ip, mac, serial) (unpoller_device_info))" }]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id          = "throughput", w = 6, type = "ts", unit = "By/s", title = "Throughput per switch"
                description = "Sum over all ports, so traffic between two ports of one switch counts twice."
                queries = [
                  { q = "sum by (name) (rate(unpoller_device_port_receive_bytes_total{name=~\"$switch\"}[5m]))", legend = "{{name}} Rx" },
                  { q = "sum by (name) (rate(unpoller_device_port_transmit_bytes_total{name=~\"$switch\"}[5m]))", legend = "{{name}} Tx" },
                ]
              },
              {
                id = "temperature", w = 6, type = "ts", unit = "celsius", title = "Temperatures"
                queries = [
                  { q = "max by (name, temp_area) (unpoller_device_temperature_celsius{name=~\"$switch\"})", legend = "{{name}} {{temp_area}}" },
                ]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id      = "cpu", w = 4, type = "ts", unit = "percentunit", title = "CPU", soft_max = 1
                queries = [{ q = "max by (name) (unpoller_device_cpu_utilization_ratio{name=~\"$switch\"})", legend = "{{name}}" }]
              },
              {
                id      = "memory", w = 4, type = "ts", unit = "percentunit", title = "Memory", soft_max = 1
                queries = [{ q = "max by (name) (unpoller_device_memory_utilization_ratio{name=~\"$switch\"})", legend = "{{name}}" }]
              },
              {
                id      = "load", w = 4, type = "ts", unit = "1", title = "Load average (5m)"
                queries = [{ q = "max by (name) (unpoller_device_load_average_5{name=~\"$switch\"})", legend = "{{name}}" }]
              },
            ]
          },
        ]
      },
      {
        title = "Ports"
        rows = [
          {
            h = 8
            panels = [
              {
                id      = "port-rx", w = 6, type = "ts", unit = "By/s", title = "Port receive"
                queries = [{ q = "sum by (name, port_name) (rate(unpoller_device_port_receive_bytes_total{name=~\"$switch\"}[5m]))", legend = "{{name}} {{port_name}}" }]
              },
              {
                id      = "port-tx", w = 6, type = "ts", unit = "By/s", title = "Port transmit"
                queries = [{ q = "sum by (name, port_name) (rate(unpoller_device_port_transmit_bytes_total{name=~\"$switch\"}[5m]))", legend = "{{name}} {{port_name}}" }]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id          = "port-errors", w = 6, type = "ts", unit = "pps", title = "Port errors and drops"
                description = "Only ports that had any in the last 5 minutes."
                queries = [
                  { q = "sum by (name, port_name) (rate(unpoller_device_port_receive_errors_total{name=~\"$switch\"}[5m]) + rate(unpoller_device_port_transmit_errors_total{name=~\"$switch\"}[5m])) > 0", legend = "{{name}} {{port_name}} errors" },
                  { q = "sum by (name, port_name) (rate(unpoller_device_port_receive_dropped_total{name=~\"$switch\"}[5m]) + rate(unpoller_device_port_transmit_dropped_total{name=~\"$switch\"}[5m])) > 0", legend = "{{name}} {{port_name}} drops" },
                ]
              },
              {
                id = "port-broadcast", w = 6, type = "ts", unit = "pps", title = "Port broadcast and multicast received"
                queries = [
                  { q = "sum by (name, port_name) (rate(unpoller_device_port_receive_broadcast_total{name=~\"$switch\"}[5m]))", legend = "{{name}} {{port_name}} broadcast" },
                  { q = "sum by (name, port_name) (rate(unpoller_device_port_receive_multicast_total{name=~\"$switch\"}[5m]))", legend = "{{name}} {{port_name}} multicast" },
                ]
              },
            ]
          },
          {
            h = 8
            panels = [
              {
                id          = "port-table", w = 12, type = "table", unit = "By/s", title = "Ports"
                description = "Link speed and current traffic of every port with a link."
                queries = [
                  { q = "max by (name, port_num, port_name) (unpoller_device_port_port_speed_bps{name=~\"$switch\"} > 0)", unit = "bit/s" },
                  { q = "sum by (name, port_num, port_name) (rate(unpoller_device_port_receive_bytes_total{name=~\"$switch\"}[5m]))" },
                  { q = "sum by (name, port_num, port_name) (rate(unpoller_device_port_transmit_bytes_total{name=~\"$switch\"}[5m]))" },
                ]
              },
            ]
          },
        ]
      },
      {
        title = "PoE"
        rows = [
          {
            h = 6
            panels = [
              {
                id      = "poe-power", w = 6, type = "ts", unit = "watt", title = "PoE power per port"
                queries = [{ q = "max by (name, port_name) (unpoller_device_port_poe_watts{name=~\"$switch\"})", legend = "{{name}} {{port_name}}" }]
              },
              {
                id = "poe-budget", w = 6, type = "ts", unit = "watt", title = "PoE draw and budget"
                queries = [
                  { q = "sum by (name) (unpoller_device_port_poe_watts{name=~\"$switch\"})", legend = "{{name}} draw" },
                  { q = "max by (name) (unpoller_device_max_power_total{name=~\"$switch\"} > 0)", legend = "{{name}} budget" },
                ]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id      = "poe-voltage", w = 6, type = "ts", unit = "volt", title = "PoE voltage", soft_min = 40
                queries = [{ q = "max by (name, port_name) (unpoller_device_port_poe_volts{name=~\"$switch\"} > 0)", legend = "{{name}} {{port_name}}" }]
              },
              {
                id      = "poe-current", w = 6, type = "ts", unit = "amp", title = "PoE current"
                queries = [{ q = "max by (name, port_name) (unpoller_device_port_poe_amperes{name=~\"$switch\"})", legend = "{{name}} {{port_name}}" }]
              },
            ]
          },
        ]
      },
      {
        title = "SFP modules"
        rows = [
          {
            h = 6
            panels = [
              {
                id          = "sfp-temperature", w = 4, type = "ts", unit = "celsius", title = "SFP temperature"
                description = "Only modules that report diagnostics; DAC cables and some optics don't."
                queries     = [{ q = "max by (name, port_name, sfp_part) (unpoller_device_port_sfp_temperature{name=~\"$switch\"} != 0)", legend = "{{name}} {{port_name}} ({{sfp_part}})" }]
              },
              {
                id      = "sfp-rx", w = 4, type = "ts", unit = "dBm", title = "SFP receive power", soft_min = -20
                queries = [{ q = "max by (name, port_name, sfp_part) (unpoller_device_port_sfp_rx_power{name=~\"$switch\"} != 0)", legend = "{{name}} {{port_name}}" }]
              },
              {
                id      = "sfp-tx", w = 4, type = "ts", unit = "dBm", title = "SFP transmit power", soft_min = -20
                queries = [{ q = "max by (name, port_name, sfp_part) (unpoller_device_port_sfp_tx_power{name=~\"$switch\"} != 0)", legend = "{{name}} {{port_name}}" }]
              },
            ]
          },
        ]
      },
    ]
  }
}
