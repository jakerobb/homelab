# UniFi client DPI: port of unpoller's "Client DPI" dashboard (grafana.com
# 11310): traffic by application and category, from the gateway's deep
# packet inspection. Grafana's per-client repeated panels become top-N
# client/application panels; there's no client variable, for the reason in
# dashboard-unifi-clients.tf. Rendered by unifi-dashboards.tf.
#
# UniFi's DPI byte and packet counts dip slightly between polls, so the charts
# use clamp_min(delta(...), 0) instead of rate(): rate() takes every dip for a
# counter reset and adds the whole count back. They also skip unpoller's
# "TOTAL" series (see local.unifi_dpi_totals_sql, which the totals use).

locals {
  unifi_client_dpi = {
    title       = "UniFi: Client DPI"
    description = "Traffic by application and category, from the gateway's deep packet inspection, via unpoller."
    duration    = "24h"
    sections = [
      {
        title = "Totals"
        rows = [
          {
            h = 8
            panels = [
              {
                id      = "category-pie", w = 6, type = "pie", unit = "By", title = "Traffic by category"
                queries = [{ sql = "SELECT category, received + sent AS total FROM (${replace(local.unifi_dpi_totals_sql, "__LABEL__", "category")})", legend = "{{category}}" }]
              },
              {
                id      = "application-pie", w = 6, type = "pie", unit = "By", title = "Traffic by application (top 15)"
                queries = [{ sql = "SELECT application, received + sent AS total FROM (${replace(local.unifi_dpi_totals_sql, "__LABEL__", "application")}) LIMIT 15", legend = "{{application}}" }]
              },
            ]
          },
          {
            h = 8
            panels = [
              {
                id           = "category-table", w = 6, type = "table", unit = "By", title = "By category"
                column_units = { received = "By", sent = "By" }
                queries      = [{ sql = replace(local.unifi_dpi_totals_sql, "__LABEL__", "category") }]
              },
              {
                id           = "client-table", w = 6, type = "table", unit = "By", title = "By client"
                column_units = { received = "By", sent = "By" }
                queries      = [{ sql = replace(local.unifi_dpi_totals_sql, "__LABEL__", "name") }]
              },
            ]
          },
        ]
      },
      {
        title = "Over time"
        rows = [
          {
            h = 7
            panels = [
              {
                id      = "category-rx", w = 6, type = "ts", unit = "By/s", title = "Received by category"
                queries = [{ q = "sum by (category) (clamp_min(delta(unpoller_client_dpi_receive_bytes{name!=\"TOTAL\"}[5m]), 0) / 300)", legend = "{{category}}" }]
              },
              {
                id      = "category-tx", w = 6, type = "ts", unit = "By/s", title = "Sent by category"
                queries = [{ q = "sum by (category) (clamp_min(delta(unpoller_client_dpi_transmit_bytes{name!=\"TOTAL\"}[5m]), 0) / 300)", legend = "{{category}}" }]
              },
            ]
          },
          {
            h = 7
            panels = [
              {
                id = "category-packets", w = 6, type = "ts", unit = "pps", title = "Packets by category"
                queries = [
                  { q = "sum by (category) (clamp_min(delta(unpoller_client_dpi_receive_packets{name!=\"TOTAL\"}[5m]), 0) / 300 + clamp_min(delta(unpoller_client_dpi_transmit_packets{name!=\"TOTAL\"}[5m]), 0) / 300)", legend = "{{category}}" },
                ]
              },
              {
                id = "top-clients", w = 6, type = "ts", unit = "By/s", title = "Top 10 clients"
                queries = [
                  { q = "topk(10, sum by (name) (clamp_min(delta(unpoller_client_dpi_receive_bytes{name!=\"TOTAL\"}[5m]), 0) / 300 + clamp_min(delta(unpoller_client_dpi_transmit_bytes{name!=\"TOTAL\"}[5m]), 0) / 300))", legend = "{{name}}" },
                ]
              },
            ]
          },
          {
            h = 8
            panels = [
              {
                id      = "client-app-rx", w = 6, type = "ts", unit = "By/s", title = "Top 15 client applications, received"
                queries = [{ q = "topk(15, sum by (name, application) (clamp_min(delta(unpoller_client_dpi_receive_bytes{name!=\"TOTAL\"}[5m]), 0) / 300))", legend = "{{name}}: {{application}}" }]
              },
              {
                id      = "client-app-tx", w = 6, type = "ts", unit = "By/s", title = "Top 15 client applications, sent"
                queries = [{ q = "topk(15, sum by (name, application) (clamp_min(delta(unpoller_client_dpi_transmit_bytes{name!=\"TOTAL\"}[5m]), 0) / 300))", legend = "{{name}}: {{application}}" }]
              },
            ]
          },
        ]
      },
    ]
  }
}
