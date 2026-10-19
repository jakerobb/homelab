# NAS purchase: DIY build

The TrueNAS/HexOS VM on the MS-A2 is temporary; the plan is a dedicated rack NAS (see
[`../HARDWARE.md`](../HARDWARE.md)). This document is the **build-it-yourself** option: a full parts list with
prices, captured on 2026-10-12, for a TrueNAS box that fits the rack's depth limit (≤480 mm), keeps iSCSI PVs on a
mirrored NVMe pool, and adds ECC, IPMI and dual SFP+.

It is a reference for comparing against the off-the-shelf options in [README.md](README.md), not a shopping list to act on today. Nothing here has been narrowed down on purpose: the open questions and unverified
items are kept so the decision can be revisited with fresh prices. HDDs are deliberately left off the list; they are
needed regardless of which box is chosen.

Prices are as of 2026-10-12. "Listing" means a current listing was seen; "est." means an estimate because no
trustworthy price could be found. Memory and drive prices in particular are volatile in 2026; re-check before
buying.

## The chassis problem

No 2U case under 480 mm with an integrated 8-bay hot-swap backplane turned up. The ones that were checked are all
deeper:

* The Rosewill RSV-H208 (8 bays with an SFF-8643 backplane) lists no depth, and 2U 8-bays usually run 550-650 mm.
* The Supermicro 813M series is 503 mm with 4 bays, in 1U.
* The iStarUSA D-260HN is 525 mm.
* The Chenbro RM252 is 450 mm but has 2.5" bays only.
* Sliger's short 2U cases are 13-15" deep but have no real hot-swap 3.5" backplane.

