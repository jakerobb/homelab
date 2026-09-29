# UniFi dashboards: SigNoz ports of unpoller's stock Grafana dashboards
# (grafana.com 11310-11315, their Prometheus editions) plus the UniFi half of
# the Compose Grafana's own "Power" dashboard. The data is unpoller's
# Prometheus output (manifests/unpoller/), federated into SigNoz from
# kube-prometheus-stack (argocd/apps/signoz/application.yaml).
#
# Charts and stats are PromQL rather than the query builder. Federation hands
# SigNoz every series as an untyped gauge, and the builder's rate/increase
# only work on counters (on a gauge, increase returns nonsense). SigNoz's
# PromQL engine reads the raw samples, so rate() works on them as usual.
# Federation delivers a sample a minute, so rates use a 5m window (at least a
# few samples) and panels step at 60s.
#
# SigNoz doesn't allow PromQL in table and pie panels, though, only the
# builder or ClickHouse SQL. Those use the builder where they only need a
# gauge's latest value, and SQL where they need more (a counter's increase,
# or labels from two metrics in one row).
#
# Each dashboard-unifi-*.tf file is one dashboard as plain data, rendered by
# the single resource below:
#
#   sections  collapsible groups, each a 12-column grid of rows
#   rows      { h = height, panels = [...] }; panel widths in a row add up to 12
#   panel     { id, title, description?, type, unit, queries, soft_min?, soft_max?,
#               thresholds?, stacked?, column_units? }
#             type: ts (time series), number, table, pie or bar
#             column_units: a table's units by column name, for SQL tables;
#             otherwise value columns are named after their query (A, B, ...)
#   query     one of, with an optional legend:
#               { q = PromQL }                  charts and stats only
#               { metric, group_by?, filter?, space? }
#                                               builder: the latest value per
#                                               series, aggregated across them
#                                               by space (default max)
#               { sql = ClickHouse SQL }        $start_timestamp_ms and
#                                               $end_timestamp_ms are the
#                                               dashboard's time range
#             Several queries share one panel.
#   variables [{ name, label, description, sql }]: a multi-select list filled
#             by a ClickHouse query. PromQL uses it as =~"$name", where several
#             values (or All) substitute a|b|c, so only use variables for label
#             values without regex metacharacters, like device names. Builder
#             filters use `label IN $name`, and SQL `IN {{.name}}`.
#
# GUI edits: same round trip as the Temperatures dashboard (README.md),
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

  # Details tables: device_info's labels and the latest uptime, one row per
  # device. replace() __VAR__ with the dashboard's device variable.
  unifi_device_details_sql = <<-EOT
    SELECT i.name AS name, i.model AS model, i.version AS version, i.ip AS ip, i.mac AS mac, i.serial AS serial, u.uptime AS uptime
    FROM (
      SELECT JSONExtractString(labels, 'name') AS name,
             argMax(JSONExtractString(labels, 'model'), unix_milli) AS model,
             argMax(JSONExtractString(labels, 'version'), unix_milli) AS version,
             argMax(JSONExtractString(labels, 'ip'), unix_milli) AS ip,
             argMax(JSONExtractString(labels, 'mac'), unix_milli) AS mac,
             argMax(JSONExtractString(labels, 'serial'), unix_milli) AS serial
      FROM signoz_metrics.distributed_time_series_v4
      WHERE metric_name = 'unpoller_device_info' AND unix_milli >= $start_timestamp_ms - 3600000
        AND JSONExtractString(labels, 'name') IN {{.__VAR__}}
      GROUP BY name
    ) AS i
    LEFT JOIN (
      SELECT JSONExtractString(t.labels, 'name') AS name, argMax(s.value, s.unix_milli) AS uptime
      FROM signoz_metrics.distributed_samples_v4 AS s
      INNER JOIN (
        SELECT DISTINCT fingerprint, labels FROM signoz_metrics.distributed_time_series_v4
        WHERE metric_name = 'unpoller_device_uptime_seconds' AND unix_milli >= $start_timestamp_ms - 3600000
      ) AS t ON s.fingerprint = t.fingerprint
      WHERE s.metric_name = 'unpoller_device_uptime_seconds' AND s.unix_milli BETWEEN $start_timestamp_ms AND $end_timestamp_ms
      GROUP BY name
    ) AS u ON i.name = u.name
    ORDER BY name
  EOT

  # DPI bytes received and sent over the dashboard's time range, per value of
  # the label that replace()s __LABEL__. UniFi's DPI byte counts aren't clean
  # counters: they dip slightly between polls, and PromQL's increase() would
  # take every dip for a counter reset and add the whole value back. So a dip
  # counts as no traffic, and only a drop to under half is a reset. The
  # "TOTAL" series is unpoller's site-wide sum, which flips between two
  # unrelated values from poll to poll.
  unifi_dpi_totals_sql = <<-EOT
    SELECT ts.__LABEL__ AS __LABEL__,
           sumIf(s.inc, s.metric_name = 'unpoller_client_dpi_receive_bytes') AS received,
           sumIf(s.inc, s.metric_name = 'unpoller_client_dpi_transmit_bytes') AS sent
    FROM (
      SELECT metric_name, fingerprint, value,
             lagInFrame(value, 1, value) OVER (PARTITION BY fingerprint ORDER BY unix_milli ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS prev,
             if(value < prev / 2, value, greatest(value - prev, 0)) AS inc
      FROM signoz_metrics.distributed_samples_v4
      WHERE metric_name IN ('unpoller_client_dpi_receive_bytes', 'unpoller_client_dpi_transmit_bytes')
        AND unix_milli BETWEEN $start_timestamp_ms AND $end_timestamp_ms
    ) AS s
    INNER JOIN (
      SELECT DISTINCT fingerprint, JSONExtractString(labels, '__LABEL__') AS __LABEL__
      FROM signoz_metrics.distributed_time_series_v4
      WHERE metric_name IN ('unpoller_client_dpi_receive_bytes', 'unpoller_client_dpi_transmit_bytes')
        AND unix_milli >= $start_timestamp_ms - 3600000
        AND JSONExtractString(labels, 'name') != 'TOTAL'
    ) AS ts ON s.fingerprint = ts.fingerprint
    GROUP BY __LABEL__
    ORDER BY received + sent DESC
  EOT

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
                # Value columns are named after their query (A, B, ...), and
                # q.unit overrides the panel's unit for one of them. SQL
                # tables name their own columns, so they set column_units.
                formatting = {
                  decimal_precision = "2"
                  column_units = try(p.column_units, {
                    for i, q in p.queries : substr("ABCDEFGHIJKLMNOP", i, 1) => try(q.unit, p.unit)
                  })
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
                # Below, not beside: a quarter-width pie leaves no room for both.
                legend = {
                  position = "bottom"
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
                          promql = try(q.q, null) == null ? null : {
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
                          clickhouse_sql = try(q.sql, null) == null ? null : {
                            type = "clickhouse_sql"
                            spec = {
                              name     = substr("ABCDEFGHIJKLMNOP", i, 1)
                              query    = q.sql
                              legend   = try(q.legend, "")
                              disabled = false
                            }
                          }
                          builder_query = try(q.metric, null) == null ? null : {
                            type = "builder_query"
                            spec = {
                              metrics = {
                                name          = substr("ABCDEFGHIJKLMNOP", i, 1)
                                signal        = "metrics"
                                step_interval = "60"
                                aggregations = [
                                  {
                                    metric_name       = q.metric
                                    time_aggregation  = "latest"
                                    space_aggregation = try(q.space, "max")
                                    reduce_to         = "last"
                                  },
                                ]
                                filter = {
                                  expression = try(q.filter, "")
                                }
                                group_by = [
                                  for g in try(q.group_by, []) : {
                                    name            = g
                                    field_context   = "attribute"
                                    field_data_type = "string"
                                  }
                                ]
                                having = {
                                  expression = ""
                                }
                                legend = try(q.legend, "")
                              }
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
