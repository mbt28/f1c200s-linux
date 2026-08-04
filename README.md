# f1c200s-linux

[![build-image](https://github.com/mbt28/f1c200s-linux/actions/workflows/build-image.yml/badge.svg?branch=dev)](https://github.com/mbt28/f1c200s-linux/actions/workflows/build-image.yml)

Custom mainline-Linux + Buildroot setup for the **Lctech Pi F1C200s** (Allwinner
F1C200S / suniv, ARM926EJ-S / ARMv5TE soft-float, 64 MiB DDR, 480×272 LCD) used as
a CarPlay / Android-Auto receiver.

This repo is **patch-only**: it does **not** vendor the Linux kernel or Buildroot
trees. It ships the scripts, patches, configs and docs that fetch those from
upstream and apply our customizations. Hardware H.264 decode uses **cedrus** —
mainline, blob-free (V4L2 stateless). **Working — hardware-validated 2026-07-04:
colour-correct decode, no freezes.** The broken reconstruction was root-caused
2026-07-03 (the suniv VE has no internal SRAM for the H.264 deblock/intra-pred
working data; the old variant was also wrongly modelled on the V3s) and fixed by
patches 0006-0009 (`docs/cedrus-status.md`).

The Allwinner BSP path (`cedar_ve` + ION + the `libcedarc` blobs) was **dropped
on the `kernel-6.6` branch** once cedrus was validated: it was the only remaining
binary-blob dependency, and its out-of-tree driver was the highest-risk item in
any kernel upgrade. `main` still carries it; see `docs/kernel-6.18-upgrade.md`.

## Branches

| branch | kernel | state |
|---|---|---|
| `main` | 6.6.143 | **stable**: every commit hardware-validated; cedrus default, cedar still present; releases are tagged here |
| `dev` | 6.6.143 | integration — day-to-day work; CI builds a flashable image per push |
| `feature/*` | — | short-lived experiment branches off `dev`, merged back via PR |
| `kernel-6.6` | 6.6.143 | cedrus-only: the cedar/ION blob path removed; CI builds an image per push |
| `kernel-7.1` | 7.1.2 | parallel 7.1 track, same fixes; open: freezes under decode — a 7.1-specific regression (main is freeze-free with identical patches); clone with `-b kernel-7.1` |

Workflow, CI details and release steps: `docs/development.md`. Every push to
`dev`/`main` gets a CI-built `sdcard.img` (Actions → run → Artifacts); `v*`
tags attach the image to a GitHub Release.

The former `cedrus-6.6-backport` branch was merged into `main` and deleted —
existing checkouts of it: `git fetch && git checkout main`.

## Quickstart

```sh
git clone https://github.com/mbt28/f1c200s-linux.git
cd f1c200s-linux
scripts/fetch-sources.sh          # clones Buildroot (pinned) + the cedar driver
scripts/build.sh                  # downloads Linux 6.6.143 + U-Boot 2026.04, builds
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
patches/linux-lctech/      0001 LCD+GT911 · 0002 VE-clk→PLL_VE · 0003 cedar+cedrus VE DT ·
                           0004 USB-OTG host · 0005 DEFE frontend · 0006-0009 cedrus suniv
                           fix (ext deblk/intra-pred bufs, MB reset, VE_MODE DRAM quirk,
                           A10-modelled variant) ·
                           0011 cedrus bounded VLD poll (hang hardening)
patches/ffmpeg/            v4l2-request hwaccel + buffer right-sizing
package/                   fastcarplay · esp-hosted-ng · libimobiledevice stack
rootfs-overlay/            init scripts (cedrus, usb-gadget, wifi/ap, aa-stack, carplay), autorun
tools/cedrus_drm_test.cpp  dongle-free decode→DEFE test rig (with --dump)
docs/                      display · hardware-fixes · cedrus-status · ffmpeg-v4l2-request
```

Upstream sources land in `buildroot/` and `output/` — both git-ignored.

## Decoder

**cedrus only** on this branch. `/etc/init.d/S20cedrus` modprobes `sunxi-cedrus`
at boot (it is a module on purpose — see `linux.fragment`), giving `/dev/video0`.
There is no runtime choice and no `/etc/ve-driver` any more.

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

## Networking & remote access (SSH) — disabled by default

Networking is **opt-in**: nothing (USB ethernet, usb-gadget, dropbear) starts
at boot. Enable it on the running board — the choice persists across reboots:

```sh
net on       # bring up eth0/usb0 + start dropbear (persists via /etc/network-enabled)
net off      # stop everything and disable again
net status
```

Dropbear uses key auth — put your public key in
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

## FastCarPlay autostart

FastCarPlay launches at boot (`S99carplay`, log in `/tmp/carplay.log`).
Control it on the board — the choice persists across reboots:

```sh
autorun off      # disable the boot autostart
autorun on       # re-enable it
autorun status   # flag + running state
autorun stop     # kill the running instance
```

The manual `carplay` command still works and replaces a running instance.

## Boot splash (runtime-selectable)

```sh
echo 03-tux > /etc/splash-theme              # pick a theme -- persists, shows from next boot
zcat /etc/splash/03-tux.fb.gz > /dev/fb0     # instant preview, no reboot
```

Ten themes ship in `/etc/splash/`. Full display documentation (pipeline,
U-Boot splash, themes, FastCarPlay DRM rendering): `docs/display.md`.

## Versions

Linux **6.6.143** (base defconfig `sunxi`) · Buildroot **2026.05** · U-Boot
**2026.04** — all pinned in `config.env` / the defconfig.
