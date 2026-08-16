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

# Cap the tmpfs mounts. Buildroot's skeleton gives none of them a size=, so each
# defaults to RAM/2 = 25.9 MiB on this board -- three mounts entitled to 77.7 MiB
# against 52 MiB of RAM. This frees nothing by itself (tmpfs only consumes what
# is written); what it buys is blast radius. A runaway writer now gets ENOSPC on
# an 8 MiB filesystem instead of consuming RAM until the OOM killer picks a
# victim, and the victim on this board would plausibly be fastcarplay.
#
# It matters MORE once zram exists, not less: tmpfs pages are swappable, so an
# uncapped /tmp writer would push through zram and out onto the SD card.
#
# /tmp 8M    - every log writer moved to /var/log on p3 (4df4538), so measured
#              use is ~64 KiB; 8M leaves room for scratch/scp.
# /run 2M    - pidfiles, the dbus socket, wpa_supplicant/hostapd/bluealsa state.
# /dev/shm 4M- glibc POSIX shm / SDL2. Do not shrink below this without
#              measuring: shm_open failures are hard errors in some libraries.
# Match on the mountpoint so the mode= flags are preserved verbatim.
sed -i '\#^tmpfs[[:space:]]\+/tmp[[:space:]]#d;
        \#^tmpfs[[:space:]]\+/run[[:space:]]#d;
        \#^tmpfs[[:space:]]\+/dev/shm[[:space:]]#d' "${FSTAB}"
printf 'tmpfs\t/tmp\ttmpfs\tmode=1777,size=8M,noatime\t0\t0\n'                  >> "${FSTAB}"
printf 'tmpfs\t/run\ttmpfs\tmode=0755,nosuid,nodev,size=2M,noatime\t0\t0\n'     >> "${FSTAB}"
printf 'tmpfs\t/dev/shm\ttmpfs\tmode=1777,size=4M,noatime\t0\t0\n'              >> "${FSTAB}"

# SD swap (p4), emergency backstop only -- see S02swap and genimage-sdcard.cfg.
# noauto is LOAD-BEARING: the partition ships unformatted (genimage has no swap
# handler), so sysinit's `swapon -a` would fail EINVAL and print to the console.
# S02swap does mkswap + `swapon -p 10` instead. busybox swapon honours noauto,
# and `swapoff -a` still covers it because it walks /proc/swaps first.
# busybox `mount -a` skips swap-type entries, so this is inert at sysinit.
sed -i '\#^/dev/mmcblk0p4#d' "${FSTAB}"
printf '/dev/mmcblk0p4\tnone\tswap\tnoauto,pri=10\t0\t0\n' >> "${FSTAB}"

# LOCK root's password. This cannot be done from BR2_TARGET_GENERIC_ROOT_PASSWD:
# Buildroot only passes a value through verbatim when it starts with $1$/$5$/$6$
# (system/Config.in:380), so "*" there is taken as CLEAR TEXT and crypt-encoded
# -- a built image came out with a live $5$ hash, i.e. root's password was
# literally one asterisk. Rewrite the field directly instead.
#
# "*" matches no input, so password login is impossible while public-key auth is
# unaffected. This is NOT an empty field, which would mean passwordless root.
# The serial console is unaffected because it is not a getty: inittab runs
# `-/bin/sh` directly (see the auto-login block above), so it never authenticates
# -- which is what keeps a locked board recoverable.
SHADOW="${TARGET_DIR}/etc/shadow"
sed -i 's|^root:[^:]*:|root:*:|' "${SHADOW}"
if ! grep -q '^root:\*:' "${SHADOW}"; then
	echo "ERROR: failed to lock root's password in ${SHADOW}" >&2
	echo "       Shipping with a guessable or empty root password alongside the" >&2
	echo "       always-on AP is exactly what this is meant to prevent." >&2
	exit 1
fi

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

# OpenSSH is enabled solely for /usr/libexec/sftp-server (the path dropbear
# already exec's for SFTP). Its S50sshd would start a SECOND ssh daemon next to
# S50dropbear -- same S50 slot, same port 22, and sshd would win or clash
# depending on ordering. Drop it: dropbear stays the only daemon and just gains
# SFTP. Fail loudly if the binary we enabled the package FOR is missing, since
# a silent absence means scp keeps failing exactly as it does today.
rm -f "${TARGET_DIR}/etc/init.d/S50sshd"
if [ ! -x "${TARGET_DIR}/usr/libexec/sftp-server" ]; then
	echo "ERROR: /usr/libexec/sftp-server missing from the target" >&2
	echo "       BR2_PACKAGE_OPENSSH_SERVER is enabled only to provide it;" >&2
	echo "       without it dropbear's SFTP subsystem fails and scp needs -O." >&2
	exit 1
