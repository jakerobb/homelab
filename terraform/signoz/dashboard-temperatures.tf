# Hardware temperatures of every physical host, one panel per kind of sensor
# and one line per host. The worker VMs expose no sensors, so they aren't here.
#
# Where each host's readings come from:
# - Raspberry Pi control planes and the MS-A2: node-exporter, federated from
#   Prometheus (`node_hwmon_*`, host in the `node` label). Pi CPU is hwmon chip
#   thermal_thermal_zone0; the MS-A2's is k10temp (chip pci0000:00_0000:00:18_3,
#   temp1 = Tctl). docs/proxmox-host-metrics.md covers the MS-A2's exporter.
# - rpi5-1: its Compose Telegraf over OTLP (`temp_temp` by `sensor`,
#   `fan_value`), see docker-compose/telegraf/telegraf.conf.
# - Macs: Telegraf over OTLP (`smc_*`, `thermal_*`), see
#   docs/mac-host-metrics.md. Both carry the host in `host.name`.
#
# Panels are generated from local.panels to keep each one to its differences.
# Edit it in the GUI if that's easier, then export the JSON and fold the
# changes back in here (README.md), or the next apply reverts them.

locals {
  # Each panel is a time series with one or more builder queries on gauges.
  panels = {
    cpu = {
      title       = "CPU temperature"
      description = "Pi 5: SoC temperature. MS-A2: Tctl. Macs: CPU die (powermetrics' SMC sampler)."
      unit        = "celsius"
      soft_max    = 105
      thresholds = [
        { value = 80, color = "#FFA500", label = "Pi 5 starts throttling" },
        { value = 100, color = "#FF0000", label = "MS-A2 and MacBook Pro CPUs throttle" },
      ]
      queries = [
        {
          metric   = "node_hwmon_temp_celsius"
          filter   = "(chip = 'thermal_thermal_zone0' AND sensor = 'temp0') OR (chip = 'pci0000:00_0000:00:18_3' AND sensor = 'temp1')"
          group_by = ["node"]
          legend   = "{{node}}"
        },
        {
          metric   = "temp_temp"
          filter   = "sensor = 'cpu_thermal'"
          group_by = ["host.name"]
          legend   = "{{host.name}}"
        },
        {
          metric   = "smc_temperature_value"
          filter   = "sensor = 'cpu_die'"
          group_by = ["host.name"]
          legend   = "{{host.name}}"
        },
      ]
    }
    nvme = {
      title       = "NVMe temperature"
      description = "Each drive's composite sensor. The warning lines are the limits the drives themselves report (node_hwmon_temp_max_celsius). The Macs don't report this."
      unit        = "celsius"
      soft_max    = 90
      thresholds = [
        { value = 74.85, color = "#FFA500", label = "MS-A2 drive warning" },
        { value = 82.85, color = "#FF0000", label = "Pi drives' warning" },
      ]
      queries = [
        {
          metric   = "node_hwmon_temp_celsius"
          filter   = "chip = 'nvme_nvme0' AND sensor = 'temp1'"
          group_by = ["node"]
          legend   = "{{node}}"
        },
        {
          metric   = "temp_temp"
          filter   = "sensor = 'nvme_composite'"
          group_by = ["host.name"]
          legend   = "{{host.name}}"
        },
      ]
    }
    gpu = {
      title       = "GPU temperature"
      description = "MS-A2: the Radeon iGPU's edge sensor. Macs: GPU die."
      unit        = "celsius"
      soft_max    = 105
      thresholds  = []
      queries = [
        {
          metric   = "node_hwmon_temp_celsius"
          filter   = "chip = '0000:00:08_1_0000:01:00_0' AND sensor = 'temp1'"
          group_by = ["node"]
          legend   = "{{node}}"
        },
        {
          metric   = "smc_temperature_value"
          filter   = "sensor = 'gpu_die'"
          group_by = ["host.name"]
          legend   = "{{host.name}}"
        },
      ]
    }
    memory = {
      title       = "Memory temperature"
      description = "The MS-A2's two DDR5 SODIMMs (spd5118 sensors); nothing else reports this. The sticks report 85 °C as critical. Their 55 °C 'max' is only the default alarm setting, not a limit."
      unit        = "celsius"
      soft_max    = 90
      thresholds = [
        { value = 85, color = "#FF0000", label = "DIMM critical" },
      ]
      queries = [
        {
          metric   = "node_hwmon_temp_celsius"
          filter   = "chip = 'i2c_2_2_0050'"
          group_by = ["node"]
          legend   = "{{node}} DIMM 1"
        },
        {
          metric   = "node_hwmon_temp_celsius"
          filter   = "chip = 'i2c_2_2_0051'"
          group_by = ["node"]
          legend   = "{{node}} DIMM 2"
        },
      ]
    }
    other = {
      title       = "Other components"
      description = "MS-A2: the Realtek 2.5GbE NIC and the MediaTek Wi-Fi card. rpi5-1: the RP1 I/O chip."
      unit        = "celsius"
      soft_max    = 90
      thresholds  = []
      queries = [
        {
          metric   = "node_hwmon_temp_celsius"
          filter   = "chip = 'r8169_0_300_r8169_0_300:00'"
          group_by = ["node"]
          legend   = "{{node}} NIC"
        },
        {
          metric   = "node_hwmon_temp_celsius"
          filter   = "chip = 'ieee80211_phy0'"
          group_by = ["node"]
          legend   = "{{node}} Wi-Fi"
        },
        {
          metric   = "temp_temp"
          filter   = "sensor = 'rp1_adc'"
          group_by = ["host.name"]
          legend   = "{{host.name}} RP1"
        },
      ]
    }
    fan = {
      title       = "Fan speed"
      description = "Only rpi5-1 and the Macs report fans. The control-plane Pis and the MS-A2 don't expose theirs."
      unit        = "rotrpm"
      soft_max    = null
      thresholds  = []
      queries = [
        {
          metric   = "fan_value"
          filter   = ""
          group_by = ["host.name"]
          legend   = "{{host.name}}"
        },
        {
          metric   = "smc_fan_rpm"
          filter   = ""
          group_by = ["host.name"]
          legend   = "{{host.name}}"
        },
      ]
    }
    mac-speed-limit = {
      title       = "Mac CPU speed limit"
      description = "macOS's thermal limit on CPU speed. 100% means not throttled."
      unit        = "%"
      soft_max    = 100
      thresholds  = []
      queries = [
        {
          metric   = "thermal_cpu_speed_limit_percent"
          filter   = ""
          group_by = ["host.name"]
          legend   = "{{host.name}}"
        },
      ]
    }
  }

  # Collapsible sections, each a grid 12 columns wide. Each item is
  # [panel, x, y, width]; every panel is 6 high.
  sections = [
    {
      title = "Temperatures"
      items = [
        ["cpu", 0, 0, 6], ["nvme", 6, 0, 6],
        ["gpu", 0, 6, 4], ["memory", 4, 6, 4], ["other", 8, 6, 4],
      ]
    },
    {
      title = "Cooling"
      items = [["fan", 0, 0, 6], ["mac-speed-limit", 6, 0, 6]]
    },
  ]
}

