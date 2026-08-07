# suniv MUSB: what the hardware actually is

Reference notes for the F1C100s/F1C200s USB-OTG (MUSB) block, assembled
2026-08-07 from the vendor manuals, Allwinner's own BSP driver, the Mentor
MUSBMHDRC programmer's guide, and measurements on our board.

Written because most of this is contradictory across sources and expensive to
re-derive. Each claim below says where it comes from and whether it is verified.

## 1. The endpoint / FIFO-RAM variants

The F1C200s and F1C600 manuals describe the SAME USB-OTG block -- section
numbering identical, most paragraphs verbatim identical, including the BUS_SEL
wording -- but give **different configuration numbers**. Same IP, different
synthesis straps.

| | F1C200s UM V1.2 | F1C600 UM V1.0 |
| --- | --- | --- |
| 7.7.2 Feature | "up to 6 User-Configurable Endpoints **(TX Endpoint 1/2/3 and RX Endpoint 1/2/3)**" | "up to **8** User-Configurable Endpoints" (no breakdown given) |
| 7.7.3.1 DMA | "TX Endpoints **1-3** and RX Endpoints **1-3**" | "TX Endpoints **1-4** and RX Endpoints **1-4**" |
| 7.7.3.2 RAM | "**2K** byte Single Port RAM ... 2K bytes RAM with 32-bit width" | "**4K** byte Single Port RAM ... 4K bytes RAM with 32-bit width" |

Each manual is internally consistent (F1C200s: 6 = 3+3; F1C600: 8 = 4+4).

### What the software declares

| source | endpoints | FIFO RAM |
| --- | --- | --- |
| Linux v6.18 `drivers/usb/musb/sunxi.c`, `suniv_f1c100s_musb_cfg` | `hdrc_config_5eps` = ep1-5 TX+RX | `SUNXI_MUSB_RAM_BITS 11` -> `1 << (11+2)` = **8192 B** |
| Linux, `hdrc_config_4eps` (H3/V3s only) | ep1-4 TX+RX | same 8192 B |
| U-Boot `drivers/usb/musb-new/sunxi.c` | 5-ep generic, 4-ep H3 | ram_bits 11 |
| our patch 0022 | ep1-3 TX+RX (`hdrc_config_3eps`) | ram_bits 11 (unchanged) |

**Mainline's 5 endpoints matches neither documented variant.** It is plausibly
correct for some other sunxi part and was applied to suniv unchecked. U-Boot has
**no suniv entry at all** (`sunxi_musb_ids[]` lists only sun4i-a10, sun6i-a31,
sun8i-a33, sun8i-h3), so it is not evidence either way.

`ram_bits = 11` declares 8 KB, which exceeds BOTH documented variants (2 KB and
4 KB). Note musb only bounds allocation against the DECLARED size
(`musb_core.c`: `offset + maxpacket > 1 << (ram_bits + 2)` -> `-EMSGSIZE`), so
over-declaring produces no error -- the hardware would simply alias.
**UNVERIFIED, and the counter-evidence is strong**: a full CarPlay session (mux
+ NCM + iAP2 + H.264) runs clean in PIO mode on the 3-endpoint layout, which
allocates 3136 B (ep0 64 + 6 x 512). Aliasing would corrupt PIO too. So either
"2K ... with 32-bit width" means 2K *words* (= 8 KB, reconciling with
ram_bits 11), or the layout happens not to collide.

### How to settle it empirically

Allwinner removed the registers that would answer this. The Mentor PSPG defines
exactly what we need:

- **EPINFO**, address 78h: D3-D0 `TxEndPoints`, D7-D4 `RxEndPoints` -- "the
  number of TX/Rx endpoints implemented in the design"
- **RAMINFO**, address 79h: D3-D0 `RamBits` ("width of the RAM address bus"),
  D7-D4 `DMAChans`

but the sunxi register map is **relocated and truncated** (see section 3), and
neither register is mapped. The practical test is behavioural: program a 4th
endpoint pair and see whether transfers on it silently vanish.

## 2. BUS_SEL: why CPU and DMA cannot share the FIFO

`VEND0` (a.k.a. `USB_EFR`), offset **0x43** in the sunxi register window:

```
bit 0      BUS_SEL   0 = FIFO accessed by CPU (PIO) over AHB
                     1 = FIFO accessed by the dedicated DMA engine
bits [1..] DRQ_SEL   routes ONE endpoint's DRQ onto the single usb_drq line
```

Confirmed against Allwinner's own BSP (`drivers/usb/sunxi_usb/include/sunxi_usb_bsp.h`):

```c
#define USBC_BP_VEND0_DRQ_SEL   1
#define USBC_BP_VEND0_BUS_SEL   0
#define USBC_IO_TYPE_PIO        0
#define USBC_IO_TYPE_DMA        1
```

Both manuals state, verbatim:

> "When BUS_SEL is '1' ... Endpoints' FIFO is accessed by dedicated DMA engine.
> **Any operation of FIFO ports by CPU host is unpredictable.**"

And `USBC_SelectBus()` in the vendor's `usbc/usbc.c` carries the decisive comment:

