# Proxmox host metrics

The Proxmox host (`proxmox.lan`, the MS-A2) runs Debian's
`prometheus-node-exporter` package, listening on `:9100`. It was installed
2026-09-27 to get the host's temperatures into SigNoz's Temperatures dashboard
([`terraform/signoz/dashboard-temperatures.tf`](../terraform/signoz/dashboard-temperatures.tf)),
and it brings the rest of node-exporter's host metrics with it.

## How the data flows

- **Prometheus** scrapes it with a static target under the job name
  `node-exporter`, labelled `node="ms-a2"`
  ([`argocd/apps/kube-prometheus-stack/application.yaml`](../argocd/apps/kube-prometheus-stack/application.yaml),
  `additionalScrapeConfigs`). The in-cluster node-exporter has the same job
  name and a `node` label, so the host's series look like any cluster node's.
- **Alerts:** because of that job name, kube-prometheus-stack's node alerts
  (filesystem filling up, memory, clock sync, network errors and so on) cover
  the Proxmox host too, through the usual Alertmanager → ntfy path. None fired
  when it was added.
- **SigNoz** gets it from Prometheus's federation, whose `{job="node-exporter"}`
  match already includes it ([`argocd/apps/signoz/application.yaml`](../argocd/apps/signoz/application.yaml)).

## Sensors

`node_hwmon_temp_celsius`, identified by `chip` and `sensor`. The chip names are
bus paths, so `node_hwmon_chip_names` and `node_hwmon_sensor_label` say what
each one is.

| Chip | Sensor | What |
|---|---|---|
| `pci0000:00_0000:00:18_3` (k10temp) | `temp1` / `temp3` / `temp4` | CPU: Tctl, Tccd1, Tccd2. The Ryzen 8845HS throttles at 100 °C. |
| `nvme_nvme0` | `temp1` / `temp3` | Boot NVMe: Composite, Sensor 2. The drive reports 74.85 °C as its warning limit and 79.85 °C as critical. |
| `i2c_2_2_0050`, `i2c_2_2_0051` (spd5118) | `temp1` | The two DDR5 SODIMMs. Critical at 85 °C. Their 55 °C "max" is only the default alarm setting. |
| `0000:00:08_1_0000:01:00_0` (amdgpu) | `temp1` | The Radeon iGPU (edge) |
| `r8169_0_300_r8169_0_300:00` | `temp1` | Realtek 2.5GbE NIC |
| `ieee80211_phy0` (mt7921) | `temp1` | MediaTek Wi-Fi card |

No fan sensors are exposed. The 2TB and 4TB NVMe drives are passed through to
the HexOS VM, so the host can't read their temperatures.

## Install (done 2026-09-27)

On the Proxmox host (from rpi5-1: `ssh proxmox`):

```bash
apt-get install --no-install-recommends prometheus-node-exporter
```

`--no-install-recommends` skips `prometheus-node-exporter-collectors`, which
adds systemd timers for extra textfile metrics (apt, SMART and so on) that
nothing here uses. The package enables and starts the service, with default
collectors and no extra arguments (`/etc/default/prometheus-node-exporter`).
Debian security updates to it arrive through unattended-upgrades
([`proxmox-os-updates.md`](proxmox-os-updates.md)).

## Checking that it's working

From rpi5-1:

```bash
curl -s http://192.168.102.21:9100/metrics | grep '^node_hwmon_temp_celsius'
```

In Prometheus, the target shows under **Status → Targets** as job
`node-exporter`, instance `192.168.102.21:9100`. If it goes down, the chart's
`TargetDown` alert fires.
