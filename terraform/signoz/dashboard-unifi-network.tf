# UniFi network overview: port of unpoller's "Network Sites" dashboard
# (grafana.com 11311), plus the gateway's WAN speed tests. One site, one
# controller, so no Site/Controller variables. Rendered by unifi-dashboards.tf.

locals {
  unifi_network = {
    title       = "UniFi: Network"
    description = "Site-wide device and client counts, traffic by subsystem, VPN users and WAN speed tests, from unpoller."
    sections = [
      {
        title = "Overview"
        rows = [
          {
            h = 3
            panels = [
              { id = "switches", w = 2, type = "number", unit = "1", title = "Switches", queries = [{ q = "sum(unpoller_site_switches)" }] },
              { id = "aps", w = 2, type = "number", unit = "1", title = "Access points", queries = [{ q = "sum(unpoller_site_aps)" }] },
              { id = "gateways", w = 2, type = "number", unit = "1", title = "Gateways", queries = [{ q = "sum(unpoller_site_gateways)" }] },
              { id = "stations", w = 2, type = "number", unit = "1", title = "Clients", queries = [{ q = "sum(unpoller_site_stations)" }] },
              { id = "uptime", w = 2, type = "number", unit = "s", title = "WAN uptime", queries = [{ q = "max(unpoller_site_uptime_seconds)" }] },
              { id = "latency", w = 2, type = "number", unit = "s", decimals = "3", title = "WAN latency", queries = [{ q = "max(unpoller_site_latency_seconds)" }] },
            ]
          },
          {
            h = 6
            panels = [
              {
                id = "transfer", w = 6, type = "ts", unit = "By/s", title = "Data transfer by subsystem"
                queries = [
                  { q = "sum by (subsystem) (unpoller_site_transmit_rate_bytes)", legend = "{{subsystem}} Tx" },
                  { q = "sum by (subsystem) (unpoller_site_receive_rate_bytes)", legend = "{{subsystem}} Rx" },
                ]
              },
              {
                id = "clients", w = 6, type = "ts", unit = "1", title = "Clients by subsystem"
                queries = [
                  { q = "sum by (subsystem) (unpoller_site_users)", legend = "{{subsystem}} users" },
                  { q = "sum by (subsystem) (unpoller_site_guests)", legend = "{{subsystem}} guests" },
                  { q = "sum by (subsystem) (unpoller_site_iots)", legend = "{{subsystem}} IoT" },
                  { q = "sum(unpoller_site_remote_user_active)", legend = "VPN active" },
                ]
              },
            ]
          },
          {
            h = 6
            panels = [
              {
                id          = "devices", w = 6, type = "ts", unit = "1", title = "Devices by subsystem"
                description = "Adopted, disconnected and pending UniFi devices. Anything but adopted deserves a look."
                queries = [
                  { q = "sum by (subsystem) (unpoller_site_adopted)", legend = "{{subsystem}} adopted" },
                  { q = "sum by (subsystem) (unpoller_site_disconnected)", legend = "{{subsystem}} disconnected" },
                  { q = "sum by (subsystem) (unpoller_site_pending)", legend = "{{subsystem}} pending" },
                  { q = "sum by (subsystem) (unpoller_site_disabled)", legend = "{{subsystem}} disabled" },
                ]
              },
              {
                id = "vpn", w = 6, type = "ts", unit = "By/s", title = "VPN users data rate"
                queries = [
                  { q = "sum(rate(unpoller_site_remote_user_transmit_bytes_total[5m]))", legend = "Tx" },
                  { q = "sum(rate(unpoller_site_remote_user_receive_bytes_total[5m]))", legend = "Rx" },
                ]
              },
            ]
          },
        ]
      },
      {
        title = "WAN speed tests"
        rows = [
          {
            h = 6
            panels = [
              {
                id          = "speedtest", w = 8, type = "ts", unit = "Mbit/s", title = "Speed test results"
                description = "The gateway's scheduled speed tests, per WAN. Values hold between runs. WANs that never ran one (the backups) are left out."
                queries = [
                  { q = "max by (wan_interface) (unpoller_speedtest_download_mbps > 0)", legend = "{{wan_interface}} down" },
                  { q = "max by (wan_interface) (unpoller_speedtest_upload_mbps > 0)", legend = "{{wan_interface}} up" },
                ]
              },
              {
                id = "speedtest-latency", w = 4, type = "ts", unit = "ms", title = "Speed test latency"
                queries = [
                  { q = "max by (wan_interface) (unpoller_speedtest_latency_ms > 0)", legend = "{{wan_interface}}" },
                ]
              },
            ]
          },
        ]
      },
    ]
  }
}
