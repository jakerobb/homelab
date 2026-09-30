# Power: the SigNoz version of the Compose Grafana's own "Power" dashboard.
# PoE and the PDU come from unpoller; PoE budgets use
# unpoller_device_max_power_total rather than Telegraf's
# unifi_device_capacity. Both UPSes (the rack CyberPower and the UniFi UPS
# Tower in the office) come from nut-relay
# (manifests/nut-exporter/), which replaced the Compose nut-influx-relay and
# webnut. unpoller reports
# the Tower too, but NUT gives both UPSes the same metrics. Rendered by
# unifi-dashboards.tf, like the UniFi dashboards it started as.

locals {
  # Named PDU outlets only: UniFi calls unnamed ones "Outlet N" and
  # "USB Outlet N", as the Grafana dashboard's filter did.
  unifi_pdu_outlets = "unpoller_device_outlet_outlet_power{outlet_name!~\"(USB )?Outlet [0-9]+\"}"

  # One section per UPS, from nut-relay. Its metrics are
  # named nut_<NUT variable, dots as underscores>, and ups.status is one 0/1
  # series per flag. `ups` is each UPS's label in the exporter's config
  # (manifests/nut-exporter/config.yaml); rating is the UPS's
  # ups.realpower.nominal.
  nut_upses = [
    { ups = "rack", title = "Rack UPS", rating = 1000 },
    { ups = "office", title = "Office UPS (UniFi UPS Tower)", rating = 600 },
  ]

  unifi_power = {
    title       = "Power"
    description = "PoE draw per switch port against each switch's budget, PDU outlet draw, and both UPSes (NUT)."
    variables = [
      {
        name        = "switch"
        label       = "Switch"
        description = "Switches with PoE ports."
        sql         = "SELECT DISTINCT JSONExtractString(labels, 'name') AS name FROM signoz_metrics.distributed_time_series_v4_1day WHERE metric_name = 'unpoller_device_port_poe_watts' ORDER BY name"
      },
    ]
    sections = concat([
      {
        title = "Now"
        rows = [
          {
            h = 3
            panels = [
              { id = "poe-total", w = 3, type = "number", unit = "watt", title = "PoE draw", queries = [{ q = "sum(unpoller_device_port_poe_watts{name=~\"$switch\"})" }] },
              { id = "pdu-total", w = 3, type = "number", unit = "watt", title = "PDU draw", queries = [{ q = "sum(unpoller_device_outlet_ac_power_consumption)" }] },
              { id = "ups-rack-battery", w = 3, type = "number", unit = "%", title = "Rack UPS battery", queries = [{ q = "max(nut_battery_charge{ups=\"rack\"})" }] },
              { id = "ups-office-battery", w = 3, type = "number", unit = "%", title = "Office UPS battery", queries = [{ q = "max(nut_battery_charge{ups=\"office\"})" }] },
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
                queries = [{ metric = "unpoller_device_port_poe_watts", group_by = ["name", "port_name"], filter = "name IN $switch", legend = "Draw" }]
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
                queries = [{ metric = "unpoller_device_outlet_outlet_power", group_by = ["outlet_name"], filter = "outlet_name NOT REGEXP '^(USB )?Outlet [0-9]+$'", legend = "Draw" }]
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
      ], [
      for u in local.nut_upses : {
        title = u.title
        rows = [
          {
            h = 3
            panels = [
              { id = "${u.ups}-draw", w = 2, type = "number", unit = "watt", title = "Draw", queries = [{ q = "max(nut_ups_realpower{ups=\"${u.ups}\"})" }] },
              { id = "${u.ups}-load", w = 2, type = "number", unit = "%", title = "Load", queries = [{ q = "max(nut_ups_load{ups=\"${u.ups}\"})" }] },
              { id = "${u.ups}-battery", w = 2, type = "number", unit = "%", title = "Battery", queries = [{ q = "max(nut_battery_charge{ups=\"${u.ups}\"})" }] },
              { id = "${u.ups}-runtime", w = 2, type = "number", unit = "s", title = "Runtime", description = "The UPS's own estimate at the current load.", queries = [{ q = "max(nut_battery_runtime{ups=\"${u.ups}\"})" }] },
              { id = "${u.ups}-on-battery", w = 2, type = "number", unit = "1", title = "On battery", description = "1 while mains power is out (the OB flag).", queries = [{ q = "max(nut_ups_status{ups=\"${u.ups}\", flag=\"OB\"})" }] },
              {
                id          = "${u.ups}-energy", w = 2, type = "number", unit = "kwatth", decimals = "2", title = "Energy, last 24h"
                description = "Average draw over the last 24 hours times 24."
                queries     = [{ q = "max(avg_over_time(nut_ups_realpower{ups=\"${u.ups}\"}[24h])) * 24 / 1000" }]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id = "${u.ups}-power", w = 6, type = "ts", unit = "watt", title = "${u.title} draw"
                thresholds = [
                  { value = u.rating * 0.8, color = "#FFA500", label = "80% of rating (alert)" },
                  { value = u.rating, color = "#FF0000", label = "Rating (${u.rating} W)" },
                ]
                queries = [
                  { q = "max(nut_ups_realpower{ups=\"${u.ups}\"})", legend = "Real power" },
                ]
              },
              {
                id = "${u.ups}-battery-ts", w = 6, type = "ts", unit = "%", title = "${u.title} battery and load", soft_max = 100
                queries = [
                  { q = "max(nut_battery_charge{ups=\"${u.ups}\"})", legend = "Battery" },
                  { q = "max(nut_ups_load{ups=\"${u.ups}\"})", legend = "Load" },
                ]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id          = "${u.ups}-voltage", w = 6, type = "ts", unit = "volt", title = "${u.title} voltage", soft_min = 85, soft_max = 150
                description = "The UPS switches to battery when input leaves the transfer range."
                queries = [
                  { q = "max(nut_input_voltage{ups=\"${u.ups}\"})", legend = "Input" },
                  { q = "max(nut_output_voltage{ups=\"${u.ups}\"})", legend = "Output" },
                  { q = "max(nut_input_transfer_low{ups=\"${u.ups}\"})", legend = "Transfer low" },
                  { q = "max(nut_input_transfer_high{ups=\"${u.ups}\"})", legend = "Transfer high" },
                ]
              },
              {
                id          = "${u.ups}-status", w = 6, type = "ts", unit = "1", title = "${u.title} status", soft_max = 1
                description = "OL: on mains. OB: on battery. LB: low battery. CHRG: charging."
                queries = [
                  { q = "max by (flag) (nut_ups_status{ups=\"${u.ups}\", flag=~\"OL|OB|LB|CHRG\"})", legend = "{{flag}}" },
                ]
              },
            ]
          },
        ]
      }
    ])
  }
}
