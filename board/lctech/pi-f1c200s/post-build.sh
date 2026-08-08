#!/bin/sh
#
# Auto-login as root (no prompt) on the serial console (ttyS0) only. The LCD has
# no text console (FRAMEBUFFER_CONSOLE disabled) — the panel is owned by the
# video — so there is no tty1 getty. Uses busybox's canonical login-shell form
# (`-/bin/sh`), which busybox init runs as a root login shell.
# Deterministic / idempotent: drop any existing lines, then add ours.
#
set -e
TARGET_DIR="$1"
INITTAB="${TARGET_DIR}/etc/inittab"

sed -i '/^ttyS0::respawn:/d; /^tty1::respawn:/d' "${INITTAB}"
echo ''                                    >> "${INITTAB}"
echo '# Auto-login as root (serial console)' >> "${INITTAB}"
echo 'ttyS0::respawn:-/bin/sh'             >> "${INITTAB}"

# Logs live on their own SD-card partition (p3), never in the rootfs -- see the
# rationale in genimage-sdcard.cfg. Buildroot's skeleton ships /var/log as a
# symlink to ../tmp (i.e. RAM), which is why no log ever survived a reboot and
# why a chatty one ate into the 64 MiB. Replace the symlink with a real
# mountpoint. It stays EMPTY in the rootfs image -- the contents only ever
# exist on p3.
rm -f "${TARGET_DIR}/var/log"
mkdir -p "${TARGET_DIR}/var/log"

# noatime: a log write should not also cost a metadata write.
# nofail:  busybox mount PARSES AND DISCARDS this -- verified on the board; it
#          is absent from `mount --help` and never shows up in /proc/mounts. It
#          is recorded here as intent, not as behaviour. What actually stops a
#          failed mount being fatal is that busybox `mount -a` already carries
#          on past a bad entry; S01logs then supplies the fallback.
FSTAB="${TARGET_DIR}/etc/fstab"
sed -i '\#^/dev/mmcblk0p3#d' "${FSTAB}"
printf '/dev/mmcblk0p3\t/var/log\text4\tnoatime,nofail\t0\t2\n' >> "${FSTAB}"

# Dropbear key auth: the overlay copy of authorized_keys/.ssh lands 0644/0755;
# tighten to the conventional 0600/0700 so dropbear never refuses the dev key.
if [ -d "${TARGET_DIR}/root/.ssh" ]; then
	chmod 700 "${TARGET_DIR}/root/.ssh"
	chmod 600 "${TARGET_DIR}/root/.ssh/authorized_keys" 2>/dev/null || true
fi

# WiFi/BT are default-off (wifi on / manual BT), but the bluez5-utils and
# dbus packages install autostart scripts that would run bluetoothd +
# dbus-daemon on every boot (~1-1.5 MiB RSS against the RAM diet). Drop
# them; hciconfig/hcitool need neither, and the P6 pairing work will start
# the daemons explicitly when it needs them.
rm -f "${TARGET_DIR}/etc/init.d/S30dbus-daemon" \
      "${TARGET_DIR}/etc/init.d/S40bluetoothd" \
      "${TARGET_DIR}/etc/init.d/S80dnsmasq"

# The overlay wpa_supplicant.conf / hostapd.conf (plaintext PSKs once
# edited) land 0644.
chmod 600 "${TARGET_DIR}/etc/wpa_supplicant.conf" \
          "${TARGET_DIR}/etc/hostapd.conf" 2>/dev/null || true

# Kernel features FastCarPlay cannot run without. The package declares them as
# LINUX_CONFIG_FIXUPS and linux.fragment sets them explicitly, but a fragment
# edit, a defconfig bump or a kconfig gate disappearing would otherwise ship an
# image where CarPlay simply cannot start -- and that only shows up on the
# board. Fail the build instead. Buildroot exports BUILD_DIR to post-build
# scripts and target-finalize runs after the linux package, so the kernel
# .config is present; if Buildroot built no kernel, skip quietly.
KCONFIG=
for d in "${BUILD_DIR}/linux-custom" "${BUILD_DIR}"/linux-[0-9]*; do
	if [ -f "${d}/.config" ]; then
		KCONFIG="${d}/.config"
		break
	fi
done
if [ -n "${KCONFIG}" ]; then
	for sym in CONFIG_IPV6 CONFIG_I2C_CHARDEV CONFIG_USB_NET_CDC_NCM CONFIG_USB_IPHETH; do
		if grep -q "^${sym}=y\$" "${KCONFIG}"; then
			continue
		fi
		case "${sym}" in
		CONFIG_IPV6)
			why="both CarPlay backends hand the phone an IPv6 link-local address
       (CarPlayStartSession ip = fe80::..%usb0 | %wlan0, port 7000); without it
       the :7000 AF_INET6 listener fails EAFNOSUPPORT and CarPlay cannot start.
       NB the base sunxi defconfig disables IPV6 explicitly." ;;
		CONFIG_I2C_CHARDEV)
			why="the MFi authentication coprocessor is driven from userspace as
       /dev/i2c-0 (mfi-i2c-bus)." ;;
		CONFIG_USB_NET_CDC_NCM|CONFIG_USB_IPHETH)
			why="wired CarPlay's data path needs both: ipheth switches the iPhone
       into NCM mode and cdc_ncm creates usb0, whose fe80:: address is what
       CarPlayStartSession hands the phone. Without usb0 the app loops on
       \"usb0 has no IPv6 link-local -- NCM link down\"." ;;
		esac
		echo "ERROR: ${sym}=y missing from ${KCONFIG}" >&2
		echo "       Needed because ${why}" >&2
		echo "       Fix: board/lctech/pi-f1c200s/linux.fragment" >&2
		exit 1
	done
fi
