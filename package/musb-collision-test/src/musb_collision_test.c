// SPDX-License-Identifier: GPL-2.0
/*
 * musb_collision_test — deterministic reproducer for the suniv MUSB
 * shared-FIFO datapath collision (RX-DMA vs TX-PIO).
 *
 * Runs on the F1C200s board (USB *host*) against a Linux g_zero (sourcesink)
 * gadget peer (`modprobe g_zero` on the other end). It drives, concurrently:
 *   - large + 4-aligned bulk-IN reads  -> the host RX-DMA path (BUS_SEL=1)
 *   - small + unaligned bulk-OUT writes -> the host TX-PIO path
 * and byte-compares each IN buffer against a clean reference captured *before*
 * the TX pressure starts. A mismatch = the TX-PIO write corrupting the
 * in-flight RX-DMA on the one shared FIFO datapath. This turns the phone's
 * fuzzy "TLS bad record mac" into a hard, deterministic corruption count.
 *
 *   musb-collision-test [in_size=16384] [out_size=13] [seconds=0(forever)]
 * exit: 0 = no corruption seen, 2 = corruption seen.
 *
 * Cross-checks to run in parallel on the board serial console:
 *   awk '/1c02000/{print $2}' /proc/interrupts   # IRQ17 climbs => RX-DMA live
 */

#include <libusb-1.0/libusb.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>

#define GZERO_VID 0x0525
#define GZERO_PID 0xa4a0   /* Linux "Gadget Zero" (sourcesink/loopback) */

static volatile sig_atomic_t g_stop;
static void on_sig(int s) { (void)s; g_stop = 1; }

static libusb_device_handle *g_dh;
static unsigned char g_ep_in, g_ep_out;
static int g_in_size  = 16384;   /* large + 4-aligned -> RX-DMA path */
static int g_out_size = 13;      /* small + unaligned -> TX-PIO path */

static unsigned char *g_ref;     /* clean IN reference (captured pre-writer) */
static int g_ref_len;
static volatile int g_writer_go; /* gate: reference is captured first */

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t in_ok, in_corrupt, in_short, in_err, out_ok, out_err;

static int first_diff(const unsigned char *a, const unsigned char *b, int n)
{
	int i;
	for (i = 0; i < n; i++)
		if (a[i] != b[i])
			return i;
	return -1;
}

static void *reader_thread(void *arg)
{
	unsigned char *buf = NULL;
	(void)arg;

	if (posix_memalign((void **)&buf, 64, g_in_size)) {
		fprintf(stderr, "reader: alloc failed\n");
		return NULL;
	}
	while (!g_stop) {
		int got = 0;
		int r = libusb_bulk_transfer(g_dh, g_ep_in, buf, g_in_size,
					     &got, 3000);
		if (r < 0) {
			pthread_mutex_lock(&g_lock);
			in_err++;
			pthread_mutex_unlock(&g_lock);
			if (r == LIBUSB_ERROR_NO_DEVICE)
				g_stop = 1;
			usleep(2000);
			continue;
		}
		if (!g_writer_go)
			continue;	/* reference still being captured */

		int cmp = (got < g_ref_len) ? got : g_ref_len;
		int bad = first_diff(buf, g_ref, cmp);

		pthread_mutex_lock(&g_lock);
		if (got < g_ref_len)
			in_short++;
		if (bad >= 0) {
			in_corrupt++;
			if (in_corrupt <= 8)
				printf("  !! CORRUPT IN @byte %d: got %02x want %02x (len %d)\n",
				       bad, buf[bad], g_ref[bad], got);
		} else {
			in_ok++;
		}
		pthread_mutex_unlock(&g_lock);
	}
	free(buf);
	return NULL;
}

static void *writer_thread(void *arg)
{
	unsigned char *buf = malloc(g_out_size ? g_out_size : 1);
	int i;
	(void)arg;

	/* match g_zero's sink pattern so the OUT itself doesn't error */
	for (i = 0; i < g_out_size; i++)
		buf[i] = (unsigned char)(i % 63);

	while (!g_writer_go && !g_stop)
		usleep(1000);

	while (!g_stop) {
		int sent = 0;
		int r = libusb_bulk_transfer(g_dh, g_ep_out, buf, g_out_size,
					     &sent, 3000);
		pthread_mutex_lock(&g_lock);
		if (r < 0) {
			out_err++;
			if (r == LIBUSB_ERROR_NO_DEVICE)
				g_stop = 1;
		} else {
			out_ok++;
		}
		pthread_mutex_unlock(&g_lock);
		/* no delay: maximal TX-PIO pressure during the RX-DMA reads */
	}
	free(buf);
	return NULL;
}

