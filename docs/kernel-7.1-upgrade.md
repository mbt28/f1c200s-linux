# Roadmap: Linux 6.6.143 → 7.1.2 (keep both cedar + cedrus)

**Baseline:** tag `v0.1.0` — kernel 6.6.143, cedar + cedrus both working end-to-end
through FastCarPlay, runtime-selectable via `/etc/ve-driver` (default cedar).
**Target:** kernel 7.1.2, same dual-decoder pipeline working; tag `v0.2.0`.

Work on a branch `kernel-7.1`; keep `main` at v0.1.0 (known-good) until 7.1.2 is
validated on hardware, then merge + tag.

## Phase 0 — feasibility & prep
- [ ] Branch `kernel-7.1` from `main`.
- [ ] Confirm the pinned Buildroot can build a 7.1 kernel: needs a matching
      `BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_7_1` (or set headers = same as kernel).
      If Buildroot 2026.05 doesn't know 7.1 → bump `config.env` `BUILDROOT_VERSION`
      to a release that does. Confirm the ARM `sunxi` base defconfig still exists.
- [ ] Bump `config.env` `LINUX_VERSION` + defconfig `BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE`
      → `7.1.2`, and the `HOST_LINUX_HEADERS_CUSTOM_*` symbol.

## Phase 1 — kernel builds, patches rebased
Rebase `patches/linux-lctech/*` onto 7.1.2 (expect offsets/rejects; some may be upstream):
- [ ] DTS: 0001 (LCD/GT911), 0003 (cedar+cedrus video-codec node, **incl. the
      `allwinner,suniv-f1c100s-cedar` compatible**), 0004 (USB dr_mode=host),
      0007 (ion heap). Base `suniv-f1c200s-lctech-pi.dts` should still be mainline —
      likely apply with offset; re-diff if the base structure moved.
- [ ] 0002 VE clock → PLL_VE (`ccu-suniv-f1c100s.c`): check if fixed upstream; else rebase.
- [ ] 0005 DEFE frontend EN bit31 (`sun4i_frontend.c`): check upstream; else rebase.
- [ ] 0006 cedrus suniv variant (`cedrus.c`): **likely merged upstream by 7.1** — if so,
      DROP the patch; else rebase.
- **Done when:** `make linux` builds and `suniv-f1c200s-lctech-pi.dtb` contains both
      `allwinner,suniv-f1c100s-cedar` and `allwinner,sunxi-ion`.

## Phase 2 — cedar BSP driver port  (HIGHEST RISK)
BSP drivers rot fast across a major kernel jump.
- [ ] Port `mbt28/cedar` (`ve/cedar_ve.c` + `ion/`) to 7.1 kernel APIs — expect breakage
      in dma_buf / ion / v4l2 / misc-device / of / timer APIs. Do it on a `kernel-7.1`
      branch of `mbt28/cedar`; the `external.mk` hook injects whatever `cedar/src` holds.
- [ ] Verify `/dev/cedar_dev` + `/dev/ion` on 7.1. libcedarc userspace blobs are
      ARMv5/kernel-agnostic — no change expected there.

## Phase 3 — cedrus + ffmpeg on 7.1
- [ ] Verify mainline cedrus decodes on 7.1 (suniv variant + V4L2 stateless uAPI). If the
      sparse-reconstruction quirk resurfaces, see `docs/cedrus-status.md`.
- [ ] `patches/ffmpeg/*` (v4l2-request hwaccel + buffer right-size): the stateless uAPI
      may have shifted in 7.1 → update the hwaccel patch if the build/decoded output breaks.

## Phase 4 — integrate, build, verify, release
- [ ] Full clean-room build → `sdcard.img`.
- [ ] On hardware: both `/etc/ve-driver` modes; `carplay` shows video on cedar AND cedrus.
- [ ] Tag `v0.2.0`; merge `kernel-7.1` → `main`.

## Notes
- Validation env here can't reach kernel.org (all tarballs 404 in-sandbox) — the real
  7.1.2 download happens on the user's network, or drop the tarball in `buildroot/dl/linux/`.
- Keep `v0.1.0` as the fallback the whole time.
- Files that move: `config.env`, `configs/…_defconfig`, `patches/linux-lctech/*`,
  maybe `patches/ffmpeg/*`, `mbt28/cedar`, and these `docs/`.
