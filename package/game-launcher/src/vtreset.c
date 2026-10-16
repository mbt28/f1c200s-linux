// SPDX-License-Identifier: GPL-2.0
/*
 * vtreset -- undo what an SDL 1.2 fbcon program leaves behind when it dies
 * without cleaning up (crash, kill -9). On entering graphics mode SDL puts its
 * VT in KD_GRAPHICS and LOCKS VT switching (VT_LOCKSWITCH is global); both are
 * only undone on a clean exit. Left behind, every later VT switch -- the next
 * game's, chvt -- waits forever. This unlocks switching and puts the active VT
 * back to text mode, automatic switching and the default keyboard mode.
 */
#include <fcntl.h>
#include <linux/kd.h>
#include <linux/vt.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(void)
{
	struct vt_mode mode = { .mode = VT_AUTO };
	struct vt_stat st;
	char path[16];
	int fd = open("/dev/tty0", O_RDWR);

	if (fd < 0) {
		perror("vtreset: /dev/tty0");
		return 1;
	}
	if (ioctl(fd, VT_UNLOCKSWITCH, 1) < 0)
		perror("vtreset: VT_UNLOCKSWITCH");
	if (ioctl(fd, VT_GETSTATE, &st) < 0) {
		perror("vtreset: VT_GETSTATE");
		return 1;
	}
	close(fd);

	snprintf(path, sizeof(path), "/dev/tty%d", st.v_active);
	fd = open(path, O_RDWR);
	if (fd < 0) {
		perror(path);
		return 1;
	}
	if (ioctl(fd, KDSETMODE, KD_TEXT) < 0)
		perror("vtreset: KDSETMODE");
	if (ioctl(fd, VT_SETMODE, &mode) < 0)
		perror("vtreset: VT_SETMODE");
	if (ioctl(fd, KDSKBMODE, K_UNICODE) < 0)
		perror("vtreset: KDSKBMODE");
	close(fd);
	return 0;
}
