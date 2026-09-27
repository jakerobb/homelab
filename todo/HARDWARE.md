# HARDWARE

This document enumerates my hardware plans.

## Upcoming

### Additional K8s nodes

* I have an M5 Ultra Mac Studio with 96GB of RAM on order; it should arrive in November. I plan to run a Talos worker in
  a VM on this machine.
* Once all Compose workloads have been migrated off, rpi5-1 (a 16GB Raspberry Pi 5) will be converted into a Talos
  worker node.
    * Before I can do this, I'll need to designate a new "jump box." My current thought is that I should get another 4GB
      Raspberry Pi 5, like the ones I'm using for the control plane. Then I can just move rpi5-1's SSD over, and it can
      mostly just work -- it wouldn't even need a new hostname. The 16GB Pi then gets a new (256GB is plenty) SSD for
      Talos; its EPHEMERAL partition only holds images, logs and emptyDirs, since PVs live on iSCSI/NFS.
    * The new jump box's role: jump box (talosctl/kubectl/helm/terraform + secrets), the GHA runner for Terraform, host
      cron jobs, and a secondary Unbound. Current usage is ~55G of real disk and well under 4GB RAM once Compose is gone.

#### Jump box swap checklist

Prerequisite: every Compose workload is migrated to k8s, except Unbound (see below).

* **Before the swap**
    * DNS: Unbound runs in both places. In k8s, multiple replicas behind a cluster VIP (UDP _and_ TCP 53, via Cilium LB
      IPAM/L2 announcements or hostNetwork). On the jump box, it stays in Compose. DHCP hands out the cluster VIP first
      and the jump box second.
        * Clients don't reliably fail over in list order (many query both, or rotate), so both must serve identical
          answers. Generate `local.conf` from a single source rather than maintaining two copies.
        * Talos nodes' own `machine.network.nameservers` should be the jump box + an upstream resolver, **not** the
          cluster VIP. Nodes need DNS to pull images before the Unbound pods exist.
    * UPS: the CyberPower PR1500's USB cable moves to the 16GB Pi (as a Talos worker). Run `nut-upsd` in k8s, pinned to
      that node, with USB device access. The worker needs a NUT client (Talos system extension) for its own clean
      shutdown, and the jump box's `nut-monitor.service` becomes a network client of the in-cluster `nut-upsd`.
    * Decide how the jump box's own logs/metrics get shipped once Compose's Vector/telegraf are gone (currently Vector
      ships rpi5-1's host logs to SigNoz via OTLP).
* **Hardware swap**
    * Set the new Pi's EEPROM boot order to NVMe before moving the SSD over.
    * Move the UniFi DHCP reservation for `.2` (and the `fd3d:b17d:9f8e:102::2` IPv6 address) to the new Pi's MAC.
    * Give the 16GB Pi a new hostname and IP for its life as a Talos worker.
* **Host cleanup on the jump box**
    * Drop the wlan0 interface (`.3`) and `wlan0-watchdog.{service,timer}`. They were only a DNS-reliability fallback
      for a flaky wired link; dual-homed Unbound makes them unnecessary.
    * Remove CUPS (`cups`, `cups-browsed`).
    * Boot to console (`sudo systemctl set-default multi-user.target`); saves ~550MB of desktop (labwc, pcmanfm,
      panel, portals, pipewire, gvfs). When the GUI is needed: `sudo systemctl start lightdm`, plus
      `sudo systemctl start wayvnc` for remote access. Keep wayvnc installed but disabled.
    * Remove the `compose-deploy.py` cron entry once no Compose services remain other than Unbound (or keep it, if
      Unbound's Compose config should still auto-deploy).
    * Clean out one-off files in `~` (`from-bwmbp`, `Weirdness.zip`, `.MOV`s, `nvme-test.tmp`; ~31G).
* **Verify these still work after the swap** (they come along on the SSD, but are easy to forget)
    * Cron: `etcd-snapshot-backup.sh` (daily), `unifi-gc-report.py` (hourly + daily), `msmtpq` queue flush (sendmail
      relay for all cron alert email), `unattended-upgrades/check.sh` for this host and Proxmox (via SSH).
    * GHA runner: `actions.runner.jakerobb-homelab.rpi5-1.service`.
    * Proxmox config backups still land in `~pve-backup/backups/proxmox/`
      ([`../docs/proxmox-config-backup.md`](../docs/proxmox-config-backup.md)).
    * kubeconfig, talosconfig, `~/bin/secrets`, msmtp config, SSH key to Proxmox.
    * Brevo and the Cloudflare Access filter allowlist the public IP. It's the same WAN, so there's nothing to change
      unless jump box egress is ever routed differently.

## Todo items

* Run two CAT6 cables from the rack switch to the living room AV cupboard, replacing existing uplinks from the Pro XG 8
  PoE to the Living Room AV switch (USW-Flex) and the Living Room AP (U7 Pro XGS).
* Choose locations outside the rack to mount the Zigbee and Z-Wave gateways, and run CAT6 cables from the rack to those
  locations. (Freeing up space on the crowded rack shelf!)
* Move the RPi mount to the back rail to free up space in the rack
* Move the PDU Pro to the back rail to free up space in the rack.
    * This will require cutting power to _everything_. Need to figure out how to prep for that.
* Shrink the MS-A2's integrated-graphics memory reservation in the BIOS, to give Proxmox VMs ~1.5 GiB more RAM.
  The firmware reserves 2 GiB of the 32 GiB for the Radeon iGPU (`0x7b8000000–0x837ffffff` in the boot log), which is
  most of why Proxmox only sees 29.1 GiB. Needs a monitor and keyboard on the MS-A2. The setting is usually
  **Advanced → AMD CBS → NBIO Common Options → GFX Configuration → UMA Frame Buffer Size** (BIOS is AMI 1.03, 12/2025);
  set it to 512M or the smallest option offered. Don't disable the iGPU entirely: the HDMI console is the only way in
  if networking breaks. It needs a Proxmox reboot, so pair it with the next Proxmox kernel update and follow the
  post-reboot checks in [`../docs/proxmox-os-updates.md`](../docs/proxmox-os-updates.md). Afterwards, `free -m` on
  the host should show about 1.5 GiB more total memory.
* Figure out why the WLED controller is offline. Did a power connection from the Meanwell PSU come loose?
* Learn how to connect multiple LED strips together (have to solder _under_ the clear rubber diffusion cover somehow)
  and then connect all the strips

## Future acquisitions

* Additional 24-port keystone patch panel (I already have 28 switch ports, so the current panel is already maxed out).
    * This is blocked until I move at least one thing to the back rail.
* UniFi USW-Pro-Aggregation, proving more SFP+ ports as well as some SFP28 which can provide 25GbE connectivity to the
  Garage Mahal once we build that
    * Maybe a USW-Aggregation as a stepping stone. Wish there was something in between! Something like 12 SFP+ and 2-4
      SFP28 would be great.