> "in 1667 1673 and later ic, FIFO_BUS_SEL bit (bit24 of reg0x40 for
> host/device) is fixed to 1, **the hw guarantee that it's ok for
> cpu/inner_dma/outer_dma transfer**"

i.e. **hardware CPU/DMA arbitration exists only on later ICs.** On those,
Allwinner pin BUS_SEL=1 permanently. On earlier parts -- ours -- BUS_SEL is
toggled per transfer and there is no arbitration. This is the authoritative
statement of the failure mode, from the vendor.

There is also only ONE `usb_drq` line: F1C200s 7.7.3.1 maps `DMA_REQ[0..2]` to
TX EP1-3 and `DMA_REQ[4..6]` to RX EP1-3, with DRQ_SEL choosing which is routed.
So at most one endpoint can use DMA at a time.

### How the vendor avoids the collision (and why we cannot copy it)

`drivers/usb/sunxi_usb/udc/sunxi_udc.c`:

- DMA is used only for LARGE transfers: `is_sunxi_udc_dma_capable()` requires
  `big_req()` (more than one max-packet) and a non-zero endpoint. Small
  transfers and ep0 are always PIO.
- It keeps a **global** `static __u32 dma_working` plus a per-endpoint
  `ep->dma_working`.

But grepping every read of that flag shows the guards only ever test
`ep->dma_working` (lines 552, 728, 1389); the **global one is written and never
read as a guard** -- it appears only in a debug print. So the vendor declares
cross-endpoint ownership and does not enforce it. That is survivable in a
device/UDC driver with one active bulk stream. It is NOT safe for a USB **host**
running two endpoints of one device concurrently, which is our case.

## 3. The register map is relocated and truncated

`drivers/usb/musb/sunxi.c` translates generic MUSB offsets to Allwinner ones:

```
POWER 0x40  DEVCTL 0x41  INDEX 0x42  VEND0 0x43  INTRTX 0x44  INTRRX 0x46
INTRTXE 0x48  INTRRXE 0x4a  INTRUSB 0x4c  INTRUSBE 0x50  FRAME 0x54
TXFIFOSZ 0x90  TXFIFOADD 0x92  RXFIFOSZ 0x94  RXFIFOADD 0x96
FADDR/TXFUNCADDR 0x98 ...  CONFIGDATA 0xC0
```

Anything not in that switch hits `default:` -> `dev_err("Error unknown readb
offset")` and returns 0. `TESTMODE` returns a hardcoded 0 ("No testmode on
sunxi"); ULPI warns as absent. This matches the community observation that the
F1C100s "register offsets are modified, not the standard musb register layout".

Critically, suniv sets `no_configdata`, so **CONFIGDATA returns a hardcoded
0xde** rather than reading silicon. Decoded: SoftConnect, **DynFIFO sizing**,
high-bandwidth TX and RX, multipoint TX and RX, 8-bit UTMI, little-endian. So on
this SoC the driver ASSUMES its capability data -- which is exactly why the
endpoint count and RAM size have to come from a hand-written `fifo_cfg` table,
and why a wrong table goes unnoticed.

## 4. Measured on our board (hardware-verified)

- With MUSB DMA enabled, bulk-OUT transfers complete successfully while the
  device never receives them. The iPhone reports usbmux sequence gaps
  ("Expected 16 received 18"). usbmux has no retransmission, so one drop
  desyncs the link permanently.
- Booting with `musb_hdrc.use_dma=0` (no DMA controller created;
  `musb_core.c` gates `musb_dma_controller_create()` on it) eliminates the loss
  entirely and a complete wired CarPlay session works: carkit TLS iAP2 channel
  up, iAP2 link NORMAL, MFi auth, video.
- The FIFO layout is identical in both modes, so **FIFO/endpoint configuration
  is not the cause** of the loss.
- Same app binary runs wired CarPlay fine on a Raspberry Pi 5 (xHCI, no shared
  datapath).

## 5. Sources, including the dead ends

Worth recording so they are not re-checked:

- **Mentor MUSBMHDRC PSPG** (`musbmhdrc_pspgUSB.pdf`, 176 pp) -- authoritative
  for the IP. EPINFO/RAMINFO at 78h/79h; DMA sections 16, 17, 20.5.2.
- **F1C200s UM V1.2** and **F1C600 UM V1.0** -- the variant table above.
- **Allwinner BSP** `allwinner-zh/linux-3.4-sunxi`,
  `drivers/usb/sunxi_usb/{usbc/usbc.c, include/sunxi_usb_bsp.h, udc/sunxi_udc.c}`
  -- the BUS_SEL bit definitions and the "1667 1673 and later ic" comment. The
  single most useful source after the PSPG.
- *Dead ends:* `catphish/allwinner-bare-metal` `usb.c`/`usb.h` are OHCI/EHCI for
  the other USB controller, nothing about MUSB. The EEVblog Ghidra thread has no
  register detail and points back at the PSPG. The cnblogs F1C100s USB post is a
  driver-integration walkthrough with no hardware content. The iipcb bare-metal
  port post is useful only for naming the vendor BSP.
