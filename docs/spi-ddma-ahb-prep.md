# SPI DDMA over AHB — preparation & design (suniv F1C200s)

Goal: offload the esp-hosted SPI1 traffic from PIO to DMA so the WiFi command
path (`CMD_SET_IE`, `CMD_MGMT_TX`) no longer times out under concurrent BT+WiFi
load (the AP-assoc-under-load blocker, see docs/esp-hosted-ap-assoc-blocker /
memory). This doc prepares the **Dedicated DMA (DDMA) over the AHB-memory
endpoint** path, per the decision to pursue it.

Status of the DMA work so far: NDMA (DRQ 0x05) was wired (patch 0014) but
`cmd_init_interface` timed out; DMA parked, PIO shipped (patch 0016). That NDMA
failure predates the esp-hosted worker-race fix (patch 0002) and was very likely
the same race hit harder — so **step 0 is still: retest NDMA on a patch-0002
kernel** before committing to DDMA (full plan: `docs/spi-ndma-roadmap.md`).
DDMA-over-AHB is the path if NDMA still fails
(or if we want DDMA ch4's deeper 8×64 FIFO for throughput).

## Correction to the earlier "rejected" analysis

`docs/spi-dma-bench-playbook.md` rejected DDMA-via-AHB claiming *"the 0x9 AHB
Memory type exists only in the DDMA source table, so the TX direction (write to
the FIFO) has no endpoint."* **That was a misread.** Re-reading the User Manual
V1.2 §3.6.7.8 (DDMA_CFG_REG), AHB Memory (0x9) is valid on **both** ends:

- DDMA **Destination** DRQ Type (bits 20:16): 0x0 SRAM, 0x1 SDRAM, 0x2 LCDC,
  0x4 USB, **0x9 AHB Memory**.
- DDMA **Source** DRQ Type (bits 4:0): 0x0 SRAM, 0x1 SDRAM, 0x4 USB,
  **0x9 AHB Memory**.

So the SPI FIFO (a plain AHB address) can be a DDMA **destination** (TX) *and* a
**source** (RX). Both directions are feasible. The real constraint is flow
control (no DRQ handshake), addressed by the DDMA parameter/pacing registers
below — it is a tuning problem, not an impossibility.

## Register map

SPI1 @ `0x01C06000`:
| reg | addr | role in DDMA/AHB |
|-----|------|------------------|
| SPI_TXD_REG | `0x01C06200` | TX FIFO data — DDMA TX **destination** (IO mode, fixed addr) |
| SPI_RXD_REG | `0x01C06300` | RX FIFO data — DDMA RX **source** (IO mode, fixed addr) |
| SPI_FCR/DMACTL | `0x01C06018` | FIFO trigger levels + access size (SPI-side DRQ unused here) |
| SPI_FSR | `0x01C0601C` | FIFO status: TX fill 23:16, RX fill (pacing/debug) |
| SPI_BC / SPI_TC | `0x01C06030` / `0x34` | burst / transfer byte counts |

DDMA channel n (n=0..3 = HW channels 4..7) @ `0x01C02000 + 0x300 + n*0x20`
(ch0 = `0x01C02300`):
| reg | off | notes |
|-----|-----|-------|
| DDMA_CFG | +0x00 | bit31 Loading(start), bit30 Busy(RO), dst/src DRQ+width+burst+addr-mode |
| DDMA_SRC_ADR | +0x04 | source phys addr |
| DDMA_DES_ADR | +0x08 | destination phys addr |
| DDMA_BYTE_CNT | +0x0C | transfer length (readable residue if CFG bit15 set) |
| DDMA_PAR | +0x18 | dst block[31:24]/comity[23:16] + src block[15:8]/comity[7:0] — pacing |

## DDMA_CFG bit layout (§3.6.7.8)

- 31 Loading (start / self-clears on done); 30 Busy (RO); 29 Continuous; 15 remain-byte-count read enable.
- Destination: 25:24 width (00=8b), 23 burst (0=Single/INCR4, 1=INCR4 via bit path), 22:21 addr mode (00=Linear, 01=IO), 20:16 DRQ type.
- Source: 9:8 width, 7 burst, 6:5 addr mode, 4:0 DRQ type.
- INCR8 (bit26 dst / bit10 src) is **DDMA3 only**; suniv otherwise Single/INCR4.

### TX (SDRAM buffer → SPI FIFO)
- dst: DRQ=0x9 (AHB Memory), addr mode=01 (IO, fixed), width=8b; DDMA_DES_ADR=`0x01C06200`
- src: DRQ=0x1 (SDRAM), addr mode=00 (Linear, increments), width=8b; DDMA_SRC_ADR=buffer phys
- DDMA_BYTE_CNT = frame len; start = DDMA_CFG bit31

### RX (SPI FIFO → SDRAM buffer)
- src: DRQ=0x9 (AHB Memory), addr mode=01 (IO); DDMA_SRC_ADR=`0x01C06300`
- dst: DRQ=0x1 (SDRAM), addr mode=00 (Linear); DDMA_DES_ADR=buffer phys

## Flow control — the crux (no DRQ)

An AHB-memory endpoint has **no DRQ handshake** with the SPI FIFO, so the engine
moves at AHB speed. TX too fast overruns the 64-byte TX FIFO; too slow underruns
→ garbage islands on MOSI (the classic symptom). Pacing knobs:

- **DDMA_PAR block/comity counters** (§3.6.7.12): "if counter=N, value is N+1".
  Interpretation to confirm on the bench: comity = transfers per burst, block =
  bursts before a wait — i.e. move `comity` bytes, pause, repeat. Tune so the
  effective DDMA byte rate ≈ SPI byte rate (SPI clock / 8).
- **DMA Wait State** field (NDMA_CFG 28:26; confirm the DDMA equivalent) —
  inter-access delay.
- **SPI FIFO trigger levels** (SPI_FCR 0x18): even without SPI-side DRQ, the
  FIFO trigger + SPI_FSR fill let a paced scheme stay inside the 64-byte window.

Because the pacing depends on the SPI clock, a fixed DDMA_PAR only works at a
fixed SPI clock — so either pin the esp-hosted SPI clock (currently 10 MHz) and
tune once, or recompute DDMA_PAR whenever the clock changes.

## NDMA vs DDMA-over-AHB (why NDMA first)

NDMA (DRQ 0x05 = SPI1 Tx/Rx) has **hardware DRQ flow control** — the SPI FIFO
trigger asserts the DRQ, NDMA responds, no manual pacing. It is strictly simpler
and clock-independent. It only "failed" pre-worker-fix. So: **retest NDMA first**
(cheap). Pursue DDMA-over-AHB only if NDMA still fails or we specifically want
DDMA ch4's 8×64-bit FIFO for throughput.

## Bench plan (incremental, each step minutes)

0. **NDMA retest**: revert patch 0016's dts hunk (restore spi1 `dmas`/`dma-names`
   NDMA drq 5) on a patch-0002 kernel; `wifi on`; check for `Command[0x1]`
   timeouts. If clean → NDMA is the answer, stop here. First poke the auto-clock-
   gating trap: `devmem 0x01C02008` |= bit16.
