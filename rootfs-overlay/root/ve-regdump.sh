#!/bin/sh
# ve-regdump.sh -- snapshot the Allwinner VE (Video Engine) register block via
# busybox devmem. Run on the board while a decode is active (cedrus ffmpeg, or
# cedar-decode-test) so the output/H264 config registers hold live values.
#
# VE physical base on suniv/F1C200s = 0x01c0e000.
#   - 0x000..0x0fc : top control + PRIMARY/SECONDARY output config
#                    (0x0c4 chroma offset, 0x0c8 stride, 0x0e8/0x0ec out fmt)
#   - 0x200..0x2fc : H.264 decode block (DPB / output frame addresses)
#
# Usage: ve-regdump.sh [label]   -> prints "off  value" lines; diff two captures.
VE=0x01c0e000
LABEL=${1:-ve}
dump_range() {
	a=$1; end=$2
	while [ "$a" -le "$end" ]; do
		phys=$(printf '0x%08x' $((VE + a)))
		val=$(devmem "$phys" 2>/dev/null)
		printf '%s 0x%03x %s\n' "$LABEL" "$a" "${val:-????????}"
		a=$((a + 4))
	done
}
echo "# $LABEL VE dump  base=$VE  $(date 2>/dev/null)"
dump_range $((0x000)) $((0x0fc))
dump_range $((0x200)) $((0x2fc))
