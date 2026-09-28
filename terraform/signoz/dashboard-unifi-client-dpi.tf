# UniFi client DPI: port of unpoller's "Client DPI" dashboard (grafana.com
# 11310): traffic by application and category, from the gateway's deep
# packet inspection. Grafana's per-client repeated panels become top-N
# client/application panels; there's no client variable, for the reason in
# dashboard-unifi-clients.tf. Totals are over the last 24 hours, a fixed
# window, since SigNoz's PromQL has no $__range. Rendered by
# unifi-dashboards.tf.

locals {
  unifi_client_dpi = {
    title       = "UniFi: Client DPI"
    description = "Traffic by application and category, from the gateway's deep packet inspection, via unpoller."
    duration    = "24h"
    sections = [
      {
        title = "Last 24 hours"
        rows = [
          {
            h = 8
            panels = [
              {
                id      = "category-pie", w = 6, type = "pie", unit = "By", title = "Traffic by category"
                queries = [{ q = "sum by (category) (increase(unpoller_client_dpi_receive_bytes[24h])) + sum by (category) (increase(unpoller_client_dpi_transmit_bytes[24h]))", legend = "{{category}}" }]
              },
              {
                id      = "application-pie", w = 6, type = "pie", unit = "By", title = "Traffic by application (top 15)"
                queries = [{ q = "topk(15, sum by (application) (increase(unpoller_client_dpi_receive_bytes[24h])) + sum by (application) (increase(unpoller_client_dpi_transmit_bytes[24h])))", legend = "{{application}}" }]
              },
            ]
          },
          {
            h = 8
            panels = [
              {
                id          = "category-table", w = 6, type = "table", unit = "By", title = "By category"
                description = "Value columns: bytes received, bytes sent."
                queries = [
                  { q = "sum by (category) (increase(unpoller_client_dpi_receive_bytes[24h]))" },
                  { q = "sum by (category) (increase(unpoller_client_dpi_transmit_bytes[24h]))" },
                ]
              },
              {
                id          = "client-table", w = 6, type = "table", unit = "By", title = "By client"
                description = "Value columns: bytes received, bytes sent."
                queries = [
                  { q = "sum by (name) (increase(unpoller_client_dpi_receive_bytes[24h]))" },
                  { q = "sum by (name) (increase(unpoller_client_dpi_transmit_bytes[24h]))" },
                ]
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
                queries = [{ q = "sum by (category) (rate(unpoller_client_dpi_receive_bytes[5m]))", legend = "{{category}}" }]
              },
              {
                id      = "category-tx", w = 6, type = "ts", unit = "By/s", title = "Sent by category"
                queries = [{ q = "sum by (category) (rate(unpoller_client_dpi_transmit_bytes[5m]))", legend = "{{category}}" }]
              },
            ]
          },
          {
            h = 7
            panels = [
              {
                id = "category-packets", w = 6, type = "ts", unit = "pps", title = "Packets by category"
                queries = [
                  { q = "sum by (category) (rate(unpoller_client_dpi_receive_packets[5m]) + rate(unpoller_client_dpi_transmit_packets[5m]))", legend = "{{category}}" },
                ]
              },
              {
                id = "top-clients", w = 6, type = "ts", unit = "By/s", title = "Top 10 clients"
                queries = [
                  { q = "topk(10, sum by (name) (rate(unpoller_client_dpi_receive_bytes[5m]) + rate(unpoller_client_dpi_transmit_bytes[5m])))", legend = "{{name}}" },
                ]
              },
            ]
          },
          {
            h = 8
            panels = [
              {
                id      = "client-app-rx", w = 6, type = "ts", unit = "By/s", title = "Top 15 client applications, received"
                queries = [{ q = "topk(15, sum by (name, application) (rate(unpoller_client_dpi_receive_bytes[5m])))", legend = "{{name}}: {{application}}" }]
              },
              {
                id      = "client-app-tx", w = 6, type = "ts", unit = "By/s", title = "Top 15 client applications, sent"
                queries = [{ q = "topk(15, sum by (name, application) (rate(unpoller_client_dpi_transmit_bytes[5m])))", legend = "{{name}}: {{application}}" }]
              },
            ]
          },
        ]
      },
    ]
  }
}
