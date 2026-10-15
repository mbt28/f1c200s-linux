# Composite video input (TVD, TVIN0/TVIN1)

Status (2026-10-15): **driver working on the bench board.** A PAL camera on
TVIN0 streams through `/dev/video1` (NV12/NV16, 720x576, 25 fps), and
`v4l2-compliance -s 50` passes 80/80 tests with 0 warnings. The picture quality
is limited by the prototype wiring (see [Open issues](#6-open-issues)).

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
| `brightness` | 0..255 (32) | `0x00C` [15:8] | verified: shifts the black level |
| `contrast` | 0..255 (104) | `0x00C` [7:0] | verified: luma gain |
| `sharpness` | 0..255 (32) | `0x00C` [23:16] | per the RE notes; effect not measured |
| `saturation` | 0..255 (PAL 80, NTSC 128) | `0x010` [7:0] | reset to the standard's default on `S_STD` |
| `hue` | -128..127 (0) | `0x010` [15:8] | |
| `chroma_enhance` | 0..255 (48) | `0x010` [23:16] | vendor value 0x30; meaning per the RE notes |
| `blue_screen` | menu (2 = auto) | `0xF14` [5:4] | auto = blue frame while unlocked |
| `3d_comb_filter` | bool (on) | `0x040` bit 4 | takes effect at the next STREAMON; costs 2 MiB CMA while streaming |

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
| `0x000` | bit 0 decoder enable; bit 4 set by the vendor whenever capture DMA runs (driver: while streaming) |
| `0x008` | mode/standard select |
| `0x00C` | contrast [7:0], brightness [15:8], sharpness [23:16]; reset 0x01202080 |
| `0x010` | saturation [7:0], hue [15:8], chroma enhance [23:16] |
| `0x014` | ? prescaler (`0x20000000`) |
| `0x018` | chroma subcarrier = `f / 27 MHz * 2^32` |
| `0x01C` | h start [27:16], v start [10:0] |
| `0x040` | 3D comb control; **bit 4 = comb filter on, which DMAs into `[0x04C, 0x050)`** |
| `0x04C` / `0x050` / `0x054` | comb filter field memory start / end / size (vendor: 2 MiB) |
| `0x060..06C` | chroma frequency presets (read-only defaults: PAL, PAL-M, PAL-Nc, NTSC) |
| `0x080` / `0x084` | capture DMA Y / C address (full physical address) |
| `0x088` | DMA cfg: b0 enable, b4 = 422 (else 420), b8 UV swap, b24 = MB tiled, b26 size valid, **b28 address valid** |
| `0x08C` | DMA size: lines per field [26:16], width [11:0] (max 720) |
| `0x090` | DMA stride |
| `0x094` / `0x09C` | IRQ status (W1C) / enable; bit 24 = frame done |
| `0xE04` | ADC/input; init `0x8002AAA8`; bit 0 = TVIN1 |
| `0xE2C` | ADC ctrl: `0x00110000` before the core setup, `0x60000000` after (the Melis value 0x00110000 gives "no signal" here) |
| `0xE30` | ? two 16-bit levels (signal amplitude / clamp?) |
| `0xE40` | status: 0 no signal, 1 H lock, 2 V lock, 3 chroma lock, 8 progressive, 9/10 H/V non-standard, 16 PAL, 17 SECAM, 18 625 lines, 19 noisy |
| `0xE44` | ? gain / line-timing estimate (`0x2000_0000` nominal when locked) |
| `0xF00..F84` | decoder core (A20 core regs); `0xF14` [5:4] blue-screen mode |

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
- **The comb filter DMAs by itself.** The vendor and bare-metal init set `0x040`
  bit 4 with `0x04C`/`0x050` left at 0, so the field memory points at physical
  0 (SRAM, then unmapped space). The driver enables bit 4 only while streaming,
  with a real 2 MiB buffer.

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
| Comb filter field memory | 2 MiB | while streaming with `3d_comb_filter=1` |

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
- **The comb filter writes phys 0** if `0x040` bit 4 is set without a buffer
  (see above).
- **Board-to-Pi bulk transfers wedge the ESP32 AP** (4 x 829 KB frame pulls did
  it): convert or thumbnail frames on the board, pull only small files.
- **Lock problems were wiring**: a solder bridge between the CVBS line and AGND
  gave V lock without H lock and an all-black picture (Y = 1). Fixed, it locked.

## 6. Open issues

- **Picture quality (wiring):** dark picture even with contrast at 255, fixed
  vertical bright lines, and line jitter (sheared edges). `0xE30` reads about
  half the vendor's locked level (0x108 vs 0x1E1), so the input is probably
  still weak or loaded. Next: short shielded lead, ground close to AGND, check
  for a coupling capacitor on TVIN0, and confirm the camera on a TV.
- **Colour lock is intermittent** and the PAL bit (`0xE40` bit 16) never sets,
  unlike the vendor dump. Likely the same signal-level cause; recheck once the
  wiring is fixed.
- **Timestamp jitter:** buffer timestamps alternate around 20/60 ms (mean
  40 ms), with no dropped frames, which suggests late IRQ servicing. Not yet
  investigated.
- **Not implemented:** `V4L2_EVENT_SOURCE_CHANGE` (apps poll `ENUM_INPUT`
  status); the MB32-tiled output (`0x088` bit 24, the format Cedrus
  produces, so it would reuse FastCarPlay's DEFE path); 704-wide capture;
  display integration in FastCarPlay (`EXPBUF` -> DRM plane).
- **Unverified standards:** PAL-M, PAL-Nc, SECAM (vendor tables).
