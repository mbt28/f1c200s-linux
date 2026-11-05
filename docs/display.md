# Display: pipeline, splash, and rendering on the Lctech Pi F1C200s

Everything display-related in one place: the hardware pipeline, the U-Boot and
Linux bring-up, the boot-splash system, and how FastCarPlay renders.

## Hardware pipeline

```
decode (VE)          scanout
tiled NV12  ──►  DEFE (front-end: de-tile MB32/NV12_32L32 + BT.601 CSC + scale)
                      │
UI / fb0    ──►  DEBE (back-end: 4 layers, ARGB blending, zpos 0-3)
                      │
                  TCON (RGB666 parallel) ──► 5.0" 800×480 panel (er-tft050-6)
```

- **Panel timings** (kernel `panel-simple` entry, mirrored in U-Boot): 9 MHz
  pixel clock, H front/sync/back = 8/4/40, V = 8/4/40, both syncs active low,
  18-bit RGB666 bus.
- **Backlight**: plain enable GPIO on **PE6**, active high (`gpio-backlight`).
  Without it the panel is driven but stays dark.
- **DEBE layers**: 4, all support ARGB8888, mutable zpos, and exactly **one**
  plane may alpha-blend (the DE has two pipes). The DEFE-routed plane cannot
  carry alpha (opaque video), which is exactly the stack we use.

## Linux side (sun4i DRM)

- Binds through the sun4i-a10 fallback compatibles; display nodes come from
  `patches/linux-lctech/0001` (LCD + GT911 touch).
- **DEFE suniv quirks** (`patches/linux-lctech/0005`): `EN_REG` bit31 resets
  to 1 on suniv and must be cleared or the front-end scans out black; the FIR
  scaler filter is bypassed (dead chroma otherwise). Both hardware-validated.
- **DEBE packed YUV422 is unusable** on this part (wrong colours) — video goes
  through the DEFE instead.
- **No LCD text console**: `FRAMEBUFFER_CONSOLE` is off; the fbdev emulation
  still provides `/dev/fb0` (XRGB8888) for the splash, but the console lives
  on serial. Keep `console=tty0` out of the bootargs.
- Plane topology as exposed to userspace: **primary** = NV12-capable,
  DEFE-routed when fed tiled NV12 via the atomic API (video); **overlay** =
  ARGB8888, alpha-blended above it (FastCarPlay's UI).

## U-Boot side (splash at power-on)

`patches/uboot/0001` enables `VIDEO_SUNXI` with the real panel mode:

```
CONFIG_VIDEO_LCD_MODE="x:480,y:272,depth:18,pclk_khz:9000,le:40,ri:8,up:40,lo:8,hs:4,vs:4,sync:0,vmode:0"
CONFIG_VIDEO_LCD_BL_EN="PE6"       # enable GPIO, NOT a PWM
# CONFIG_VIDEO_DT_SIMPLEFB is not set
```

Two hard-won 64 MiB lessons baked into the patches:

1. **`VIDEO_DT_SIMPLEFB` stays off** — the suniv DT has no simplefb template
   node (the fixup fails harmlessly), and the kernel has its own DRM driver;
   we do not want U-Boot shrinking the kernel's memory map.
2. **`patches/uboot/0002` caps the framebuffer reservation** (4K worst case =
   ~32 MiB = half the RAM). Without the cap, U-Boot 2026.04 relocates itself
   to ~31 MiB, its LMB no-overwrite region covers everything above ~13.5 MiB,
   and the relocated DTB lands inside the ~14 MiB the zImage decompresses
   over → silent death right after "Starting kernel ...". Diagnosis tools if
   this class of bug returns: the `Loading Device Tree to <addr>` boot line
   and `bdinfo` (full LMB dump).

**Handoff**: the U-Boot splash keeps scanning through early kernel boot (its
framebuffer sits inside the region Linux reserves for CMA, so nothing
scribbles on it), until the sun4i DRM probe takes the pipeline over ~1 s in.

## Boot splash (psplash)

psplash (`BR2_PACKAGE_PSPLASH`), as on LEHU OS: LEHU's badge full screen on
black, a flat amber progress bar under it and the last three init scripts
under the bar ("Starting network", ...).

- **The picture** is LEHU's badge (`lehu/assets/logo/lehu-display.svg`, also
  its CarPlay icon), rendered by
  `board/lctech/pi-f1c200s/splash/generate.py <lehu-display.svg>` (rsvg-convert
  + Pillow) into `lehu.png` beside it.
- **The look** is two patches to psplash (`patches/psplash/`, the same ones
  LEHU OS applies):
  - 0001: the colours, the flat bar, and up to three message lines under it
    (`|` in a message starts a new line);
  - 0002: psplash-systemd sending the units being started (LEHU OS only).
- **Init:** `S00splash` starts `psplash` as soon as `/dev/fb0` exists (the
  DRM pipeline defer-probes). `rcS` (`rootfs-overlay/etc/init.d/rcS`, Buildroot's
  own plus the splash) sends a progress step and the script's name per init
  script through `/run/psplash_fifo`, then `QUIT` after the last one.

```sh
psplash-write "MSG one|two|three"   # by hand, while it runs
psplash-write "PROGRESS 50"
```

FastCarPlay's ten themes, its psplash image and the raw-framebuffer
`S00splash` that blitted them were removed (git history has them).

## FastCarPlay rendering (`video-path = auto`)

Nothing in the settings selects a decoder or a renderer any more (app d58e335
dropped the `renderer` / `*-decode` keys): `video-path` defaults to `auto`,
which probes the V4L2 decoder nodes and whether it can become DRM master, then
picks one of three modes — `Drm` (we own KMS), `Sdl` (a desktop session owns
the screen) or `Headless` (no display). `video-path = hw|sw|headless` forces
one, for bring-up and for boards that lie. On the F1C200s auto resolves to Drm.

The F1C200s has **no GPU**, and SDL2's only embedded video backend (KMSDRM)
requires GBM + EGL — so the Sdl mode can never drive this panel. The DRM path
replaces it wholesale:

- **Video**: the decoder (cedrus or cedar) presents each frame itself —
  tiled-NV12 dma-buf imported as a DRM framebuffer and committed on the
  primary plane, which sun4i routes through the DEFE (hardware de-tile + CSC
  + scale, zero CPU per pixel).
- **UI** (home screen, toasts, debug): the UI code runs against an SDL
  *software* renderer targeting an offscreen surface (no SDL video driver
  involved), which is copied into double-buffered DRM dumb framebuffers on the
  ARGB **overlay plane** above the video. Per-pixel alpha is blended by the
  DEBE. The plane is disabled whenever there is nothing to show, so it costs
  no scanout bandwidth during playback. With `lvgl-ui = true` (set in
  `settings_drm.txt`) the LVGL screens replace the plain status home screen
  and render through that same surface.
- Both paths share one DRM master session (`src/drm_display.{h,cpp}` in the
  FastCarPlay fork).
- **Idle streams**: CarPlay sends frames only when the screen content
  changes. Video therefore counts as "flowing" from the first presented frame
  of a session until disconnect — never on a frame-recency timeout (that
  repainted the home screen over idle-but-live video once; fixed).

`video-path = headless` remains the minimal fallback: the app brings up no
display at all. Separately, the cedar decoder keeps its own `/dev/fb0` path
(CPU de-tile straight to the framebuffer) for when the DRM DEFE plane is
unavailable.
