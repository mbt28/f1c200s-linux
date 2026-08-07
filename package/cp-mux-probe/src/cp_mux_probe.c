// cp-mux-probe -- standalone usbmux VERSION probe for the iPhone, no app involved.
//
// Wired CarPlay needs the iPhone's usbmux bulk-IN endpoint to answer while
// cdc_ncm's usb0 is up. On the F1C200s it does not: the endpoint is polled and
// returns nothing. Every measurement so far has been taken through FastCarPlay,
// which conflates "the host cannot service the endpoint" with "the app is
// asking wrongly". This probe removes the app from the picture entirely.
//
// It speaks the minimum of the usbmux-over-USB protocol: a VERSION packet is
// the first thing usbmuxd sends after opening the device, and the phone replies
// with a 20-byte VERSION of its own. Header is 8 bytes (protocol, length) at
// version 0/1 -- the magic/seq fields only appear from version 2 -- followed by
// a 12-byte body (major, minor, padding), all big-endian.
//
// Talks to usbfs directly rather than through libusb: no library dependency, so
// it cross-compiles against nothing but libc and can be dropped onto a board
// over serial.
//
//   Usage: cp-mux-probe [-t timeout_ms] [-r reads] [-s readsize] [-i iface]
//
// Exit 0 = the phone replied. Non-zero = it did not, and the message says how
// far it got, so a failure distinguishes claim/permission problems from a
// silent endpoint.

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <sys/ioctl.h>
#include <arpa/inet.h>
#include <linux/usbdevice_fs.h>

#define APPLE_VID	"05ac"
#define MUX_IFACE	1	/* ff/fe in config 6 */
#define EP_OUT		0x04
#define EP_IN		0x85
#define MUX_PROTO_VERSION 0

struct mux_hdr {		/* version 0/1 header: no magic, no seq */
	uint32_t protocol;
	uint32_t length;
} __attribute__((packed));

struct version_body {
	uint32_t major;
	uint32_t minor;
	uint32_t padding;
} __attribute__((packed));

static int read_sysfs(const char *dir, const char *attr, char *out, size_t n)
{
	char path[512];
	int fd;
	ssize_t r;

	snprintf(path, sizeof(path), "/sys/bus/usb/devices/%s/%s", dir, attr);
	fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	r = read(fd, out, n - 1);
	close(fd);
	if (r <= 0)
		return -1;
	out[r] = 0;
	while (r > 0 && (out[r - 1] == '\n' || out[r - 1] == ' '))
		out[--r] = 0;
	return 0;
}

/* Find the Apple device and return its usbfs path plus the config it is in. */
static int find_phone(char *path, size_t pathn, int *cfg, char *devdir, size_t ddn)
{
	DIR *d = opendir("/sys/bus/usb/devices");
	struct dirent *e;
	char vid[32], bus[32], dev[32], cfgs[32];
	int found = 0;

	if (!d)
		return -1;
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.' || strchr(e->d_name, ':'))
			continue;	/* skip interfaces, only whole devices */
		if (read_sysfs(e->d_name, "idVendor", vid, sizeof(vid)) < 0)
			continue;
		if (strcmp(vid, APPLE_VID) != 0)
			continue;
		if (read_sysfs(e->d_name, "busnum", bus, sizeof(bus)) < 0 ||
		    read_sysfs(e->d_name, "devnum", dev, sizeof(dev)) < 0)
			continue;
		if (read_sysfs(e->d_name, "bConfigurationValue", cfgs, sizeof(cfgs)) == 0)
			*cfg = atoi(cfgs);
		snprintf(path, pathn, "/dev/bus/usb/%03d/%03d", atoi(bus), atoi(dev));
		snprintf(devdir, ddn, "%s", e->d_name);
		found = 1;
		break;
	}
	closedir(d);
	return found ? 0 : -1;
}

static void hexdump(const unsigned char *p, int n)
{
	int i;
	for (i = 0; i < n; i++)
		printf("%02x%s", p[i], (i % 16 == 15 || i == n - 1) ? "\n" : " ");
}

