# Roadmap: Linux 6.6.143 → 7.1.2 (keep both cedar + cedrus)

**Baseline:** tag `v0.1.0` — kernel 6.6.143, cedar + cedrus both working end-to-end
through FastCarPlay, runtime-selectable via `/etc/ve-driver` (default cedar).
**Target:** kernel 7.1.2, same dual-decoder pipeline working; tag `v0.2.0`.

Work on a branch `kernel-7.1`; keep `main` at v0.1.0 (known-good) until 7.1.2 is
validated on hardware, then merge + tag.

## Phase 0 — feasibility & prep  ✅ DONE (config validated offline via `make defconfig`)
- [x] Branch `kernel-7.1` from `main` (both f1c200s-linux + mbt28/cedar).
- [x] Buildroot 2026.05 **can** build a 7.1 kernel — no Buildroot bump needed:
      - its linux-headers choice caps at `CUSTOM_7_0` (no `_7_1`), but the **kernel** is
        pinned via `CUSTOM_TARBALL` = a `git.kernel.org` stable-git **snapshot** URL
        (retention-proof; any version builds).
      - **headers = `CUSTOM_7_0`** (`AT_LEAST=7.0`) paired with **GCC 15.2.0**
        (`BR2_GCC_VERSION_15_X`). **LESSON:** kernel headers must be a version the
        toolchain's GCC supports — GCC 14.3.0's bundled **libsanitizer** can't compile
        against 7.0 headers (it hardcodes kernel structs newer than itself), so 7.0
        headers require GCC 15+. (Valid alternative, not taken: keep GCC 14.3.0 + 6.6
        headers — fine since headers ≤ kernel is only a userspace floor.)
- [x] defconfig bumped to 7.1.2: `CUSTOM_TARBALL_LOCATION` → `linux-7.1.2` snapshot;
      headers `CUSTOM_6_6` → `CUSTOM_7_0`; GCC `14.3.0` → `15.2.0`. Removed the redundant
      `CUSTOM_VERSION` lines
      (killed the "override: changes choice state" warning); the tarball URL is now the
      **single** version source and the scripts derive the banner from it.
- **Verify at build time** (needs kernel.org / a network): the 7.1.2 snapshot + the 7.0
  headers download, and the ARM **`sunxi`** base defconfig still exists in 7.1.2.
  If `sunxi` is gone/renamed, that's a Phase 1 fix (defconfig name).

## Phase 1 — kernel builds, patches rebased  ✅ series verified on 7.1 (2026-07-03)
Rebase `patches/linux-lctech/*` onto 7.1.2 (expect offsets/rejects; some may be upstream):
- [x] DTS: 0001 (LCD/GT911), 0003 (cedar+cedrus video-codec node, **incl. the
      `allwinner,suniv-f1c100s-cedar` compatible**; V3s fallback DROPPED — wrong VE
      class), 0004 (USB dr_mode=host), 0010 (ion heap, was 0007). All apply clean
      on 7.1 (verified against the 7.1 git tree; 7.1.2 delta expected nil).
- [x] 0002 VE clock → PLL_VE: NOT fixed upstream; replaced with a better patch
      (pll-ve + **CLK_SET_RATE_PARENT** — fixes the VE stuck at PLL_VE's 210 MHz
      power-on default).
- [x] 0005 DEFE frontend: NOT upstream; applies with 1-line offsets on 7.1.
- [x] 0006 cedrus suniv variant: NOT merged upstream. Old V3s-modelled patch
      REPLACED by the root-cause series 0006-0009 from `../cedrus-development/`
      (external deblk/intra-pred buffers, MB-position reset, VE_MODE DRAM quirk,
      A10-modelled variant without UNTILED). See ANALYSIS.md there.
- **Done when:** `make linux` builds and `suniv-f1c200s-lctech-pi.dtb` contains both
      `allwinner,suniv-f1c100s-cedar` and `allwinner,sunxi-ion`.

## Phase 2 — cedar BSP driver port  ✅ compiles on 7.1.2 (2026-07-03; HW pending)
BSP drivers rot fast across a major kernel jump.
- [x] Port `mbt28/cedar` (`ve/cedar_ve.c` + `ion/`) to 7.1 kernel APIs — actual breakage
      found+fixed on the `kernel-7.1` branch (all LINUX_VERSION_CODE-guarded, still
      builds on 6.6): void platform `.remove` (≥6.11), `no_llseek` removal (≥6.12),
      `MODULE_IMPORT_NS("string")` (≥6.13), explicit `<linux/plist.h>` (7.x header
      cleanup), `zap_page_range_single` → `zap_vma()` (7.x), and the 6.7+ shrinker API
      (`shrinker_alloc`/`shrinker_register`, private_data instead of container_of).
      `config.env` now pins `CEDAR_REF="kernel-7.1"`.
- [ ] Verify `/dev/cedar_dev` + `/dev/ion` on 7.1 **on hardware**. libcedarc userspace
      blobs are ARMv5/kernel-agnostic — no change expected there.

## Phase 3 — cedrus + ffmpeg on 7.1  ✅ builds (2026-07-03; HW pending)
- [x] cedrus builds on 7.1 with the new root-cause fix series (0006-0009, see
      `docs/cedrus-status.md` + `../cedrus-development/`); module carries the
      `allwinner,suniv-f1c100s-video-engine` of-alias, vermagic 7.1.2 ARMv5.
- [x] `patches/ffmpeg/*` (v4l2-request hwaccel + buffer right-size): apply clean
      (offsets only) — stateless uAPI unchanged; ffmpeg builds.
- [ ] **On hardware:** verify the reconstruction fix (expect sparse-luma/green gone;
      remove the XOR-0x80 chroma workaround from any test tooling first).

## Phase 4 — integrate, build, verify, release
- [x] Full clean-room build → `sdcard.img` (2026-07-03, `output/images/sdcard.img`,
      kernel 7.1.2 + U-Boot 2024.01; needed `--disable-libsanitizer` for the cross
      gcc — gcc 14.3's libsanitizer includes the removed `<linux/scc.h>`).
- [ ] On hardware: both `/etc/ve-driver` modes; `carplay` shows video on cedar AND cedrus.
- [ ] Tag `v0.2.0`; merge `kernel-7.1` → `main`.

## Notes
- Validation env here can't reach kernel.org (all tarballs 404 in-sandbox) — the real
  7.1.2 download happens on the user's network, or drop the tarball in `buildroot/dl/linux/`.
- Keep `v0.1.0` as the fallback the whole time.
- Files that move: `config.env`, `configs/…_defconfig`, `patches/linux-lctech/*`,
  maybe `patches/ffmpeg/*`, `mbt28/cedar`, and these `docs/`.
