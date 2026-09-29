# UniFi clients: port of unpoller's "Client Insights" dashboard (grafana.com
# 11315). Filters by AP and switch only, not by client: client names can
# contain regex metacharacters, which break multi-select variables (see
# unifi-dashboards.tf). Bandwidth panels show the top 10 instead. Grafana's
# Echo/Fire TV and camera panels matched the dashboard author's device names,
# so they're left out. Rendered by unifi-dashboards.tf.

locals {
  unifi_clients = {
    title       = "UniFi: Clients"
    description = "Wireless and wired clients: who's connected where, bandwidth, and Wi-Fi signal and quality, from unpoller."
    variables = [
      {
        name        = "ap"
        label       = "Access point"
        description = "Filters wireless clients by the AP they're connected to."
        sql         = "SELECT DISTINCT JSONExtractString(labels, 'ap_name') AS ap FROM signoz_metrics.distributed_time_series_v4_1day WHERE metric_name = 'unpoller_client_uptime_seconds' AND JSONExtractString(labels, 'wired') = 'false' ORDER BY ap"
      },
      {
        name        = "switch"
        label       = "Switch"
        description = "Filters wired clients by the switch they're plugged into."
        sql         = "SELECT DISTINCT JSONExtractString(labels, 'sw_name') AS sw FROM signoz_metrics.distributed_time_series_v4_1day WHERE metric_name = 'unpoller_client_uptime_seconds' AND JSONExtractString(labels, 'wired') = 'true' ORDER BY sw"
      },
    ]
    sections = [
      {
        title = "Clients"
        rows = [
          {
            h = 3
            panels = [
              { id = "wireless", w = 3, type = "number", unit = "1", title = "Wireless clients", queries = [{ q = "count(unpoller_client_uptime_seconds{wired=\"false\", ap_name=~\"$ap\"})" }] },
              { id = "wired", w = 3, type = "number", unit = "1", title = "Wired clients", queries = [{ q = "count(unpoller_client_uptime_seconds{wired=\"true\", sw_name=~\"$switch\"})" }] },
              { id = "satisfaction", w = 3, type = "number", unit = "percentunit", title = "Average Wi-Fi satisfaction", queries = [{ q = "avg(unpoller_client_satisfaction_ratio{ap_name=~\"$ap\"})" }] },
              { id = "signal", w = 3, type = "number", unit = "dBm", title = "Average Wi-Fi signal", queries = [{ q = "avg(unpoller_client_radio_signal_db{ap_name=~\"$ap\"})" }] },
            ]
          },
          {
            h = 8
            panels = [
              {
                id      = "per-network", w = 3, type = "pie", unit = "1", title = "Clients per network"
                queries = [{ metric = "unpoller_client_uptime_seconds", space = "count", group_by = ["network"], filter = "(wired = 'false' AND ap_name IN $ap) OR (wired = 'true' AND sw_name IN $switch)", legend = "{{network}}" }]
              },
              {
                id      = "per-channel", w = 3, type = "pie", unit = "1", title = "Wireless clients per channel"
                queries = [{ metric = "unpoller_client_uptime_seconds", space = "count", group_by = ["channel"], filter = "wired = 'false' AND ap_name IN $ap", legend = "Channel {{channel}}" }]
              },
              {
                id      = "per-protocol", w = 3, type = "pie", unit = "1", title = "Wireless clients per Wi-Fi standard"
                queries = [{ metric = "unpoller_client_uptime_seconds", space = "count", group_by = ["radio_proto"], filter = "wired = 'false' AND ap_name IN $ap", legend = "{{radio_proto}}" }]
              },
              {
                id      = "per-vendor", w = 3, type = "pie", unit = "1", title = "Clients per vendor"
                queries = [{ metric = "unpoller_client_uptime_seconds", space = "count", group_by = ["oui"], filter = "(wired = 'false' AND ap_name IN $ap) OR (wired = 'true' AND sw_name IN $switch)", legend = "{{oui}}" }]
              },
            ]
          },
          {
            h = 8
            panels = [
              {
                id          = "wireless-table", w = 12, type = "table", unit = "s", title = "Wireless clients"
                description = "Channels and Wi-Fi standards are in the pie charts above."
                queries = [
                  { metric = "unpoller_client_uptime_seconds", group_by = ["name", "ip", "mac", "ap_name", "network", "oui"], filter = "wired = 'false' AND ap_name IN $ap", legend = "Uptime" },
                  { metric = "unpoller_client_receive_rate_bytes", group_by = ["name", "ip", "mac", "ap_name", "network", "oui"], filter = "wired = 'false' AND ap_name IN $ap", unit = "By/s", legend = "Receive" },
                  { metric = "unpoller_client_transmit_rate_bytes", group_by = ["name", "ip", "mac", "ap_name", "network", "oui"], filter = "wired = 'false' AND ap_name IN $ap", unit = "By/s", legend = "Transmit" },
                ]
              },
            ]
          },
          {
            h = 8
            panels = [
              {
                id = "wired-table", w = 12, type = "table", unit = "s", title = "Wired clients"
                queries = [
                  { metric = "unpoller_client_uptime_seconds", group_by = ["name", "ip", "mac", "sw_name", "sw_port", "network", "oui"], filter = "wired = 'true' AND sw_name IN $switch", legend = "Uptime" },
                  { metric = "unpoller_client_receive_rate_bytes", group_by = ["name", "ip", "mac", "sw_name", "sw_port", "network", "oui"], filter = "wired = 'true' AND sw_name IN $switch", unit = "By/s", legend = "Receive" },
                  { metric = "unpoller_client_transmit_rate_bytes", group_by = ["name", "ip", "mac", "sw_name", "sw_port", "network", "oui"], filter = "wired = 'true' AND sw_name IN $switch", unit = "By/s", legend = "Transmit" },
                ]
              },
            ]
          },
        ]
      },
      {
        title = "Bandwidth"
        rows = [
          {
            h = 8
            panels = [
              {
                id = "wireless-bandwidth", w = 6, type = "ts", unit = "By/s", title = "Wireless clients (top 10)"
                queries = [
                  { q = "topk(10, sum by (name) (unpoller_client_receive_rate_bytes{wired=\"false\", ap_name=~\"$ap\"}))", legend = "{{name}} Rx" },
                  { q = "topk(10, sum by (name) (unpoller_client_transmit_rate_bytes{wired=\"false\", ap_name=~\"$ap\"}))", legend = "{{name}} Tx" },
                ]
              },
              {
                id = "wired-bandwidth", w = 6, type = "ts", unit = "By/s", title = "Wired clients (top 10)"
                queries = [
                  { q = "topk(10, sum by (name) (unpoller_client_receive_rate_bytes{wired=\"true\", sw_name=~\"$switch\"}))", legend = "{{name}} Rx" },
                  { q = "topk(10, sum by (name) (unpoller_client_transmit_rate_bytes{wired=\"true\", sw_name=~\"$switch\"}))", legend = "{{name}} Tx" },
                ]
              },
            ]
          },
        ]
      },
      {
        title = "Wi-Fi quality"
        rows = [
          {
            h = 6
            panels = [
              {
                id      = "signal-db", w = 4, type = "ts", unit = "dBm", title = "Signal", soft_min = -90
                queries = [{ q = "max by (name) (unpoller_client_radio_signal_db{ap_name=~\"$ap\"})", legend = "{{name}}" }]
              },
              {
                id      = "rssi", w = 4, type = "ts", unit = "dB", title = "RSSI"
                queries = [{ q = "max by (name) (unpoller_client_rssi_db{ap_name=~\"$ap\"})", legend = "{{name}}" }]
              },
              {
                id      = "noise", w = 4, type = "ts", unit = "dBm", title = "Noise", soft_min = -110
                queries = [{ q = "max by (name) (unpoller_client_noise_db{ap_name=~\"$ap\"})", legend = "{{name}}" }]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id      = "tx-rate", w = 6, type = "ts", unit = "bit/s", title = "Link rate: AP to client"
                queries = [{ q = "max by (name) (unpoller_client_radio_transmit_rate_bps{ap_name=~\"$ap\"})", legend = "{{name}}" }]
              },
              {
                id      = "rx-rate", w = 6, type = "ts", unit = "bit/s", title = "Link rate: client to AP"
                queries = [{ q = "max by (name) (unpoller_client_radio_receive_rate_bps{ap_name=~\"$ap\"})", legend = "{{name}}" }]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id      = "satisfaction-ts", w = 4, type = "ts", unit = "percentunit", title = "Satisfaction", soft_max = 1
                queries = [{ q = "max by (name) (unpoller_client_satisfaction_ratio{ap_name=~\"$ap\"})", legend = "{{name}}" }]
              },
              {
                id      = "ccq", w = 4, type = "ts", unit = "percentunit", title = "Connection quality (CCQ)", soft_max = 1
                queries = [{ q = "max by (name) (unpoller_client_ccq_ratio{ap_name=~\"$ap\"})", legend = "{{name}}" }]
              },
              {
                id          = "roams", w = 4, type = "ts", unit = "1", title = "Roams per hour"
                description = "Only clients that roamed."
                queries     = [{ q = "sum by (name) (increase(unpoller_client_roam_count_total{ap_name=~\"$ap\"}[1h])) > 0", legend = "{{name}}" }]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id          = "retries", w = 6, type = "ts", unit = "pps", title = "Transmit retries"
                description = "Only clients with retries in the last 5 minutes."
                queries     = [{ q = "sum by (name) (rate(unpoller_client_transmit_retries_total{ap_name=~\"$ap\"}[5m])) > 0", legend = "{{name}}" }]
              },
              {
                id          = "anomalies", w = 6, type = "ts", unit = "1", title = "Anomalies"
                description = "Connectivity problems UniFi flagged, per client."
                queries     = [{ q = "max by (name) (unpoller_client_anomalies{ap_name=~\"$ap\"}) > 0", legend = "{{name}}" }]
              },
            ]
          },
        ]
      },
    ]
  }
}
