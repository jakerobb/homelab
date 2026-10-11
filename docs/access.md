# Getting access

Where the credentials live and how to get into each part of the homelab.

## Passwords and secrets

- **Everyday passwords** are in 1Password, in the **Tech** vault, which is
  shared with the family. Accounts for outside services (Cloudflare,
  Backblaze B2, GitHub, UniFi, HexOS) are there too.
- **Cluster secrets** (app credentials, API tokens) are in the **homelab-k8s**
  1Password vault. The cluster reads them from there itself (External Secrets
  Operator), so nobody should need to copy them by hand. See
  [Adding an app](adding-an-app.md#5-secrets-1password--external-secrets-operator).
- **Encrypted files in this repo** (`*.sops.yaml`) are encrypted with an
  [age](https://github.com/FiloSottile/age) key. The private key is at
  `~/.config/sops/age/keys.txt` on Jake's Mac, and a copy is in 1Password. See
  [Talos cluster](../talos/README.md#secrets-sops--age-decided-2026-09-08).

## Web apps (`*.jakerobb.org`)

The web apps only work from the home network: their DNS names point at a LAN
address. See [How it fits together](overview.md#how-a-request-reaches-an-app).

Every app in the cluster except ntfy sits behind Authelia
(`auth.jakerobb.org`). Sign in
with a username and password, then a TOTP code from an authenticator app.
There is one account today, `jake`.

- **Lost the TOTP device or password?** Authelia has no email set up, so reset
  links aren't emailed. Start a reset on the login page, then read the link
  from inside the pod on rpi5-1:

```bash
kubectl exec -n authelia authelia-0 -- cat /config/notification.txt
```

- **Adding an account:** users are defined in the `users_database.yml` file
  held in the `authelia-users-database` item's notes in the homelab-k8s vault.
  Generate the password hash with `authelia crypto hash generate argon2`, add
  the user there, and restart Authelia once the Secret has synced (hourly, or
  force it by annotating the ExternalSecret). See
  [Authelia SSO](../argocd/README.md#authelia-sso-decided-2026-09-13).

| App | URL | What it is |
| --- | --- | --- |
| Glance | <https://home.jakerobb.org> | Start page with a link to every app, plus cluster and storage status |
| Docs | <https://docs.jakerobb.org> | This site |
| ArgoCD | <https://argocd.jakerobb.org> | Deploys the cluster's apps from this repo |
| Headlamp | <https://headlamp.jakerobb.org> | Web UI for the Kubernetes cluster |
| Radar | <https://radar.jakerobb.org> | A second cluster UI: topology, events, Helm releases, GitOps state. Runs as you, so Kubernetes RBAC applies |
| SigNoz | <https://signoz.jakerobb.org> | Logs, metrics and dashboards |
| Prometheus | <https://prometheus.jakerobb.org> | Cluster metrics and alert rules |
| Alertmanager | <https://alertmanager.jakerobb.org> | Active alerts and silences |
| Hubble | <https://hubble.jakerobb.org> | Cilium network flows and dropped packets |
| ntfy | <https://ntfy.jakerobb.org> | Push notifications and alerts. No login |
| Speed test | <http://speedtest.jakerobb.org:3005> | LAN speed test (Network Optimizer). LAN only, no login |
| SearXNG | <https://search.jakerobb.org> | Private web search |

The Compose apps on rpi5-1 (Home Assistant, Zigbee2MQTT, Z-Wave JS and
others) and some LAN devices go through the same Gateway. Home Assistant,
Scrypted, the UniFi gateway and the KVM use their own logins; the rest are
behind Authelia. The hostnames are the files in `manifests/lan-routes/`; see
[LAN routes](../argocd/README.md#lan-routes-replacing-caddy-added-2026-09-29).

## Infrastructure

| System | How to get in |
| --- | --- |
| UniFi network | <https://unifi.ui.com>, or the UniFi app |
| rpi5-1 (jump box) | `ssh jakerobb@rpi5-1.lan` (`192.168.102.2`). Key-based login, passwordless `sudo` |
| Kubernetes | From rpi5-1: `kubectl` works as-is (`~/.kube/config`). Or use Headlamp or Radar in a browser |
| Talos nodes | From rpi5-1: `talosctl` with `~/talos/homelab/talosconfig`. Talos has no SSH |
| Cilium flows | From rpi5-1: `hubble observe -P` (`-P` port-forwards to hubble-relay by itself). Or Hubble UI in a browser |
| Proxmox (MS-A2) | <https://proxmox.lan:8006>, or `ssh proxmox` from rpi5-1 (logs in as root) |
| HexOS / TrueNAS | <https://deck.hexos.com/dash>. The API and shares are at `truenas.lan`. Claude Code's scoped SSH access: [TrueNAS ops access](truenas-ops-access.md) |
| MacBook Pro worker host | `ssh jakerobb@192.168.102.9`. The Talos VM runs in UTM on that Mac |
| KVM (GL.iNet Comet X) | `kvm.jakerobb.org` or `kvm.lan`. Console for rpi5-1, the MS-A2 and the MacBook Pro |

### When the network is down

- **rpi5-1** has a console on the KVM. tty1 logs in automatically as
  `jakerobb`, so it goes straight to a shell. For a desktop, run
  `sudo systemctl start lightdm`.
- **The MS-A2** has an HDMI console through the KVM, and Proxmox's own
  console gets you into each VM from there.
- **Talos nodes** have no shell at all. If the API is unreachable, the fix is
  usually a power cycle: the control-plane Pis are PoE-powered from the rack
  switch, so cycling their switch port in UniFi does it.
