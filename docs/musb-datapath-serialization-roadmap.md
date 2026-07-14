# Roadmap & Test Plan — serialize the suniv MUSB shared-FIFO datapath

Status: **PLAN** (2026-07-13). Fixes the RX-DMA↔TX-PIO collision that corrupts
wired-AA video (`TLS bad record mac`). Companion to the bounded-flush fix
(shipped, `1a450c9`) and the separate kernel CMA leak (open, see
`docs/` / memory `cedrus-cma-leak-kernel-side`).

## 1. Problem & root cause (established)

The F1C200s MUSB has **one shared FIFO datapath**, gated by the global VEND0
`BUS_SEL` bit (reg 0x43). `sunxi_dma.c` sets `BUS_SEL=1` when an RX video DMA
starts (`sunxi_dma_configure_channel` → `set_ep_mode(true)`) and holds it for
the whole transfer (~0.3–1 ms), clearing it only on completion/abort.

**While `BUS_SEL=1`, any CPU FIFO operation corrupts the in-flight RX DMA:**
a TX-PIO write (AA touch / heartbeat / ep0 control-OUT) or an RX-PIO fallback
read goes through the same datapath the DMA engine is driving → the RX video
bytes land wrong → the AA transport's TLS layer rejects the block
(`bad record mac`) → the app reconnects.

Evidence:
- Driver audit: `sunxi_dma.c` header comment (lines ~19–20) explicitly punts —
  *"concurrent bidirectional DMA is a bring-up item."* Nothing guards it.
- Cache coherency was audited and is **fine** (the USB core's
  `dma_map/unmap(FROM_DEVICE)` handles ARMv5 invalidation; the driver uses the
  pre-mapped `dma_addr` and never re-maps). Coherency is NOT the cause.
- PIO signal: forcing `use_dma=N` made `TLS decrypt failed` and `ep2 RX
  three-strikes` disappear (weak — the run was hub-confounded, see §6).

Not to be confused with two **separate** axes:
- **Disconnects / `-71` enumeration storms** = hub / VBUS / phone-side, NOT DMA.
- **CMA leak** (~10 MB/session, kernel-side) = turns any reconnect into an
  unrecoverable spiral. Independent workstream; needed for full recovery.

## 2. The fix — cooperative TX-PIO deferral (enforce half-duplex)

Principle: **no CPU FIFO op while an RX-DMA owns `BUS_SEL`**; the deferred op is
run the instant the RX-DMA completes. This matches the vendor BSP, which is
strictly half-duplex (one transfer on the datapath at a time).

Mechanism (all `#if CONFIG_USB_SUNXI_DMA`, suniv-only):
- **Datapath ownership** in the sunxi controller: `dp_owner ∈ {FREE, RX_DMA,
  TX_DMA}` + a small pending-TX record (ep + qh/urb).
- **RX-DMA arm** (`sunxi_dma_configure_channel`, sets `BUS_SEL`): `dp_owner = RX_DMA`.
- **RX-DMA complete** (`sunxi_dma_callback`, clears `BUS_SEL`): `dp_owner = FREE`;
  if a TX is pending, **kick** it (re-enter the TX FIFO-load path).
- **CPU FIFO write** (bulk-OUT / ep0 control-OUT, in `musb_host_tx` / the FIFO
  load): if `dp_owner == RX_DMA` → **defer** (record ep, do NOT set `TXPKTRDY`,
  return); else proceed and set `dp_owner = TX` for the (short) PIO write.

Protocol safety: host-initiated OUT (bulk + control DATA-OUT) is timed by the
host, so deferring it <1 ms is invisible to the device. (IN/REQPKT is not
deferred — only one RX-DMA channel exists; RX-PIO fallback is gated the same way.)

Why not the alternatives (all rejected with cause):
- **Busy-wait for `BUS_SEL=0`** — RX-DMA holds it ~0.3–1 ms; spinning that long
  under `musb->lock`/IRQs-off starves the RT thread (the very failure the
  bounded-flush fix removed).
- **Pause/resume RX-DMA or clear `BUS_SEL` mid-flight** — destroys the RX
  stream; this is exactly the re-enumeration storm already observed (`2c6e60d`).
