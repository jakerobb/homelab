# SigNoz has stopped ingesting logs. On 2026-11-21 and 2026-11-22 the log path
# went quiet for about 8 hours each time and nothing said so: first a ClickHouse
# table (signoz_logs.tag_attributes_v2) stuck read-only, which made the
# collector's inserts time out and drop data; then the collector itself wedged
# after ClickHouse restarted, and kept failing until it was restarted by hand.
# Either way ClickHouse still answers reads, so SigNoz can see its own silence.
#
# Every Kubernetes pod log (the k8s-infra agents) and the Vector feeds (UniFi,
# the Pi journal, Talos kernel, Docker) go through the same collector and the
# same ClickHouse inserts, so a count of in-cluster logs falling to zero covers
# a stall anywhere along that path. Normal volume is tens of thousands of lines
# an hour, so ten minutes of none is not a quiet moment. The zero shows up as
# no data at all rather than as a 0, hence alert_on_absent.
#
# If this fires: check `kubectl -n signoz get pods`, then the collector's log
# for "Exporting failed" and the ClickHouse replicas for a read-only table:
#   SELECT database, table, is_readonly FROM system.replicas WHERE is_readonly
# Restarting signoz-otel-collector clears a wedged collector. A read-only table
# needs the force_restore_data flag (see todo/DONE.md, 2026-11-22).
#
# Delivery is the ntfy-alertmanager channel from alert-packet-loss.tf.

resource "signoz_rule" "logs_stale" {
  alert          = "SigNoz logs stale"
  alert_type     = "LOGS_BASED_ALERT"
  rule_type      = "threshold_rule"
  schema_version = "v2alpha1"
  description    = "No logs have reached SigNoz for ten minutes."

  annotations = {
    summary     = "SigNoz has stopped ingesting logs"
    description = "No Kubernetes pod logs have arrived in SigNoz for ten minutes. Check the signoz-otel-collector log for failed exports, the ClickHouse replicas for a read-only table (system.replicas, is_readonly), and restart the collector."
  }

  labels = {
    severity = "warning"
    # ntfy-alertmanager's body line leads with the first of
    # name/pod/node/instance/url/namespace it finds.
    name = "signoz-logs"
  }

  condition = {
    composite_query = {
      panel_type = "graph"
      query_type = "builder"

      queries = [
        {
          builder_query = {
            type = "builder_query"
            spec = {
              logs = {
                name   = "A"
                signal = "logs"

                aggregations = [
                  {
                    expression = "count()"
                  }
                ]

                filter = {
                  expression = "k8s.namespace.name EXISTS"
                }

                step_interval = "60"
              }
            }
          }
        }
      ]
    }

    selected_query_name = "A"

    # absent_for is in minutes.
    alert_on_absent = true
    absent_for      = 10

    thresholds = {
      basic = {
        kind = "basic"
        spec = [
          {
            name       = "warning"
            op         = "below"
            match_type = "all_the_times"
            target     = 1
            channels   = [signoz_notification_channel.ntfy.display_name]
          }
        ]
      }
    }
  }

  evaluation = {
    rolling = {
      kind = "rolling"
      spec = {
        eval_window = "10m"
        frequency   = "1m"
      }
    }
  }

  notification_settings = {
    renotify = {
      alert_states = ["firing"]
      enabled      = true
      interval     = "4h"
    }
  }
}
