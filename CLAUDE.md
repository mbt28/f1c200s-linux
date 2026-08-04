# f1c200s-linux — working notes for Claude

Patch-only Buildroot external tree for the Lctech Pi F1C200s (Allwinner suniv,
ARM926EJ-S / ARMv5TE soft-float, **64 MiB DDR**, 480x272 LCD) used as a
CarPlay / Android-Auto head unit. The kernel and Buildroot are fetched from
upstream by `scripts/fetch-sources.sh`; this repo ships only patches, configs,
overlay and docs. See `README.md` for the full picture.

## Hardware rules — these break things

- **Never assert DTR or RTS on `/dev/ttyUSB0`.** On this CH341 wiring either
  line **resets the board**; a live debugging session was lost to it once. Set
  `dtr = False` and `rts = False` *before* opening the port. Use the
  `board-serial` skill, which handles this.
- **Verify the target before `dd`.** `/dev/mmcblk0` is the SD card; the Pi
  itself boots from NVMe (`/dev/nvme0n1p2`). Check `findmnt -no SOURCE /`
  first — writing the wrong device destroys the host.
- **Keep the ESP32 DevKitC USB unplugged while the board runs.** Its CP2102
  fights the IO3 handshake line. Plug it in only to flash the ESP32.
- **Do not install packages on the Pi** (no `apt`, no pip installs). Say what
  is needed and let the owner install it.
- **64 MiB of RAM total.** `board/lctech/pi-f1c200s/linux.fragment` has a
  deliberate RAM-diet section. Anything that grows the kernel or adds a
  resident daemon needs justifying; measure the `zImage` delta.

## Git conventions

- Commit as **`mbt28 <btekbas@gmail.com>`**. **Do not** add a
  `Co-Authored-By: Claude` trailer or any Claude/Anthropic attribution.
- **Never push without explicit approval.** Commit locally, summarise what
  changed, and wait. Pushing to `main`/`dev`/`kernel-7.1` triggers a CI image
  build (`.github/workflows/build-image.yml`).
- Branches: `main` = stable/hw-validated + tags, `dev` = integration,
  `feature/*` and `kernel-7.1` = tracks.

## Build facts

- Pinned versions live in `config.env` (Buildroot 2026.05, Linux 6.6.143,
  U-Boot 2026.04, `CEDAR_REF`). The kernel version must match
  `BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE` in the defconfig.
- Build with `scripts/build.sh` (wraps Buildroot; any Buildroot target is
  forwarded, e.g. `scripts/build.sh linux-rebuild`).
- A cold CI build takes ~80 min; warm (caches restored) ~25-30 min. GitHub
  evicts Actions caches after 7 days of no access, and `actions/cache` does
  **not** save when a job fails — so a failed build leaves the next one cold.
- Kernel config is `sunxi` defconfig + `board/lctech/pi-f1c200s/linux.fragment`
  + `linux-sdcard.fragment`. Fragments are merged **before** package
  `LINUX_CONFIG_FIXUPS`, and `olddefconfig` runs last.

## Kernel config traps

- **Menu gates.** A symbol whose gate is off is silently dropped by
  `olddefconfig`: `IPV6` needs `INET`, `CFG80211` needs `WIRELESS`, `VT` needs
  `EXPERT`, `I2C_CHARDEV` needs `I2C`. Always enable the gate too.
- **`olddefconfig` pulls in `default y` neighbours.** Enabling `USB_USBNET`
  dragged in `USB_NET_CDC_SUBSET`, `USB_ARMLINUX`, `USB_BELKIN`, `USB_NET_NET1080`,
  `USB_NET_ZAURUS`, `USB_RTL8153_ECM`. Diff the resulting config and disable
  what you did not ask for.
- A package that *needs* a kernel symbol should declare it in its
  `LINUX_CONFIG_FIXUPS` (see `package/fastcarplay/fastcarplay.mk`) rather than
  relying on the board fragment; `board/lctech/pi-f1c200s/post-build.sh` then
  fails the build if it is missing. Buildroot Kconfig cannot express a Linux
  config symbol, so `depends on` is not available.
- Verify what actually shipped by extracting the config from the built
  `zImage` (`CONFIG_IKCONFIG_PROC=y` bakes it in) rather than trusting the log.

## Target userspace

BusyBox: `ip` has no `-br`, `grep` has no `--line-buffered`, `dmesg` has no
`-w`. Device creation is **devtmpfs-only** — no udev, no mdev; the kernel
uevent helper (`/proc/sys/kernel/hotplug`, `CONFIG_UEVENT_HELPER=y`) is the
only hotplug hook, used by `rootfs-overlay/etc/init.d/S46usb0-up`.
