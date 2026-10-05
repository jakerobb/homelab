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

# Three more rules on restock-radar's delivery and backups, defined once here
# and expanded below since they differ only in query, threshold and wording.
# Same ntfy channel and `name` label as "Restock Radar stalled" above.
#
#  - notifications_stuck: events detected but not delivered for 30 minutes. A
#    normal event is delivered in the same pass that finds it, seconds later, so
#    this means ntfy is down or unreachable from the pod.
#  - notification_rejected: ntfy refused a notification for good (an HTTP 4xx),
#    so the app gave up on it. That alert is lost, and the cause (a topic that
#    needs auth, an oversized message) will repeat. Stays true for an hour after
#    the last drop, so the 5-minute window below has time to confirm it.
#  - backup_stale: no successful database backup for 36 hours (they run every 24).
#    The metric only exists once the app is configured with backup_dir, so this
#    stays quiet until then, and the "stalled" rule above covers the app dying.
#
# alert_on_absent is off for all three: they ask about a metric the app emits
# only in some states, and a missing series is already the "stalled" rule's job.
locals {
  restock_radar_rules = {
    notifications_stuck = {
      alert       = "Restock Radar notifications stuck"
      description = "restock-radar has detected changes that it hasn't been able to deliver to ntfy for 30 minutes."
      summary     = "Restock Radar can't deliver notifications"
      detail      = "{{$value}} detected change(s) are waiting to be sent. Check that ntfy is reachable from the restock-radar pod and its log."
      query       = "max(restock_radar_pending_events)"
      target      = 0
      eval_window = "30m"
    }
    notification_rejected = {
      alert       = "Restock Radar notification rejected"
      description = "ntfy permanently refused a restock-radar notification, so it was dropped."
      summary     = "Restock Radar notification dropped"
      detail      = "ntfy rejected {{$value}} notification(s) in the last hour with a 4xx error. They won't be retried; the pod's log has the response."
      query       = "sum(increase(restock_radar_notifications_total{result=\"dropped\"}[1h])) or vector(0)"
      target      = 0
      eval_window = "5m"
    }
    backup_stale = {
      alert       = "Restock Radar backup stale"
      description = "restock-radar hasn't backed up its database for over 36 hours (it runs every 24)."
      summary     = "Restock Radar database backup is overdue"
      detail      = "Last successful backup was {{$value}} seconds ago. Check the restock-radar-backups volume and the pod's log for backup errors."
      query       = "time() - max(restock_radar_last_backup_timestamp_seconds)"
      target      = 129600
      eval_window = "10m"
    }
  }
}

resource "signoz_rule" "restock_radar" {
  for_each = local.restock_radar_rules

  alert          = each.value.alert
  alert_type     = "METRIC_BASED_ALERT"
  rule_type      = "promql_rule"
  schema_version = "v2alpha1"
  description    = each.value.description

  annotations = {
    summary     = each.value.summary
    description = each.value.detail
  }

  labels = {
    severity = "warning"
    name     = "restock-radar"
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
              name  = "A"
              query = each.value.query
            }
          }
        }
      ]
    }

    selected_query_name = "A"
    alert_on_absent     = false

    thresholds = {
      basic = {
        kind = "basic"
        spec = [
          {
            name       = "warning"
            op         = "above"
            match_type = "all_the_times"
            target     = each.value.target
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
        eval_window = each.value.eval_window
        frequency   = "5m"
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
