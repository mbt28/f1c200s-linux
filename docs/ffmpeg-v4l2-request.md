# Userspace decode: ffmpeg V4L2 Request API → cedrus (Phase 3)

How CarPlay H.264 is decoded **blob-free** on the F1C200s: ffmpeg drives the
in-kernel **cedrus** stateless decoder through the **V4L2 Request API**, and the
tiled-NV12 output dma-buf feeds the existing sun4i **DEFE** display path.

## Stack
```
H.264 (USB) → ffmpeg (libavcodec h264 + v4l2_request hwaccel)
            → /dev/media0 + /dev/video0 (cedrus, V4L2 stateless)
            → tiled-NV12 (ST12) capture dma-buf → DEFE drm_show → panel
```
Upstream ffmpeg ships only the **stateful** `v4l2_m2m`; the **stateless**
`v4l2_request` hwaccel is out-of-tree, so we add it.

## Build integration (buildroot)
- **ffmpeg 8.0.3** (since 2026-11-05; 6.1.5 before), the same version and
  patches as LEHU OS's AGL ffmpeg. Buildroot 2026.05 packages 6.1.5, so
  `patches/buildroot/0001-package-ffmpeg-8.0.3-for-the-v4l2-request-hwaccels.patch`
  bumps its `package/ffmpeg` (version, hash, the options 8.0 dropped:
  postproc, crystalhd) and carries the libudev build-order dependency.
  `scripts/build.sh` applies `patches/buildroot/*.patch` to the checkout.
- **Patches** (`patches/ffmpeg/`, applied via `BR2_GLOBAL_PATCH_DIR`): Kwiboo's
  `v4l2-request-n8.0.1` series, 13 patches (h264/hevc/mpeg2/vp8/vp9/av1
  Request-API hwaccels, the `v4l2request` hwdevice). They apply clean to 8.0.3.
  The 6.1 series was one squashed patch plus `0002` (the coded-buffer right-size,
  see *Memory*), which 8.x no longer needs.
- **The hwdevice type.** In the 8.x series the hwdevice has its own type,
  `AV_HWDEVICE_TYPE_V4L2REQUEST` (`"v4l2request"`); in 6.1 it was DRM. The frames
  are `DRM_PRIME` in both. The apps look the type up by name and fall back to DRM
  (LEHU 81610e7, FastCarPlay and LIVI likewise), so they run on either.
- **Config knobs** (defconfig):
  - `BR2_PACKAGE_FFMPEG_EXTRACONF="--enable-v4l2-request --enable-libudev ...
    --disable-hwaccels --enable-hwaccel=h264_v4l2request,hevc_v4l2request"`
    (`--enable-libdrm` already on). Each 8.x hwaccel selects its decoder, so
    `--enable-hwaccels` would add mpeg2, vp8, vp9 and av1 to libavcodec.
  - `BR2_PACKAGE_LIBUDEV_ZERO=y` — provides `libudev` (device discovery) **without**
    switching the device manager (we stay on `devtmpfs`).
- **Kernel** (`board/lctech/pi-f1c200s/linux.fragment`): `CONFIG_CMA_SIZE_MBYTES=32`.

Verify on target: `ffmpeg -hwaccels` lists `drm`; `libavcodec.so` exports
`h264_v4l2request`. Decode: `ffmpeg -hwaccel drm -i clip.h264 -f null -`.

## Memory — the crux on a 64 MB part

cedrus uses `vb2-dma-contig`, i.e. **CMA**. Two facts collide on 64 MB:

1. **`free` ≠ contiguous.** A `cma_alloc` needs a *physically contiguous*,
   *aligned* span. With movable/pinned pages (e.g. the display framebuffer) in the
   shared CMA, a large contiguous request can fail with `-ENOMEM` even when MBs are
   "free". `CmaFree: 15 MB` still failed a 4 MB alloc.

2. **The hwaccel bundles a coded buffer per DPB frame.** `v4l2_request_frame_alloc`
   allocates an OUTPUT (coded) buffer **and** a CAPTURE (decoded) buffer for *every*
   pooled frame, and the pool grows to the **DPB** (~6–8 frames for H.264). The
   upstream code hardcodes the coded buffer at **4 MiB**:

   | coded buffer | per frame | × ~8 DPB | + 720p capture (~1.4 MB ea) | total |
   |---|---|---|---|---|
   | **4 MiB (upstream)** | 4 MiB | 32 MiB | +11 MiB | **~44 MiB** ❌ (> 64 MB) |
   | **right-sized (patch 0002)** | ~1 MiB | 8 MiB | +11 MiB | **~20 MiB** ✅ |

   Coded data is bounded by the raw frame size, so `0002` sized it to
   `max(1 MiB, width×height)` → ~1 MiB for ≤720p, auto-scaling at 1080p.
   **ffmpeg 8.x:** Kwiboo's 8.x code sizes it itself,
   `max(width×height×3/2, 256 KiB)` (`hwcontext_v4l2request.c`), about 0.55 MiB at
   800×480, in an OUTPUT pool of its own: `0002` is gone.

### Chosen values
| Knob | Value | Why |
|---|---|---|
| ffmpeg coded/OUTPUT buffer | `max(1 MiB, w×h)` | ~1 MiB ≤720p; the `×DPB` multiplier is what made 4 MiB fatal |
| `CONFIG_CMA_SIZE_MBYTES` | **16** | proven-bootable; holds the ≤480p pool (~7–13 MiB) |

> **CMA boot limit (64 MiB part).** The CMA reservation runs in `setup_arch`,
> *before* the console. Reserving too much wedges there with **zero kernel output**
> ("stuck at Starting kernel") — empirically **32 MiB does not boot**, 16 MiB does.
> So the global-CMA bump is capped well below what 720p wants.

**Resolution coverage with CMA=16 + the 1 MiB coded buffer:**
- 320×240 (proof) ~7–10 MiB ✅ · 800×480 ~13 MiB ✅ (no display buffer during
  `-f null`) · **720p ~20 MiB ✗** — exceeds a bootable global CMA.

**720p → dedicated VE carveout.** Because a *global* CMA large enough for 720p
won't boot, 720p uses a dedicated **`reserved-memory` region** bound to the VE node
(`memory-region`; cedrus' `of_reserved_mem_device_init` picks it up). It is
reserved at a fixed address at boot (no late `setup_arch` sizing failure) and is
fragmentation-free. Sized ~24 MiB it covers 720p; the OS keeps the rest. This is
the path for full-res CarPlay; the 16 MiB global CMA is the proof/≤480p default.
