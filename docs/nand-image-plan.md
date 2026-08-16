# Plan: build a NAND image in CI, flash it over USB

Status: **PLAN**, 2026-08-16. Target: the on-board 128 MiB SPI NAND, so the
board runs our firmware with no SD card.

## The premise needs correcting first

**`sunxi-fel` cannot write SPI NAND.** Verified twice: `fel-spiflash.c`
implements raw NOR opcodes only (`0x9F` JEDEC, `0x06` WREN, `0xD8`/`0x20`
erase, `0x02` page program) with no NAND command set, no ECC and no bad-block
handling; and the locally built `sunxi-fel v1.4.2-208-gd7bbd17` contains **zero**
mentions of NAND. Upstream tracks this as an open request (issue #163).

So "flash it with sunxi-fel over USB" has to mean:

```
FEL  ->  load U-Boot into RAM  ->  U-Boot writes the NAND
```

FEL supplies only RAM read/write and code execution. That makes **U-Boot with
SPI-NAND support a hard prerequisite**, not an optional extra. The good news is
that U-Boot 2026.04 already ships `drivers/mtd/nand/spi/gigadevice.c` — exactly
our chip's vendor — so this is configuration, not porting.

## Measured facts this plan is sized against

Chip, as the vendor kernel reports it:

```
spi-nand spi0.0: GigaDevice SPI NAND, 128 MiB
                 block 128 KiB, page 2048 B, OOB 64 B
```

Stock layout, and how our artifacts fit into it:

| mtd | size | stock use | ours | headroom |
| --- | ---: | --- | ---: | ---: |
| 0 `u-boot` | 512 KiB | SPL + U-Boot | **422.3 KiB** | 89.7 KiB |
| 1 `kernel.itb` | 5.5 MiB | FIT | **4.71 MiB** (zImage+dtb) | 1.05 MiB |
| 2 `rom` | 64 MiB | squashfs ro | **~25 MiB** squashfs | ~39 MiB |
| 3 `overlay` | 48 MiB | jffs2 rw | jffs2 rw | — |

The rootfs number is the one that decides viability: 64 MiB of content, and
`tar.xz` of the whole tree is **21.8 MiB**, so squashfs-xz lands around 25 MiB
in a 64 MiB partition. Comfortable. (Dominated by libavcodec 12.4 MB,
libavfilter 3.8, libcrypto 3.6, fastcarplay 3.2.)

**Board RAM is 64 MiB** — this constrains FEL staging more than anything else.

## Decision: mirror the stock partition layout

Rather than invent one. It is proven on this exact hardware, every one of our
artifacts fits, our existing backup maps onto it 1:1 for restore, and it keeps
the option of running the *stock* U-Boot if ours misbehaves.

---

## Stage 1 — U-Boot that can see and write the NAND

**Files:** `board/lctech/pi-f1c200s/uboot-sdcard.fragment` (or a new
`uboot-nand.fragment`).

Today the config has only `CONFIG_MTD=y` and `CONFIG_SPI=y` — the framework and
the controller, but no driver and no command. Add:

```
CONFIG_DM_MTD=y
CONFIG_MTD_SPI_NAND=y     # selects MTD_NAND_CORE + SPI_MEM
CONFIG_CMD_MTD=y          # plain bool, no default -- `mtd` does not exist without it
```

`MTD_SPI_NAND` depends on `DM_MTD` **and** `DM_SPI`; confirm the sunxi SPI
driver is enabled under DM. The U-Boot DT also needs the `spi-nand` node under
`&spi0` (the Linux DTS has it; check U-Boot's copy).

**Exit criterion:** at the U-Boot prompt, `mtd list` reports a 128 MiB device
with 128 KiB erase blocks.

**Watch the size.** Our U-Boot is 422.3 KiB in a 512 KiB partition — 89.7 KiB
spare. MTD + SPI-NAND + the `mtd` command will eat into that. If it overflows,
the partition layout has to change, which invalidates the "mirror stock"
decision. Measure `u-boot-sunxi-with-spl.bin` after this stage before going on.

**Not in scope here:** booting *from* NAND. That is SPL-side SPI support and is
a separate question from U-Boot being able to *write* the chip.

---

## Stage 2 — Kernel and rootfs that can live on NAND

**DTS patch (new, 00xx):** add a `partitions` node under the `spi-nand` chip
with the four fixed-partitions above. Without it our kernel presents the whole
chip as a single `mtd0` — deliberate for backups, wrong for booting.

**Kernel fragment:** `CONFIG_SQUASHFS` (+ `SQUASHFS_XZ`), `CONFIG_JFFS2_FS`,
`CONFIG_OVERLAY_FS`. `MTD`, `MTD_BLOCK` and `MTD_SPI_NAND` already landed.

**Buildroot:** `BR2_TARGET_ROOTFS_SQUASHFS=y` *alongside* the existing ext4, so
one build produces both the SD image and the NAND rootfs.

### The rootfs is WRITABLE -- decided 2026-08-16, option A

squashfs lower layer + writable upper layer, unioned by overlayfs, exactly as
the vendor firmware does it. **`/` is read-write from userspace's point of
view.** `touch /etc/wifi-enabled` succeeds and the file lands in the upper
layer; `/etc` edits, `/var` writes and the `/etc/*-enabled` flag files
(`wifi on`, `ap on`, `autorun`, `swap-disable`) all behave normally.

An earlier draft of this plan claimed a squashfs root would break the flag-file
pattern and called it "the biggest hidden cost". **That was wrong** and is
struck. It would only hold for a bare squashfs root with no overlay.

Why this over a plain writable UBIFS root, which was the alternative: this board
loses power the instant the ignition goes off. With the overlay, the OS lives in
squashfs and **nothing ever writes to it**, so a power cut cannot corrupt the
system -- only the overlay, which is erasable and rebuildable. A live UBIFS root
is far more robust than jffs2 and handles unclean shutdown well, but a bad
enough corruption takes the OS with it and needs a reflash. This is the same
reasoning that put logs on their own partition, applied to the whole rootfs. It
also boots faster (squashfs mounts instantly; UBI has to attach and scan) and is
the arrangement already proven on this exact hardware.

  layer      where           filesystem   notes
  lower      mtd2 "rom"      squashfs-xz  ~25 MiB, immutable, never written
  upper      mtd3 "overlay"  jffs2        48 MiB, all runtime writes land here
  union      /               overlayfs    what userspace sees, read-write

What this still needs:

  - **Early userspace to assemble the union.** Stock uses `init=/preinit`:
    mount the upper, mount the lower, `mount -t overlay`, then pivot into it.
    We need the equivalent -- a small initramfs or a `preinit` shipped inside
    the squashfs. This is the one genuinely new piece of machinery.
  - **First-boot format of mtd3.** jffs2 formats itself on first mount of an
    erased partition, so flashing just needs to erase mtd3, not write it.
  - **`/var/log`** no longer needs its own partition: it is simply a directory
    on the overlay. `S01logs` and the p3 mount become SD-only concerns. Keep
    the size bounding -- the overlay is 48 MiB and a runaway log fills it.
  - **Swap**: not applicable, and already disabled by `/etc/swap-disable`.

Upper-layer filesystem choice: jffs2 is what stock uses and is proven here, but
it scans the whole partition at mount, so both boot time and RAM scale with the
48 MiB. If that proves slow on our kernel, UBIFS for the upper layer is the
drop-in alternative -- at the cost of pulling UBI in.

---

## Stage 3 — CI emits a NAND bundle

Alongside `sdcard-*.img.xz`, produce `nand-<sha>.tar.gz` containing:

```
u-boot-sunxi-with-spl.bin     -> mtd0
kernel.itb                    -> mtd1   (FIT: zImage + dtb)
rootfs.squashfs               -> mtd2
MANIFEST.txt                  offsets, sizes, sha256 of each
flash-nand.sh                 the host-side FEL script (Stage 4)
```

`kernel.itb` needs a FIT `.its` (kernel + fdt). **Gzip the kernel inside the
FIT**: 4.71 MiB raw leaves only 1.05 MiB spare in a 5.5 MiB partition, and a
compressed kernel roughly halves that, buying real headroom for kernel growth.

No `overlay` image ships: jffs2 formats itself on first mount of an erased
partition. Erasing mtd3 is part of flashing.

---

## Stage 4 — The FEL flashing procedure

`sunxi-fel uboot` starts U-Boot and then **exits**, so there is no interactive
session to drive. Two ways to get commands executed:

**Preferred — a U-Boot script, fully automated, no serial needed:**

1. `sunxi-fel write <addr> …` each artifact into RAM
2. `sunxi-fel write <addr> flash-nand.scr` (a `mkimage -T script` image)
3. `sunxi-fel uboot u-boot-sunxi-with-spl.bin` — U-Boot starts and its
   `bootcmd` sources the script, which runs `mtd erase` + `mtd write` for each
   partition from the RAM addresses

**Fallback — drive the U-Boot prompt over serial** (the `board-serial` skill
already does this for Linux). Simpler to debug, needs the cable.

**The real constraint is RAM.** DRAM is 64 MiB at `0x80000000`
(`0x80000000`–`0x84000000`). U-Boot relocates to the top; the existing bootcmd
already uses `0x80008000` (zImage) and `0x80C00000` (dtb). Staging a ~25 MiB
squashfs plus a ~2.5 MiB FIT plus U-Boot itself is feasible but not roomy —
budget the map explicitly, and if the rootfs ever outgrows it, write mtd2 in
chunks (`mtd write` supports an offset and length) rather than one shot.

---

## Stage 5 — Verification

```
mtd list                       # 128 MiB, 4 partitions, 128 KiB erase
mtd read  <part> <addr> …      # read back and compare against the sha256s
```

Then boot from NAND with no SD card inserted and confirm the same acceptance
tests the SD image passes. Keep the SD card as the fallback throughout.

**Restore path, already in hand:** `~/projects/f1c200s/nand-backup/` holds the
stock `u-boot`, `kernel.itb` and `rom` images, all three verified byte-exact,
so the vendor firmware can be put back. (`mtd3-overlay.bin` is a torn image —
the jffs2 was mounted read-write while being read — but an overlay is meant to
be erased and rebuilt, so this does not block a restore.)

---

## Risks

- **U-Boot outgrowing 512 KiB** (89.7 KiB spare today). Measure after Stage 1.
- **RAM staging** for a 25 MiB rootfs on a 64 MiB board. Chunked writes are the
  mitigation.
- **The overlay filling up.** 48 MiB, and everything written at runtime lands
  there -- logs above all. On squashfs+overlay a full upper layer makes `/`
  appear full even though the OS itself is fine, which reads as a confusing
  failure. Carry the log bounding from `S01logs` across to it.
- **The preinit/union step is new machinery.** If it fails the board does not
  boot, and the failure is early, before any console output we control. Get it
  working from SD first, where the fallback is trivial.
- **Bad blocks.** `mtd write` skips them; a naive `dd`-style write would not.
  Never write the NAND with anything that is not bad-block aware.
- **Booting from NAND is unproven** — Stage 1 only gives write capability. If
  SPL cannot load U-Boot from SPI, the board still needs an SD to boot even
  with a fully populated NAND.

## Cheaper alternative worth stating

**Writing the NAND from Linux booted off the SD card works today.** The image
already carries `MTD_SPI_NAND` plus `nanddump`/`nandwrite`/`flash_erase`, and a
real shell is far more pleasant than U-Boot's. It needs an SD card at flash
time, which the FEL route does not — that is the entire difference. If the goal
is field/factory flashing of blank boards, do the FEL work; if it is developing
against NAND, the SD route needs no new work at all.
