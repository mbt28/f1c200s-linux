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
//   Usage: cp-mux-probe [-t timeout_ms] [-r reads] [-s readsize]
//
// Exit 0 = the phone replied. Non-zero = it did not, and the message says how
// far it got, so a failure distinguishes claim/permission problems from a
// silent endpoint.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <libusb-1.0/libusb.h>

#define APPLE_VID	0x05ac
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

static void hexdump(const unsigned char *p, int n)
{
	int i;
	for (i = 0; i < n; i++)
		printf("%02x%s", p[i], (i % 16 == 15 || i == n - 1) ? "\n" : " ");
}

int main(int argc, char **argv)
{
	int timeout = 1000, reads = 5, readsize = 4096, opt;
	libusb_context *ctx = NULL;
	libusb_device_handle *h = NULL;
	libusb_device **list = NULL;
	struct libusb_device_descriptor dd;
	unsigned char buf[65536];
	unsigned char pkt[sizeof(struct mux_hdr) + sizeof(struct version_body)];
	struct mux_hdr *hdr = (struct mux_hdr *)pkt;
	struct version_body *vb = (struct version_body *)(pkt + sizeof(*hdr));
	ssize_t ndev;
	int i, rc, transferred, detached = 0, found = 0;

	while ((opt = getopt(argc, argv, "t:r:s:")) != -1) {
		switch (opt) {
		case 't': timeout = atoi(optarg); break;
		case 'r': reads = atoi(optarg); break;
		case 's': readsize = atoi(optarg); break;
		default:
			fprintf(stderr, "usage: %s [-t ms] [-r reads] [-s size]\n", argv[0]);
			return 2;
		}
	}
	if (readsize > (int)sizeof(buf))
		readsize = sizeof(buf);

	if ((rc = libusb_init(&ctx)) < 0) {
		fprintf(stderr, "libusb_init: %s\n", libusb_error_name(rc));
		return 1;
	}

	ndev = libusb_get_device_list(ctx, &list);
	for (i = 0; i < ndev; i++) {
		if (libusb_get_device_descriptor(list[i], &dd) < 0)
			continue;
		if (dd.idVendor != APPLE_VID)
			continue;
		found = 1;
		rc = libusb_open(list[i], &h);
		if (rc < 0) {
			fprintf(stderr, "open %04x:%04x: %s\n", dd.idVendor,
				dd.idProduct, libusb_error_name(rc));
			h = NULL;
			continue;
		}
		printf("device %04x:%04x on bus %d addr %d\n", dd.idVendor, dd.idProduct,
		       libusb_get_bus_number(list[i]), libusb_get_device_address(list[i]));
		break;
	}
	if (!h) {
		fprintf(stderr, found ? "cp-mux-probe: found an Apple device but could not open it\n"
				      : "cp-mux-probe: no Apple device found (plugged in? config 6?)\n");
		libusb_free_device_list(list, 1);
		libusb_exit(ctx);
		return 1;
	}

	int cfg = 0;
	if (libusb_get_configuration(h, &cfg) == 0)
		printf("configuration: %d%s\n", cfg, cfg == 6 ? "" : "  (expected 6 for CarPlay)");

	if (libusb_kernel_driver_active(h, MUX_IFACE) == 1) {
		printf("kernel driver holds interface %d -- detaching\n", MUX_IFACE);
		if (libusb_detach_kernel_driver(h, MUX_IFACE) == 0)
			detached = 1;
	}
	if ((rc = libusb_claim_interface(h, MUX_IFACE)) < 0) {
		fprintf(stderr, "claim interface %d: %s\n", MUX_IFACE, libusb_error_name(rc));
		goto out;
	}
	printf("claimed interface %d, EP OUT 0x%02x / EP IN 0x%02x\n",
	       MUX_IFACE, EP_OUT, EP_IN);

	memset(pkt, 0, sizeof(pkt));
	hdr->protocol = htonl(MUX_PROTO_VERSION);
	hdr->length   = htonl(sizeof(pkt));
	vb->major     = htonl(2);
	vb->minor     = htonl(0);
	vb->padding   = 0;

	rc = libusb_bulk_transfer(h, EP_OUT, pkt, sizeof(pkt), &transferred, timeout);
	printf("VERSION out: rc=%s transferred=%d/%d\n",
	       libusb_error_name(rc), transferred, (int)sizeof(pkt));
	if (rc < 0)
		goto release;

	for (i = 0; i < reads; i++) {
		transferred = 0;
		rc = libusb_bulk_transfer(h, EP_IN, buf, readsize, &transferred, timeout);
		printf("read %d: rc=%s len=%d\n", i + 1, libusb_error_name(rc), transferred);
		if (rc == 0 && transferred > 0) {
			hexdump(buf, transferred < 32 ? transferred : 32);
			printf("cp-mux-probe: PHONE REPLIED (%d bytes)\n", transferred);
			libusb_release_interface(h, MUX_IFACE);
			if (detached)
				libusb_attach_kernel_driver(h, MUX_IFACE);
			libusb_close(h);
			libusb_free_device_list(list, 1);
			libusb_exit(ctx);
			return 0;
		}
	}
	fprintf(stderr, "cp-mux-probe: NO REPLY after %d reads of %d bytes (%d ms each)\n",
		reads, readsize, timeout);

release:
	libusb_release_interface(h, MUX_IFACE);
out:
	if (detached)
		libusb_attach_kernel_driver(h, MUX_IFACE);
	libusb_close(h);
	libusb_free_device_list(list, 1);
	libusb_exit(ctx);
	return 1;
}
