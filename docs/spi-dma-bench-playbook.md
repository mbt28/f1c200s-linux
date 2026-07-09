# SPI DMA bench playbook (suniv NDMA ↔ spi-sun6i ↔ ESP-Hosted)

Prepared 2026-07-09 from the User Manual V1.2 (§3.6 pp. 106–115, §7.3
pp. 282–294) plus three hardware iterations. DMA is parked (patch 0016,
PIO ships); this is the plan for the focused bench effort.

## Symptom, precisely

With `dmas` wired on spi1 (NDMA DRQ 5 both directions):
- **ESP→host works**: boot-up event and firmware version arrive and parse.
- **host→ESP never answered**: `cmd_init_interface` (`Command[0x1]`) times
  out, every retry, every boot. No transfer errors — irq counters show
  transfers completing mechanically (dma-controller: 3, handshake: 8).
- Unchanged by the two in-tree fixes (both stay, both were real bugs):
  burst clamped to INCR4 (0015), TX beat width dropped to byte (0015 v2).
- PIO on the same wiring/kernel: fully functional (scans, SoftAP, streaming).

Working theory class: the command frame leaves the DMA correctly but
arrives at the ESP mangled — i.e., **the TX FIFO underruns or misfeeds
while the SPI master clocks the burst**, producing garbage on MOSI that the
ESP discards as an invalid frame. (A read transaction's TX side is dummy
bytes, which the ESP ignores — explaining the RX-works asymmetry.)

## Established facts (do not re-derive)

1. **DDMA cannot service SPI on the suniv — dead end, confirmed.** The
   DDMA DRQ tables list only SRAM/SDRAM/USB/AHB-mem (src) and +LCDC (dst).
   NDMA is the only pairing; `SPI_FCR.RX_DMA_MODE` (bit 9) must stay 0
   (Normal), which is its default. Unlike the A10, where SPI classically
   paired with DDMA.
2. **NDMA_CFG bit audit, driver vs manual — slave path all correct**:
   dst width 25:24 / burst 23 / addr-type 22:21 / drq 20:16; src width 9:8
   / burst 7 / addr-type 6:5 / drq 4:0. The SUNIV width macros (<<24, <<8)
   match; the shared burst/addr macros match.
3. **One real driver/manual mismatch found** (not our path, note for
   upstream): `SUN4I_NDMA_CFG_CONT_MODE = BIT(30)`, but on the suniv bit 30
   is the RO **busy** flag and continuous mode is **bit 29** (§3.6.7.4).
   Affects cyclic mode only (audio); slave_sg never sets it.
4. **SPI_FCR (0x18) suniv-only fields** (absent on real sun6i parts, all
   default-inherited because spi-sun6i never writes them):
   - `TX_FIFO_ACCESS_SIZE` bits 27:26, `RX_FIFO_ACCESS_SIZE` bits 11:10 —
     default `00 = byte` (why the 4-byte TX beats of stock spi-sun6i broke;
     `11 = controlled by bus` is the interesting alternative)
   - `RX_DMA_MODE` bit 9 (keep 0)
   - `TF_DRQ_EN` bit 24 / `RF_DRQ_EN` bit 8 (driver does set these)
5. **The unresolved ambiguity — prime suspect**: `TX_TRIG_LEVEL` (bits
   23:16), default **0x40 = 64 = the entire suniv TX FIFO depth**, described
   as "TX FIFO Empty Request Trigger Level". Two readings:
   - DRQ while fill < trigger → default fine (request whenever not full);
   - DRQ only while empty-space ≥ trigger → with 64-deep FIFO, DRQ only
     when *completely empty* → NDMA refills 4 bytes per full drain → the
     master (which clocks the whole burst continuously once started)
     underruns → garbage islands on MOSI → **exactly our symptom**.
   RX_TRIG default is 1 (per-byte) — consistent with RX working either way.

## Additions from the full §3.6 read (pp. 106–115, 2026-07-09)

- **NEW PRIME SUSPECT — DMA auto clock gating** (`DMA_PTY_CFG` @
  `0x01C02008`, bit 16): **default 0 = auto-gating ENABLED**, and the manual
  itself warns it must be disabled for continuous operation. sun4i-dma
  never touches this register. The failure fit is excellent: RX at
  trigger=1 gets a constant DRQ stream (gate stays open, works); paced TX
  DRQs arrive with gaps → the gated engine misses/stalls them. This is the
  classic sunxi-DMA trap (other generations need the same bit handled).
  **Test = one poke**: `devmem 0x01C02008` read, OR in bit 16, retry the
  command. If it fixes: one-line sun4i-dma probe addition (suniv config
  flag) — clean and upstreamable.
