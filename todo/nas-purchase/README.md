# Network-attached storage (NAS) plans

Running TrueNAS as a VM on the MS-A2 is temporary, until I can afford a real NAS. I have not yet determined what path I 
will take, but I have these requirements:

* Runs TrueNAS
* Upgradeable RAM to at least 64GB
* Two 10GbE (or preferably SFP+ or SFP28) interfaces capable of LACP
* Hot-swappable drive bays
* Rack-mountable form factor (1-3U) with a case no deeper than 480mm
* Support for 2+ NVMe drives (gen3 or better) for cache or just dedicated fast volumes.
* 4 HDD bays
* SATA or SAS connectivity -- no port-multipliers

And these nice-to-haves:

* 8-12 HDD bays
* ECC RAM
* Hardware warranty coverage unaffected by use of TrueNAS (software support is not needed)
* A PCIe slot

The NAS will serve multiple purposes:

* Serving Kubernetes persistent volumes (PVs) via iSCSI
  * Fast I/O, low latency. 
  * 2-4 TB should be plenty. 
  * Likely NVMe; ideally dual sticks mirrored with power-loss protection (PLP).
* Backup and archival storage (Time machine, rsync, scp)
  * No significant performance target
  * Very large capacity - many TB
  * Likely HDD
* Media streaming (Plex/Jellyfin/*arr-style)
  * Sustained read performance at a low level
  * Very large capacity - many TB
  * Likely HDD

I could see someday having two separate NASes -- one all flash storage, and one all HDD. For now, I am assuming that
this is a single device.

## Options

### Custom, DIY build

The option that gets closest to my needs is a custom server build. I've documented that build and the parts+cost 
breakdown in [DIY.md](DIY.md).

### Off-the-shelf NAS

Prices are street prices as of 2026-10-12; where no current price could be found, the closest dated figure is given.
"Misses" lists where a product falls short of the requirements or nice-to-haves above. Anything not listed is met, or is
not confirmed by public specs (marked "unconfirmed").

#### Rackmount

| Product | Street price | Misses: requirements | Misses: nice-to-haves |
|---|---|---|---|
| **Terramaster U8-500 Plus** (2U, 384 mm, 8 bays) | $1,699.99 at TerraMaster US (sold out at last check; $1,740-2,160 elsewhere) | RJ45 10GbE only, no SFP+ (needs 10GBASE-T modules in an SFP+ switch). Bay wiring undocumented, so a port multiplier is not ruled out. | No ECC. No PCIe slot. No BMC. TrueNAS boot device undocumented. Warranty unaffected by TrueNAS per one secondary source, unconfirmed. |
| **Terramaster U4-500** (1U, 381 mm, 4 bays) | $899.99 list (sold out at last check) | RJ45 10GbE only. Bay wiring undocumented. Both M.2 slots would be needed for the NVMe mirror, leaving no boot slot. | Only 4 bays. No ECC. No PCIe slot. No BMC. |
| **Terramaster U12-500 Plus** (2U, 550 mm, 12 bays) | ~$2,099.99 (TerraMaster US sale price) | **Too deep (550 mm).** RJ45 10GbE only. Bay wiring undocumented. | No ECC. No BMC. (Has a PCIe 3.0 x2 slot and 12 bays.) |
| **iXsystems TrueNAS Mini R** (2U, 12 bays) | Under $2,000 at the 2023 launch; no current price found, so get a configurator quote | **Too deep (~533 mm / 21").** 10GbE is RJ45 by default (SFP+ card optional). Only one M.2 (boot), so 2+ NVMe needs the single PCIe x4 slot. | None of the listed ones: ECC, 12 bays, PCIe slot, IPMI and the official hardware warranty are all there. Caveats: Atom C3758 CPU, 64GB RAM ceiling. |
| **OWC Jupiter Callisto 2U** (2U, 8 bays) | $4,988 for the 16TB SSD config at launch; no diskless price found | **Far too deep (~737 mm).** 10GbE is RJ45 (QSFP+ optional). NVMe support unconfirmed. | Meets ECC, 8 bays and TrueNAS (it ships with it). Most expensive option by far. |
| **QNAP TS-h1277AXU-RP** (2U, 12 bays) | ~$5,650-5,700 (R7-32G, US resellers) | **Too deep (~511 mm).** 2× 10GBASE-T + 2× 2.5GbE, no SFP+. Runs QNAP's own OS; TrueNAS is community-installed. | Meets ECC (UDIMM support, kit ships non-ECC), 12 bays, 3× PCIe Gen4, 2× M.2 Gen5. TrueNAS use vs. QNAP hardware warranty is unclear. |
| **45HomeLab HL15** (4U, 15 bays) | ~$1,999.99 fully built (older review) | **4U exceeds the 1-3U limit.** 10GbE is an add-in card (~$400). Ships with Rocky/Houston, not TrueNAS. | Meets ECC, 15 bays, PCIe slots. |

#### Non-rackmount (tower or desktop)

These can sit on a rack shelf, but they are not rack-mountable and some are not hot-swap or lack a second 10GbE port.

| Product | Street price | Misses: requirements | Misses: nice-to-haves |
|---|---|---|---|
| **iXsystems TrueNAS Mini X+ / XL+** (tower, 5 / 8 hot-swap bays) | No current price found; a 2026 reseller quote for a Mini X+ with 32GB and a 1GbE NIC was ~$3,237 | Not rackmount. 10GbE is RJ45. 2+ NVMe unconfirmed (verify against the current datasheet). | Meets ECC, IPMI, PCIe slot and the official hardware warranty. Fewer bays on the X+ (5). |
| **Minisforum N5 Pro** (desktop, 5 hot-swap SATA bays) | ~$899-1,299, current price unconfirmed | Not rackmount. Only **one** 10GbE plus one 5GbE (a second 10GbE needs a PCIe NIC). 3× M.2 share four lanes (x2, x1, x1). Bay wiring unconfirmed. | Meets ECC (up to 96GB) and a PCIe 4.0 x4 slot. Only 5 bays. |
| **AOOSTAR WTR Max, AMD variant** (desktop, 6 SATA bays) | $659 barebones (May 2026 report) | Not rackmount. Bay hot-swap unconfirmed. Bay wiring unconfirmed. Sources disagree on whether 10GbE is SFP+ or RJ45. | Meets ECC (AMD Pro CPU), 5× M.2. No PCIe slot (OCuLink only). 6 bays. |

Of these, the **Mini X+/XL+** is the best supported by far, the **WTR Max** is the cheapest way to check most of the
boxes, and the **N5 Pro** needs an add-in NIC to reach two 10GbE ports.

#### Sources

* [TerraMaster U8-500 Plus (US store)](https://shop.terra-master.com/products/terramaster-u8-500-plus-nas-test)
* [TerraMaster U12-500 Plus specification](https://www.terra-master.com/pages/u12-500-plus-specification)
* [TerraMaster U4-500 specification](https://www.terra-master.com/pages/u4-500-specification)
* [TrueNAS Mini R launch coverage](https://www.cnx-software.com/2023/02/23/truenas-mini-r-system-truenas-core-debian-truenas-scale/)
* [TrueNAS Mini family datasheet](https://www.truenas.com/docs/files/MiniFamily3.6.pdf)
* [TrueNAS forum: Mini X+ 2026 quote](https://forums.truenas.com/t/testimonial-how-to-buy-a-truenas-mini-x-in-2026-outside-the-us/64732)
* [OWC Jupiter Callisto launch pricing](https://storagenewsletter.com/?p=136500)
* [OWC Jupiter Callisto listing](https://www.focusnordic.com/products/photo/memory-cards-storage/network-attached-storage-nas/owc-jupiter-nas-callisto-2s-ssd-2u-rack-8-drives-nas-dual-10gbe-40gbe-100gbe-qsfp-128gb-ram-16tb)
* [QNAP TS-h1277AXU-RP listing](https://esaitech.com/products/qnap-ts-h1277axu-rp-r7-32g-us-32gb-network-storage)
* [45HomeLab HL15 review](https://www.storagereview.com/review/45homelab-hl15-storage-server-review-top-shelf-homelab-kit)
* [Minisforum N5 Pro review](https://www.servethehome.com/minisforum-n5-pro-review-an-awesome-nas-platform/4/)
* [AOOSTAR WTR Max review](https://nascompares.com/review/aoostar-wtr-max-nas-review-nas-perfection/amp/)
