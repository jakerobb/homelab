# homelab

## Cluster access

The Talos jump box (`rpi5-1.lan`, `.2` on the Server VLAN) holds `talosctl`,
`kubectl`/`helm` access to the cluster, and cluster secrets. SSH in as
`jakerobb@rpi5-1.lan` — key auth is already set up, no need to ask before
connecting. This is also where `terraform plan`/`apply` and similar
cluster-admin actions get run from. Cilium's ongoing lifecycle is managed
via ArgoCD, not manual `helm upgrade` — see [`talos/README.md`](talos/README.md).

## Making changes

Before making any change:
1. Make sure the local repo is clean and up to date. 
   * Feel free to pull in latest. If there are uncommitted changes (staged or otherwise), check with me before you proceed.
2. Create a suitably named branch