- **Route small TX through DMA too** — a tiny DMA on the USB DRQ never completes
  and stalls the endpoint (per `channel_program`'s own comment).

Implementation surface (small, contained):
- `sunxi_dma.c`: ownership state; set/clear at arm/complete; kick-pending helper.
- `musb_host.c` / sunxi glue: gate the TX FIFO load; re-enter on kick. Gated.
- Escape hatch preserved: `musb_hdrc.use_dma=0` = pure PIO, no `BUS_SEL`, no gate.

## 3. Phased roadmap

- **Phase 0 — Deterministic reproducer (Pi USB gadget). BLOCKING; do first.**
  Stand up the phone-free harness (§4.1) so every later step is measured in
  seconds with a hard pass/fail, not phone-churn minutes.
- **Phase 1 — Instrument & quantify.** Add debug counters (TX-writes-while-
  `BUS_SEL`-held; deferrals; kicks) + confirm the baseline collision
  deterministically (data mismatch > 0, counter > 0, correlated).
- **Phase 2 — Implement cooperative deferral** (§2).
- **Phase 3 — Validate on the harness** (§4.3): zero corruption, bounded TX
  latency, unchanged RX throughput, 30-min soak, no deadlock.
- **Phase 4 — Validate on the phone** (§4.4): sustained AA, zero TLS fails.
- **Phase 5 — Cleanup:** strip debug counters/configs, finalize the patch,
  update this doc + memory.

## 4. Test & validation plan

### 4.1 Pi-as-USB-gadget harness (fast, deterministic, phone-free)
- **Pi = Compute Module 5 Lite**, has a **dwc2 USB2-OTG** controller (verified
  2026-07-13). It ships `dtoverlay=dwc2,dr_mode=host` (so `/sys/class/udc/` is
  empty). To make it a gadget: set `dtoverlay=dwc2,dr_mode=peripheral` in
  `/boot/firmware/config.txt` and **reboot the Pi** → `/sys/class/udc/` then
  lists the dwc2 UDC. `g_zero.ko` is already present on the Pi. Confirm which
  **carrier-board USB connector** carries the CM5's dwc2/OTG lines (CM5-carrier
  dependent) — that's the one to cable to the board's host port. NOTE: the Pi
  reboot interrupts the dev tooling (serial/builds), so schedule it; this step
  is the **user's** (their machine, needs a reboot + config edit).
- `g_zero` sourcesink: bulk-IN sources a known mod-63 pattern, bulk-OUT sinks +
  verifies it.
- **Wire:** Pi dwc2/OTG connector (gadget) ↔ board USB host port.
- **Board (host)** drives the gadget **concurrently**. Two options for the
  host-side driver:
  - **(preferred, no board rebuild)** a small **libusb** program on the board
    (libusb is already there for FastCarPlay): submit large aligned bulk-IN
    reads (→ RX-DMA) + small bulk-OUT writes (→ TX-PIO) concurrently, verify the
    g_zero IN pattern. Cross-build + drop on the SD card (like the fastcarplay pkg).
  - **(alt)** `usbtest` + `testusb` — needs `CONFIG_USB_TEST=m` added to the
    board kernel (a rebuild).
  Either way, drive:
  - **RX-DMA path:** bulk-IN, length ≥512 and 4-aligned → passes the DMA gate
    (`IRQ 17 / 1c02000.dma-controller` climbs = DMA engaged).
  - **TX-PIO path:** bulk-OUT, small/unaligned (<512) → forced to PIO.
- **Corruption detector:** `g_zero` sourcesink pattern-checks every byte →
  a mismatch is a **hard, deterministic** corruption signal (vs the phone's
  fuzzy `TLS bad record mac`).
- **Instrumentation:** `IRQ 17` delta (DMA active); a driver counter of
  "TX FIFO write attempted while `BUS_SEL` held"; deferral/kick counts.

### 4.2 Baseline (Phase 1 exit)
Concurrent IN-DMA + OUT-PIO must show **data errors > 0** AND the
"TX-while-`BUS_SEL`" counter **> 0**, time-correlated. This finally *proves* the
collision deterministically (removes the last hand-wave).

### 4.3 Fix validation (Phase 3 exit)
- Same load, patched driver → **data errors == 0** over ≥1e5 transfers.
- "TX-while-`BUS_SEL`" counter **== 0**; deferrals **> 0**, kicks == deferrals
  (every deferred TX is eventually sent — no lost TX, no deadlock).
- **TX added latency** = the deferral wait; expect < one RX-DMA transfer
  (~1 ms worst case). Acceptable for AA input; record the distribution.
- **RX throughput** unchanged vs baseline; **TX throughput** acceptable.
- **30-min soak:** zero errors, no endpoint stalls, no deadlock.

### 4.4 Phone validation (Phase 4 exit)
- Wired AA, 10-min hands-off + touch: **zero** `TLS decrypt failed`, **zero**
  `ep2 RX three-strikes`, device number stable, `flush=0`, `RT throttling=0`.
- `use_dma=1`, `IRQ 17` climbing (DMA on RX confirmed).
- Full end-to-end recovery also requires the **CMA-leak fix** (separate); until
  then a rare drop still spirals — track both to call wired-AA "done".

## 5. Risks, fallbacks, rollback
- **Deadlock** (a deferred TX never kicked, e.g. RX-DMA completion missed):
  mitigate with a bounded watchdog that force-kicks pending TX after N ms;
  covered by the Phase 3 soak (kicks == deferrals).
- **Latency** on TX input: bounded by one RX-DMA transfer; measured in Phase 3.
- **Rollback:** entire path is `#if CONFIG_USB_SUNXI_DMA`; `use_dma=0` disables
  DMA (proven-safe PIO baseline) with no code change.

