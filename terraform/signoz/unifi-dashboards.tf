# UniFi dashboards: SigNoz ports of unpoller's stock Grafana dashboards
# (grafana.com 11310-11315, their Prometheus editions) plus the UniFi half of
# the Compose Grafana's own "Power" dashboard. The data is unpoller's
# Prometheus output (manifests/unpoller/), federated into SigNoz from
# kube-prometheus-stack (argocd/apps/signoz/application.yaml).
#
# Every panel is PromQL rather than the query builder. Federation hands SigNoz
# every series as an untyped gauge, and the builder only offers rate/increase
# on counters. SigNoz's PromQL engine reads the raw samples, so rate() works
# on them as usual. Federation delivers a sample a minute, so rates use a 5m
# window (at least a few samples) and panels step at 60s.
#
# Each dashboard-unifi-*.tf file (and dashboard-power.tf) is one dashboard as
# plain data, rendered by the single resource below:
#
#   sections  collapsible groups, each a 12-column grid of rows
#   rows      { h = height, panels = [...] }; panel widths in a row add up to 12
#   panel     { id, title, description?, type, unit, queries, soft_min?, soft_max?,
#               thresholds?, stacked? }
#             type: ts (time series), number, table, pie or bar
#   query     { q = PromQL, legend? }. Several queries share one panel.
#   variables [{ name, label, description, sql }]: a multi-select list filled
#             by a ClickHouse query, used in PromQL as =~"$name". Selecting
#             several values (or All) substitutes a|b|c, so only use them for
#             label values without regex metacharacters, like device names.
#
# Grafana edits: same round trip as the Temperatures dashboard (README.md),
# except the exported JSON maps to these files' data, not to the resource.

locals {
  unifi_dashboards = {
    unifi-network       = local.unifi_network
    unifi-gateway       = local.unifi_gateway
    unifi-switches      = local.unifi_switches
    unifi-access-points = local.unifi_access_points
    unifi-clients       = local.unifi_clients
    unifi-client-dpi    = local.unifi_client_dpi
    unifi-power         = local.unifi_power
  }

  # Grid positions, from the order of panels in each row and of rows in each
  # section.
  unifi_layouts = {
    for dk, d in local.unifi_dashboards : dk => [
      for sec in d.sections : {
        title = sec.title
        open  = try(sec.open, true)
        items = flatten([
          for ri, row in sec.rows : [
            for pi, p in row.panels : {
              id = p.id
              x  = pi == 0 ? 0 : sum([for q in slice(row.panels, 0, pi) : q.w])
              y  = ri == 0 ? 0 : sum([for r in slice(sec.rows, 0, ri) : r.h])
              w  = p.w
              h  = row.h
            }
          ]
        ])
      }
    ]
  }

  unifi_panels = {
    for dk, d in local.unifi_dashboards : dk => merge(flatten([
      for sec in d.sections : [for row in sec.rows : [for p in row.panels : { (p.id) = p }]]
    ])...)
  }
}

