# Roadmap: Linux 6.6.143 → 6.18.42

Analysis dated 2026-08-04, against `dev` (20 kernel patches). Every claim below
was checked by diffing real source/headers at the `v6.6` and `v6.18` tags --
**nothing here has been compiled or booted**. Treat it as a work plan, not a
green build.

Supersedes `kernel-7.1-upgrade.md` as the recommended next hop: 6.18 is a much
softer target than 7.1 (see "Why not 7.1 first"), and the `kernel-7.1` branch is
stale anyway -- it carries 7 patches against dev's 20, predating all the cedrus
h264, SPI/DMA, MUSB-DMA, ESP32 and mv-col work. **Branch fresh from `dev`.**

## Infrastructure -- no toolchain or Buildroot move needed

The pinned Buildroot 2026.05 already offers `BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_18`
and defaults to GCC 14.x; 6.18 needs GCC >= 8.1 / binutils >= 2.30. So unlike the
7.1 attempt (which needed 7.0 headers *and* GCC 14.3 -> 15.2), the only edits are:

- `config.env`: `LINUX_VERSION="6.18.42"`
- `configs/lctech_pi_f1c200s_sdcard_defconfig`:
  `BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="6.18.42"` and
  `BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_6=y` -> `..._6_18=y`
- `config.env`: `CEDAR_REF="master"` -> the ported ref (see below)

## Kernel patches

`suniv-f1c200s-lctech-pi.dts` is **byte-identical** 6.6 -> 6.18, so every
board-DTS patch applies unchanged. `suniv-f1c100s.dtsi` gained exactly two
upstream nodes (dma, codec) -- see 0014 and "Audio" below.

| Patch | Verdict at 6.18 |
|---|---|
| 0001 0003 0004 0010 0012 0013 (board DTS) | apply unchanged -- base file identical |
| 0014 sun4i-dma backport + spi1 | **collapses to ~5 lines**; driver + DT node now upstream |
| 0002 VE clock -> pll-ve | still needed; upstream unchanged (same line 314) |
| 0005 DEFE frontend | still needed; `sun4i_frontend.c` drifted 2 lines |
| 0009 cedrus suniv variant | still needed -- not upstream |
| 0019 DDMA IRQ bit | still needed -- **bug still in mainline 6.18** |
| 0020 mv-col leak | still needed -- no `buf_cleanup` upstream |
| 0016 0017 0018 MUSB DMA | easy rebase; musb files drifted 5-8 lines |
| 0006 0007 0008 0011 cedrus h264 | offsets + fixup; still in `staging`, drift 5-43 lines |
| 0015 spi-sun6i burst limit | **re-derive**; `spi-sun6i.c` drifted 167 lines |

### 0014 is the big win
Upstream 6.18 carries `suniv_f1c100s_dma_cfg`, `set_{dst,src}_data_width_f1c100s`
and `convert_burst_f1c100s` in `drivers/dma/sun4i-dma.c`, plus a
`dma-controller@1c02000` node in the dtsi identical to the one this patch adds.
The 611-line patch reduces to the board-DTS `spi1` dmas wiring, which upstream
still does not have. 0017 then wires musb DDMA onto a dtsi that already has the
dma node.

### Two of our patches fix live mainline bugs
- **0019**: 6.18 still does `reg |= BIT(pchan_number * 2)` while
  `SUNIV_NDMA_NR_MAX_CHANNELS` is 4, so suniv DDMA completion IRQs are enabled at
  the wrong bit and never fire.
- **0020**: `cedrus_video.c` at 6.18 has no `buf_cleanup` op, so the per-buffer
  mv-col leak on close-without-STREAMOFF is still there.

Both are upstream candidates when that task is resumed.

## Out-of-tree drivers -- both already handled

**cedar (BSP VE + ION): the port exists.** `mbt28/cedar` branch `kernel-7.1`
(HEAD `b9cf21f`) is 3 commits on the 6.6 baseline, ~60 lines, all mechanical:
shrinker API (6.7), `platform_driver.remove` returning void (6.11), `no_llseek`
removal (6.12), `MODULE_IMPORT_NS` string form (6.13), and an explicit
`<linux/plist.h>` (sched.h stopped including it). Every `LINUX_VERSION_CODE`
guard is keyed correctly for 6.18; the one guard keyed `>= 7.0.0` (around
`zap_vma`) is right, because `zap_page_range_single()` still exists at 6.18 with
an identical signature.
**Action:** `CEDAR_REF` must point at that branch (or merge it to master) --
`config.env` currently pins `master`, i.e. the unported driver.
**Note:** ION is a non-issue. It does not exist upstream at 6.18 *or* 6.6 (removed
in 5.11), so the vendored copy contributes zero delta; only the generic APIs it
consumes broke. The whole `dma_buf` API is unchanged between the two versions.

**esp-hosted-ng: zero source edits.** Espressif already ships version
conditionals up to `KERNEL_VERSION(6, 17, 0)`, and `struct cfg80211_ops` is
byte-identical between 6.17 and 6.18 (371 lines, no diff). Every driver gate
matches the kernel boundary exactly (`change_beacon` 6.7, `get_tx_power` 6.14,
`set_tx_power`/`get_tx_power`/`set_wiphy_params` radio_idx 6.17). `HCI_PRIMARY`
and `hdev->dev_type` are gone at 6.18 but the driver already `#ifdef`s them.
Our package pin (`53bdeeec`) needs **no change** -- it is new enough.

## Audio may start working (bonus)

6.6's `suniv-f1c100s.dtsi` has no audio codec node at all. 6.18 adds
`codec@1c23c00` (`allwinner,suniv-f1c100s-codec`) *and* `sun4i-codec.c` carries
suniv register/control support. The fragment already sets
`CONFIG_SND_SUN4I_CODEC=y`, and `settings_drm.txt` asks for `audio-driver = alsa`
while the app is still launched with `SDL_AUDIODRIVER=dummy`. Worth testing for a
real ALSA device after the bump.

## Risks / unknowns

- **The 7.1 freeze.** Recorded as a base-kernel regression (the same patches
  backported to 6.6 were freeze-free). Whether the cause landed before or after
  6.18 is unknown. Being 12 releases from 6.6 rather than ~19 reduces the odds,
  but only a hardware soak settles it. Keep the current image as fallback.
- **Nothing has been compiled.** All conclusions are declaration-level.
- `0015` is the one patch needing genuine re-derivation, not a rebase.
- Latent cedar bugs found in passing (pre-existing, not upgrade-caused):
  `dma_sync_sg_for_device(NULL, ...)` in 3 places (a no-op or NULL-deref at 6.18
  depending on `CONFIG_DMA_NEED_SYNC`), `dma_buf_map_attachment()` called without
  holding `dmabuf->resv`, and `sgt->nents` used where `orig_nents` is meant.

## Suggested order

1. Version/headers/CEDAR_REF bump; confirm the kernel builds with patches
   temporarily reduced to the DTS set.
2. Re-add driver patches in order; drop 0014's driver+dtsi hunks; re-derive 0015.
3. Boot: check cedrus decode, SPI/ESP32, MUSB host + DDMA, and the new codec.
4. Soak for the 7.1-class freeze before tagging.
