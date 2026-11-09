#!/bin/sh
# Buildroot as an OSTree system (docs/ostree.md), under fakeroot, from
# package/ostreefs. Turns TREE, its own copy of the target, into OSTree's
# layout, commits it to $OSTREE_REPO on the branch f1c-buildroot, and writes
# OUT: an ext4 image for p2 with one deployment of that commit, as a board has
# after its first install.
#
#   BINARIES_DIR=... OSTREE_REPO=... OSTREE_VERSION=... OSTREE_FS_KB=... \
#       ostree-image.sh TREE OUT
#
# No initramfs. U-Boot reads /boot/loader/uEnv.txt on p2 (f1c-boot.cmd) and
# starts the kernel with init=<deployment>/usr/lib/ostree/ostree-prepare-root,
# the static build, which sets up the deployment as / and execs /sbin/init.
#
# The layout (as LEHU OS's image_types_lehu_ostree.bbclass):
#   /etc   moves to /usr/etc; ostree merges it into each deployment's /etc.
#   kernel and device tree go to /usr/lib/modules/<version>/.
#   /home and /root move under /var, which is shared by the deployments and
#          kept across updates. ostree fills /var from the commit only at the
#          first deployment, so their files go to /usr/share/factory/var, and
#          S00ostree copies what is missing into /var at every boot: the files
#          a version adds arrive with it, a file already in /var stays.
#   /opt   moves to /usr/opt: programs, which updates must reach.
#
# Signing: each commit with the ed25519 key in $LEHU_OSTREE_SIGN_KEY, by
# default ~/.config/lehu-os/ostree-sign.sec. Without the key the commit is not
# signed, with a warning: the image boots, and no board takes it as an update.
set -eu

TREE=$1
OUT=$2
BRANCH=f1c-buildroot
OSNAME=buildroot
DTB=suniv-f1c200s-lctech-pi.dtb
KEY=${LEHU_OSTREE_SIGN_KEY:-$HOME/.config/lehu-os/ostree-sign.sec}

cd "$TREE"

kver=$(ls usr/lib/modules)
[ "$(echo "$kver" | wc -w)" = 1 ] || { echo "ostree-image: one kernel expected in /usr/lib/modules, found: $kver" >&2; exit 1; }
[ -L lib ] && [ -L bin ] && [ -L sbin ] || { echo "ostree-image: /lib, /bin and /sbin must be links into /usr (BR2_ROOTFS_MERGED_USR)" >&2; exit 1; }
[ -x usr/lib/ostree/ostree-prepare-root ] || { echo "ostree-image: no ostree-prepare-root in the target" >&2; exit 1; }
if file -L usr/lib/ostree/ostree-prepare-root 2>/dev/null | grep -q 'dynamically linked'; then
	echo "ostree-image: ostree-prepare-root is not static: the kernel cannot run it as init" >&2
	exit 1
fi

# The kernel and device tree, where ostree looks for them.
cp "$BINARIES_DIR/zImage" "usr/lib/modules/$kver/vmlinuz"
cp "$BINARIES_DIR/$DTB" "usr/lib/modules/$kver/devicetree"
rm -rf boot
mkdir boot

mv etc usr/etc

# The persistent directories: empty in the commit, filled at boot.
factory=usr/share/factory/var
mkdir -p "$factory"
to_var() {
	mv "$1" "$factory/$2"
	mkdir -p "var/$2"
	chown --reference="$factory/$2" "var/$2"
	chmod --reference="$factory/$2" "var/$2"
}
to_var home home
ln -s var/home home
to_var root roothome
ln -s var/roothome root

if [ -d opt ]; then
	mv opt usr/opt
	ln -s usr/opt opt
fi

# The skeleton's /var/tmp and /var/cache are links to /tmp, 8 MiB of RAM. They
# are real folders here: updates are uploaded to /var/cache, and ostree fails
# on a /var/tmp link, which dangles from where it sets up /var.
rm var/tmp var/cache
mkdir var/tmp var/cache
chmod 1777 var/tmp

# The NAND path's overlay root: not on this partition.
rm -f preinit
rmdir overlay 2>/dev/null || true

# The physical root (the partition) is mounted at /sysroot.
mkdir sysroot
ln -s sysroot/ostree ostree

# The commit, on top of the last build's.
sign=
if [ -r "$KEY" ]; then
	sign="--sign-type=ed25519 --sign-from-file=$KEY"
else
	echo "ostree-image: WARNING: no signing key ($KEY): the commit is not signed, and boards will not install it as an update" >&2
fi
[ -d "$OSTREE_REPO/objects" ] || ostree --repo="$OSTREE_REPO" init --mode=archive
# shellcheck disable=SC2086
ostree --repo="$OSTREE_REPO" commit \
	--branch=$BRANCH \
	--tree=dir="$TREE" \
	--subject="Buildroot $OSTREE_VERSION" \
	--add-metadata-string=version="$OSTREE_VERSION-$(date -u +%Y%m%d%H%M%S)" \
	--skip-if-unchanged $sign
ostree --repo="$OSTREE_REPO" summary -u
ostree --repo="$OSTREE_REPO" log $BRANCH | sed -n '1p;/^Version:/{p;q}'

# The partition: one deployment, as after a first install.
sysroot=$TREE.sysroot
rm -rf "$sysroot"
mkdir "$sysroot"
ostree admin init-fs "$sysroot"
ostree --repo="$sysroot/ostree/repo" config set sysroot.bootloader uboot
# ostree's U-Boot backend reads the current uEnv.txt (through the boot/loader
# symlink) before it writes the next one.
mkdir -p "$sysroot/boot/loader.0"
ln -s loader.0 "$sysroot/boot/loader"
touch "$sysroot/boot/loader.0/uEnv.txt"
ostree admin os-init --sysroot="$sysroot" $OSNAME
ostree --repo="$sysroot/ostree/repo" pull-local "$OSTREE_REPO" $BRANCH
ostree admin deploy --sysroot="$sysroot" --os=$OSNAME $BRANCH

# -m 0: only root writes to this partition, and the room is for updates.
rm -f "$OUT"
mkfs.ext4 -q -F -t ext4 -L buildroot -m 0 -d "$sysroot" "$OUT" "$OSTREE_FS_KB"
rm -rf "$sysroot"