int main(int argc, char **argv)
{
	libusb_context *ctx = NULL;
	struct libusb_config_descriptor *cfg = NULL;
	const struct libusb_interface_descriptor *id;
	libusb_device *dev;
	pthread_t tr, tw;
	int seconds, e;
	time_t t0;

	if (argc > 1)
		g_in_size = atoi(argv[1]);
	if (argc > 2)
		g_out_size = atoi(argv[2]);
	seconds = (argc > 3) ? atoi(argv[3]) : 0;
	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);

	if (libusb_init(&ctx)) {
		fprintf(stderr, "libusb_init failed\n");
		return 1;
	}
	g_dh = libusb_open_device_with_vid_pid(ctx, GZERO_VID, GZERO_PID);
	if (!g_dh) {
		fprintf(stderr, "g_zero %04x:%04x not found -- is the peer `modprobe g_zero` and cabled to the host port? (check `lsusb`)\n",
			GZERO_VID, GZERO_PID);
		return 1;
	}
	libusb_set_auto_detach_kernel_driver(g_dh, 1);
	if (libusb_claim_interface(g_dh, 0)) {
		fprintf(stderr, "claim_interface(0) failed\n");
		return 1;
	}

	/* locate the bulk IN/OUT endpoints on interface 0 */
	dev = libusb_get_device(g_dh);
	if (libusb_get_active_config_descriptor(dev, &cfg)) {
		fprintf(stderr, "get_active_config_descriptor failed\n");
		return 1;
	}
	id = &cfg->interface[0].altsetting[0];
	for (e = 0; e < id->bNumEndpoints; e++) {
		const struct libusb_endpoint_descriptor *ep = &id->endpoint[e];

		if ((ep->bmAttributes & 0x03) == LIBUSB_TRANSFER_TYPE_BULK) {
			if (ep->bEndpointAddress & 0x80)
				g_ep_in = ep->bEndpointAddress;
			else
				g_ep_out = ep->bEndpointAddress;
		}
	}
	libusb_free_config_descriptor(cfg);
	if (!g_ep_in || !g_ep_out) {
		fprintf(stderr, "no bulk IN/OUT endpoints on g_zero if0 (wrong config? try loopback/sourcesink)\n");
		return 1;
	}
	printf("g_zero ep_in=0x%02x ep_out=0x%02x | IN=%d (aligned->RX-DMA) OUT=%d (small->TX-PIO)\n",
	       g_ep_in, g_ep_out, g_in_size, g_out_size);

	/* capture a clean IN reference BEFORE any concurrent TX-PIO pressure */
	g_ref = malloc(g_in_size);
	{
		int got = 0, tries = 0;

		for (;;) {
			int r = libusb_bulk_transfer(g_dh, g_ep_in, g_ref,
						     g_in_size, &got, 3000);
			if (r == 0 && got > 0)
				break;
			if (++tries > 20) {
				fprintf(stderr, "could not capture reference IN buffer\n");
				return 1;
			}
		}
		g_ref_len = got;
		printf("reference IN captured: %d bytes, head %02x %02x %02x %02x %02x %02x\n",
		       got, g_ref[0], g_ref[1], g_ref[2], g_ref[3], g_ref[4],
		       g_ref[5]);
	}
	/* sanity: a 2nd clean read must equal the reference (stable pattern) */
	{
		unsigned char *b2 = malloc(g_in_size);
		int got = 0, d;

		libusb_bulk_transfer(g_dh, g_ep_in, b2, g_in_size, &got, 3000);
		d = first_diff(b2, g_ref, (got < g_ref_len ? got : g_ref_len));
		if (d >= 0)
			printf("WARN: reference not stable (diff@%d) -- g_zero pattern varies per request; corruption count may be unreliable. Try a sourcesink config or set g_zero pattern=1.\n",
			       d);
		else
			printf("reference stable (2 clean reads match) -- starting concurrent load\n");
		free(b2);
	}

	pthread_create(&tr, NULL, reader_thread, NULL);
	pthread_create(&tw, NULL, writer_thread, NULL);
	g_writer_go = 1;	/* release the writer + arm reader comparison */

	t0 = time(NULL);
	while (!g_stop) {
		sleep(2);
		pthread_mutex_lock(&g_lock);
		printf("IN ok=%llu CORRUPT=%llu short=%llu err=%llu | OUT ok=%llu err=%llu\n",
		       (unsigned long long)in_ok, (unsigned long long)in_corrupt,
		       (unsigned long long)in_short, (unsigned long long)in_err,
		       (unsigned long long)out_ok, (unsigned long long)out_err);
		pthread_mutex_unlock(&g_lock);
		if (seconds && (time(NULL) - t0) >= seconds)
			g_stop = 1;
	}
	pthread_join(tr, NULL);
	pthread_join(tw, NULL);

	printf("=== FINAL IN ok=%llu CORRUPT=%llu short=%llu err=%llu | OUT ok=%llu err=%llu ===\n",
	       (unsigned long long)in_ok, (unsigned long long)in_corrupt,
	       (unsigned long long)in_short, (unsigned long long)in_err,
	       (unsigned long long)out_ok, (unsigned long long)out_err);

	libusb_release_interface(g_dh, 0);
	libusb_close(g_dh);
	libusb_exit(ctx);
	return in_corrupt ? 2 : 0;
}
