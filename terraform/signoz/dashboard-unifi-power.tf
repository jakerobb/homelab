# UniFi power: the PoE and PDU halves of the Compose Grafana's own "Power"
# dashboard, plus the UniFi UPS Tower. The Grafana dashboard's UPS rows read
# NUT data (upsd, via Telegraf into InfluxDB) and stay there until NUT
# migrates. PoE budgets come from unpoller (unpoller_device_max_power_total)
# rather than Telegraf's unifi_device_capacity. Rendered by
# unifi-dashboards.tf.

locals {
  # Named PDU outlets only: UniFi calls unnamed ones "Outlet N" and
  # "USB Outlet N", as the Grafana dashboard's filter did.
  unifi_pdu_outlets = "unpoller_device_outlet_outlet_power{outlet_name!~\"(USB )?Outlet [0-9]+\"}"

  unifi_power = {
    title       = "UniFi: Power"
    description = "PoE draw per switch port against each switch's budget, PDU outlet draw, and the UniFi UPS Tower, from unpoller."
    variables = [
      {
        name        = "switch"
        label       = "Switch"
        description = "Switches with PoE ports."
        sql         = "SELECT DISTINCT JSONExtractString(labels, 'name') AS name FROM signoz_metrics.distributed_time_series_v4_1day WHERE metric_name = 'unpoller_device_port_poe_watts' ORDER BY name"
      },
    ]
    sections = [
      {
        title = "Now"
        rows = [
          {
            h = 3
            panels = [
              { id = "poe-total", w = 3, type = "number", unit = "watt", title = "PoE draw", queries = [{ q = "sum(unpoller_device_port_poe_watts{name=~\"$switch\"})" }] },
              { id = "pdu-total", w = 3, type = "number", unit = "watt", title = "PDU draw", queries = [{ q = "sum(unpoller_device_outlet_ac_power_consumption)" }] },
              { id = "ups-load", w = 3, type = "number", unit = "%", title = "UPS Tower load", queries = [{ q = "max(unpoller_device_ups_load_percent)" }] },
              { id = "ups-battery", w = 3, type = "number", unit = "%", title = "UPS Tower battery", queries = [{ q = "min(unpoller_device_ups_battery_level_percent)" }] },
            ]
          },
        ]
      },
      {
        title = "PoE"
        rows = [
          {
            h = 8
            panels = [
              {
                id      = "poe-now", w = 4, type = "table", unit = "watt", title = "PoE draw per port"
                queries = [{ q = "max by (name, port_name) (unpoller_device_port_poe_watts{name=~\"$switch\"} > 0)" }]
              },
              {
                id      = "poe-history", w = 8, type = "ts", unit = "watt", title = "PoE draw per port"
                queries = [{ q = "max by (name, port_name) (unpoller_device_port_poe_watts{name=~\"$switch\"})", legend = "{{name}} {{port_name}}" }]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id = "poe-budget", w = 12, type = "ts", unit = "watt", title = "PoE draw and budget per switch"
                queries = [
                  { q = "sum by (name) (unpoller_device_port_poe_watts{name=~\"$switch\"})", legend = "{{name}} draw" },
                  { q = "max by (name) (unpoller_device_max_power_total{name=~\"$switch\"} > 0)", legend = "{{name}} budget" },
                ]
              },
            ]
          },
        ]
      },
      {
        title = "PDU"
        rows = [
          {
            h = 9
            panels = [
              {
                id      = "pdu-now", w = 4, type = "table", unit = "watt", title = "Draw per outlet"
                queries = [{ q = "max by (outlet_name) (${local.unifi_pdu_outlets})" }]
              },
              {
                id      = "pdu-history", w = 8, type = "ts", unit = "watt", title = "Draw per outlet"
                queries = [{ q = "max by (outlet_name) (${local.unifi_pdu_outlets})", legend = "{{outlet_name}}" }]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id          = "pdu-budget", w = 12, type = "ts", unit = "watt", title = "PDU total draw"
                description = "Every outlet, named or not."
                thresholds = [
                  { value = 1800, color = "#FF0000", label = "PDU rating (1800 W)" },
                ]
                queries = [
                  { q = "sum(unpoller_device_outlet_ac_power_consumption)", legend = "Total" },
                ]
              },
            ]
          },
        ]
      },
      {
        title = "UPS Tower"
        rows = [
          {
            h = 6
            panels = [
              {
                id = "ups-power", w = 6, type = "ts", unit = "watt", title = "UPS Tower output"
                queries = [
                  { q = "max by (device_name) (unpoller_device_ups_power_output_watts)", legend = "Output" },
                  { q = "max by (device_name) (unpoller_device_ups_power_budget_watts)", legend = "Budget" },
                ]
              },
              {
                id = "ups-battery-ts", w = 6, type = "ts", unit = "%", title = "UPS Tower battery and load", soft_max = 100
                queries = [
                  { q = "max by (device_name) (unpoller_device_ups_battery_level_percent)", legend = "Battery" },
                  { q = "max by (device_name) (unpoller_device_ups_load_percent)", legend = "Load" },
                ]
              },
            ]
          },
        ]
      },
    ]
  }
}
