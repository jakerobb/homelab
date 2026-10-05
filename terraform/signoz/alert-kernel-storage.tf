# A node's kernel logged a storage error: an iSCSI/disk command timed out, an
# I/O error, or ext4/XFS reporting errors or data loss. Talos sends each
# worker's kernel log over UDP (the talos.logging.kernel kernel arg in the
# worker schematics) to the Compose Vector on rpi5-1, which forwards it here
# (docker-compose/vector/vector.yaml, source talos_kernel). See "Talos kernel
# logs" in talos/README.md. The control planes don't send theirs.
#
# Why this lives in SigNoz and not Prometheus: on 2026-09-29 and 2026-10-05 the
# victim was Prometheus's own iSCSI volume, so the ISCSIVolumeIOStall rule
# (argocd/apps/kube-prometheus-stack/application.yaml) couldn't see the stall
# it was meant to catch. SigNoz's ClickHouse sits on a different volume, and
# the kernel's own error messages don't depend on any metric being recorded.
#
# The pattern is deliberately narrow. The "EXT4-fs (sdX): error count since
# last fsck" and "mounting fs with errors" notices (an old error flag, logged
# when a volume mounts) are not matched. Talos replays the whole boot's kernel
# log to Vector after every reboot, so a loose pattern would fire on each one.
#
# Delivery is the ntfy-alertmanager channel from alert-packet-loss.tf.

resource "signoz_rule" "kernel_storage_error" {
  alert          = "Kernel storage error"
  alert_type     = "LOGS_BASED_ALERT"
  rule_type      = "threshold_rule"
  schema_version = "v2alpha1"
  description    = "A node's kernel logged a disk I/O timeout or error, or filesystem errors."

  annotations = {
    summary     = "Kernel storage error on {{$k8s.node.name}}"
    description = "{{$k8s.node.name}} logged {{$value}} storage errors in 5 minutes. Run `talosctl -n <node> dmesg | grep -E 'timing out|I/O error|EXT4-fs'` to see which device, find the pod that mounts it, and restart that pod if it logged write errors. Then check HexOS for what stalled."
  }

  labels = {
    severity = "warning"
    # ntfy-alertmanager's body line leads with the first of
    # name/pod/node/instance/url/namespace it finds.
    name = "kernel-storage-error"
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
                  expression = "source_type = 'talos-kernel' AND body REGEXP 'timing out command|I/O error|potential data loss|Remounting filesystem read-only|EXT4-fs error|XFS .*(Corruption|Metadata I/O)|blocked for more than [0-9]+ seconds'"
                }

                group_by = [
                  {
                    field_context   = "resource"
                    field_data_type = "string"
                    name            = "k8s.node.name"
                  }
                ]

                legend        = "{{k8s.node.name}}"
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
            name       = "warning"
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
    group_by = ["k8s.node.name"]
    renotify = {
      alert_states = ["firing"]
      enabled      = true
      interval     = "4h"
    }
  }
}
