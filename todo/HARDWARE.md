# HARDWARE

This document enumerates my hardware plans.

## Upcoming

### Additional K8s nodes

* I have an M5 Ultra Mac Studio with 96GB of RAM on order; it should arrive in November. I plan to run a Talos worker in
  a VM on this machine. It becomes `talos-worker-4`.

### Left over from the jump box swap (done 2026-10-06)

The swap itself is finished; see [`../docs/jump-box-swap.md`](../docs/jump-box-swap.md) and [`DONE.md`](DONE.md).

* Remove the `compose-deploy.py` cron entry once no Compose services remain other than Unbound (or keep it, if
  Unbound's Compose config should still auto-deploy).
* Confirm the Proxmox config backup lands on the new rpi5-1 at its next 03:00 run
  (`~pve-backup/backups/proxmox/`, [`../docs/proxmox-config-backup.md`](../docs/proxmox-config-backup.md)). Delete this
  item once it has.
* Reconnect the Comet X KVM's USB cable to the new rpi5-1 (the old one had two USB cables, the UPS and the KVM; only
  the UPS was moved). Without it the KVM has no keyboard/mouse path to the jump box. Or decide you don't need it.
* Optional: the UPS plan from the swap checklist was to move its USB cable to the worker and run `nut-upsd` in the
  cluster pinned to that node, with the jump box's `nut-monitor.service` as a network client. The swap kept the UPS on
  the jump box with Compose's `nut-upsd` instead, and there are no UPS-triggered shutdowns planned
  (the generator and solid-state storage cover outages), so this is only worth doing if the jump box's Compose stack
  goes away.

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
