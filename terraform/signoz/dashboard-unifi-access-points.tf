# UniFi access points: port of unpoller's "UAP Insights" dashboard
# (grafana.com 11314). Grafana's separate 2.4/5 GHz panels become one line
# per AP and band here, which also covers the 6 GHz radios. Bands show as
# unpoller's radio codes: ng = 2.4 GHz, na = 5 GHz, 6e = 6 GHz. Rendered by
# unifi-dashboards.tf.

locals {
  unifi_access_points = {
    title       = "UniFi: Access Points"
    description = "Access point health, clients, signal, channel utilization and radio traffic, from unpoller."
    variables = [
      {
        name        = "ap"
        label       = "Access point"
        description = "UniFi access points."
        sql         = "SELECT DISTINCT JSONExtractString(labels, 'name') AS name FROM signoz_metrics.distributed_time_series_v4_1day WHERE metric_name = 'unpoller_device_info' AND JSONExtractString(labels, 'type') = 'uap' ORDER BY name"
      },
    ]
    sections = [
      {
        title = "Access points"
        rows = [
          {
            h = 8
            panels = [
              {
                id      = "clients-ap", w = 3, type = "pie", unit = "1", title = "Clients per AP"
                queries = [{ metric = "unpoller_client_uptime_seconds", space = "count", group_by = ["ap_name"], filter = "wired = 'false' AND ap_name IN $ap", legend = "{{ap_name}}" }]
              },
              {
                id      = "clients-channel", w = 3, type = "pie", unit = "1", title = "Clients per channel"
                queries = [{ metric = "unpoller_client_uptime_seconds", space = "count", group_by = ["channel"], filter = "wired = 'false' AND ap_name IN $ap", legend = "Channel {{channel}}" }]
              },
              {
                id      = "clients-protocol", w = 3, type = "pie", unit = "1", title = "Clients per Wi-Fi standard"
                queries = [{ metric = "unpoller_client_uptime_seconds", space = "count", group_by = ["radio_proto"], filter = "wired = 'false' AND ap_name IN $ap", legend = "{{radio_proto}}" }]
              },
              {
                id      = "clients-oui", w = 3, type = "pie", unit = "1", title = "Clients per vendor"
                queries = [{ metric = "unpoller_client_uptime_seconds", space = "count", group_by = ["oui"], filter = "wired = 'false' AND ap_name IN $ap", legend = "{{oui}}" }]
              },
            ]
          },
          {
            h = 5
            panels = [
              {
                id           = "details", w = 12, type = "table", unit = "s", title = "Details"
                column_units = { uptime = "s" }
                queries      = [{ sql = replace(local.unifi_device_details_sql, "__VAR__", "ap") }]
              },
            ]
          },
          {
            h = 5
            panels = [
              {
                id          = "networks", w = 12, type = "table", unit = "dBm", title = "Networks"
                description = "Each SSID on each radio, with its clients' average signal."
                queries     = [{ metric = "unpoller_device_vap_average_client_signal", group_by = ["name", "essid", "radio", "bssid"], filter = "name IN $ap", legend = "Average client signal" }]
              },
            ]
          },
        ]
      },
      {
        title = "Clients"
        rows = [
          {
            h = 6
            panels = [
              {
                id      = "stations", w = 6, type = "ts", unit = "1", title = "Clients per radio"
                queries = [{ q = "sum by (name, radio) (unpoller_device_radio_stations{name=~\"$ap\"})", legend = "{{name}} {{radio}}" }]
              },
              {
                id = "vendor-traffic", w = 6, type = "ts", unit = "By/s", title = "Wireless traffic by vendor (top 10)"
                queries = [
                  { q = "topk(10, sum by (oui) (unpoller_client_receive_rate_bytes{wired=\"false\", ap_name=~\"$ap\"} + unpoller_client_transmit_rate_bytes{wired=\"false\", ap_name=~\"$ap\"}))", legend = "{{oui}}" },
                ]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id      = "vap-signal", w = 6, type = "ts", unit = "dBm", title = "Average client signal", soft_min = -90
                queries = [{ q = "max by (name, radio) (unpoller_device_vap_average_client_signal{name=~\"$ap\"} < 0)", legend = "{{name}} {{radio}}" }]
              },
              {
                id      = "satisfaction", w = 6, type = "ts", unit = "percentunit", title = "Average client satisfaction", soft_max = 1
                queries = [{ q = "avg by (ap_name) (unpoller_client_satisfaction_ratio{ap_name=~\"$ap\"})", legend = "{{ap_name}}" }]
              },
            ]
          },
        ]
      },
      {
        title = "Radios"
        rows = [
          {
            h = 6
            panels = [
              {
                id          = "channel-utilization", w = 6, type = "ts", unit = "percentunit", title = "Channel utilization", soft_max = 1
                description = "How busy the channel is, including other networks' traffic."
                queries     = [{ q = "max by (name, radio) (unpoller_device_radio_channel_utilization_total_ratio{name=~\"$ap\"})", legend = "{{name}} {{radio}}" }]
              },
              {
                id          = "ccq", w = 6, type = "ts", unit = "percentunit", title = "Client connection quality (CCQ)", soft_max = 1
                description = "Average over each AP's clients. The APs' own per-radio CCQ reads 0 on this hardware."
                queries     = [{ q = "avg by (ap_name) (unpoller_client_ccq_ratio{ap_name=~\"$ap\"})", legend = "{{ap_name}}" }]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id = "radio-traffic", w = 6, type = "ts", unit = "By/s", title = "Traffic per radio"
                queries = [
                  { q = "sum by (name, radio) (rate(unpoller_device_vap_transmit_bytes_total{name=~\"$ap\"}[5m]))", legend = "{{name}} {{radio}} Tx" },
                  { q = "sum by (name, radio) (rate(unpoller_device_vap_receive_bytes_total{name=~\"$ap\"}[5m]))", legend = "{{name}} {{radio}} Rx" },
                ]
              },
              {
                id = "radio-packets", w = 6, type = "ts", unit = "pps", title = "Packets per radio"
                queries = [
                  { q = "sum by (name, radio) (rate(unpoller_device_vap_transmit_packets_total{name=~\"$ap\"}[5m]))", legend = "{{name}} {{radio}} Tx" },
                  { q = "sum by (name, radio) (rate(unpoller_device_vap_receive_packets_total{name=~\"$ap\"}[5m]))", legend = "{{name}} {{radio}} Rx" },
                ]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id          = "radio-errors", w = 6, type = "ts", unit = "pps", title = "Drops, errors and retries"
                description = "Summed over each AP's radios. Only series that had any in the last 5 minutes."
                queries = [
                  { q = "sum by (name) (rate(unpoller_device_vap_receive_dropped_total{name=~\"$ap\"}[5m]) + rate(unpoller_device_vap_transmit_dropped_total{name=~\"$ap\"}[5m])) > 0", legend = "{{name}} drops" },
                  { q = "sum by (name) (rate(unpoller_device_vap_receive_errors_total{name=~\"$ap\"}[5m]) + rate(unpoller_device_vap_transmit_errors_total{name=~\"$ap\"}[5m])) > 0", legend = "{{name}} errors" },
                  { q = "sum by (name) (rate(unpoller_device_vap_transmit_retries_total{name=~\"$ap\"}[5m])) > 0", legend = "{{name}} Tx retries" },
                ]
              },
              {
                id      = "tx-power", w = 6, type = "ts", unit = "dBm", title = "Radio transmit power"
                queries = [{ q = "max by (name, radio) (unpoller_device_radio_transmit_power{name=~\"$ap\"})", legend = "{{name}} {{radio}}" }]
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
                id      = "cpu", w = 4, type = "ts", unit = "percentunit", title = "CPU", soft_max = 1
                queries = [{ q = "max by (name) (unpoller_device_cpu_utilization_ratio{name=~\"$ap\"})", legend = "{{name}}" }]
              },
              {
                id      = "memory", w = 4, type = "ts", unit = "percentunit", title = "Memory", soft_max = 1
                queries = [{ q = "max by (name) (unpoller_device_memory_utilization_ratio{name=~\"$ap\"})", legend = "{{name}}" }]
              },
              {
                id      = "load", w = 4, type = "ts", unit = "1", title = "Load average (5m)"
                queries = [{ q = "max by (name) (unpoller_device_load_average_5{name=~\"$ap\"})", legend = "{{name}}" }]
              },
            ]
          },
        ]
      },
    ]
  }
}
