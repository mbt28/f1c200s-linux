# MUSB DMA for wired Android Auto — feasibility study & required changes

**Question:** use kernel MUSB DMA to offload the wired-AA USB data path on the
suniv F1C200s. **Short answer:** possible but it is a *driver port*, not a
config flag — mainline sunxi MUSB is PIO-only *by design* (the DMA hook is a
`return NULL` stub). The good news: the DMA engine it needs is the same
`sun4i-dma` (dedicated-DMA / DDMA) we already backported for SPI, and there is a
clean in-tree template (`ux500_dma.c`).

## Why bother (the payoff)

Wired AA = F1C200s as USB **host** (host mode via patch 0004) ↔ phone in AOAP
accessory mode; FastCarPlay drives the bulk IN (H.264 video) / OUT endpoints via
**libusb**. Today the kernel `musb_host` driver moves **every bulk packet by PIO**
— a CPU `memcpy` from the endpoint FIFO on the 408 MHz ARM926, the *same* core
that demuxes the stream and feeds cedrus/DEFE. DMA'ing USB→SDRAM frees those
cycles → potential wired-AA framerate/stability gain.
**Measure the PIO CPU cost during wired AA before committing** — that sizes the win.

## Current state (established from the tree)

- Config (`board/lctech/pi-f1c200s/linux.fragment`): `USB_MUSB_HDRC`,
  `USB_MUSB_SUNXI`, `USB_MUSB_DUAL_ROLE`, `PHY_SUN4I_USB`. **No DMA symbols.**
- Mainline `drivers/usb/musb/sunxi.c:322`:
  `sunxi_musb_dma_controller_create()` → **`return NULL`**. So
  `musb->dma_controller` is NULL and `musb_core`/`musb_host` always take the PIO
  path. sunxi MUSB DMA was never mainlined.
- `musb_core.c`: DMA vs PIO keys entirely off a non-NULL `dma_controller`; there
  is a `use_dma` module param (default true) for runtime disable.
- Kconfig MUSB DMA backends: INVENTRA / CPPI41 / UX500 / TUSB — **no sunxi**.
- DT binding `allwinner,sun4i-a10-musb.yaml` (suniv reuses it): **no `dmas`**.

## Hardware mechanism (F1C200s UM §7.7.3.1)

- TX EP1–3 and RX EP1–3 FIFOs are DMA-serviceable by the **external dedicated
  DMA engine** — the block `sun4i-dma` drives (already in-tree, patch 0014).
  **EP0 is always PIO.**
- `USB_EFR.BUS_SEL`: 0 = CPU/PIO FIFO access; 1 = dedicated-DMA FIFO access —
  and while 1, CPU FIFO access is "unpredictable". So per endpoint, PIO and DMA
  are **mutually exclusive** and must be switched around each transfer.
- **One** `usb_drq` line to the DMA engine, muxed by `DRQ_SEL[2:0]` across the 6
  endpoint request lines (TX EP1-3 = DMA_REQ[0..2], RX EP1-3 = DMA_REQ[4..6]).
  Only one endpoint's DRQ drives that line at a time.
- DRQ numbers: **DDMA type 0x4 = USB** (the single muxed line); **NDMA types
  0x15/0x16/0x17 = USB-EP1/2/3** (per-endpoint). → NDMA can bind a channel per
  TX endpoint; DDMA uses the muxed single USB DRQ + `DRQ_SEL`.

## Required changes

### 1. Kernel driver — a real sunxi MUSB `dma_controller` (the bulk of the work)
Replace the NULL stub with a `struct dma_controller` implementing
`channel_alloc` / `channel_release` / `channel_program` / `channel_abort` /
`channel_status`.
- **Template: `drivers/usb/musb/ux500_dma.c`** — it does exactly this over the
  generic **dmaengine** API (`dma_request_chan`, `dmaengine_slave_config`,
  `dmaengine_prep_slave_sg`, cyclic/sg completion callbacks), pulling channels
  from DT `dmas`. This is the closest precedent to what sunxi needs (both use a
  SoC dmaengine, not the Inventra internal DMA). `musb_cppi41.c` is a second
  reference.
- suniv-specific glue on top of the ux500 skeleton:
  - Set `USB_EFR.BUS_SEL=1` for the endpoint being DMA'd; restore 0 for PIO and
    for the short-packet tail.
  - Program `DRQ_SEL` to route that endpoint's request onto `usb_drq`.
  - Request a `sun4i-dma` slave channel with the USB DRQ (NDMA per-EP 0x15-0x17
    or DDMA 0x4); slave-config src/dst = endpoint FIFO phys addr ↔ SDRAM.
  - Handle MUSB **DMA mode 1** (multi-packet bulk) vs mode 0, and the classic
    **short-packet tail** (DMA the N×maxpacket body, PIO the final partial
    packet). This is the fiddly, bug-prone part and where the time goes.
