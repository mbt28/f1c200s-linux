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

## JPEG decoding (patches 0038-0039) — WORKING, 2026-11-10

The VE's JPEG decoder (it shares the MPEG engine) is a V4L2 mem2mem decoder
on cedrus's `/dev/video*`: a whole baseline JPEG in on OUTPUT
(`V4L2_PIX_FMT_JPEG`, no request needed; the kernel parses the headers with
`v4l2-jpeg`), the picture out on CAPTURE. For LEHU's offline map tiles.

- **Where the registers come from.** The F1C200s manual (V1.2, section 2.5)
  only lists "JPEG decode up to 16384x16384"; it documents the VE's clock,
  gate, reset and address range, but no VE register. 0038 is patch 2/4 of the
  unmerged upstream series "media: cedrus: Add a JPEG decoder" (Emmanuel Gil
  Peyrot, 2024-07-31,
  https://lore.kernel.org/all/20240731164422.206503-1-linkmauve@linkmauve.fr/),
  written from the linux-sunxi VE register guide and the legacy cedar
  userland. 0039 is ours: suniv only, 4:2:0 only, requests JPEG-only.
- **CAPTURE format: `NV12_32L32` (ST12, 32x32 tiles)**, like H.264 here: this
  variant has no `CEDRUS_CAPABILITY_UNTILED`. The DEFE video plane scans it
  out directly (`DRM_FORMAT_NV12` + `DRM_FORMAT_MOD_ALLWINNER_TILED`, the
  CarPlay path). `VIDIOC_EXPBUF` gives a dma-buf. A 256x256 picture is 98304
  bytes: luma 256x256, then chroma 256x128.
- **4:2:0 only.** This A10-generation engine does not downsample to 4:2:0: a
  4:4:4 JPEG comes out as 4:2:2 (63 dB against a 4:2:2 reference) and the
  engine wrote 32 KiB past the end of the CAPTURE buffer. Upstream's patches
  offer 4:4:4 on the A10 too. 0039 refuses anything but 4:2:0 on the
  tiled-only VEs, and the buffers come back with `V4L2_BUF_FLAG_ERROR`.
- **H.264** still requires requests: 0039's `cedrus_qbuf()` returns `EBADR`
  for a non-JPEG OUTPUT buffer without one (upstream's 4/4 dropped the rule for
  all codecs, which Jernej Skrabec objected to in review). With the patched
  module loaded, a wired CarPlay session decoded its H.264 on v4l2-request as
  before (172 frames, 13-24 fps, 2026-11-10).
- **Memory:** both are modules. `sunxi_cedrus` grows from 40960 to 45056 bytes
  and `v4l2_jpeg` adds 12288, so about 16 KiB resident. No zImage change. A
  256x256 CAPTURE buffer takes 96 KiB of CMA.

Measured on the board (Buildroot, 792 MHz, `tools/cedrus_jpeg_test.c`, 1000
decodes of four synthetic 256x256 4:2:0 tiles at quality 75-85, 8-10 KB each):

| | |
|---|---|
| queue JPEG to dequeue picture | 1.26 ms average (1.14 min, 2.34 max) |
| throughput, one tile at a time | 705 tiles/s |
| copy of the JPEG into the OUTPUT buffer | 0.1 ms |
| CPU over the loop | this process 45% of the wall (user 110 ms, sys 521 ms per 1000) |
| CPU read of one picture from its CAPTURE buffer (98 KB, uncached) | 0.96 ms |
| output vs libjpeg (Pillow), 4:2:0 | PSNR Y 69 dB, Cb/Cr 48-55 dB |

The CPU cost is about 0.63 ms per tile, mostly in the kernel: header
parsing from the uncached OUTPUT buffer, about 600 register writes of
Huffman tables, and the ioctls. Decoding several tiles at a time (more
CAPTURE buffers queued) would overlap that with the engine.

To test: `tools/cedrus_jpeg_compare.py make DIR` writes test tiles on the
build host; on the board, `cedrus_jpeg_test -o /tmp/hw tile0.jpg ...`, then
`cedrus_jpeg_compare.py check hw tile0.jpg ...` on the host. Use
`cedrus_jpeg_test -n 1000 ...` for timing, and `cedrus_jpeg_test -H` for the
H.264 request rule.

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
