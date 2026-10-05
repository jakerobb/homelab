# The descheduler evicted at least one pod. It evicts to even out the workers
# (argocd/apps/descheduler/application.yaml), and each eviction is a brief
# outage for a single-replica pod, so a push when it happens is worth having,
# from the 03:30 CronJob and manual runs (`kubectl create job -n descheduler
# --from=cronjob/descheduler ...`) alike.
#
# The Job's pod log is the source: signoz-k8s-infra ships it, and the
# descheduler logs one `"Evicted pod" pod=<ns/name> ...` line per eviction
# (and a second `"Evicted pods"` line, which the pattern skips so each
# eviction counts once). Its Kubernetes Events (reason LowNodeUtilization)
# aren't collected in SigNoz. The alert doesn't name the pods; `kubectl logs
# -n descheduler job/<name>` does.
#
# Delivery is the ntfy-alertmanager channel from alert-packet-loss.tf. The
# severity label "none" is the lowest ntfy priority there, since this is
# informational. The channel also sends a "resolved" message a few minutes
# later, so each run produces two pushes.

resource "signoz_rule" "descheduler_evicted" {
  alert          = "Descheduler evicted pods"
  alert_type     = "LOGS_BASED_ALERT"
  rule_type      = "threshold_rule"
  schema_version = "v2alpha1"
  description    = "The descheduler evicted pods to rebalance the workers."

  annotations = {
    summary     = "Descheduler evicted {{$value}} pod(s)"
    description = "The descheduler evicted {{$value}} pod(s) in the last 5 minutes. See which with `kubectl logs -n descheduler job/<name>`."
  }

  labels = {
    severity = "none"
    # ntfy-alertmanager's body line leads with the first of
    # name/pod/node/instance/url/namespace it finds.
    name = "descheduler"
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
                  expression = "k8s.namespace.name = 'descheduler' AND body REGEXP 'Evicted pod. pod='"
                }

                step_interval = "60"
              }
            }
          }
        }
      ]
    }

    selected_query_name = "A"

    thresholds = {
      basic = {
        kind = "basic"
        spec = [
          {
            name       = "info"
            op         = "above"
            match_type = "at_least_once"
            target     = 0
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