fi

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

	# The NAND root is squashfs (mtd2) + jffs2 (mtd3) unioned by overlayfs, all
	# assembled by /preinit. If any of these three is missing the board does not
	# boot from NAND at all -- and the failure lands in PID 1 before anything
	# else runs, which is a miserable way to discover a missing kconfig symbol.
	# Catch it here instead.
	for sym in CONFIG_SQUASHFS CONFIG_JFFS2_FS CONFIG_OVERLAY_FS; do
		if ! grep -q "^${sym}=[ym]\$" "${KCONFIG}"; then
			echo "ERROR: ${sym} missing from ${KCONFIG}" >&2
			echo "       The NAND root needs squashfs (lower) + jffs2 (upper) +" >&2
			echo "       overlayfs (union); /preinit cannot assemble / without it." >&2
			echo "       Fix: board/lctech/pi-f1c200s/linux.fragment" >&2
			exit 1
		fi
	done

	# MTD_SPI_NAND depends on SPI_MASTER, so it is exactly the shape of symbol
	# that disappears quietly if a dependency moves -- and the failure is only
	# visible on the board, as a missing /dev/mtd0. Without it the on-board
	# GigaDevice SPI NAND cannot be dumped or written at all, which is the
	# whole point of shipping mtd-utils alongside it.
	if ! grep -q "^CONFIG_MTD_SPI_NAND=[ym]\$" "${KCONFIG}"; then
		echo "ERROR: CONFIG_MTD_SPI_NAND missing from ${KCONFIG}" >&2
		echo "       The on-board 128 MiB SPI NAND on spi0 would not be probed," >&2
		echo "       so /dev/mtd0 never appears and nanddump/nandwrite are inert." >&2
		echo "       Fix: board/lctech/pi-f1c200s/linux.fragment" >&2
		exit 1
	fi

	# zram is =m, not =y, so it needs its own check -- the loop above matches
	# "=y" exactly and would pass a silently-missing module straight through.
	if ! grep -q "^CONFIG_ZRAM=[ym]\$" "${KCONFIG}"; then
		echo "ERROR: CONFIG_ZRAM missing from ${KCONFIG}" >&2
		echo "       /etc/init.d/S02swap modprobes zram for the primary swap tier;" >&2
		echo "       without it the board silently runs with no swap at all." >&2
		echo "       Fix: board/lctech/pi-f1c200s/linux.fragment" >&2
		exit 1
	fi

	# The debug symbols retired for RAM. DMA_API_DEBUG alone preallocates 65536
	# dma_debug_entry at core_initcall and never frees them: ~3.5-4 MiB on a
	# 52 MiB board. FTRACE is the sneaky one -- CONFIG_EXPERT=y selects
	# DEBUG_KERNEL and FTRACE is "default y if DEBUG_KERNEL", so it comes back
	# unless the fragment says "is not set" explicitly. Catch a regression here
	# rather than on the board.
	for sym in CONFIG_DMA_API_DEBUG CONFIG_FTRACE; do
		if grep -q "^${sym}=y\$" "${KCONFIG}"; then
			echo "ERROR: ${sym}=y is back in ${KCONFIG}" >&2
			echo "       It was retired to reclaim RAM (see linux.fragment)." >&2
			echo "       FTRACE in particular returns unless it is disabled" >&2
			echo "       EXPLICITLY, because EXPERT selects DEBUG_KERNEL." >&2
			exit 1
		fi
	done
fi

# swapon -p must really be compiled in, or S02swap cannot rank zram above the SD
# card and the priority policy silently inverts -- the failure mode being
# "video stutters sometimes", the worst class of bug on this board. A busybox
# version bump that renames the symbol should fail the build, not ship.
for d in "${BUILD_DIR}"/busybox-*; do
	[ -f "${d}/.config" ] || continue
	if ! grep -q "^CONFIG_FEATURE_SWAPON_PRI=y\$" "${d}/.config"; then
		echo "ERROR: CONFIG_FEATURE_SWAPON_PRI missing from ${d}/.config" >&2
		echo "       Without it busybox swapon rejects -p outright (bb_show_usage)," >&2
		echo "       so S02swap cannot put zram above the SD swap." >&2
		echo "       Fix: board/lctech/pi-f1c200s/busybox.fragment + the" >&2
		echo "       BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES line in the defconfig." >&2
		exit 1
	fi
	break
done
