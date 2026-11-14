# OSTree: Buildroot updates on one partition

The SD image's Buildroot on p2 is an OSTree system, as LEHU OS on p6 is
(`lehu-os/docs/ostree.md` has the design and how the numbers came about). Each
version is a commit, and the board keeps the version it runs and the one before
it. An update ships only the files that changed. There is no second root
partition and no initramfs. The NAND image is not an OSTree system.

The two systems share the signing key and the installer. Each has its own branch
(`f1c-buildroot` here, `lehu-os` there) and stateroot, and an update for one is
refused by the other.

## The boot

1. `f1c-boot.scr` (`uboot-menu/f1c-boot.cmd`) reads `/boot/loader/uEnv.txt` on p2,
   which ostree keeps up to date. The kernel and device tree load from p2, so an
   update carries them; the zImage on p1 is used only if p2 has no uEnv.txt.
2. The kernel starts `init=<deployment>/usr/lib/ostree/ostree-prepare-root`, a
   static program. It binds `/var` and `/boot`, makes `/usr` read-only, pivots into
   the deployment with the partition at `/sysroot`, and execs `/sbin/init`.
3. BusyBox init does what systemd does on LEHU OS:
   - the first line of inittab mounts devtmpfs. The kernel mounted it on the
     partition's `/dev`, not on the deployment's, which is empty after the pivot
     (`post-build.sh`). Without it there is no console login, no udev and no p3;
   - `S00ostree` writes `/run/ostree-booted`, makes the mounts shared with
     `/sysroot` private (otherwise `ostree admin unlock` says it worked, but its
     overlay is gone when it exits), copies what is missing from
     `/usr/share/factory/var` into `/var`, and makes the updates' folders;
   - `S05lehu-update`, with `f1c.update=1` on the command line, runs the update
     instead of letting the boot go on.

## The layout

| Path | What it is |
|---|---|
| `/usr` | read-only, the commit's |
| `/etc` | the deployment's, writable; ostree merges local changes into each new version |
| `/var` | shared by all versions, kept across updates |
| `/home` | link to `var/home`; first filled from `/usr/share/factory/var/home` |
| `/root` | link to `var/roothome`; the same |
| `/opt` | link to `usr/opt`: programs, which updates must reach |
| `/var/tmp`, `/var/cache` | real folders on the card, not the skeleton's links to the 8 MiB `/tmp` |
| `/var/log` | p3 |

`board/lctech/pi-f1c200s/ostree-image.sh` makes this layout from the target, commits
it to `output/ostree_repo` and writes `rootfs.ostreefs`, the 512 MiB image for p2.
`package/ostreefs` runs it under fakeroot, like any other Buildroot file system.
Without the signing key (`~/.config/lehu-os/ostree-sign.sec`, or
`$LEHU_OSTREE_SIGN_KEY`) the commit is not signed, with a warning: such an image
boots, but no board takes it as an update.

## Changing files on the board

`cp` over `/usr/bin/lehu` no longer works, and neither does `vi` on a script in `/usr/bin`.

    sudo ostree admin unlock            # a writable /usr until the next reboot
    sudo ostree admin unlock --hotfix   # kept across reboots, until the next update

`/etc` and `/var` are writable as usual. Lasting changes go in the repository.

## An update

On the build host, after `scripts/build.sh`:

    scripts/make-update.sh board        # from the version the board runs
    # output/updates/buildroot-<version>-from-<commit>.tar, and manifest.json

Put the tar in `/var/cache/lehu-update` on the board (it is on the card, group
`f1c`), then:

    sudo lehu-os-update check /var/cache/lehu-update/NAME.tar
    sudo lehu-os-update apply /var/cache/lehu-update/NAME.tar
    lehu-os-update status               # no root needed: LEHU runs it as f1c

Up to 4 MiB it installs in the running system and reboots. Larger ones go through
the update boot: the board reboots, the menu boots "Buildroot, install the update"
by itself whatever the default system is, LEHU does not start, and the board
reboots when done. Progress goes to the serial console in both cases. The version
before stays on the menu as "Buildroot, previous version".

## Installing on a card that has the plain system

`scripts/install-p2.sh`, with the board in LEHU OS. It writes p2 and then the boot
script on p1, and verifies p2 with an md5 of what is read back from the card. It
keeps the state listed in its `KEEP`: LEHU's settings and pairings, the iPhone's
pairing (`/var/lib/lockdown`), Bluetooth, SSH keys, the AP's settings, and the
switches of `net` and `wifi`. Without `/etc/network-enabled` the new system would
start no SSH server. A copy goes to `output/card-backup/`. It works from either
layout, and does not change the default system.

**Anything else on p2 is lost**, including hand edits under `/usr` or `/etc`. Compare
first. `sdcard.img` also carries this layout, but flashing a whole card with it has
not been tried; only `install-p2.sh` has.

## What was tested

On the board, 2026-11-08, with LEHU b80665e:

| Test | Result |
|---|---|
| First boot, state kept, LEHU, AP and SSH up | works |
| `/usr` read-only, `/etc` and `/var` writable, `status` as f1c | works |
| In-place update, 30 KB, LEHU running | 15 s |
| "Previous version" entry | boots the old commit, and the new one stays the default |
| LEHU OS's update offered to Buildroot | refused and removed |
| Update boot: 130 MB of new files from a 38 MB upload | 113 s from kernel to reboot, cleans up after itself |
| LEHU OS through the new boot script | works |
| `install-p2.sh` from an OSTree layout | state kept |
| `ostree admin unlock` | `/usr` writable with LEHU running, gone after a reboot |
| `ostree admin unlock --hotfix` | survives reboots; the next update replaces it |

The update boot ran on the build before shared mounts went into `S00ostree`. The
in-place update, which uses the same pull and deploy, ran on the build after.

Open: one boot of LEHU OS (from the Buildroot before these tests' last builds)
came up with `f1c200s-ap` beaconing open and refusing clients, which took SSH with
it. The next boot was normal. LEHU OS's journal does not survive a reboot, so the
cause is not known; it has not happened again.

## Limits

**Room on p2.** The image uses 188 MB of the 488 MB usable, leaving 300 MB. A version
keeps its own objects until it is neither running nor the previous one, and the new
objects are pulled before the oldest version goes. Versions share every unchanged
file, so this only matters when most files change at once. After the 130 MB test
165 MB was free, and a second update that size would not have fitted beside it.
`check` refuses what will not fit (4 times the upload, plus 32 MB), and removes the
upload. Nothing breaks, but such an update needs the rollback removed by hand first.

**The space check is an estimate.** The ratio seen so far is about 3.5. Above it, the
pull's own margin stops it cleanly.
