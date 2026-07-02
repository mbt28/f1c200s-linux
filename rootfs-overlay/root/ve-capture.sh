#!/bin/sh
# Capture the BSP's VE output-stage registers while libcedarc decodes (cedar mode).
# Boot with ve=cedar (or echo cedar >/etc/ve-driver; reboot). Then run this.
VE=0x01c0e000
[ -e /dev/cedar_dev ] || { echo "no /dev/cedar_dev -- not in cedar mode (boot ve=cedar)"; exit 1; }
( cedar-decode-test /root/videos/test.h264 >/dev/null 2>&1 & ) ; sleep 1
echo "--- VE output/SDROT block during cedar decode ---"
for o in 0c4 0c8 0cc 0e8 0ec 240 244 248 24c; do
  printf '0x%s = %s\n' "$o" "$(devmem 0x01c0e$o)"
done
pkill -f cedar-decode-test 2>/dev/null