- New Kconfig symbol `USB_SUNXI_DMA` (`depends on USB_MUSB_SUNXI && DMADEVICES`),
  wired into the musb `Makefile`/`Kconfig`; new `sunxi_dma.c` (or fold into
  `sunxi.c`).

### 2. Device tree — wire `dmas` to the musb node
- Add optional `dmas`/`dma-names` to `usb@1c13000` in the suniv dtsi referencing
  `&dma` with the USB DRQ(s). **Use the DDMA USB DRQ (`SUN4I_DMA_DEDICATED` 0x4),
  driver manages `DRQ_SEL`** — this keeps USB entirely on the DDMA bank, disjoint
  from SPI's NDMA bank (see risks). The per-EP NDMA DRQs (0x15-0x17) would give
  per-endpoint concurrency but at the cost of sharing SPI's 4-channel NDMA bank —
  avoid unless a measured concurrency limit forces it.
- Extend the binding YAML to allow `dmas`.
- Ship as a board patch, exactly like patch 0014 did for spi1
  (`00NN-suniv-wire-musb-dma.patch`).

### 3. Kernel config (fragment)
- Add `CONFIG_USB_SUNXI_DMA=y`. `DMADEVICES=y` / `DMA_SUN4I=y` are **already
  present** (from the SPI work). Ensure `MUSB_PIO_ONLY` stays unset.

### 4. Buffers / coherency
- usbfs already `dma_map`s libusb URB buffers; the controller must honor
  sun4i-dma **word alignment** (same constraint we hit for SPI) and cache-sync.
  libusb bulk buffers are usually page-aligned — verify, don't assume.

## Risks (significant — this is why it's not mainline)

- **MUSB DMA integration is notoriously subtle**: RX short-packet, mode-1 bulk,
  the BUS_SEL PIO/DMA mutual-exclusion, DRQ_SEL muxing under concurrent
  endpoints. Expect real on-hardware debugging, not a clean first boot.
- **Stability blast radius**: the 7.1 lockup triage already fingers MUSB deltas
  as a freeze suspect — do this on **6.6 (stable)**, isolated, with `use_dma=0`
  as the escape hatch.
- **Single `usb_drq` mux**: high-rate video-IN + audio concurrently may serialize
  on the one muxed DRQ; per-EP NDMA avoids it for TX but complicates the mapping.
- **DMA banks do NOT clash (route USB to DDMA)**: suniv has *separate* physical
  banks — **4 NDMA + 4 DDMA** pchans (`sun4i-dma`: `SUNIV_NDMA/DDMA_NR_MAX_CHANNELS
  = 4`). esp-hosted SPI uses **NDMA** (`SUN4I_DMA_NORMAL`, drq 5); route USB to
  **DDMA** (`SUN4I_DMA_DEDICATED`, USB drq 0x4) and the two **never share a
  channel**. They share only (a) AHB/SDRAM bandwidth — ample at SPI 10 Mbps +
  USB, a bandwidth question not a starvation one, and (b) the DMA-controller
  clock gate/reset (CLK_BUS_DMA/RST_BUS_DMA), already handled. The *only* way to
  manufacture contention is to (mis)use USB's **NDMA per-EP DRQs (0x15-0x17)**,
  which would eat into SPI's 4-channel NDMA bank — so don't; use DDMA for USB.
  This is why the DTS section below prefers the DDMA USB DRQ.

## Validation / acceptance (SPI-roadmap style)

- **P0** driver builds, board boots, musb probes a **non-NULL** dma_controller
  (dmesg), `use_dma=1`.
- **P1** `dma_request_chan` for the USB DRQ succeeds; channel bound, no error.
- **P2** a bulk transfer completes over DMA — cheap proof: run `iperf` over the
  in-tree USB NIC (DM9601 / AX88179) to exercise bulk endpoints **without the
  phone**; verify data integrity + DMA IRQs.
- **P3** wired AA plays **with video**, no corruption, no USB stalls/babble.
- **P4** measure ARM926 CPU during wired AA, DMA vs PIO baseline — must drop
  meaningfully (the entire point); framerate ≥ PIO.
- **P5** soak + concurrent esp-hosted SPI (WiFi) active — no channel starvation,
  no lockups over 10 min.
- **Rollback**: `use_dma=0` module param, or drop the dtsi `dmas` → instant PIO
  fallback (same safety model as the SPI DMA opt-in).

## Effort & recommendation

Weeks of kernel work + hardware bring-up — the DMA controller is a genuine
driver, and the MUSB short-packet/mux handling is the hard part. The `ux500_dma.c`
template plus our existing `sun4i-dma`/DDMA groundwork (from the SPI effort) cut
it down materially, but do not make it a weekend job.
**Recommended first step: measure the PIO CPU cost during a real wired-AA session**
(top/`/proc/stat` on the ARM926 while streaming). If USB PIO isn't a large slice,
the payoff may not justify the risk to a working, stable 6.6 image.