resource "signoz_dashboard" "temperatures" {
  schema_version = "v6"
  name           = "temperatures"
  tags = [
    { key = "tag", value = "hardware" },
  ]

  spec = {
    display = {
      name        = "Temperatures"
      description = "CPU, NVMe, GPU, memory and other temperatures, fan speed and thermal throttling for every physical host."
    }
    duration         = "24h"
    refresh_interval = "1m"
    links            = []
    variables        = []

    panels = {
      for id, p in local.panels : id => {
        kind = "Panel"
        spec = {
          display = {
            name        = p.title
            description = p.description
          }
          links = []
          plugin = {
            time_series_panel = {
              kind = "signoz/TimeSeriesPanel"
              spec = {
                visualization = {
                  time_preference = "global_time"
                  fill_spans      = false
                }
                formatting = {
                  unit              = p.unit
                  decimal_precision = "1"
                }
                chart_appearance = {
                  line_interpolation = "spline"
                  show_points        = false
                  line_style         = "solid"
                  fill_mode          = "none"
                }
                # Start at zero so a few degrees of normal variation doesn't
                # fill the whole chart and look alarming.
                axes = {
                  soft_min     = 0
                  soft_max     = p.soft_max
                  is_log_scale = false
                }
                legend = {
                  position = "bottom"
                  mode     = "list"
                }
                thresholds = [
                  for t in p.thresholds : {
                    value = t.value
                    color = t.color
                    label = t.label
                    unit  = p.unit
                  }
                ]
              }
            }
          }
          queries = [
            for i, q in p.queries : {
              kind = "time_series"
              spec = {
                name = substr("ABCDEFGH", i, 1)
                plugin = {
                  builder_query = {
                    kind = "signoz/BuilderQuery"
                    spec = {
                      metrics = {
                        name   = substr("ABCDEFGH", i, 1)
                        signal = "metrics"
                        # Prometheus federation and Telegraf's OTLP output
                        # both send about once a minute or faster.
                        step_interval = "60"
                        aggregations = [
                          {
                            metric_name       = q.metric
                            time_aggregation  = "avg"
                            space_aggregation = "max"
                            reduce_to         = "avg"
                          },
                        ]
                        filter = {
                          expression = q.filter
                        }
                        group_by = [
                          for g in q.group_by : {
                            name            = g
                            field_context   = "attribute"
                            field_data_type = "string"
                          }
                        ]
                        having = {
                          expression = ""
                        }
                        legend = q.legend
                      }
                    }
                  }
                }
              }
            }
          ]
        }
      }
    }

    layouts = [
      for sec in local.sections : {
        grid = {
          kind = "Grid"
          spec = {
            display = {
              title    = sec.title
              collapse = { open = true }
            }
            items = [
              for i in sec.items : {
                x       = i[1]
                y       = i[2]
                width   = i[3]
                height  = 6
                content = { ref = "#/spec/panels/${i[0]}" }
              }
            ]
          }
        }
      }
    ]
  }
}