- **NDMA requires word-aligned src+dst addresses** (§3.6.5.1). Audited:
  esp-hosted's `esp_alloc_skb` force-aligns skb->data to 4 and transfers
  are fixed 1600 bytes — TX buffers are aligned by construction, so this
  is *probably* not it; keep a one-time `pr_info("%px")` of `trans.tx_buf`
  in the instrumentation as a cheap invariant check.
- NDMA/CPU AHB arbitration defaults to **CPU > NDMA** with NDMA priority
  counter 3 (§3.6.7.3) — matters for throughput tuning later, not for
  correctness (RX works under the same arbitration).
- Channels 0–3 = NDMA, 4–7 = DDMA (matches the driver's pchan layout);
  DDMA ch 4 has the 8×64-bit FIFO, others 8×32.
- CCU gate + reset handling (§3.6.5.2) is already correct in the dtsi node
  (CLK_BUS_DMA + RST_BUS_DMA).

## Bench sequence (each step ~minutes, do in order)

Registers for devmem (all 32-bit): SPI1 base `0x01C06000`: FCR `+0x18` =
`0x01C06018`, FSR `+0x1C` = `0x01C0601C`, BC `+0x30`, TC `+0x34`.
NDMA channel n: `0x01C02100 + n*0x20`: CFG `+0x00`, SRC `+0x04`, DST
`+0x08`, BCNT `+0x0C` (set CFG bit 15 to make BCNT readable as residue).

1. **Re-enable DMA** (revert patch 0016's dts hunk / restore the two
   `dmas` lines + `dma-names`), rebuild, flash.
2. **Forensics on a stuck command** (5 s window after `wifi on` while
   `Command[0x1]` is outstanding), via devmem on the console:
   - `SPI_FSR` (0x01C0601C): TX fill (bits 23:16) — stuck full? empty?
   - `SPI_TC` (0x34) vs `SPI_BC` (0x30): has the master clocked the burst?
   - NDMA CFG/BCNT of the active channel: descriptor loaded? bytes left?
   This one dump localizes the stall: DMA-side / FIFO-side / SPI-clock-side.
3. **H1 — auto clock gating (do this FIRST, one poke)**:
   `devmem 0x01C02008` read → write value | (1<<16) → reload esp32_spi,
   retry. Best symptom fit + known sunxi precedent.
4. **H2 — TX trigger**: `devmem 0x01C06018` read, rewrite with TX_TRIG
   (bits 23:16) = 0x20, then 0x08, retry the command each time (reload
   esp32_spi). Two pokes decide the trigger-semantics question for good.
   If it fixes: 3-line spi-sun6i patch (program TX_TRIG = fifo_depth/2
   when DMA is used on burst-limited engines).
5. **H3 — access size**: set FCR ACCESS_SIZE fields to `11` (bus-
   controlled), restore 4-byte TX beats (drop the 0015 v2 width override),
   retest — the performance-correct endgame if H1/H2 alone are not it.
6. **H4 — scope MOSI** if software forensics disagree with all theories:
   valid frame header bytes vs zeros/garbage during a command transfer.

## Instrumentation patch (if step 2 needs more resolution)

- `spi-sun6i.c sun6i_spi_transfer_one()`: dev_info FCR/FSR before start +
  after completion/timeout.
- `esp_hosted host/spi/esp_spi.c` TX path: hexdump first 16 bytes of the
  command frame buffer pre-submit (compare with what a logic analyzer /
  the ESP console reports receiving).
- ESP-side view: `idf.py monitor` on the DevKitC USB **with `wifi off`**
  (IO3 conflict!) — the NG firmware logs malformed-frame drops.

## Success gate (from the roadmap)

`sun6i-spi` IRQs collapse to ~1/transfer with `dma-controller` doing the
work, `wifi on` → wlan0 + scan, iperf ≥ 15 Mbit/s, and CPU during iperf
measurably below the PIO baseline. Then delete this playbook's parked
status from `wireless-esp-hosted.md` P6.
