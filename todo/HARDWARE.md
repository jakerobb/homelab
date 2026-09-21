# HARDWARE

This document enumerates my hardware plans.

## Upcoming

### Additional K8s nodes

* I have a 2018 15" Macbook Pro with 32GB of RAM sitting idle with a connection to the Server VLAN. I plan to run a
  Talos worker in a VM on this machine.
* I have an M5 Ultra Mac Studio with 96GB of RAM on order; it should arrive in November. I plan to run a Talos worker in
  a VM on this machine.
* Once all workloads have been migrated off, rpi5-1 (a 16GB Raspberry Pi 5) will be converted into a Talos worker node.
    * Before I can do this, I'll need to designate a new "jump box." My current thought is that I should get another 4GB
      Raspberry Pi 5, like the ones I'm using for the control plane. Then I can just move rpi5-1's SSD over, and it can
      just work without any configuration effort -- it wouldn't even need a new hostname.

## Todo items

* Run two CAT6 cables from the rack switch to the living room AV cupboard, replacing existing uplinks from the Pro XG 8
  PoE to the Living Room AV switch (USW-Flex) and the Living Room AP (U7 Pro XGS).
* Choose locations outside the rack to mount the Zigbee and Z-Wave gateways, and run CAT6 cables from the rack to those
  locations. (Freeing up space on the crowded rack shelf!)
* Move the RPi mount to the back rail to free up space in the rack
    * Reorder the cables from the rack switch to the Talos controller nodes; they are currently in a weird order (port
      9 -> cp3, port 10 -> cp1, port 11 -> cp2).
* Move the PDU Pro to the back rail to free up space in the rack.
    * This will require cutting power to _everything_. Need to figure out how to prep for that.
* Figure out why the WLED controller is offline. Did a power connection from the Meanwell PSU come loose?

## Future acquisitions

* Additional 24-port keystone patch panel (I already have 28 switch ports, so the current panel is already maxed out).
    * This is blocked until I move at least one thing to the back rail.
* UniFi USW-Pro-Aggregation, proving more SFP+ ports as well as some SFP28 which can provide 25GbE connectivity to the
  Garage Mahal once we build that
    * Maybe a USW-Aggregation as a stepping stone. Wish there was something in between! Something like 12 SFP+ and 2-4
      SFP28 would be great.
