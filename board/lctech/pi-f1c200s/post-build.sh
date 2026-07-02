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