1. **Manual DDMA TX proof (devmem)**: configure SPI1 for a short known TX; set up
   DDMA ch0: src=test buf phys, dst=`0x01C06200`, dst DRQ=0x9/IO, src DRQ=0x1/Linear,
   byte cnt=N; start (CFG bit31); scope MOSI — do the N bytes appear correctly?
2. **Tune pacing**: sweep DDMA_PAR (comity/block) + wait-state until MOSI is clean
   at 10 MHz SPI. Record the working values.
3. **Manual DDMA RX proof**: DDMA src=`0x01C06300`/0x9/IO, dst=buf; clock in known
   bytes on MISO (loopback or the ESP); verify the buffer.
4. **Driver integration**: sun4i-dma exposes only DRQ-based dmaengine slaves; an
   AHB-memory endpoint is not a standard `slave_sg`. Options: (a) add a private
   DDMA "AHB-memory" transfer path in sun4i-dma and call it from spi-sun6i for
   spi1; (b) a bespoke DDMA driver outside dmaengine for this one channel. Keep
   NDMA/dmaengine for other users.

## Open questions / risks (resolve on the bench)

- Pacing/clock coupling (above) — the primary unknown.
- SPI_DMACTL(0x18): does the SPI need a DMA-mode / FIFO-access-size bit set for
  the FIFO to be externally drained/filled cleanly? Audit RX_DMA_MODE (bit9),
  TX/RX FIFO access size, TX/RX trigger levels.
- Cache coherency: DDMA buffers via `dma_alloc_coherent` or explicit sync.
- Word alignment: DDMA src/dst word-aligned (§3.6.5.1) — esp-hosted skbs are
  4-aligned; fine.
- DMA_PTY_CFG (`0x01C02008`) bit16 auto-clock-gating default-on (sunxi trap) —
  disable before any DMA use.

## Prereqs already in-tree (from the NDMA work)
- sun4i-dma backported (patch 0014); DMA clk-gate + reset in the dtsi (CLK_BUS_DMA
  / RST_BUS_DMA). spi-sun6i burst clamp (patch 0015). PIO ships today (patch 0016).
