# etcd: health and performance of the three control-plane members. Talos runs
# etcd as a host service, so the metrics come from the plain-HTTP listener on
# each node's own IP (:2381, talos/patches/control-plane/cp*.yaml), scraped
# by kube-prometheus-stack's `kube-etcd` job and federated into SigNoz
# (argocd/apps/signoz/application.yaml). Rendered by unifi-dashboards.tf, like
# the dashboards it was built from.
#
# What to look at, from etcd's own operations guidance: disk latency first
# (WAL fsync p99 over 10ms and backend commit p99 over 25ms mean the disk is
# too slow, and leader elections follow), then peer RTT, then DB size against
# the backend quota (2 GiB by default; at the quota etcd goes read-only for
# writes and raises a NOSPACE alarm).
#
# Every query is PromQL over the federated samples (one a minute), so rates
# use a 5m window, as in the UniFi dashboards.

locals {
  etcd = {
    title       = "etcd"
    description = "Control-plane etcd: members and leader, disk and network latency, database size against its quota, and request load."
    tags        = ["kubernetes", "etcd"]
    sections = [
      {
        title = "Now"
        rows = [
          {
            h = 3
            panels = [
              { id = "members", w = 2, type = "number", unit = "1", title = "Members up", description = "Scrape targets answering. Quorum needs 2 of 3.", queries = [{ q = "count(up{job=\"kube-etcd\"} == 1)" }] },
              { id = "has-leader", w = 2, type = "number", unit = "1", title = "Has leader", description = "1 when every member sees a leader; 0 if any member doesn't.", queries = [{ q = "min(etcd_server_has_leader{job=\"kube-etcd\"})" }] },
              { id = "changes-24h", w = 2, type = "number", unit = "1", title = "Leader changes, 24h", description = "Elections. A few after a reboot or upgrade is normal; repeated ones aren't.", queries = [{ q = "sum(increase(etcd_server_leader_changes_seen_total{job=\"kube-etcd\"}[24h]))" }] },
              { id = "failed-1h", w = 2, type = "number", unit = "1", title = "Failed proposals, 1h", queries = [{ q = "sum(increase(etcd_server_proposals_failed_total{job=\"kube-etcd\"}[1h]))" }] },
              { id = "db-size", w = 2, type = "number", unit = "By", title = "Largest DB", queries = [{ q = "max(etcd_mvcc_db_total_size_in_bytes{job=\"kube-etcd\"})" }] },
              { id = "db-quota-pct", w = 2, type = "number", unit = "percentunit", decimals = "1", title = "DB vs quota", description = "Largest member's DB size as a share of the backend quota.", queries = [{ q = "max(etcd_mvcc_db_total_size_in_bytes{job=\"kube-etcd\"} / etcd_server_quota_backend_bytes{job=\"kube-etcd\"})" }] },
            ]
          },
          {
            h = 5
            panels = [
              {
                id          = "leader", w = 6, type = "ts", unit = "1", title = "Leader", soft_max = 1
                description = "1 on the member that currently holds leadership. Exactly one line should sit at 1."
                queries     = [{ q = "max by (instance) (etcd_server_is_leader{job=\"kube-etcd\"})", legend = "{{instance}}" }]
              },
              {
                id          = "up", w = 6, type = "ts", unit = "1", title = "Member up", soft_max = 1
                description = "Whether Prometheus could scrape each member."
                queries     = [{ q = "max by (instance) (up{job=\"kube-etcd\"})", legend = "{{instance}}" }]
              },
            ]
          },
        ]
      },
      {
        title = "Latency"
        rows = [
          {
            h = 6
            panels = [
              {
                id          = "wal-fsync", w = 6, type = "ts", unit = "s", title = "WAL fsync p99"
                description = "Time to flush the write-ahead log to disk. etcd recommends p99 under 10ms."
                thresholds = [
                  { value = 0.01, color = "#FFA500", label = "10 ms" },
                ]
                queries = [{ q = "histogram_quantile(0.99, sum by (le, instance) (rate(etcd_disk_wal_fsync_duration_seconds_bucket{job=\"kube-etcd\"}[5m])))", legend = "{{instance}}" }]
              },
              {
                id          = "backend-commit", w = 6, type = "ts", unit = "s", title = "Backend commit p99"
                description = "Time to commit a batch to the boltdb file. etcd recommends p99 under 25ms."
                thresholds = [
                  { value = 0.025, color = "#FFA500", label = "25 ms" },
                ]
                queries = [{ q = "histogram_quantile(0.99, sum by (le, instance) (rate(etcd_disk_backend_commit_duration_seconds_bucket{job=\"kube-etcd\"}[5m])))", legend = "{{instance}}" }]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id          = "peer-rtt", w = 6, type = "ts", unit = "s", title = "Peer round trip p99"
                description = "Heartbeat round trip between members. Election timeout is 1s, so this should stay far below it."
                queries     = [{ q = "histogram_quantile(0.99, sum by (le, instance) (rate(etcd_network_peer_round_trip_time_seconds_bucket{job=\"kube-etcd\"}[5m])))", legend = "{{instance}}" }]
              },
              {
                id          = "slow-applies", w = 6, type = "ts", unit = "1", title = "Slow applies and heartbeat failures, per second"
                description = "Applies that took over 100ms, and heartbeats that arrived late. Both should be flat at zero."
                queries = [
                  { q = "sum by (instance) (rate(etcd_server_slow_apply_total{job=\"kube-etcd\"}[5m]))", legend = "{{instance}} slow applies" },
                  { q = "sum by (instance) (rate(etcd_server_heartbeat_send_failures_total{job=\"kube-etcd\"}[5m]))", legend = "{{instance}} heartbeat failures" },
                ]
              },
            ]
          },
        ]
      },
      {
        title = "Raft"
        rows = [
          {
            h = 6
            panels = [
              {
                id          = "proposals", w = 6, type = "ts", unit = "1", title = "Proposals committed, per second"
                description = "Writes through raft, as seen by each member. Every member applies the same ones."
                queries     = [{ q = "sum by (instance) (rate(etcd_server_proposals_committed_total{job=\"kube-etcd\"}[5m]))", legend = "{{instance}}" }]
              },
              {
                id          = "pending", w = 6, type = "ts", unit = "1", title = "Pending and failed proposals"
                description = "Pending: proposals waiting to commit (a backlog means the cluster can't keep up). Failed: per second."
                queries = [
                  { q = "max by (instance) (etcd_server_proposals_pending{job=\"kube-etcd\"})", legend = "{{instance}} pending" },
                  { q = "sum by (instance) (rate(etcd_server_proposals_failed_total{job=\"kube-etcd\"}[5m]))", legend = "{{instance}} failed/s" },
                ]
              },
            ]
          },
        ]
      },
      {
        title = "Database"
        rows = [
          {
            h = 6
            panels = [
              {
                id          = "db-size-ts", w = 6, type = "ts", unit = "By", title = "DB size and quota"
                description = "Size on disk, size in use, and the backend quota. Compaction and defragmentation close the gap between the first two."
                queries = [
                  { q = "max(etcd_mvcc_db_total_size_in_bytes{job=\"kube-etcd\"})", legend = "On disk (largest member)" },
                  { q = "max(etcd_mvcc_db_total_size_in_use_in_bytes{job=\"kube-etcd\"})", legend = "In use (largest member)" },
                  { q = "max(etcd_server_quota_backend_bytes{job=\"kube-etcd\"})", legend = "Quota" },
                ]
              },
              {
                id          = "keys", w = 6, type = "ts", unit = "1", title = "Keys"
                description = "Keys in the keyspace on each member."
                queries = [
                  { q = "max by (instance) (etcd_debugging_mvcc_keys_total{job=\"kube-etcd\"})", legend = "{{instance}} keys" },
                ]
              },
            ]
          },
        ]
      },
      {
        title = "Load"
        rows = [
          {
            h = 6
            panels = [
              {
                id          = "grpc-rate", w = 6, type = "ts", unit = "1", title = "gRPC requests, per second"
                description = "Completed unary and streaming calls by method."
                queries     = [{ q = "sum by (grpc_method) (rate(grpc_server_handled_total{job=\"kube-etcd\", grpc_type=\"unary\"}[5m]))", legend = "{{grpc_method}}" }]
              },
              {
                id          = "grpc-errors", w = 6, type = "ts", unit = "1", title = "gRPC errors, per second"
                description = "Calls ending in anything but OK, Canceled or NotFound (both of those are routine for the API server)."
                queries     = [{ q = "sum by (grpc_code) (rate(grpc_server_handled_total{job=\"kube-etcd\", grpc_code!~\"OK|Canceled|NotFound\"}[5m]))", legend = "{{grpc_code}}" }]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id = "client-traffic", w = 6, type = "ts", unit = "By/s", title = "Client traffic"
                queries = [
                  { q = "sum by (instance) (rate(etcd_network_client_grpc_received_bytes_total{job=\"kube-etcd\"}[5m]))", legend = "{{instance}} in" },
                  { q = "sum by (instance) (rate(etcd_network_client_grpc_sent_bytes_total{job=\"kube-etcd\"}[5m]))", legend = "{{instance}} out" },
                ]
              },
              {
                id = "peer-traffic", w = 6, type = "ts", unit = "By/s", title = "Peer traffic"
                queries = [
                  { q = "sum by (instance) (rate(etcd_network_peer_received_bytes_total{job=\"kube-etcd\"}[5m]))", legend = "{{instance}} in" },
                  { q = "sum by (instance) (rate(etcd_network_peer_sent_bytes_total{job=\"kube-etcd\"}[5m]))", legend = "{{instance}} out" },
                ]
              },
            ]
          },
        ]
      },
      {
        title = "Process"
        open  = false
        rows = [
          {
            h = 6
            panels = [
              {
                id      = "memory", w = 4, type = "ts", unit = "By", title = "Resident memory"
                queries = [{ q = "max by (instance) (process_resident_memory_bytes{job=\"kube-etcd\"})", legend = "{{instance}}" }]
              },
              {
                id          = "cpu", w = 4, type = "ts", unit = "1", title = "CPU, cores"
                description = "CPU seconds per second."
                queries     = [{ q = "sum by (instance) (rate(process_cpu_seconds_total{job=\"kube-etcd\"}[5m]))", legend = "{{instance}}" }]
              },
              {
                id      = "fds", w = 4, type = "ts", unit = "1", title = "Open file descriptors"
                queries = [{ q = "max by (instance) (process_open_fds{job=\"kube-etcd\"})", legend = "{{instance}}" }]
              },
            ]
          },
        ]
      },
    ]
  }
}
