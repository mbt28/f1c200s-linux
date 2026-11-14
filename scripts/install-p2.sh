#!/bin/bash
# Write the OSTree Buildroot image into p2 of the shared card (docs/ostree.md),
# from the running LEHU OS over SSH, and the boot script that boots it onto p1.
# Buildroot's state is kept across the write: LEHU's settings and pairings, the
# Bluetooth pairings, the SSH host keys, the access point's and Wi-Fi's
# settings. Run on the build host with the board in LEHU OS.
#
#   scripts/install-p2.sh [ssh-target]
#
# The state is kept by the paths Buildroot sees (home/f1c/.lehu, etc/dropbear,
# ...), whichever layout p2 has before and after: on an OSTree system /home is
# var/home, /root is var/roothome and /etc is the booted deployment's.
#
# It stops at the first failure: nothing is written unless the image exists,
# the board answers from LEHU OS, p2 is the 512 MiB partition and is not
# mounted, and the state and p1's script were saved to output/card-backup/.
# LEHU OS on p6 and p1's kernel are not touched: a failure leaves LEHU OS
# bootable from the menu, and U-Boot itself is not written.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
IMAGES=$HERE/output/images
IMAGE=$IMAGES/rootfs.ostreefs
BOARD=${1:-f1c@192.168.9.1}
OPTS=(-i "$HOME/.ssh/f1c200s_dev" -o BatchMode=yes -o ConnectTimeout=15
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
SSH=(ssh "${OPTS[@]}" "$BOARD")
SCP=(scp "${OPTS[@]}" -q)
# etc/*-enabled, lehu-off and swap-disable are the on/off switches of `net`, `wifi`
# and the like: without network-enabled the new system would start no SSH server.
KEEP="home/f1c/.lehu home/f1c/.config home/f1c/.local home/f1c/.ssh home/f1c/memsnap.sh root/lehu root/.ssh var/lib/bluetooth var/lib/bluealsa var/lib/lehu var/lib/lockdown var/lib/seedrng var/lbreakout2.hscr var/ltris.hscr etc/dropbear etc/ssh/ssh_host_ed25519_key etc/ssh/ssh_host_ed25519_key.pub etc/ssh/ssh_host_rsa_key etc/ssh/ssh_host_rsa_key.pub etc/ssh/ssh_host_ecdsa_key etc/ssh/ssh_host_ecdsa_key.pub etc/hostapd.conf etc/wpa_supplicant.conf etc/network-enabled etc/wifi-enabled etc/lehu-off etc/swap-disable"
P2_SECTORS=1048576

[ -f "$IMAGE" ] && [ -f "$IMAGES/f1c-boot.scr" ] && [ -f "$IMAGES/f1c-settings.dtb" ] \
	|| { echo "no image in $IMAGES: scripts/build.sh" >&2; exit 1; }
SIZE=$(stat -c %s "$IMAGE")
[ "$((SIZE / 512))" = "$P2_SECTORS" ] || { echo "the image is $SIZE bytes, p2 is $P2_SECTORS sectors" >&2; exit 1; }
SUM=$(md5sum < "$IMAGE" | cut -d' ' -f1)
echo "image: $IMAGE ($SIZE bytes, md5 $SUM)"

"${SSH[@]}" "grep -q '^ID=agl' /etc/os-release" \
	|| { echo "the board does not answer, or does not run LEHU OS" >&2; exit 1; }
"${SSH[@]}" "[ \"\$(cat /sys/class/block/mmcblk0p2/size)\" = $P2_SECTORS ] && ! grep -q '^/dev/mmcblk0p[12] ' /proc/mounts" \
	|| { echo "p2 is not the ${P2_SECTORS}-sector partition, or p1 or p2 is mounted" >&2; exit 1; }

# Where a path Buildroot sees lives on p2 (mounted at $M), in either layout. On
# an OSTree system the deployment is the one uEnv.txt boots.
M=/run/install-p2
PHYS='phys() {
	if [ -d '$M'/ostree/deploy/buildroot/var ]; then
		o=$(sed -n "s/^bootargs=.*ostree=\([^ ]*\).*/\1/p" '$M'/boot/loader/uEnv.txt)
		dep=$(readlink -f "'$M'$o")
		case $1 in
		var/*) echo "'$M'/ostree/deploy/buildroot/$1" ;;
		home/*) echo "'$M'/ostree/deploy/buildroot/var/$1" ;;
		root/*) echo "'$M'/ostree/deploy/buildroot/var/roothome/${1#root/}" ;;
		etc/*) echo "$dep/$1" ;;
		*) echo "'$M'/$1" ;;
		esac
	else
		echo "'$M'/$1"
	fi
}'

# The state, and p1's boot files, off the board.
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=$HERE/output/card-backup/$STAMP
mkdir -p "$BACKUP"
W=/home/f1c/buildroot-keep
"${SSH[@]}" "sudo sh -s" <<EOS
set -e
$PHYS
mkdir -p $M
mount -o ro /dev/mmcblk0p2 $M
rm -rf $W $W.tar && mkdir -p $W
for f in $KEEP; do
	p=\$(phys \$f)
	if [ -e "\$p" ]; then mkdir -p "$W/\$(dirname \$f)"; cp -a "\$p" "$W/\$f"; fi
done
umount $M
tar cf $W.tar -C $W .
chown f1c $W.tar
mount -o ro /dev/mmcblk0p1 $M
cp $M/f1c-boot.scr $M/f1c-settings.dtb $M/f1c-settings.txt /home/f1c/
chown f1c /home/f1c/f1c-boot.scr /home/f1c/f1c-settings.dtb /home/f1c/f1c-settings.txt
umount $M
EOS
"${SCP[@]}" "$BOARD:$W.tar" "$BOARD:/home/f1c/f1c-boot.scr" "$BOARD:/home/f1c/f1c-settings.dtb" "$BOARD:/home/f1c/f1c-settings.txt" "$BACKUP/"
echo "state saved: $BACKUP ($(tar tf "$BACKUP/buildroot-keep.tar" | wc -l) entries)"

# The write, then the check over the image's whole length.
# (LEHU OS's BusyBox dd has no conv=; the check reads the card, not the cache.)
gzip -1 -c "$IMAGE" | "${SSH[@]}" "gunzip | sudo dd of=/dev/mmcblk0p2 bs=1M && sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null"
GOT=$("${SSH[@]}" "sudo dd if=/dev/mmcblk0p2 bs=1M count=$((SIZE / 1048576)) 2>/dev/null | md5sum" | cut -d' ' -f1)
[ "$GOT" = "$SUM" ] || { echo "p2 md5 $GOT, image $SUM: the write failed" >&2; exit 1; }
echo "written and verified: md5 $GOT"

# The state back into the new layout, owned by the image's f1c, then p2's
# scratch copies gone.
"${SSH[@]}" "sudo sh -s" <<EOS
set -e
$PHYS
mount /dev/mmcblk0p2 $M
for f in $KEEP; do
	if [ -e "$W/\$f" ]; then
		p=\$(phys \$f)
		mkdir -p "\$(dirname "\$p")"; rm -rf "\$p"; cp -a "$W/\$f" "\$p"
	fi
done
o=\$(sed -n "s/^bootargs=.*ostree=\([^ ]*\).*/\1/p" $M/boot/loader/uEnv.txt)
dep=\$(readlink -f "$M\$o")
ids=\$(awk -F: '\$1 == "f1c" { print \$3 ":" \$4 }' "\$dep/etc/passwd")
[ -n "\$ids" ]
chown -R "\$ids" $M/ostree/deploy/buildroot/var/home/f1c
sync; umount $M
rm -rf $W $W.tar /home/f1c/f1c-boot.scr /home/f1c/f1c-settings.dtb /home/f1c/f1c-settings.txt
EOS
echo "state restored"

# The boot script last: until now the old one and LEHU OS on p6 were untouched.
"${SCP[@]}" "$IMAGES/f1c-boot.scr" "$IMAGES/f1c-settings.dtb" "$BOARD:/home/f1c/"
"${SSH[@]}" "sudo sh -s" <<EOS
set -e
mount /dev/mmcblk0p1 $M
cp /home/f1c/f1c-boot.scr $M/f1c-boot.scr.new && mv $M/f1c-boot.scr.new $M/f1c-boot.scr
cp /home/f1c/f1c-settings.dtb $M/f1c-settings.dtb.new && mv $M/f1c-settings.dtb.new $M/f1c-settings.dtb
sync; umount $M; rmdir $M
rm -f /home/f1c/f1c-boot.scr /home/f1c/f1c-settings.dtb
EOS
echo "boot script written: boot Buildroot from the menu"
