# F1C200s hardware-specific gotchas (hard-won)

The F1C200s (Allwinner suniv / `sun8iw8`) is ARM926EJ-S (ARMv5TE, **soft-float**,
no FPU/NEON), **64 MiB** 16-bit DDR, no HDMI. These bit us; they are encoded in the
patches/config but documented here so they are not re-discovered.

## Boot / memory
- **CMA has a low boot ceiling.** The reservation runs in `setup_arch` *before the
  console*, so an over-large pool hangs at **"Starting kernel" with zero output**.
  `CONFIG_CMA_SIZE_MBYTES=32` does **not** boot; **16 boots**. ≥720p decode needs a
  dedicated VE `reserved-memory` carveout, not a global CMA bump. (`linux.fragment`)
- **A pre-console hang ≠ a driver bug.** A driver hang prints boot messages first;
  "no output at all" = pre-console (CMA/`setup_arch`) or a corrupt boot FAT.
- **ffmpeg v4l2-request** bundles a coded OUTPUT buffer **per DPB frame**; the
  upstream hardcoded 4 MiB × DPB ≈ 24–44 MB blows past 64 MB. `patches/ffmpeg/0002`
  right-sizes it to `max(1 MiB, w×h)`.

## Display
Moved to **[display.md](display.md)** — pipeline (DEFE/DEBE/TCON), panel
timings, U-Boot splash + the 2026.04 fb-reservation trap, DEFE EN-bit31 and
DEBE-YUV422 quirks, runtime boot splash, FastCarPlay DRM rendering.

## Serial console
- The board's USB-C serial is **UART1** (PA2/PA3, CH340). The DT aliases
  `serial0 → uart1`, so the Linux console is `ttyS0`. U-Boot's mainline
  `lctech_pi_f1c200s` board already sets `CONS_INDEX=2` and ships the uart1 DT
  (`suniv-f1c200s-lctech-pi`), so no U-Boot patch is needed; `uboot-sdcard.fragment`
  only adds the SD bootargs/bootcmd.
- Some **CH340/CH341** adapters stay **silent unless DTR/RTS are cleared** on open.

## USB (host ⇄ slave switch)
- The OTG port defaults to `dr_mode = "peripheral"` in the in-tree DT.
  `patches/linux-lctech/0004` overrides it to **host** for the CarPlay/AA dongle.
- For the SSH dev loop, keep peripheral mode and use **g_ether** (`usb0`, Type-C
  straight to the host — power + a deterministic link, no adapter). `S42usb-gadget`
  brings the gadget up; it is simply unused in host mode.

## Toolchain / decode
- ARMv5 **soft-float** — the libcedarc blobs must be the `toolchain-sunxi-arm9-glibc`
  variant; the `arm-linux-gnueabi` variant is ARMv7 Thumb-2 and **SIGILLs** on ARM926.
- **libcedarc ION must be uncached** on this part: the kernel ion cache-flush
  clobbers VE-written frames with dirty-zero cache lines → the CPU reads zeros
  (green). `package/libcedarc/libcedarc.mk` allocates ion buffers write-combine.
  (Same cache-coherency class as the cedrus `vb2_plane_vaddr` trap in
  `docs/cedrus-status.md`.)
