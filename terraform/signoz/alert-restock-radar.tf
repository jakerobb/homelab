# restock-radar's poller has stopped making progress: no successful product
# fetch for an hour. The app polls every 20 minutes (plus or minus a minute), so
# an hour is three missed passes. restock_radar_last_success_timestamp_seconds
# moves only when a fetch succeeds, and starts at process start, so this covers
# a blocked or rate-limited store, a store outage, and a hung poller alike. The
# app's own failure alerts (in ntfy) cover a single item going bad; this is
# the "nothing is working" backstop. restock_radar_fetches_total{result} in
# SigNoz says which it was (blocked, schema, error, ...).
#
# The metric reaches SigNoz by federation from Prometheus
# (argocd/apps/signoz/application.yaml, job "restock-radar"). If that, the
# scrape, or the pod itself stops, the series disappears; alert_on_absent
# turns that into an alert too, after 30 minutes.
#
# Delivery is the same ntfy-alertmanager channel as the packet-loss alert
# (alert-packet-loss.tf), landing in ntfy's homelab-alerts topic.

resource "signoz_rule" "restock_radar_stalled" {
  alert          = "Restock Radar stalled"
  alert_type     = "METRIC_BASED_ALERT"
  rule_type      = "promql_rule"
  schema_version = "v2alpha1"
  description    = "restock-radar hasn't fetched any UniFi store product successfully for over an hour."

  annotations = {
    summary     = "Restock Radar has stopped checking the store"
    description = "No successful fetch for {{$value}} seconds (polls run every 20 minutes). Check restock_radar_fetches_total by result, and the restock-radar pod's log."
  }

  labels = {
    severity = "warning"
    # The query aggregates away every label, and ntfy-alertmanager's body line
    # (manifests/ntfy-alertmanager/configmap.yaml) leads with the first of
    # name/pod/node/instance/url/namespace it finds, falling back to "?". This
    # is what shows there.
    name = "restock-radar"
  }

  condition = {
    composite_query = {
      panel_type = "graph"
      query_type = "promql"

      queries = [
        {
          promql = {
            type = "promql"
            spec = {
              name = "A"
              # Seconds since the last successful fetch.
              query = "time() - max(restock_radar_last_success_timestamp_seconds)"
            }
          }
        }
      ]
    }

    selected_query_name = "A"

    # absent_for is in minutes.
    alert_on_absent = true
    absent_for      = 30

    thresholds = {
      basic = {
        kind = "basic"
        spec = [
          {
            name       = "warning"
            op         = "above"
            match_type = "all_the_times"
            target     = 3600
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
        eval_window = "5m"
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
