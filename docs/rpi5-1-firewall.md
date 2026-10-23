# rpi5-1 host firewall

rpi5-1 has its own nftables table, `inet homelab_fw`, that decides who on the network can reach the jump box. Docker's
iptables-nft tables are left alone, and the ruleset never flushes anything. The files live in
[`scripts/rpi5-1-firewall/`](../scripts/rpi5-1-firewall/): the ruleset (`homelab-fw.nft`), a systemd unit that loads it
at boot (`homelab-fw.service`) and `install.sh`. It isn't deployed by the Compose auto-deploy; install it by hand
(below).

## What it allows

| What | Port | From |
| --- | --- | --- |
| SSH | TCP 22 | VPN VLAN (`192.168.3.0/24`) and Trusted (`192.168.92.0/24`), plus their IPv6 ULA `/64`s |
| DNS (Unbound) | TCP/UDP 53 | Any `192.168.0.0/16` and the ULA `fd3d:b17d:9f8e::/48` |
| NUT (UPS data) | TCP 3493 | The worker nodes' IPs (`192.168.102.31`, `.32`, `.34`, `.35`), IPv4 only |
| UniFi syslog and Talos kernel logs into Vector | UDP 514 and 5140 | Server and Management (`192.168.0.0/24`) VLANs |

It also allows replies to anything rpi5-1 started, loopback, traffic from Docker's own bridges, ICMP and ICMPv6, and
DHCP replies. Nothing else is allowed in.

The IPv4 ports Docker publishes (NUT and Vector) never reach the normal input rules: Docker DNATs them in prerouting and
forwards them to the container. A separate `published` chain, hooked ahead of Docker's own forward chain, covers them.
Docker's IPv6 listeners and host-local connections reach the containers through `docker-proxy`, which is an ordinary
input path, so the input chain has the same port rules too.

Who actually talks to these ports (checked 2026-10-22):

- **Syslog:** the gateway, which sends from its Server VLAN address `192.168.102.1`, and the living room AP at
  `192.168.0.50`. Talos nodes send to 5140 only when they boot.
- **NUT:** the `nut-exporter` pod (nut-relay), on `talos-worker-1`, so the traffic arrives from the node's IP. The pod can
  reschedule onto any worker, so every worker is allowed. Control planes don't run it.

## Adding a node

**Add every new worker's IP to `nut_v4` in `homelab-fw.nft`** (and remove a decommissioned one), then rerun
`sudo ./install.sh` on rpi5-1. If you skip it, the `nut-exporter` pod stops reading the UPS the first time it
reschedules onto the new node, and (once enforcing) the UPS metrics go quiet without an obvious error. A node that
sends Talos kernel logs is allowed by the Server VLAN syslog rule already, so that part needs nothing. The same goes for
a new control plane: it never runs the exporter, so it doesn't need a NUT entry.

## Log-only mode, then enforcing

The firewall starts in log-only mode: anything no rule allows is logged and then allowed anyway. Enforcing mode drops it
instead. The only difference is the contents of `/etc/homelab-fw/mode.nft`, which `install.sh` writes.

```bash
sudo ./install.sh log       # log what would be dropped, drop nothing (default)
sudo ./install.sh enforce   # drop whatever the rules don't allow
```

On rpi5-1, from `~/dev/homelab/scripts/rpi5-1-firewall`. Rerun it after changing the ruleset; it's atomic and checks
the syntax first. See what would be dropped, and whether the allow rules are being used (the counters):

```bash
sudo journalctl -k | grep homelab-fw
sudo nft list table inet homelab_fw
```

Expect UniFi's discovery broadcast to UDP 10001 from `192.168.102.1`, which is harmless. Anything else that's
legitimate needs a rule before enforcing.

**Recovering from a mistake:** if enforcing locks you out, use the console and run `sudo nft delete table inet homelab_fw`,
or `sudo ./install.sh log`. The table isn't saved anywhere except the unit, so a reboot with the unit disabled
(`systemctl disable homelab-fw`) also clears it.
