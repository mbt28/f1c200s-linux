# f1c200s-linux

[![build-image](https://github.com/mbt28/f1c200s-linux/actions/workflows/build-image.yml/badge.svg?branch=dev)](https://github.com/mbt28/f1c200s-linux/actions/workflows/build-image.yml)

Mainline-Linux + Buildroot for the **Lctech Pi F1C200s** (Allwinner F1C200S /
suniv, ARM926EJ-S / ARMv5TE, 64 MiB DDR, 800×480 LCD) — a wireless **CarPlay /
Android-Auto** receiver. The head unit is **LEHU** (its Buildroot package is in LEHU's own
repository, `packaging/buildroot`, a second external tree), started
by the console's `f1c` login (`~/.profile`).

**Patch-only:** this repo ships the scripts, patches, configs and docs that
fetch the Linux kernel and Buildroot from upstream and apply our customizations
— it does not vendor those trees. Hardware H.264 decode uses mainline **cedrus**
(V4L2 stateless, blob-free) — hardware-validated, colour-correct, no freezes.
The Allwinner `cedar`/ION blob path was dropped once cedrus was proven; details
in `docs/cedrus-status.md` and `docs/kernel-6.18-upgrade.md`.

## Branches

| branch | kernel | state |
|---|---|---|
| `main` | 6.6.143 | **stable** — every commit hardware-validated; releases tagged here |
| `dev` | 6.6.143 | integration; CI builds a flashable image per push |
| `kernel-6.6` | 6.6.143 | cedrus-only (cedar/ION blob path removed) |
| `kernel-6.18` | 6.18.42 | 6.18 kernel; adds boot from on-board NAND (squashfs + UBIFS overlay) |
| `kernel-7.1` | 7.1.2 | parallel 7.1 track — open: freezes under decode (a 7.1 regression) |

Short-lived `feature/*` branches (e.g. `feature/spi-dma`) hang off `dev`. Every
push to a build branch gets a CI-built `sdcard.img` (Actions → run → Artifacts);
`v*` tags attach it to a Release. Workflow and release steps: `docs/development.md`.

## Quickstart

```sh
git clone https://github.com/mbt28/f1c200s-linux.git
cd f1c200s-linux
scripts/fetch-sources.sh      # clone Buildroot (pinned) + LEHU (its packaging)
scripts/build.sh              # fetch Linux + U-Boot, build the image
sudo dd if=output/images/sdcard.img of=/dev/sdX bs=1M conv=fsync   # your SD device!
```

Versions are pinned in `config.env`; any Buildroot target is forwarded, e.g.
`scripts/build.sh menuconfig` or `scripts/build.sh linux-rebuild`.

## The SD card

| | Start (sector) | Size | Type | Use |
|---|---|---|---|---|
| p1 | 1024 | 8 MiB | FAT (0x0c) | kernel, dtb, boot menu |
| p2 | 17408 | 512 MiB | Linux | the OSTree root (`docs/ostree.md`) |
| p3 | 1065984 | 64 MiB | Linux | `/var/log` |
| p4 | 1197056 | rest of the card | extended (0x0f) | holds p5-p7 |
| p5 | 1199104 | 64 MiB | swap (0x82) | emergency swap (`S03swap`) |
| p6 | 1332224 | 4 GiB | Linux | empty: LEHU OS's root, if it is installed (LEHU OS's `docs/dual-boot.md`) |
| p7 | 9723904 | the rest | exFAT (0x07), `LEHU-MAPS` | LEHU's map data, read-only on `/maps` |

`sdcard.img` holds p1-p5; it cannot know how big the card is. On the first boot of
a card flashed with it, `S02maps` grows p4 to the end of the card, adds p6 and p7,
and formats p7 empty. It never touches a card laid out differently, and never formats
a p7 it did not just make. The card needs about 6 GiB.

The map data is written to p7 on a PC (Windows, macOS or Linux) with a card reader:
the board mounts it read-only and never writes there, and no image or update carries
map data. A card without p7 still boots: `mount -a` reports the missing `LEHU-MAPS`
and LEHU uses `/var/lib/lehu` instead.

## Layout

This repo root is a Buildroot `BR2_EXTERNAL` tree (CARPLAY); LEHU's
`packaging/buildroot` is the second one (LEHU).

```
config.env                 pinned versions + upstream URLs
scripts/                   fetch-sources.sh · build.sh
configs/…_defconfig        the board defconfig
board/lctech/pi-f1c200s/   linux/uboot fragments · genimage · post-build · flash-nand.sh
patches/linux-lctech/      LCD+GT911 touch · VE/codec clocks · USB-OTG host · cedrus suniv fixes · audio codec
patches/ffmpeg/            v4l2-request hwaccel
package/                   livi · esp-hosted-ng · libimobiledevice stack
rootfs-overlay/            init scripts (cedrus · usb-gadget · wifi/ap · audio · splash) · f1c's .profile (LEHU)
docs/                      display · audio · hardware-fixes · cedrus-status · …
```

Upstream sources land in `buildroot/`, `lehu/` and `output/` (all git-ignored);
a symlink `lehu -> ~/path/to/lehu` makes the build use a local LEHU checkout's
packaging.

## Boot: SD card, or on-board NAND

The `sdcard.img` boots from an SD card. On `kernel-6.18` the board can also boot
from its on-board **128 MiB SPI NAND**, giving a self-contained device with a
**writable, persistent root**: a read-only squashfs (lower) unioned with a UBIFS
overlay (upper) via overlayfs, assembled by `/preinit`. CI emits a
`nand-bundle.tar.gz` next to the SD image; flash it with `flash-nand.sh` from an
SD boot (kernel + rootfs to NAND, the vendor bootloader kept).

> **NAND is a workaround, and SPI NOR is preferred.** Mainline U-Boot's SPL
> cannot boot SPI NAND on suniv, so the board keeps the **vendor bootloader**
> (with a one-time `bootm_size` env patch), and SPI NAND needs **UBIFS** to dodge
> a bad-block-marker conflict on this chip. SPI NOR has none of this — mainline
> boots it directly from the SPL, no bad blocks, no vendor bootloader — so the
> plan is to **move to a NOR flash chip** in the future.

## Runtime controls

All of these run on the board and **persist across reboots**:

```sh
net on | off | status        # eth0/usb0 + dropbear (SSH) — off by default
lehu                         # the head unit (the console's f1c login runs it; log: ~/.lehu/run.log)
```

## USB OTG: host (default) ⇄ gadget

The Type-C port is **host mode by default** (`patches/linux-lctech/0004`),
driving the CarPlay/Android-Auto dongle and/or a USB-Ethernet adapter.

> ⚠ VBUS is tied to the board Vin — **power the board from a second source**
> when hosting a device.

For **gadget mode** (one Type-C cable = power + a `usb0` link to a dev host), set
`dr_mode = "peripheral"`; `S42usb-gadget` brings up `usb0` at `192.168.8.2`.

## Networking / SSH (opt-in)

`net on` starts dropbear (key auth — put your public key in
`rootfs-overlay/root/.ssh/authorized_keys` **before building**). With a
USB-Ethernet adapter in the OTG port, `eth0` comes up (DHCP, else
`192.168.7.2/24`) and prints its address on the serial console:

```
============ eth-dev: eth0 = <ip>   (ssh root@<ip>) ============
```

Built-in USB-NIC drivers: DM9601, AX8817x, AX88179, CDC-ECM, SMSC95xx. File
transfer is `ssh … cat` (no scp/sftp) or `rz`/`sz` over serial. OTG switch and
the rest of the board gotchas: `docs/hardware-fixes.md`.

## Versions

Pinned in `config.env` / the defconfig. This branch (`kernel-6.18`): Linux
**6.18.42** · Buildroot **2026.05** · U-Boot **2026.07**. Stable `main`: Linux
**6.6.143** · U-Boot **2026.04**.