resource "signoz_dashboard" "unifi" {
  for_each = local.unifi_dashboards

  schema_version = "v6"
  name           = each.key
  tags = [
    { key = "tag", value = "unifi" },
    { key = "tag", value = "network" },
  ]

  spec = {
    display = {
      name        = each.value.title
      description = each.value.description
    }
    duration         = try(each.value.duration, "6h")
    refresh_interval = "1m"
    links            = []

    variables = [
      for v in try(each.value.variables, []) : {
        list_variable = {
          kind = "ListVariable"
          spec = {
            name = v.name
            display = {
              name        = v.label
              description = v.description
            }
            allow_all_value = true
            allow_multiple  = true
            sort            = "alphabetical-asc"
            plugin = {
              query_variable = {
                kind = "signoz/QueryVariable"
                spec = {
                  query_value = v.sql
                }
              }
            }
          }
        }
      }
    ]

    panels = {
      for id, p in local.unifi_panels[each.key] : id => {
        kind = "Panel"
        spec = {
          display = {
            name        = p.title
            description = try(p.description, "")
          }
          links = []
          plugin = {
            time_series_panel = p.type != "ts" ? null : {
              kind = "signoz/TimeSeriesPanel"
              spec = {
                visualization = {
                  time_preference = "global_time"
                  fill_spans      = false
                }
                formatting = {
                  unit              = p.unit
                  decimal_precision = "2"
                }
                chart_appearance = {
                  line_interpolation = "linear"
                  show_points        = false
                  line_style         = "solid"
                  fill_mode          = "none"
                }
                axes = {
                  soft_min     = try(p.soft_min, 0)
                  soft_max     = try(p.soft_max, null)
                  is_log_scale = false
                }
                legend = {
                  position = "bottom"
                  mode     = "list"
                }
                thresholds = [
                  for t in try(p.thresholds, []) : {
                    value = t.value
                    color = t.color
                    label = t.label
                    unit  = p.unit
                  }
                ]
              }
            }
            bar_chart_panel = p.type != "bar" ? null : {
              kind = "signoz/BarChartPanel"
              spec = {
                visualization = {
                  time_preference   = "global_time"
                  fill_spans        = false
                  stacked_bar_chart = try(p.stacked, true)
                }
                formatting = {
                  unit              = p.unit
                  decimal_precision = "2"
                }
                axes = {
                  soft_min     = 0
                  soft_max     = try(p.soft_max, null)
                  is_log_scale = false
                }
                legend = {
                  position = "bottom"
                  mode     = "list"
                }
                thresholds = [
                  for t in try(p.thresholds, []) : {
                    value = t.value
                    color = t.color
                    label = t.label
                    unit  = p.unit
                  }
                ]
              }
            }
            number_panel = p.type != "number" ? null : {
              kind = "signoz/NumberPanel"
              spec = {
                visualization = {
                  time_preference = "global_time"
                }
                formatting = {
                  unit              = p.unit
                  decimal_precision = try(p.decimals, "0")
                }
              }
            }
            table_panel = p.type != "table" ? null : {
              kind = "signoz/TablePanel"
              spec = {
                visualization = {
                  time_preference = "global_time"
                }
                # Value columns are named after their query (A, B, ...);
                # q.unit overrides the panel's unit for one column.
                formatting = {
                  decimal_precision = "2"
                  column_units = {
                    for i, q in p.queries : substr("ABCDEFGHIJKLMNOP", i, 1) => try(q.unit, p.unit)
                  }
                }
              }
            }
            pie_chart_panel = p.type != "pie" ? null : {
              kind = "signoz/PieChartPanel"
              spec = {
                visualization = {
                  time_preference = "global_time"
                }
                formatting = {
                  unit              = p.unit
                  decimal_precision = "0"
                }
                legend = {
                  position = "right"
                  mode     = "list"
                }
              }
            }
          }
          queries = [
            {
              # Charts get a series per step; stats, tables and pies one
              # value per group, from an instant query at the end of the range.
              kind = contains(["ts", "bar"], p.type) ? "time_series" : "scalar"
              spec = {
                plugin = {
                  composite_query = {
                    kind = "signoz/CompositeQuery"
                    spec = {
                      queries = [
                        for i, q in p.queries : {
                          promql = {
                            type = "promql"
                            spec = {
                              name     = substr("ABCDEFGHIJKLMNOP", i, 1)
                              query    = q.q
                              legend   = try(q.legend, "")
                              step     = "60"
                              disabled = false
                              stats    = false
                            }
                          }
                        }
                      ]
                    }
                  }
                }
              }
            },
          ]
        }
      }
    }

    layouts = [
      for sec in local.unifi_layouts[each.key] : {
        grid = {
          kind = "Grid"
          spec = {
            display = {
              title    = sec.title
              collapse = { open = sec.open }
            }
            items = [
              for i in sec.items : {
                x       = i.x
                y       = i.y
                width   = i.w
                height  = i.h
                content = { ref = "#/spec/panels/${i.id}" }
              }
            ]
          }
        }
      }
    ]
  }
}