## 6. Notes / confounds seen during triage
- The `use_dma` runtime toggle (`/sys/module/musb_hdrc/parameters/use_dma`) is
  writable but leaves the live controller in a **dirty** DMA↔PIO state; for a
  clean PIO comparison, boot with `musb_hdrc.use_dma=0` (bootarg), not a runtime
  toggle. The `-71` "device not accepting address" storm in the runtime-PIO run
  was the **USB hub** in the path (phone at `1-1.3` behind a Fresco Logic hub),
  not PIO — re-test **direct** (no hub).
- Serial: only ever open the console DTR=False/RTS=False (asserting DTR resets
  the board). See memory `ch341-serial-dtr-rts-silent`.

## 7. State of knowledge / parking notes (2026-07-14)

Consolidated before parking so the work resumes cleanly.

### 7.1 Reference survey — nobody uses the suniv MUSB external DMA
Every MUSB implementation surveyed is **PIO-only**; the external-DMA backend in
this branch (patch 0016) is **novel**, and the shared-FIFO collision is exactly
why the ecosystem avoids it:
- **mainline Linux `drivers/usb/musb/sunxi.c`** — forces `VEND0 = PIO`; no DMA.
- **CherryUSB** (production F1C100s/F1C200s USB *host* stack) — `musb_read/write_packet`
  are raw `HWREG`/`HWREGB` FIFO access; **no DMA**; `usb_glue_sunxi.c` is FIFO-size
  config only.
- **TinyUSB** `portable/mentor/musb/hcd_musb.c` (host) & `dcd_musb.c` (device) —
  PIO (`musb_regs->fifo[epnum]`); **0 DMA**.
- **decaday/musb** (Rust, device-mode) — PIO, generic profiles, no Allwinner/DMA.

### 7.2 The collision is structural; "global DMA mode" is a common shape
- suniv has ONE **single-port** FIFO RAM shared by all endpoints (PSPG p12),
  muxed CPU-vs-DMA by the **global** `VEND0.BUS_SEL` bit. The external-DMA path
  has no CPU/DMA arbitration → any CPU FIFO op during an RX-DMA corrupts it.
- Parallel: **DWC2** (TinyUSB PR #2576) also makes DMA a **global, core-reset-time,
  compile-time** mode (default OFF). These controllers want **all-DMA or all-PIO**;
  the per-transfer **hybrid** this driver does (DMA for big RX, PIO for TX/ep0/small)
  is what creates the collision.

### 7.3 Resolved via the MUSBMHDRC PSPG (see memory `musb-hdrc-dma-facts`)
- Cache coherency: **not** the bug (USB core `dma_map/unmap` handles ARMv5).
- `actual_len = cur_len`: **not** a bug — Mode-1 bulk suppresses the EP interrupt
  except on a short packet, which is handled via `RXCOUNT`, not the DMA callback.
- three-strikes: **hardware** (3 failed attempts → Error → DMA request disabled).

### 7.4 Deterministic reproducer (the go-to test; memory `usb-dma-stress-test-suniv`)
SanDisk `/dev/sda` `dd bs=64k` (RX-DMA) + `musb-collision-test --ctrl 0781 5583`
(ep0 PIO hammer) + `dd|md5` vs a clean reference → **6/6 corrupt** baseline;
**0/6** = fixed. Phone-free, ~90 s. Note: SanDisk (0781:5583) enumeration is
VBUS-flaky at boot — reseat the stick to get `/dev/sda`.

### 7.5 Phase-2 attempt 1 = FAILED (commit ff1a655, on dev, no-op/no-regression)
Masked other-EP MUSB IRQs while an RX-DMA held BUS_SEL. Still 6/6, hammer
unslowed. Wrong layer: CPU FIFO ops ALSO come from the **URB-submission path**
(`musb_ep_program` writes the ep0 SETUP / TX FIFO), which masking IRQs doesn't
cover; the raw INTRTXE write also fights the core's `musb->intrtxe` shadow. Left
in place because it regresses nothing (RX-DMA clean, no wedge/starvation).

### 7.6 The two viable paths to resume
1. **All-PIO (`use_dma=0`)** — proven, collision-free, what the whole ecosystem
   uses. Open question: fast enough for the AA video now that the console-flood /
   RT-throttle is fixed? Video is only a few Mbps; PIO did ~21 Mbps on the storage
   test. Cheapest to validate: boot `musb_hdrc.use_dma=0` + phone → measure fps +
   confirm zero TLS corruption. **If PIO holds, the DMA (and this whole
   workstream) is optional.**
2. **Hybrid DMA + transaction-level defer** — gate `musb_ep_program` (+ the TX/ep0
   IRQ continuation) so no CPU-FIFO transaction *starts* while RX-DMA owns
   BUS_SEL, and reschedule deferred endpoints from the DMA completion callback.
   Correct + keeps DMA throughput, but invasive MUSB-host-scheduler surgery.
   Validate against the reproducer (→0/6), then the phone.

**Recommended resume order:** test path 1 first (cheap; may make the DMA moot).
Only if PIO can't sustain the video, invest in path 2. Independently, the kernel
**CMA-leak** (`cedrus-cma-leak-kernel-side`) still needs fixing so a reconnect
recovers cleanly regardless of which path wins.
