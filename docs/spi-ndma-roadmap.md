# SPI NDMA implementation roadmap (suniv F1C200s, esp-hosted SPI1)

**Goal:** move esp-hosted SPI1 traffic from PIO to **NDMA** (Normal DMA, DRQ
0x05 = SPI1 Tx/Rx) so the WiFi SPI command path stops timing out under
concurrent BT+WiFi+AA load — the AP-assoc-under-load blocker
(`decode_common_resp: Failed … resp_skb:00000000`, `cmd_set_ie` failure,
`Command response not expected=25`). NDMA is the proper path: hardware DRQ flow
control, a standard dmaengine slave, clock-independent. It was already wired
(patch 0014) but `cmd_init_interface` timed out — **before** the esp-hosted
worker-race fix (patch 0002), which very likely caused it. So this roadmap is
"un-park and retest, with a triage tree for the historic failure."

If NDMA still fails after P2 triage, fall back to `docs/spi-ddma-ahb-prep.md`
(DDMA over AHB) — the P0/P1 scaffold carries over.

## Prereqs / starting state
- `patch 0014` — sun4i-dma backported; DMA clk-gate + reset in the dtsi
  (CLK_BUS_DMA / RST_BUS_DMA); spi1 `dmas` NDMA drq 5.
- `patch 0015` — spi-sun6i burst clamped to INCR4 + TX beat width dropped to byte.
- `patch 0016` — **PARKS** DMA (strips `dmas` from spi1 → PIO ships). Un-parking is P0.
- `patch 0002` — esp-hosted worker drain-loop + re-check (the likely reason the
  earlier NDMA attempt failed).
- ESP firmware: use the **clean cs748** build for the bench (the current on-board
  build carries the AP force-success experiment — a confound). Pin the SPI clock
  at the current 10 MHz for the whole bench.

## Register / tuning cheat-sheet (devmem, all 32-bit)
- SPI1 @ `0x01C06000`: FCR `0x01C06018` (TX_TRIG 23:16 **default 0x40 = full FIFO**,
  access size, DRQ enables), FSR `0x01C0601C` (TX fill 23:16 / RX fill), TXD
  `0x01C06200`, RXD `0x01C06300`, BC `0x30`, TC `0x34`.
- NDMA ch n @ `0x01C02100 + n*0x20`: CFG `+0x00`, SRC `+0x04`, DST `+0x08`,
  BCNT `+0x0C` (set CFG bit15 to read BCNT residue).
- `DMA_PTY_CFG` `0x01C02008` bit16 = auto-clock-gating, **default ON** (the sunxi
  trap) — must be cleared before any DMA use.
- Prime suspects for the historic timeout, in order: (A) auto-clock-gating;
  (B) `TX_TRIG_LEVEL 0x40` → DRQ only when the FIFO is fully empty → the master
  clocks the burst continuously and the FIFO underruns → garbage on MOSI;
  (C) burst/width mismatch (should be fixed by 0015 — verify).

---

## P0 — Un-park + build + boot
**Goal:** a kernel with NDMA wired on spi1, boots.
**Steps:** revert patch 0016's spi1 dts hunk (restore `dmas`/`dma-names` NDMA
drq 5); keep 0014/0015 and the patch-0002 esp-hosted. Build (CI or local), flash.
**Acceptance:**
- [ ] Kernel builds clean with the DMA patches applied.
- [ ] Board boots to login.
- [ ] `dmesg | grep -i sun4i-dma` shows the controller probed, no error.
- [ ] The spi1 node has `dmas` again (`dtc`/`/proc/device-tree` or dmesg).
**Triage:** build fail → 0014 API shims (kernel drift); no controller → dtsi node / clk / reset. **Rollback:** re-apply 0016 (PIO, known-good).

## P1 — DMA channel allocation (spi-sun6i ↔ sun4i-dma)
**Goal:** spi-sun6i requests + configures the NDMA tx/rx channels for spi1.
**Steps:** ensure `DMA_PTY_CFG` bit16 auto-gating is cleared (driver fix or a
`devmem` poke for the bench); `wifi up` (loads esp32_spi → probes spi1).
**Acceptance:**
- [ ] dmesg: no `spi-sun6i … Failed to request DMA` / `dma_request_chan` error.
- [ ] `spi-sun6i` reports DMA mode available for spi1 (channels bound).
- [ ] `devmem 0x01C02008` shows bit16 = 0 (auto-gating off).
**Triage:** channel request fails → DT `dmas`/`dma-names`, drq index 5, channel count.

