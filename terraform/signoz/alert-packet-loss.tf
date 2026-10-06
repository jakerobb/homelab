# Packet loss on rpi5-1's wired interface (.2; the Wi-Fi interface and its .3
# were retired in the 2026-10 jump box swap), pinged by
# its Compose Telegraf (docker-compose/telegraf/telegraf.conf; `ping_percent_packet_loss`
# by `url`, over OTLP). Ported from the old Compose Grafana's "Packet Loss"
# rule: over 50% loss for 2 minutes, and no data counts as alerting too.
#
# Delivery: SigNoz's webhook channel sends Alertmanager-format JSON, so it
# goes straight to ntfy-alertmanager (manifests/ntfy-alertmanager/), the same
# bridge kube-prometheus-stack's Alertmanager uses, and lands in ntfy's
# homelab-alerts topic. The `severity` label picks the ntfy priority there.
#
# Needs /api/v2/rules and /api/v2/notification_channels open in
# argocd/apps/signoz/httproute.yaml, and the terraform service account on
# Admin: creating channels is Admin-only (README.md).

resource "signoz_notification_channel" "ntfy" {
  name         = "ntfy-alertmanager"
  display_name = "ntfy-alertmanager"

  config = {
    webhook = {
      kind = "webhook"
      spec = {
        url           = "http://ntfy-alertmanager.monitoring.svc.cluster.local:8080"
        send_resolved = true
      }
    }
  }
}

resource "signoz_rule" "packet_loss" {
  alert          = "Packet loss"
  alert_type     = "METRIC_BASED_ALERT"
  rule_type      = "promql_rule"
  schema_version = "v2alpha1"
  description    = "Telegraf on rpi5-1 pings its own wired interface; over 50% loss for 3 minutes."

  annotations = {
    summary     = "Packet loss detected"
    description = "Packet loss alert: {{$labels.url}} ({{$value}}% loss)"
  }

  labels = {
    severity = "warning"
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
              # [.] instead of \. so no escaping is needed through HCL and PromQL.
              query = "max by (url) (ping_percent_packet_loss{url=~\"192[.]168[.]102[.]2\"})"
            }
          }
        }
      ]
    }

    selected_query_name = "A"

    # Grafana's rule had no-data = Alerting. absent_for is in minutes.
    alert_on_absent = true
    absent_for      = 2

    thresholds = {
      basic = {
        kind = "basic"
        spec = [
          {
            name       = "warning"
            op         = "above"
            match_type = "all_the_times"
            target     = 50
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
        eval_window = "3m"
        frequency   = "1m"
      }
    }
  }

  notification_settings = {
    group_by = ["url"]
    renotify = {
      alert_states = ["firing"]
      enabled      = true
      interval     = "4h"
    }
  }
}
