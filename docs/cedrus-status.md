# Cedrus (mainline, blob-free) status on the F1C200s — WORKING

**VALIDATED 2026-07-04 on F1C200s hardware, this branch's 6.6.143 image:
colour-correct cedrus decode, no lock-ups.** (The freezes seen on the 7.1.x
branch do not occur here with identical cedrus patches — they are a 7.1
base-kernel regression, tracked on the `kernel-7.1` branch.)

**UPDATE 2026-07-04 — root cause found and fixed; this branch carries the
backport.** The suniv VE (revision 0x1663, read from VE_VERSION) is an
A10-generation engine with **no internal SRAM for the H.264 deblock and
intra-prediction working data**; cedrus's `VE_BUF_CTRL = INT_SRAM` (used for
all pictures <=2048 px wide) made intra prediction read dead storage, so
reconstruction degenerated to clip(residual): the sparse luma AND the
zero-centred "signed" chroma below were ONE bug. The BSP decoder (libawh264)
allocates both buffers in DRAM at every resolution on this engine and selects
the fully external placement - patches 0006-0009 make cedrus do the same
(plus: VE_MODE DRAM-config quirk for the 16-bit DDR, MB-position reset on new
frames, and an A10-modelled variant without UNTILED replacing the old
V3s-modelled one). 0011 additionally bounds an unbounded VLD busy-wait that
could hang the whole machine pre-watchdog. Colour-correct decode was validated
on F1C200s hardware on the 7.1.x branch on 2026-07-03; the evidence trail
(decompiled libawh264/libVE) lives in the kernel-7.1 workspace
(`cedrus-development/ANALYSIS.md`). Everything below is the historical
pre-root-cause investigation.

---

# Cedrus historical status (pre-fix) — was: NOT working

**Summary:** the blob-free pipeline (mainline cedrus V4L2 stateless H.264 →
ffmpeg v4l2-request → sun4i DEFE) **builds and runs**, but the suniv VE produces a
**broken reconstruction**. Use **cedar** (BSP, `docs`/`cedar/README.md`) for
correct output. Cedrus is kept as a research track.

## What works
- `suniv_f1c100s` cedrus variant (`patches/linux-lctech/0006`); binds the VE,
  claims SRAM, clocks, `/dev/video0`.
- ffmpeg v4l2-request hwaccel decodes end-to-end with **0 errors** at 320×240,
  output tiled-NV12 dma-buf (`docs/ffmpeg-v4l2-request.md`).
- The DEFE display plane (`patches/linux-lctech/0005`) scans out the dma-buf.

## What's broken (the "mystery")
The VE's **reconstruction is sparse**, even for **I-frames**. Measured against a
software reference (`test.h264` frame 120, an IDR = the Paramount logo):

| plane  | reference        | cedrus output      |
|--------|------------------|--------------------|
| luma   | mean 59, 99% nz  | **mean 5, ~32% nz**|

It is **deterministic** (byte-identical run to run) and **unchanged by** every
knob tried:
- linear `NV12` vs tiled `NV12_32L32`
- `VE_MODE` `REC_WR_MODE` 1MB vs 2MB, `DDR_MODE_BW` 128
- chroma inline vs a separate `dma_alloc_coherent` buffer
- `memcpy` vs value transforms in the fold
- a full **reboot** (so it is not a boot-time DRAM-training transient)

### Two traps that misled earlier sessions
1. **Cached-read illusion.** `vb2_plane_vaddr()` returns a *cached* mapping; on
   this ARMv5 part it reads **stale, coherent-looking** luma while DRAM holds the
   sparse data. Only a `dma_sync_single_for_cpu(DMA_FROM_DEVICE)` before reading —
   or the dma-buf `DMA_BUF_IOCTL_SYNC` in `cedrus_drm_test --dump` — shows the
   truth. This is why luma looked "perfect" before.
2. **Signed chroma.** Independent of the sparse-luma bug, the VE emits chroma
   **signed** (0 = neutral). The display wants unsigned (128 = neutral), so a raw
   read is pure green. `XOR 0x80` while folding yields correct 128-centred chroma.
   (This — not tiling or the DEFE — is the real cause of the long-standing
   "green" symptom.)

### Clock note
The VE clock reads **210 MHz** while cedrus requests 297 MHz (`mod_rate`). Not
proven to be the cause (a slow clock would stall, not sparsify), but worth ruling
out via PLL-VE / DRAM-timing when this is revisited.

## Where the WIP lives
The signed-chroma fold + separate-chroma-buffer experiments are **build-tree
edits**, not yet distilled into a clean patch (they carry debug probes and the
underlying decode is still broken). Do not ship them. The clean, mergeable cedrus
contribution is `patches/linux-lctech/0006` (the variant) only.

## Next step to actually fix it
Register-level diff against the **working cedar/libcedarc** during a live decode:
capture cedar's VE register writes + SRAM DPB descriptor sequence for one frame,
diff against cedrus's, and find the missing/wrong reconstruction config. That is
the only path left; the analytical/config-sweep leads are exhausted.