## P2 — First DMA transfer: the historic failure point
**Goal:** ESP boot-up + `cmd_init_interface` complete over DMA (this timed out
before). Highest-risk gate.
**Steps:** `wifi up`; watch dmesg through the init handshake.
**Acceptance:**
- [ ] `esp32_spi: … Received ESP boot-up event` + `Chipset=ESP32 … detected over SPI`.
- [ ] `check_esp_version: … NG-1.0.6.0.1`.
- [ ] **NO** `Command[0x1] timed out` / `cmd_init_interface … failure`.
- [ ] `wlan0` netdev appears.
**Triage (if `cmd_init` times out — the old symptom):**
1. One devmem forensic dump during the stuck 5 s window: `SPI_FSR` (TX fill
   stuck full/empty?), `SPI_TC` vs `SPI_BC` (did the master clock the burst?),
   NDMA `CFG`/`BCNT` of the active channel (descriptor loaded? bytes left?) —
   localizes DMA-side vs FIFO-side vs SPI-clock-side.
2. Suspect A: `devmem 0x01C02008` |= (1<<16 cleared), reload esp32_spi, retry.
3. Suspect B: `devmem 0x01C06018` rewrite `TX_TRIG` (23:16) = 0x20, then 0x08,
   retry each (TX-underrun theory; a fix would program TX_TRIG = depth/2).
4. Suspect C: verify 0015's INCR4 clamp + byte TX width actually took.
5. Cross-check against PIO (0016) as the known-good reference for the same frame.

## P3 — Functional WiFi over DMA (isolation, no BT load)
**Goal:** scans + association + data path all work over DMA.
**Steps:** `wifi up`; 8 consecutive scans; a real STA-assoc+DHCP or AP+client; iperf.
**Acceptance:**
- [ ] 8/8 `iw dev wlan0 scan` return SSIDs; **ZERO** `timed out` in dmesg.
- [ ] STA associates + DHCP + `ping -c3` gateway (or AP mode + a client associates+4-way).
- [ ] `iperf` ≥ 15 Mbit/s.
- [ ] dmesg clean: no DMA errors, no `SPI Transaction failed`.

## P4 — Robustness under concurrent BT+WiFi+AA load — **THE GOAL**
**Goal:** the AP-assoc-under-load failure is gone; the SPI command path holds
while BT is active.
**Steps:** full wireless-AA session — `bt on` + the app + phone does the BT
handshake, gets creds, joins the FastCarPlay AP. Watch dmesg for the command-
timeout signatures throughout.
**Acceptance (definition of done for the whole effort):**
- [ ] Phone **associates to the ESP AP during a live BT+AA session** —
      `iw dev wlan0 station dump` shows the station **authorized**.
- [ ] **NONE** of `decode_common_resp: Failed … resp_skb:00000000`,
      `cmd_set_ie … failure`, `Command response not expected=25` under load.
- [ ] End-to-end: Android Auto video streams (app logs the session established).
- [ ] 3 consecutive full connect cycles succeed (not a one-off).

## P5 — Efficiency validation (confirm the mechanism)
**Goal:** prove DMA actually cut the CPU/IRQ load that caused the timeouts.
**Steps:** measure SPI IRQ rate + CPU during iperf, DMA vs the PIO baseline;
then soak.
**Acceptance:**
- [ ] SPI-controller IRQs collapse to ~1/transfer (from the ~25 FIFO IRQs/frame
      of PIO — compare `/proc/interrupts` deltas over a fixed transfer count).
- [ ] CPU during iperf measurably below the PIO baseline (`top`/`/proc/stat`).
- [ ] 10-min soak: iperf + BT active, **no** timeouts, no `dmesg` regressions,
      no memory growth.

---

## Ship
On P4+P5 pass: fold the un-park into a patch (drop 0016, or a 0017 that re-wires
`dmas` cleanly + any TX_TRIG/auto-gating fix P2 needed), promote to dev via
`feature/spi-dma`, tag. Update the playbook's "success gate" and retire the
DMA-parked note.

## Rollback / safety
PIO (patch 0016) is the always-available known-good. Every phase's failure path
ends in "re-apply 0016." DMA is opt-in per the spi1 DT `dmas`, so a bad DMA build
never bricks the board's console (serial is spi-independent).
