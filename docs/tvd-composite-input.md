# Composite video input (TVD, TVIN0/TVIN1)

Status (2026-10-16): **driver working on the bench board.** The F1C's own TV
encoder looped into TVIN0 (PAL colour bars) streams through `/dev/video1`
(NV12/NV16, 720x576, 25 fps) rock-stable: 100% H/V/colour lock, PAL detected,
frame-to-frame noise ~1, edge jitter 0.01 px. `v4l2-compliance -s 30` passes
80/80 tests with 0 warnings. A real camera does not lock yet: the board grounds
TVIN0 through 75 ohm at the pin, which the decoder's clamp cannot work against
(see [Open issues](#6-open-issues)).

| Piece | Where |
|---|---|
| CCU: pll-video fixed, `CLK_PLL_VIDEO` exported to the DT | `patches/linux-lctech/0032-*` |
| Driver `sun4i_tvd` (`drivers/media/platform/sunxi/sun4i-tvd/`) + uapi control base | `patches/linux-lctech/0033-*` |
| Board DT: TVD node, `&ccu` pll-video = 297 MHz | `patches/linux-lctech/0034-*` |
| `CONFIG_VIDEO_SUN4I_TVD=m` | `board/lctech/pi-f1c200s/linux.fragment` |
| Loader (after cedrus, so the camera is `/dev/video1`) | `rootfs-overlay/etc/init.d/S21tvd` |
| `v4l2-ctl`, `v4l2-compliance`, `media-ctl` (`BR2_PACKAGE_LIBV4L` + `_UTILS`) | defconfig |

## 1. Using it

```sh
v4l2-ctl -d /dev/video1 --all                 # format, input + lock status, controls
v4l2-ctl -d /dev/video1 --get-standard --get-input
v4l2-ctl -d /dev/video1 --query-standard      # what the decoder detects on the input
v4l2-ctl -d /dev/video1 -s pal                # or ntsc; not while streaming
v4l2-ctl -d /dev/video1 -i 1                  # TVIN1
v4l2-ctl -d /dev/video1 -c contrast=200,brightness=40,saturation=96
v4l2-ctl -d /dev/video1 -c blue_screen=0      # 0 off, 1 on, 2 auto (no signal)
v4l2-ctl -d /dev/video1 --set-fmt-video=pixelformat=NV12 \
	--stream-mmap --stream-count=50 --stream-to=/tmp/cam.nv12
```

| Control | Range (default) | Register | Notes |
|---|---|---|---|
| `brightness` | 0..255 (32) | `0x00C` [15:8] | 0x20 = no offset (V40 BRIGHT_OFFSET); verified: shifts the black level |
| `contrast` | 0..255 (128) | `0x00C` [7:0] | 0x80 = unity gain (V40 CONTRAST_GAIN); the vendor's 0x68 is 0.8x |
| `sharpness` | 0..255 (32) | `0x00C` [23:16] | per the RE notes; effect not measured. Bit 24 (sharpen enable, set at reset) is cleared, as the vendor does |
| `saturation` | 0..255 (PAL 80, others 128) | `0x010` [7:0] | 0x80 = unity; verified (0 removes all chroma). Reset to the standard's default on `S_STD` |
| `hue` | -128..127 (0) | `0x010` [15:8] | |
| `chroma_gain` | 0..255 (PAL 147, NTSC/PAL-M 138, PAL-Nc/SECAM 220) | `0xF1C` [23:16] | vendor `com_video_set_chrom_gain`; reset per standard on `S_STD` |
| `chroma_enhance` | menu Off/Mild/Low/Middle/High (Off) | `0x010` bit 16 + [21:20] | vendor `c_peak` = bit 16; strength as V40 `CHROMA_ENHANCE_STRENGTH` |
| `burst_gate_start` | 0..255 (50) | `0xF10` [15:8] | colour-burst window after hsync (V40 `TVD_CLOCK1`) |
| `burst_gate_end` | 0..255 (138 = 0x8A) | `0xF10` [23:16] | **keep bit 6 (0x40) clear**: 0x40..0x7F and 0xC0..0xFF make the decoder output per-pixel noise (~60 rms) while it still reports lock. The vendor's 0x8A is clean |
| `blue_screen` | menu (2 = auto) | `0xF14` [5:4] | auto = blue frame while unlocked (V40 `TVD_MODE`) |
| `comb_filter_3d` | bool (off) | `0x000` bit 4, `0x008` bit 0, `0x048` | **leave off**: with it on, the decoder locking overwrote random page-cache pages on the bench. Takes effect at the next STREAMON; costs 2 MiB CMA while streaming. (Was `3d_comb_filter`: v4l2-ctl parses names starting with a digit as a control ID, so `-c 3d_comb_filter=0` failed) |

Settings are kept by the driver across opens (until the module is reloaded).
The decoder is powered and clocked only while the node is open, so the input
status (`--all`, `ENUM_INPUT`) needs a few hundred ms after open to show lock;
`--all` right after opening reports "no hsync lock".

## 2. The hardware

| Item | Value | Source |
|---|---|---|
| TVD MMIO | `0x01C0B000`, 4 KiB | User Manual V1.2, memory map |
| IRQ | 27 | User Manual V1.2, interrupt table |
| Bus gate | CCU `0x064` bit 9 (`bus-tvd`) | UM + mainline `ccu-suniv-f1c100s.c` |
| DRAM gate | CCU `0x100` bit 3 (`dram-tvd`) | same |
| Module clock | CCU `0x124` (`tvd`), parents pll-video / osc24M / pll-video-2x, M divider | same |
| Reset | CCU `0x2C4` bit 9 (`RST_BUS_TVD`) | same |
| Pins | TVIN0 = pin 78, TVIN1 = pin 77, TV_VRP/VRN = 76/75, TVAVCC/TVAGND | Datasheet V1.1 |

The pins are dedicated analog inputs (no pinctrl). The User Manual has **no
register chapter** for the TVD. On the bench board the camera is soldered to
the TVIN0 end of the board's 75 ohm termination resistor (no connector).

It is the **A20 TVD decoder core behind a different register layout**: the A20
core registers appear at F1C `+0xF00` with the same PAL/NTSC values
(`0x11590x02`, `0xD74`, `0x0682810A`, `0x0E70106C`), status bit 18 = 625 lines
is shared, and so are the DMA format bits. The V40/F133 TVD ("sunxi_tvd" BSP) is
a newer, different block. On reset the F1C200s reads back exactly the F1C100s
defaults (`F1C100s_info/TVD_TVE/tvd_regs_default.txt`).

### Register map (assembled; ? = inferred)

| Offset | Role |
|---|---|
| `0x000` | bit 0 decoder enable; **bit 4 3D comb filter enable**; [12:8] pulsed (`0x1F00`) by the vendor init |
| `0x008` | mode: [14:12] colour standard (0 NTSC, 1 PAL, 2 PAL-M, 3 PAL-Nc, 4 SECAM: the V40 `COLOR_STD` codes); [24] 625 lines; **bit 0 = 2D comb (cleared when the 3D comb runs)**; cleared without the 3D comb running, the output goes blank |
| `0x00C` | contrast [7:0] (0x80 = 1x), brightness [15:8] (0x20 = 0), sharpness [23:16], sharpen enable [24]; reset 0x01202080 |
| `0x010` | saturation [7:0] (0x80 = 1x), hue [15:8], chroma enhance enable [16] + strength [21:20] |
| `0x014` | ? prescaler (`0x20000000`) |
| `0x018` | chroma subcarrier = `f / 27 MHz * 2^32` |
| `0x01C` | h start [27:16], v start [10:0] |
| `0x040` | 3D comb control, vendor constant `0x04000310` (bit 4 is NOT the enable) |
| `0x048` | 3D comb latch: write `0x04040001` after programming the memory (bits 26 and 18 self-clear) |
| `0x04C` / `0x050` / `0x054` | 3D comb field memory start / end / size (vendor: 2 MiB) |
| `0x060..06C` | chroma frequency presets (read-only defaults: PAL, PAL-M, PAL-Nc, NTSC) |
| `0x080` / `0x084` | capture DMA Y / C address (full physical address) |
| `0x088` | DMA cfg: b0 enable, b4 = 422 (else 420), b8 UV swap, b24 = MB tiled, b26 size valid, **b28 address valid** |
| `0x08C` | DMA size: lines per field [26:16], width [11:0] (max 720) |
| `0x090` | DMA stride |
| `0x094` / `0x09C` | IRQ status (W1C) / enable; bit 24 = frame done |
| `0xE04` | ADC/input; init `0x8002AAA8`; bit 0 = TVIN1 |
| `0xE2C` | ADC ctrl: `0x00110000` before the core setup, `0x60000000` after (the Melis value 0x00110000 gives "no signal" here) |
| `0xE30` | [31:16] chroma (burst) magnitude: ~0x245 locked here, ~0x108 unlocked, 0x4DC no signal; [15:0] ? |
| `0xE40` | status: 0 no signal, 1 H lock, 2 V lock, 3 chroma lock, 8 progressive, 9/10 H/V non-standard, 16 PAL, 17 SECAM, 18 625 lines, 19 noisy |
| `0xE44` | ? gain / line-timing estimate (`0x2000_0000` nominal when locked) |
| `0xF00..F84` | decoder core: the A20 core registers, carrying the V40 core fields in a different arrangement (some with the 16-bit halves swapped, e.g. V40 `HLOCK3` 0x0FE9_502D = F1C `0xF3C` 0x502D_0FE9) |
| `0xF10` | burst gate: end [23:16], start [15:8] (V40 `TVD_CLOCK1`); **bit 22 set = noise output** (see below) |
| `0xF14` | [5:4] blue-screen mode (V40 `TVD_MODE`) |
| `0xF1C` | [23:16] chroma gain |
| `0xF24` / `0xF28` | AGC gate (V40 `TVD_CLAMP_AGC2`: `0x682` gate begin, `0x64` back porch, `0x40` width) |
| `0xF30` | default `0x21F07C1F` = V40 `TVD_CLOCK2` (NTSC C_SAMPLE_STEP); the vendor never writes it and setting the PAL value changed nothing, so 0x018 is the live subcarrier |

### Measured behaviour the driver relies on

- **Frame-done IRQ once per frame** (40 ms PAL), not per field.
- **The DMA address is double-buffered.** An address armed with `0x088` bit 28
  during frame N is latched about 80 us before frame N's done IRQ and used for
  frame N+1 (bit 28 self-clears at the latch). So the IRQ handler queues the
  next buffer one frame ahead with 40 ms of slack. The first boundary after
  enabling DMA mid-frame latches without a done IRQ, so the driver treats its
  first IRQ as a sync and completes nothing.
- **Both fields are woven into one buffer** (lines-per-field in `0x08C`, stride =
  width): `V4L2_FIELD_INTERLACED`.
- **The 3D comb filter is switched by three registers** (the vendor's
  `BSP_TVD_3D_COMB_Filter()`): program `0x04C/0x050/0x054`, arm `0x048 =
  0x04040001`, clear `0x008` bit 0, set `0x000` bit 4; off is the reverse.
  The driver runs it only while streaming, when its 2 MiB memory exists.
- **`0xF10` bit 22 must stay clear.** A bit-by-bit scan of the core
  registers on the TV-encoder bars found it: with `0xF10` [23:16] in
  0x40..0x7F or 0xC0..0xFF the decoder reports full lock but outputs
  per-pixel noise (Y ~62 rms, C ~25 rms, every bit plane random); with
  0x00..0x3F or 0x80..0xBF the bars are clean (noise ~1, edge jitter
  0.01-0.03 px, H and chroma DTOs on nominal). 0x20 and the vendor's 0x8A
  measured the same, also with the bars weakened to 45% amplitude or 10%
  chroma; the default is 0x8A (the value the standard tables write, and the
  only one of the two that is a window after the 0x32 start). An earlier
  default of 0x60, picked because the camera only locked colour with
  0x46..0x7C, caused all the "noise" reported below for 2026-10-15.

## 3. Clocking: pll-video fixed at 297 MHz

The TVD needs exactly 27 MHz. pll-video also feeds the TCON, whose clock had
`CLK_SET_RATE_PARENT`, so each modeset retuned the PLL to a multiple of the
pixel clock (100 MHz for the 25 MHz panel), from which 27 MHz cannot be divided.
Patch 0032 drops the flag; the board DT pins pll-video at 297 MHz and the
TCON's dclk divider finds the pixel clock from it:

| Clock | Before | After |
|---|---|---|
| pll-video | 100 MHz | 297 MHz |
| tcon-pixel-clock (ER-TFT050-6, 25 MHz mode) | 25 MHz | 24.75 MHz (/12) |
| 480x272 panel (10.8 MHz mode) | | 11 MHz (/27) |
| tvd | | 27 MHz (/11) |
| de-fe | 100 MHz | 297 MHz (the driver asks for 300) |

This matches the vendor Melis setup exactly (PLL_VIDEO `0x93006207`, TVD clock
`0x8000000A`). Display and wireless CarPlay video were unaffected on the bench.

## 4. Memory

| | Size | When |
|---|---|---|
| Module | ~18 KB | always (loaded at boot) |
| Capture buffers, NV12 720x576 | 608 KiB each, 3-4 typical | while streaming |
| Comb filter field memory | 2 MiB | while streaming with `comb_filter_3d=1` |

All from the 24 MiB CMA pool shared with cedrus and the display. Running the
camera *alongside* CarPlay video was not tested; `v4l2-compliance`'s
max-buffer tests fail allocations while FastCarPlay is running (expected; vb2
falls back to fewer buffers).

## 5. How it was brought up

Reference material:

1. **nminaylov/F1C100s_projects** `f1c100s/drivers/src/f1c100s_tvd.c` and
   `projects/tv_in_test`: working bare-metal F1C100s driver (NTSC, PAL-B). **GPL-3.0**:
   used for register facts and values only, no code copied.
2. **nminaylov/F1C100s_info** `LIB_RE/sys_tvd.c` (decompiled Melis `sys_tvd.o`:
   IRQ bit, DMA format bits) and `TVD_TVE/dump_tvd{1,2}_{pal,ntsc,nosignal}.txt`
   (full register dumps of Melis capturing: the golden reference that exposed
   the comb filter buffer and `0x000` bit 4).
3. **ihuguet/sunxi-tv-decoder** (LGPL-2.1): the A20 `sun7i_tvd` Linux 3.x
   driver; same decoder core, different layout.

Bench gotchas, each of which cost a board hang or reboot:

- **Never take a DMA address from `/dev/fb0`**: DRM fbdev reports
  `smem_start = 0` (`DRM_FBDEV_LEAK_PHYS_SMEM` is off), and a TVD DMA to phys 0
  wedged the bus (serial dead, power cycle needed).
- An earlier reading of the dumps took `0x040` bit 4 for the comb enable; it is
  a vendor constant. The real enable is `0x000` bit 4 (above).
- **Board-to-Pi bulk transfers wedge the ESP32 AP** (4 x 829 KB frame pulls did
  it): convert or thumbnail frames on the board, pull only small files.
- **Lock problems were wiring**: a solder bridge between the CVBS line and AGND
  gave V lock without H lock and an all-black picture (Y = 1). Fixed, it locked.

## 6. Open issues

### 2026-10-16: decoder clean on a known-good source, camera input still broken

- **TV encoder -> TVIN0** (the TVE's internal PAL colour-bar generator):
  100% H/V/colour/PAL lock, H DTO (`0xE44`) within +-7 ppm of nominal,
  noise ~1-2, correct bar colours. The remaining fine vertical stripes in
  the saturated bars (luma ripple ~14 in magenta, at the 4.43 MHz
  subcarrier) have the **same phase on every line and in both fields**; a
  standard PAL signal steps 3/4 cycle per line, which is what a line comb
  cancels. So the TVE bar generator's subcarrier is line-locked and no comb
  can remove it; judge Y/C separation on a real PAL source. `0xF44` (comb
  mode/factors) does not change it.
- **Camera -> TVIN0** (same settings): the line PLL never tracks the camera.
  `0xE44` swings +-4.7% (+-47000 ppm) under every `0xE2C` / `0xF10` setting
  tried; V lock 15-85%, no PAL or colour detect, the picture is dark and
  rolls, and 14-30% of the time the decoder reports no signal. The vendor
  clamp (`0xE2C = 0x00110000`) gives no H lock at all. Since the same
  settings lock the TVE perfectly, this is the input circuit (next section).
  Most likely: the TVE drives a DC-coupled signal whose sync tips sit above
  0 V even into the 75 ohm at the pin, while a camera with the usual
  AC-coupled output is centred on 0 V there, so its sync tips go below
  ground, which the ADC cannot digitise (not yet measured at the pin).
- A series capacitor **on the camera side of the pin's 75 ohm** does not help:
  0.1 uF into 75 ohm is a high-pass with a 7.5 us time constant (~21 kHz),
  which differentiates a 64 us video line and removes the field sync. The
  termination has to sit *before* the capacitor (next section).

### The input circuit: TVIN0 must not be tied to ground at the pin (probable root cause)

On this board TVIN0 has a 75 ohm resistor straight to AGND at the pin (the
reference CherryPi schematic does the same: R38, for an unrouted input). The
evidence that this breaks the decoder's analog front end:

- With the vendor/xboot ADC setting (`0xE2C = 0x00110000`, clamp step 1) the
  decoder reports **no signal at all**; only `0x60000000` (clamp off) shows a
  picture, while the vendor's dumps run locked with `0x00110000`. A whycan user
  with the same symptom on a Widora Tiny200 (F1C200s) posted `0xE2C = 0xB0000`
  and no signal; xboot's author answered that the board's TVD circuit is wrong:
  remove R30 so the CVBS signal is not grounded at the pin ("如果共地，则完全是一
  个白屏") ([whycan t_5612](https://whycan.com/t_5612.html), post #28).
- With the clamp off the picture is dark (camera white overlay at Y ~95 instead
  of ~235), has 2.5-3 px rms line jitter (the sync is not cleanly sliced), and
  as soon as PAL locks (`0xE40` bit 16) the decoder core outputs **uniformly
  random luma** (measured: frame-to-frame std ~68, adjacent rows uncorrelated,
  every byte rewritten each frame, forced blue screen clean). That happens with
  any comb mode, chroma gain 0, saturation 0, the TVE powered, the vendor or the
  A20 core values, and the xboot init sequence replayed register by register.

Fix to try (hardware): remove the 75 ohm resistor at the TVIN0 pin. Either
connect the camera straight to the pin (xboot's fix), or, better, terminate the
camera with 75 ohm to AGND on the camera side and feed the pin through a series
capacitor (0.1-1 uF), so the pin has no DC path to ground and the internal
clamp can set the level. Then retest with the vendor values: `0xE2C =
0x00110000` (the driver currently forces `0x60000000`) and burst gate end 0x8A.

(2026-10-16: the "uniformly random luma once PAL locks" below was the burst
gate end 0x60, not the input; see `0xF10` bit 22 above. The no-signal result
with the vendor clamp and the line jitter remain input problems.)

Other measured facts from the same session:

- The fixed vertical lines sit at the same image columns in NV12 and NV16 and
  move with the picture: most likely the camera sensor's column fixed-pattern
  noise in a dark scene, not the decoder.
- The 3D comb field memory is never written by the decoder (stays zero while
  streaming, `0x070` = 0x17 as in the vendor dump): the comb DMA does not run.
  Comb off gives the same picture today.
- Measuring tools (scratchpad, bench only): `camview` (zero-copy LCD viewer,
  `kill -USR1` saves two frames), `tvdcap` (V4L2 client; `FILL=0x55` poisons
  buffers), `tstat` (temporal noise, line jitter, column pattern), `cstat`
  (chroma statistics). The board's /tmp is only 8 MB: delete captures.

### D1s User Manual (TVD chapter, pp. 528-566): mapping and tests (2026-10-15)

The D1s TVD (2 inputs, 1 decoder, TOP block + TVD0 core, front end
"TVIN -> clamp -> PGA -> ADC") documents the same core as the V40 with default
values, which pins down more of the F1C layout:

- F1C `0xE2C` is at the D1s `TVD_ADC_CFG` offset (TOP +0x2C): CLP_STEP [18:16]
  (vendor `0x00110000` = step 1). D1s TOP `TOP_MAP`/`TOP_CTL`/`ADC_CTL`
  (`0xE00`/`0xE24`/`0xE28`) are not implemented on the F1C (writes read 0);
  `0xE0C` = 0x5 matches `ADC_CTL` ADC_EN + LPF_EN with AFE_EN = 0, and `0xE04`
  = 0x8002AAA8 matches `ADC_CFG` (stage ibias 0xAAA8, CLP_STEP 2, bit 31 ADC_TEST).
- The F1C 0xF00 core packs the D1s 16-bit halves differently: `0xF38` = HLOCK4
  swapped, `0xF3C` = HLOCK3 swapped, `0xF40` = HLOCK2 hi + HLOCK5 hi, `0xF84` hi
  = VLOCK1 hi, `0xF24`/`0xF28` = CLAMP_AGC2, `0x018` = CLOCK2, `0x00C`/`0x010` =
  ENHANCE1/2, `0xF10` [15:8] = CLOCK1 burst start, [7:0] = CLAMP_AGC1 AGC target.
- `0xE40` = D1s `TVD_STATUS4` bit for bit.

Tested from it, none changes the picture: AFE enable (`0xE0C` 0x7/0xF/0x17),
`0xE04` without ADC_TEST, with DATA_DLY, CLP_STEP 0..7; `0x054` as a
DEBUG1-like AFE gain mode (default 0x00100000, the vendor overwrites it with
0x200000); chroma gain 0x10..0xFF; chroma enhance. With the vendor clamp
(`0xE2C` = 0x00110000) the no-signal bit clears but H/V never lock (blue screen),
with any `0xE0C`/`0xE04` variant.

New measurements (brighter scene, unlocked Y mean 44 instead of 14): colour
lock still corrupts the luma, but less (temporal noise 30 instead of 67), and a
blur recovers the scene from the locked Y plane: the corruption is chroma-band
noise. At the same time the luma mean jumps from 44 to 99, so the decoder
re-levels and re-scales the luma once locked from its own sync/black-level
measurements, which the clamp-off front end makes unreliable.

### Earlier notes

(The colour noise and the "corrupted luma" in these notes and the D1s section
above were the burst gate end 0x60 with bit 22 set; see 2026-10-16.)

- **Picture quality (wiring):** dark picture even with contrast at 255, fixed
  vertical bright lines, and line jitter (sheared edges). `0xE30` reads about
  half the vendor's locked level (0x108 vs 0x1E1), so the input is probably
  still weak or loaded. Next: short shielded lead, ground close to AGND, check
  for a coupling capacitor on TVIN0, and confirm the camera on a TV.
- **Colour is locked but noisy.** With the burst gate fixed, colour lock holds
  and PAL is detected (`0xE40` 0x0005020E vs the vendor's 0x0005000E), but the
  chroma is dominated by noise: horizontal colour dashes, chroma rms ~39-62
  with ~zero mean, uncorrelated line to line, almost nothing left after 16x16
  averaging. Its spectrum has no beat line (so no subcarrier frequency error)
  and the luma has 15% of its energy in 3.9-5.0 MHz without a subcarrier peak:
  broadband input noise in the chroma band, which the decoder turns into colour
  noise. Comb mode (2D/3D), the burst gate within its window, the YC
  separation candidates in `0xF44` and `0xF30` changed nothing. Expected to
  improve with the wiring; until then `saturation=0` gives a clean
  monochrome picture.
- **Timestamp jitter:** buffer timestamps alternate around 20/60 ms (mean
  40 ms), with no dropped frames, which suggests late IRQ servicing. Not yet
  investigated.
- **Not implemented:** `V4L2_EVENT_SOURCE_CHANGE` (apps poll `ENUM_INPUT`
  status); the MB32-tiled output (`0x088` bit 24, the format Cedrus
  produces, so it would reuse FastCarPlay's DEFE path); 704-wide capture;
  display integration in FastCarPlay (`EXPBUF` -> DRM plane).
- **Unverified standards:** PAL-M, PAL-Nc, SECAM (vendor tables).
