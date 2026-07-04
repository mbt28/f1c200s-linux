# f1c200s-linux

Custom mainline-Linux + Buildroot setup for the **Lctech Pi F1C200s** (Allwinner
F1C200S / suniv, ARM926EJ-S / ARMv5TE soft-float, 64 MiB DDR, 480×272 LCD) used as
a CarPlay / Android-Auto receiver.

This repo is **patch-only**: it does **not** vendor the Linux kernel or Buildroot
trees. It ships the scripts, patches, configs and docs that fetch those from
upstream and apply our customizations. Two hardware H.264 decoders are supported
and selectable at boot:

- **cedar** — the Allwinner BSP VideoEngine + `libcedarc` blobs. **Colour-correct,
  working.** Driver fetched from a separate repo (`cedar/README.md`).
- **cedrus** — mainline, blob-free (V4L2 stateless). Reconstruction root cause
  found and fixed 2026-07-03 (VE has no deblk/intra-pred SRAM; patches 0006-0009,
  from `../cedrus-development/`) — **colour-correct on hardware**. Open issue:
  sporadic full-system freezes under sustained decode on 7.1.x, affecting BOTH
  decoders (not the cedrus fix; triage notes in `docs/cedrus-status.md`).

## Branches (pick one — the clone below already does)

| branch | kernel | state |
|---|---|---|
| `main` | 6.6.143 | v0.1.0 baseline — cedar validated; cedrus pre-fix (broken) |
| `cedrus-6.6-backport` | 6.6.143 | main + the cedrus reconstruction fix (colour-correct) |
| `kernel-7.1` | 7.1.2 | **this branch** — 7.1 port, same fix; open issue: sporadic freezes under decode |

## Quickstart

```sh
git clone -b kernel-7.1 https://github.com/mbt28/f1c200s-linux.git
cd f1c200s-linux
scripts/fetch-sources.sh          # clones Buildroot (pinned) + the cedar driver
scripts/build.sh                  # downloads Linux 7.1.2 + U-Boot 2024.01, builds
sudo dd if=output/images/sdcard.img of=/dev/sdX bs=1M conv=fsync   # your SD device!
```

Re-pin versions in `config.env`. Any Buildroot target is forwarded, e.g.
`scripts/build.sh menuconfig`, `scripts/build.sh linux-rebuild`.

## Layout (Buildroot external tree — this repo root is `BR2_EXTERNAL`)

```
config.env                 pinned versions + upstream URLs
scripts/fetch-sources.sh   clone Buildroot + cedar
scripts/build.sh           make BR2_EXTERNAL=. O=output <defconfig> && make
external.desc / .mk        BR2_EXTERNAL "CARPLAY"; injects cedar into the kernel
Config.in                  package menu
configs/…_defconfig        the board defconfig (paths are $(BR2_EXTERNAL_CARPLAY_PATH)-relative)
board/lctech/pi-f1c200s/   linux/uboot config fragments, genimage, post-build
patches/linux-lctech/      0001 LCD+GT911 · 0002 VE-clk→PLL_VE (+SET_RATE_PARENT) ·
                           0003 cedar+cedrus VE DT · 0004 USB-OTG host · 0005 DEFE frontend ·
                           0006-0009 cedrus suniv fix (ext deblk/intra-pred bufs, MB reset,
                           VE_MODE DRAM quirk, suniv variant — see
                           ../cedrus-development/ANALYSIS.md) · 0010 cedar ion heap ·
                           0011 cedrus bounded VLD poll (hang hardening)
patches/ffmpeg/            v4l2-request hwaccel + buffer right-sizing
package/                   fastcarplay · libcedarc · cedar-decode-test
rootfs-overlay/            /etc/ve-driver, init scripts (VE-select, usb-gadget), autorun
cedar/                     pointer + fetch of the cedar VE+ION driver (not vendored)
tools/cedrus_drm_test.cpp  dongle-free decode→DEFE test rig (with --dump)
docs/                      hardware-fixes · cedrus-status · ffmpeg-v4l2-request
```

Upstream sources land in `buildroot/`, `cedar/src/`, `output/` — all git-ignored.

## Choosing the decoder (both are built)

At boot, `/etc/init.d/S20ve-select` reads `/etc/ve-driver` and modprobes the chosen
engine. **Default is `cedar`** (the working, colour-correct decoder):

```sh
echo cedar  > /etc/ve-driver     # default — working, colour-correct (/dev/cedar_dev + /dev/ion)
echo cedrus > /etc/ve-driver     # blob-free, colour-correct (freeze issue open, see docs)
```

## USB: host (default) ⇄ slave

The OTG (Type-C) port is **host mode by default** — `patches/linux-lctech/0004`
forces `dr_mode = "host"` (the in-tree DT is `peripheral`). Host mode drives:
- the **CarPlay / Android-Auto dongle** (via libusb from FastCarPlay), and/or
- a **USB-to-Ethernet adapter** for remote access (see below).

> ⚠ VBUS on this socket is tied to the board Vin — **power the board from a second
> source** when hosting a dongle/adapter.

To use **slave/gadget** instead (peripheral + `g_ether`: one Type-C cable = power +
a `usb0` link to a dev host, no adapter), revert patch 0004 or set
`dr_mode = "peripheral"`/`"otg"`; `/etc/init.d/S42usb-gadget` then brings up `usb0`.

## Remote access (SSH)

Dropbear (key auth) is enabled — put your public key in
`rootfs-overlay/root/.ssh/authorized_keys` **before building**.

**Host mode + USB-Ethernet adapter (default):** plug the adapter into the OTG port;
`/etc/init.d/S41eth-dev` brings up **`eth0`** (DHCP first, else static
**`192.168.7.2/24`**) and prints the address on the serial console:

```
============ eth-dev: eth0 = <ip>   (ssh root@<ip>) ============
```

then from your host:

```sh
ssh root@<ip>              # or ssh root@192.168.7.2 if it fell back to static
```

Built-in USB-NIC drivers cover DM9601, AX8817x, AX88179, CDC-ECM, SMSC95xx.

**Slave mode + g_ether (dev):** `usb0` comes up static at **`192.168.8.2/24`**
(`S42usb-gadget`) → `ssh root@192.168.8.2` over the single Type-C cable.

File transfer is `ssh … cat` (dropbear has no scp/sftp); `lrzsz` (`rz`/`sz`) also
works over the serial console.

See `docs/hardware-fixes.md` for the OTG `dr_mode` switch and the rest of the
board gotchas (CMA boot ceiling, DEFE EN bit31, CH340 console, ION cache).

## Versions

Linux **7.1.2** (base defconfig `sunxi`; branch `kernel-7.1`) · Buildroot
**2026.05** · U-Boot **2024.01** — all pinned in `config.env` / the defconfig.
