---
name: kernel-patch-triage
description: Classify every patch in patches/linux-lctech against a target kernel tag before attempting a version bump — which are now upstream and can be dropped, which apply unchanged, which need a rebase, and which must be re-derived. Use when planning or executing a kernel upgrade (6.6 -> 6.18, 6.18 -> 7.x, or an LTS point-release jump).
---

# Triaging our kernel patches against a new tag

Goal: before touching `config.env`, know exactly what each patch costs at the
target version. The output is a per-patch verdict, and the expensive surprises
(a patch that is now upstream, a file that moved 200 lines under you) surface
in minutes instead of during a rebase.

Everything below is source comparison against the two tags. **It proves
nothing about whether the kernel builds or boots** — say so in the write-up.

## Procedure

### 1. Map each patch to the files it touches

```sh
cd patches/linux-lctech
for p in *.patch; do
  files=$(grep -E "^\+\+\+ b/" "$p" | sed 's|^+++ b/||' | tr '\n' ' ')
  printf "%-58s %s\n" "${p%.patch}" "$files"
done
```

### 2. Measure drift per file between the two tags

For every touched file, fetch both versions and count changed lines. Small
drift means offsets; large drift means the patch must be re-derived.

```sh
for v in v6.6 v6.18; do
  curl -s "https://raw.githubusercontent.com/torvalds/linux/$v/$FILE" -o "x-$v"
done
diff x-v6.6 x-v6.18 | grep -c '^[<>]'
```

Rules of thumb from the 6.6 -> 6.18 pass: 0 lines = applies unchanged;
under ~50 = rebase with offsets; over ~150 = re-derive from scratch
(`spi-sun6i.c` moved 167 lines and cannot be rebased mechanically).

### 3. Ask, per patch, whether the fix is already upstream

This is the highest-value step and cannot be inferred from drift — grep the
target file for the thing the patch adds:

```sh
curl -s ".../$TAG/drivers/dma/sun4i-dma.c" | grep -nE "suniv|f1c100s"
```

Three outcomes:
- **Present upstream** -> drop that hunk. (6.18 gained the whole sun4i-dma
  suniv backport *and* the `dma-controller@1c02000` DT node, collapsing patch
  0014 from 611 lines to ~5.)
- **Absent** -> patch still needed.
- **Present but still wrong** -> patch still needed *and* it is an upstream
  bug-fix candidate. Check this deliberately: at 6.18 the DDMA IRQ-bit bug
  (0019) and the cedrus mv-col leak (0020) were both still live in mainline.

### 4. Check the DTS base separately

DTS patches usually dominate the count and are usually free. Diff the board
file and the SoC include:

```sh
arch/arm/boot/dts/allwinner/suniv-f1c200s-lctech-pi.dts   # board
arch/arm/boot/dts/allwinner/suniv-f1c100s.dtsi            # SoC
```

If the board file is unchanged between tags, every board-DTS patch applies as
is. Watch the `.dtsi` for **new upstream nodes that collide with ours** — 6.18
added both a `dma` node (ours duplicated it) and an audio `codec` node.

### 5. Check the infrastructure, not just the patches

- Does the pinned Buildroot offer the headers symbol?
  `git -C buildroot show <tag>:package/linux-headers/Config.in.host | grep CUSTOM_<ver>`
  and check `package/linux-headers/` for the version directory.
- Toolchain floor: `Documentation/process/changes.rst` at the target tag
  (6.18 needs GCC >= 8.1, binutils >= 2.30; Buildroot 2026.05 defaults to GCC 14.x).
- Out-of-tree drivers are separate work: the cedar BSP driver (`CEDAR_REF` in
  `config.env`) and `package/esp-hosted-ng`. For those, diff the *kernel
  headers* they consume between tags rather than the driver itself, and check
  whether upstream already carries `LINUX_VERSION_CODE` gates covering the
  target.
- Confirm whether a subsystem **moved**. Cedrus is still under
  `drivers/staging/media/sunxi/cedrus/` at 6.18; if it graduates to
  `drivers/media/`, every cedrus patch path changes.

## Output

A table of patch -> verdict (`drop` / `apply clean` / `rebase` / `re-derive`),
the infrastructure deltas, and an explicit list of what was **not** verified.
Write it to `docs/kernel-<version>-upgrade.md` in the style of
`docs/kernel-6.18-upgrade.md`, which is the worked example for this procedure.

## Traps

- **Do not trust a stale port branch.** `kernel-7.1` carries 7 patches against
  dev's 20; branch from `dev`, not from an old attempt.
- Grep patterns lie. `grep "SUNXI_CCU_GATE(ve_clk"` returned nothing on one
  fetch and the line was there — download the file and grep locally rather
  than piping curl straight into grep for anything load-bearing.
- A patch can be *partly* upstream. Split it rather than dropping it whole.