int main(int argc, char **argv)
{
	int timeout = 1000, reads = 5, readsize = 4096, iface = MUX_IFACE, opt;
	char path[256], devdir[256];
	int cfg = -1, fd, rc, i;
	unsigned char buf[65536];
	unsigned char pkt[sizeof(struct mux_hdr) + sizeof(struct version_body)];
	struct mux_hdr *hdr = (struct mux_hdr *)pkt;
	struct version_body *vb = (struct version_body *)(pkt + sizeof(*hdr));
	struct usbdevfs_bulktransfer bt;
	struct usbdevfs_disconnect_claim dc;
	int claimed = 0;

	while ((opt = getopt(argc, argv, "t:r:s:i:")) != -1) {
		switch (opt) {
		case 't': timeout = atoi(optarg); break;
		case 'r': reads = atoi(optarg); break;
		case 's': readsize = atoi(optarg); break;
		case 'i': iface = atoi(optarg); break;
		default:
			fprintf(stderr, "usage: %s [-t ms] [-r reads] [-s size] [-i iface]\n", argv[0]);
			return 2;
		}
	}
	if (readsize > (int)sizeof(buf))
		readsize = sizeof(buf);

	if (find_phone(path, sizeof(path), &cfg, devdir, sizeof(devdir)) < 0) {
		fprintf(stderr, "cp-mux-probe: no Apple device found (plugged in directly?)\n");
		return 1;
	}
	printf("device %s (sysfs %s), configuration %d%s\n", path, devdir, cfg,
	       cfg == 6 ? "" : "  <-- expected 6 for CarPlay");

	fd = open(path, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return 1;
	}

	/* Take the interface even if a kernel driver holds it. */
	memset(&dc, 0, sizeof(dc));
	dc.interface = iface;
	dc.flags = USBDEVFS_DISCONNECT_CLAIM_EXCEPT_DRIVER;
	strncpy(dc.driver, "usbfs", sizeof(dc.driver) - 1);
	if (ioctl(fd, USBDEVFS_DISCONNECT_CLAIM, &dc) == 0) {
		claimed = 1;
	} else {
		unsigned int n = iface;
		if (ioctl(fd, USBDEVFS_CLAIMINTERFACE, &n) == 0)
			claimed = 1;
	}
	if (!claimed) {
		fprintf(stderr, "claim interface %d: %s\n", iface, strerror(errno));
		fprintf(stderr, "  (is fastcarplay still running? it holds this interface)\n");
		close(fd);
		return 1;
	}
	printf("claimed interface %d, EP OUT 0x%02x / EP IN 0x%02x\n", iface, EP_OUT, EP_IN);

	memset(pkt, 0, sizeof(pkt));
	hdr->protocol = htonl(MUX_PROTO_VERSION);
	hdr->length   = htonl(sizeof(pkt));
	vb->major     = htonl(2);
	vb->minor     = htonl(0);
	vb->padding   = 0;

	memset(&bt, 0, sizeof(bt));
	bt.ep = EP_OUT;
	bt.len = sizeof(pkt);
	bt.timeout = timeout;
	bt.data = pkt;
	rc = ioctl(fd, USBDEVFS_BULK, &bt);
	printf("VERSION out: rc=%d (%s) sent=%d/%d\n", rc,
	       rc < 0 ? strerror(errno) : "ok", rc < 0 ? 0 : rc, (int)sizeof(pkt));
	if (rc < 0)
		goto done;

	for (i = 0; i < reads; i++) {
		memset(&bt, 0, sizeof(bt));
		bt.ep = EP_IN;
		bt.len = readsize;
		bt.timeout = timeout;
		bt.data = buf;
		rc = ioctl(fd, USBDEVFS_BULK, &bt);
		printf("read %d: rc=%d (%s) len=%d\n", i + 1, rc,
		       rc < 0 ? strerror(errno) : "ok", rc < 0 ? 0 : rc);
		if (rc > 0) {
			hexdump(buf, rc < 32 ? rc : 32);
			printf("cp-mux-probe: PHONE REPLIED (%d bytes)\n", rc);
			{
				unsigned int n = iface;
				ioctl(fd, USBDEVFS_RELEASEINTERFACE, &n);
			}
			close(fd);
			return 0;
		}
	}
	fprintf(stderr, "cp-mux-probe: NO REPLY after %d reads of %d bytes (%d ms each)\n",
		reads, readsize, timeout);

done:
	{
		unsigned int n = iface;
		ioctl(fd, USBDEVFS_RELEASEINTERFACE, &n);
	}
	close(fd);
	return 1;
}