The workable route is a short chassis plus hot-swap cages: the **Chenbro RM24200** (430 × 457 × 88 mm, micro-ATX, two
5.25" bays, 4 low-profile slots) with **two 3-in-2 hot-swap cages** in the 5.25" bays. That gives six real hot-swap
3.5" bays at 457 mm. The cages are sold separately, so the sheet below prices them.

## Purchase sheet

| Part | Pick | Price | Basis |
|---|---|---|---|
| Chassis | Chenbro RM24200 (2U, 457 mm, mATX) | $160-300 | One US listing at $159 (out of stock), EU resellers ~€380 |
| Rails | Chenbro slide-rail kit | $50-80 | est. |
| Hot-swap cages | 2× 3-in-2 5.25" cages (iStarUSA/Icy Dock class) | $100-180 | est. |
| Motherboard | ASRock Rack B650D4U (mATX, IPMI, ECC UDIMM, 2× M.2, 4× SATA, 2× i210 GbE) | $295-360 | Listing |
| CPU | AMD EPYC 4244P (6c, 65 W, officially ECC-validated); Ryzen 5 7600 is ~$30-50 cheaper and works with ECC on this board but isn't AMD-validated | $230-255 | Listing |
| CPU cooler | Noctua NH-L9a-AM5 (37 mm; fits 2U) | ~$50 | est. |
| RAM | **64GB (2×32GB) ECC DDR5 UDIMM** | **$890-1,850** | Listings are inconsistent; see below |
| NIC | Intel X710-DA2 (dual SFP+, low-profile) | $50-190 | Mostly refurb/OEM listings |
| HBA | LSI 9300-8i (IT mode), low-profile | $40-180 | Listing |
| Breakout cables | 2× SFF-8643 → 4× SATA | $32-48 | Listing |
| DAC cables | 2× SFP+ DAC to the aggregation switch | $30-50 | est. |
| PSU | 300-450 W, form factor depends on chassis | $90-120 | est. |
| Fans | 3× Noctua NF-A8 PWM (if the chassis uses 80 mm) | ~$55 | est. |
| Boot | 2× small SATA SSD on the onboard ports | $60-100 | est. |
| NVMe | 1× 2TB TLC with DRAM to mirror the existing T500 | $200-300 | est. |
| **Total, no HDDs** | | **≈ $2,350-4,100** | |

The six cage bays are for HDDs, which are not priced here.

### Other case options

SilverStone RM21-308

## Where the money goes

* **ECC DDR5 is the swing factor.** 32GB UDIMMs were seen at $445 (Micron, undated), $880-930 (A-Tech) and about
  $1,035 (Kingston). That is a $1,000 spread for the same capacity.
    * Buying one 32GB stick now and adding a second later takes $450-900 off today's bill. The board has 4 slots, and
      single channel is fine for a NAS.
    * With one stick the total is about $1,900-3,200, HDDs excluded.

## Existing NVMe drives

* **T500 2TB: reuse, at least to start.** It's TLC with DRAM, so it's a good mirror member.
    * Pairing it with a PLP drive keeps most of the safety: a sync write is acknowledged only after both sides flush,
      and if the T500 loses in-flight data or corrupts older data in a power loss, ZFS detects it by checksum and
      repairs it from the PLP side.
    * It does not keep the speed: sync-write latency is set by the slower device, so the T500 is the bottleneck.
    * It can be swapped for a second PLP drive later with `zpool replace`, with no data movement.
    * With only two M.2 slots there is no spare slot for the T500 as a boot or cache device. If both slots hold PLP
      drives, the T500 is better used elsewhere.
* **P3 Plus 4TB: don't use for iSCSI.** It's QLC with no DRAM, which is the wrong profile for small sync writes. Keep
  it as a replication or cold target.
* **Capacity check.** The current pool is 4TB and a T500 mirror is 2TB, so confirm actual usage is under 2TB. If it
  isn't, the alternative is a matched 4TB QLC pair, which isn't recommended for iSCSI.
* **The SLOG goes away.** Mirrored NVMe takes sync writes directly, so the 2TB drive doesn't need a SLOG role.
  Neither drive has PLP. On a UPS plus generator that's an acceptable risk, but it is a risk.

## Risks and unverified items

1. **Chassis PSU type and fan size.** Unconfirmed. If the PSU is SFX or a 2U mini-redundant form, the PSU line
   changes.
2. **PCIe slot layout.** The board has one x16, one x4 (maybe), and one x1. The X710 is an x8 card, so it needs the
   x16 slot or an open-ended x4 slot. The HBA needs the other. Check the board manual before ordering.
3. **M.2 length.** It isn't confirmed that the M.2 slots take 22110. Plain 2280 is fine for the T500.
4. **ASRock Rack ECC memory list.** Check that the specific UDIMM part is on the board's QVL.
5. **X710 SFP+ coding.** The i40e driver can refuse non-Intel modules, which can be worked around, so DACs from a
   known-good vendor save grief.
6. **Cooling.** The 65 W CPU on a 37 mm cooler in 2U may run warm under load. A 2U server cooler is the fallback.

## Is it worth it?

This build gives ECC, IPMI, a real HBA, two SFP+ ports and room to grow, in a 457 mm 2U. It's also more work, and it
costs well above the Terramaster U8-500 Plus, mostly because of RAM. If ECC isn't critical, the U8-500 Plus at 384 mm
is still the lower-effort path. What decides it is whether ECC and IPMI are worth roughly $1,000+ more plus the
assembly.

## Sources

* [Chenbro RM24200 listing](https://www.connection.com/product/chenbro-chassis-rm24100-2u-rm-micro-atx-2x5.25-bays-1x3.5-2x2.5-bays-4xlp-slots/rm24200-l/15639886)
* [Chenbro RM24200 dimensions](https://www.pccomponentes.com/caja-de-rack-chenbro-rm24200-2u-430-mm-x-457-mm-x-88-mm)
* [Chenbro RM252 (2.5" bays)](https://www.chenbro.com/en-US/product/RackmountChassis/item/RM25204RIO)
* [Supermicro SC813MFTQ](https://www.supermicro.com/zh_cn/products/chassis/1U/813/SC813MFTQ-R606CB)
* [iStarUSA D-260HN datasheet](https://newsite.istarusa.com/assets/pdf/datasheet/D-260HN_datasheet.pdf)
* [Sliger CX2137b](https://www.sliger.com/products/rackmount/2u/cx2137b/)
* [ASRock Rack B650D4U (SHI)](https://www.shi.com/product/45649261/ASRock-Rack-B650D4U-Motherboard)
* [ECC UDIMM price bands, Oct 2026](https://computingforgeeks.com/best-ecc-udimm-kits/)
* [Intel X710-DA2 listings](https://www.shi.com/product/33204890/Intel-Ethernet-Converged-Network-Adapter-X710-DA2)
* [EPYC 4244P listing](https://ebay.com/itm/305816615779)

# Alternative build

⚙️ Components Selected So Far

• Chassis: Athena Power RM-2U208G (2U, 8-Bay Front Hot-Swap, 430mm short depth).
• Motherboard: ASUS Pro WS W680M-ACE SE (Micro-ATX, Intel W680 Workstation Chipset with onboard ASpeed AST2600 IPMI/BMC
remote management).
• Host Bus Adapter (HBA): LSI 9300-8i (PCIe 3.0 x8, flashed to IT Mode for raw ZFS disk access).
• Internal Data Cabling: Two SFF-8643 to SFF-8643 (Mini-SAS HD to Mini-SAS HD) internal server cables to bridge the HBA
directly to the Athena front drive backplane.
• Expansion Connectivity: Two Flexible PCIe 90-degree Riser Ribbon Cables (allows mounting the LSI HBA and your SFP+ NIC
horizontally into the 2U rear chassis tracks).
• Network Interface Card (NIC): A generic Dual-Port SFP+ PCIe Network Interface Card (e.g., Intel X520-DA2 or Mellanox
ConnectX-3/4) configured with a low-profile bracket.

🔍 Missing Components Needed to Complete the Machine

To turn this into a fully operational, bootable server, you still need to select the following five hardware categories:

1. The Processor (CPU)

Because compute and app workloads (like Plex) live on your Kubernetes cluster, your NAS processor only needs to handle
basic ZFS pool calculations. It will spend most of its life idling.
• What to buy: An entry-level, non-K 12th, 13th, or 14th Gen Intel Core i3 or i5 processor (e.g., Intel Core i3-12100 or
i5-13400). These chips pull very little power at idle but provide massive bandwidth for storage throughput.
• Note: Avoid "F" suffix chips (e.g., i5-13400F) just in case you ever need to tap into local diagnostics, but standard
consumer chips will unlock full ECC features once socketed into your W680 motherboard.

2. System Memory (RAM)

True ZFS data protection requires true side-band server memory.
• What to buy: DDR5 ECC Unbuffered (ECC UDIMM) modules. Ensure you do not buy standard desktop DDR5, nor enterprise
Registered ECC (RDIMM) memory, as neither will boot.
• Capacity: Aim for 32GB or 64GB (e.g., a 2x16GB or 2x32GB kit) to give your Kubernetes iSCSI block storage plenty of
high-speed caching headroom.

3. Power Supply Unit (PSU)

Because the Athena case is a short-depth 2U layout, standard consumer ATX power supplies will not physically fit.
• What to buy: A 1U Server Power Supply or a Flex-ATX Power Supply.
• Specs to look for: Look for a unit rated between 400W and 500W to comfortably cover the spin-up power surge of 8
mechanical hard drives. High-efficiency ratings (80 Plus Gold or Platinum) are critical because server power supplies
use tiny 40mm fans; higher efficiency means less wasted heat and a much quieter fan curve inside your home.

4. OS Boot Drives

TrueNAS SCALE takes over its entire installation medium, meaning you cannot store personal data on the boot drive.
• What to buy: One or two small, cheap M.2 NVMe SSDs (128GB to 256GB is more than enough).
• Why two? TrueNAS allows you to natively mirror your boot drive across two physical M.2 slots during installation. If
one cheap boot SSD dies down the road, your server stays online without interruption.

5. CPU Cooling (Low Profile)

Standard Intel stock coolers are too tall to fit underneath the metal lid of a 2U rack chassis.
• What to buy: A low-profile CPU cooler with a maximum height clearance of under 65mm (such as the Noctua NH-L9i or
Thermalright AXP90-X47).
