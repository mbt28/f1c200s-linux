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
