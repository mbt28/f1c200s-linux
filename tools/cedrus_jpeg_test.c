// cedrus_jpeg_test: decode baseline JPEGs on the VE's hardware JPEG decoder
// (cedrus, V4L2 mem2mem, no requests) and time it.
//
//   cedrus_jpeg_test [-r] [-n LOOPS] [-o OUT_PREFIX] [-d /dev/videoN] FILE.jpg...
//   cedrus_jpeg_test -H [-d /dev/videoN]
//
// -r also times the CPU reading each picture out of its CAPTURE buffer (a
// memcpy of the whole buffer), as composing tiles in software would.
//
// -H checks only that the stateless codecs still require requests now that
// JPEG does not: an H.264 OUTPUT buffer queued without one must get EBADR.
//
// Each FILE is decoded LOOPS times (default 100), round robin across the
// files. All files must have the same size (map tiles: 256x256). Per decode
// it measures queueing the JPEG to getting the picture back, and the copy of
// the JPEG into the OUTPUT buffer separately; over the whole loop the CPU
// time of this process and of the system (/proc/stat).
//
// With -o, the first decode of each file is written as OUT_PREFIX<i>.nv12:
// the CAPTURE buffer detiled to linear NV12 (Y plane, then interleaved CbCr),
// for comparison with a software decode (tools/cedrus_jpeg_compare.py).
//
// The CAPTURE format is whatever cedrus gives on this VE: NV12_32L32 (ST12,
// 32x32 tiles) on the suniv F1C100s/F1C200s. VIDIOC_EXPBUF is checked on
// CAPTURE buffer 0, as a compositor would use it.
//
// Build with the Buildroot toolchain:
//   output/host/bin/arm-buildroot-linux-gnueabi-gcc -O2 -Wall
//       -o cedrus_jpeg_test tools/cedrus_jpeg_test.c

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <linux/videodev2.h>

#define NCAP 4

struct buf {
	void *p;
	size_t len;
};

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;

	do
		r = ioctl(fd, req, arg);
	while (r < 0 && errno == EINTR);
	return r;
}

static void die(const char *what)
{
	fprintf(stderr, "%s: %s\n", what, strerror(errno));
	exit(1);
}

static double now_us(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}

static uint8_t *read_file(const char *path, size_t *len)
{
	struct stat st;
	uint8_t *d;
	int fd = open(path, O_RDONLY);

	if (fd < 0 || fstat(fd, &st) < 0)
		die(path);
	d = malloc(st.st_size);
	if (!d || read(fd, d, st.st_size) != st.st_size)
		die(path);
	close(fd);
	*len = st.st_size;
	return d;
}

// Width and height from the first SOF0 marker (baseline only).
static int jpeg_size(const uint8_t *d, size_t len, unsigned *w, unsigned *h)
{
	size_t i = 2;

	if (len < 4 || d[0] != 0xff || d[1] != 0xd8)
		return -1;
	while (i + 9 < len) {
		if (d[i] != 0xff)
			return -1;
		if (d[i + 1] == 0xc0) {
			*h = d[i + 5] << 8 | d[i + 6];
			*w = d[i + 7] << 8 | d[i + 8];
			return 0;
		}
		if (d[i + 1] >= 0xc1 && d[i + 1] <= 0xcf && d[i + 1] != 0xc4 &&
		    d[i + 1] != 0xc8 && d[i + 1] != 0xcc)
			return -2; // not baseline
		i += 2 + (d[i + 2] << 8 | d[i + 3]);
	}
	return -1;
}

static int find_cedrus(char *path, size_t n)
{
	struct v4l2_capability cap;
	int i, fd;

	for (i = 0; i < 16; i++) {
		snprintf(path, n, "/dev/video%d", i);
		fd = open(path, O_RDWR);
		if (fd < 0)
			continue;
		if (!xioctl(fd, VIDIOC_QUERYCAP, &cap) &&
		    !strcmp((char *)cap.driver, "cedrus"))
			return fd;
		close(fd);
	}
	return -1;
}

// NV12_32L32: each plane is stored as 32x32-byte tiles, row of tiles by row
// of tiles; the chroma plane starts after the 32-aligned luma height.
static void detile(const uint8_t *src, uint8_t *dst, unsigned stride,
		   unsigned w, unsigned rows)
{
	unsigned x, y;

	for (y = 0; y < rows; y++)
		for (x = 0; x < w; x++)
			dst[y * w + x] = src[((y / 32) * (stride / 32) + x / 32) * 1024 +
					     (y % 32) * 32 + x % 32];
}

static int check_h264_needs_request(int fd)
{
	struct v4l2_format f;
	struct v4l2_requestbuffers rb;
	struct v4l2_buffer b;

	memset(&f, 0, sizeof(f));
	f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	f.fmt.pix.pixelformat = V4L2_PIX_FMT_H264_SLICE;
	f.fmt.pix.width = 256;
	f.fmt.pix.height = 256;
	if (xioctl(fd, VIDIOC_S_FMT, &f) || f.fmt.pix.pixelformat != V4L2_PIX_FMT_H264_SLICE)
		die("S_FMT OUTPUT H264_SLICE");
	memset(&rb, 0, sizeof(rb));
	rb.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	rb.memory = V4L2_MEMORY_MMAP;
	rb.count = 1;
	if (xioctl(fd, VIDIOC_REQBUFS, &rb))
		die("REQBUFS OUTPUT");
	memset(&b, 0, sizeof(b));
	b.type = rb.type;
	b.memory = V4L2_MEMORY_MMAP;
	b.bytesused = 16;
	if (!xioctl(fd, VIDIOC_QBUF, &b)) {
		printf("H.264 OUTPUT buffer without a request: queued (should be refused)\n");
		return 1;
	}
	printf("H.264 OUTPUT buffer without a request: %s (%s)\n", strerror(errno),
	       errno == EBADR ? "ok" : "should be EBADR");
	return errno == EBADR ? 0 : 1;
}

static void cpu_stat(unsigned long long *busy, unsigned long long *total)
{
	unsigned long long v[8] = { 0 };
	FILE *f = fopen("/proc/stat", "r");

	if (!f || fscanf(f, "cpu %llu %llu %llu %llu %llu %llu %llu %llu",
			 &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) != 8)
		die("/proc/stat");
	fclose(f);
	*total = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7];
	*busy = *total - v[3] - v[4];
}

int main(int argc, char **argv)
{
	const char *out = NULL, *dev = NULL;
	char path[32];
	int loops = 100, opt, fd, i, nfiles;
	uint8_t **jpg;
	size_t *jlen, maxlen = 0;
	unsigned w = 0, h = 0;
	struct v4l2_format fo, fc;
	struct v4l2_requestbuffers rb;
	struct v4l2_buffer b;
	struct v4l2_exportbuffer eb;
	struct buf ob, cb[NCAP];
	enum v4l2_buf_type t;
	double tmin = 1e18, tmax = 0, tsum = 0, csum = 0, w0, w1;
	struct rusage r0, r1;
	unsigned long long b0, t0, b1, t1;
	int errors = 0, h264 = 0, rd = 0;
	double rsum = 0;
	uint8_t *rbuf = NULL;

	while ((opt = getopt(argc, argv, "Hrn:o:d:")) != -1) {
		switch (opt) {
		case 'H': h264 = 1; break;
		case 'r': rd = 1; break;
		case 'n': loops = atoi(optarg); break;
		case 'o': out = optarg; break;
		case 'd': dev = optarg; break;
		default:
			fprintf(stderr, "usage: %s [-n LOOPS] [-o OUT_PREFIX] [-d DEV] FILE.jpg...\n"
				"       %s -H [-d DEV]\n", argv[0], argv[0]);
			return 2;
		}
	}
	nfiles = argc - optind;
	if (h264) {
		if (dev) {
			fd = open(dev, O_RDWR);
			if (fd < 0)
				die(dev);
		} else if ((fd = find_cedrus(path, sizeof(path))) < 0) {
			fprintf(stderr, "no cedrus video device\n");
			return 1;
		}
		return check_h264_needs_request(fd);
	}
	if (nfiles < 1 || loops < 1) {
		fprintf(stderr, "no JPEG given\n");
		return 2;
	}
	jpg = calloc(nfiles, sizeof(*jpg));
	jlen = calloc(nfiles, sizeof(*jlen));
	for (i = 0; i < nfiles; i++) {
		unsigned fw, fh;
		int r;

		jpg[i] = read_file(argv[optind + i], &jlen[i]);
		r = jpeg_size(jpg[i], jlen[i], &fw, &fh);
		if (r) {
			fprintf(stderr, "%s: %s\n", argv[optind + i],
				r == -2 ? "not a baseline JPEG" : "no SOF0 marker");
			return 1;
		}
		if (i && (fw != w || fh != h)) {
			fprintf(stderr, "%s: %ux%u, the first file is %ux%u\n",
				argv[optind + i], fw, fh, w, h);
			return 1;
		}
		w = fw;
		h = fh;
		if (jlen[i] > maxlen)
			maxlen = jlen[i];
	}

	if (dev) {
		fd = open(dev, O_RDWR);
		if (fd < 0)
			die(dev);
	} else {
		fd = find_cedrus(path, sizeof(path));
		if (fd < 0) {
			fprintf(stderr, "no cedrus video device\n");
			return 1;
		}
		dev = path;
	}

	memset(&fo, 0, sizeof(fo));
	fo.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	fo.fmt.pix.pixelformat = V4L2_PIX_FMT_JPEG;
	fo.fmt.pix.width = w;
	fo.fmt.pix.height = h;
	fo.fmt.pix.sizeimage = (maxlen + 4095) & ~4095u;
	if (xioctl(fd, VIDIOC_S_FMT, &fo))
		die("S_FMT OUTPUT JPEG (no JPEG decoder in this cedrus?)");
	if (fo.fmt.pix.pixelformat != V4L2_PIX_FMT_JPEG) {
		fprintf(stderr, "%s: JPEG is not an OUTPUT format of this cedrus\n", dev);
		return 1;
	}

	memset(&fc, 0, sizeof(fc));
	fc.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (xioctl(fd, VIDIOC_G_FMT, &fc))
		die("G_FMT CAPTURE");
	printf("%s: %ux%u JPEG -> %.4s %ux%u, stride %u, %u bytes\n", dev, w, h,
	       (char *)&fc.fmt.pix.pixelformat, fc.fmt.pix.width,
	       fc.fmt.pix.height, fc.fmt.pix.bytesperline,
	       fc.fmt.pix.sizeimage);
	if (fc.fmt.pix.pixelformat != V4L2_PIX_FMT_NV12_32L32 && out) {
		fprintf(stderr, "only NV12_32L32 can be written out\n");
		return 1;
	}

	memset(&rb, 0, sizeof(rb));
	rb.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	rb.memory = V4L2_MEMORY_MMAP;
	rb.count = 1;
	if (xioctl(fd, VIDIOC_REQBUFS, &rb))
		die("REQBUFS OUTPUT");
	memset(&b, 0, sizeof(b));
	b.type = rb.type;
	b.memory = V4L2_MEMORY_MMAP;
	if (xioctl(fd, VIDIOC_QUERYBUF, &b))
		die("QUERYBUF OUTPUT");
	ob.len = b.length;
	ob.p = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
	if (ob.p == MAP_FAILED)
		die("mmap OUTPUT");

	memset(&rb, 0, sizeof(rb));
	rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	rb.memory = V4L2_MEMORY_MMAP;
	rb.count = NCAP;
	if (xioctl(fd, VIDIOC_REQBUFS, &rb) || rb.count < 1)
		die("REQBUFS CAPTURE");
	for (i = 0; i < (int)rb.count && i < NCAP; i++) {
		memset(&b, 0, sizeof(b));
		b.type = rb.type;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		if (xioctl(fd, VIDIOC_QUERYBUF, &b))
			die("QUERYBUF CAPTURE");
		cb[i].len = b.length;
		cb[i].p = mmap(NULL, b.length, PROT_READ, MAP_SHARED, fd, b.m.offset);
		if (cb[i].p == MAP_FAILED)
			die("mmap CAPTURE");
	}

	memset(&eb, 0, sizeof(eb));
	eb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	eb.index = 0;
	eb.flags = O_RDONLY | O_CLOEXEC;
	if (xioctl(fd, VIDIOC_EXPBUF, &eb))
		printf("EXPBUF CAPTURE 0: failed: %s\n", strerror(errno));
	else {
		printf("EXPBUF CAPTURE 0: dma-buf fd %d\n", eb.fd);
		close(eb.fd);
	}

	t = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	if (xioctl(fd, VIDIOC_STREAMON, &t))
		die("STREAMON OUTPUT");
	t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (xioctl(fd, VIDIOC_STREAMON, &t))
		die("STREAMON CAPTURE");

	if (rd && !(rbuf = malloc(cb[0].len)))
		die("malloc");
	getrusage(RUSAGE_SELF, &r0);
	cpu_stat(&b0, &t0);
	w0 = now_us();
	for (i = 0; i < loops; i++) {
		int f = i % nfiles, ci = i % (int)rb.count;
		double c0, q0, q1;

		c0 = now_us();
		memcpy(ob.p, jpg[f], jlen[f]);
		q0 = now_us();

		memset(&b, 0, sizeof(b));
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = ci;
		if (xioctl(fd, VIDIOC_QBUF, &b))
			die("QBUF CAPTURE");
		memset(&b, 0, sizeof(b));
		b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = 0;
		b.bytesused = jlen[f];
		if (xioctl(fd, VIDIOC_QBUF, &b))
			die("QBUF OUTPUT");

		memset(&b, 0, sizeof(b));
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		b.memory = V4L2_MEMORY_MMAP;
		if (xioctl(fd, VIDIOC_DQBUF, &b))
			die("DQBUF CAPTURE");
		q1 = now_us();
		if (b.flags & V4L2_BUF_FLAG_ERROR)
			errors++;
		ci = b.index;
		memset(&b, 0, sizeof(b));
		b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
		b.memory = V4L2_MEMORY_MMAP;
		if (xioctl(fd, VIDIOC_DQBUF, &b))
			die("DQBUF OUTPUT");

		if (rd) {
			double r0 = now_us();

			memcpy(rbuf, cb[ci].p, cb[ci].len);
			rsum += now_us() - r0;
		}
		csum += q0 - c0;
		tsum += q1 - q0;
		if (q1 - q0 < tmin)
			tmin = q1 - q0;
		if (q1 - q0 > tmax)
			tmax = q1 - q0;

		if (out && i < nfiles) {
			char name[256];
			unsigned s = fc.fmt.pix.bytesperline;
			unsigned lh = (h + 31) & ~31u;
			uint8_t *lin = malloc(w * h * 3 / 2);
			FILE *o;

			detile(cb[ci].p, lin, s, w, h);
			detile((uint8_t *)cb[ci].p + s * lh, lin + w * h, s, w, h / 2);
			snprintf(name, sizeof(name), "%s%d.nv12", out, f);
			o = fopen(name, "wb");
			if (!o || fwrite(lin, 1, w * h * 3 / 2, o) != w * h * 3 / 2)
				die(name);
			fclose(o);
			free(lin);
		}
	}
	w1 = now_us();
	cpu_stat(&b1, &t1);
	getrusage(RUSAGE_SELF, &r1);

	{
		double u = (r1.ru_utime.tv_sec - r0.ru_utime.tv_sec) * 1e6 +
			   (r1.ru_utime.tv_usec - r0.ru_utime.tv_usec);
		double s = (r1.ru_stime.tv_sec - r0.ru_stime.tv_sec) * 1e6 +
			   (r1.ru_stime.tv_usec - r0.ru_stime.tv_usec);

		printf("decodes: %d of %d file(s), %d with the ERROR flag\n",
		       loops, nfiles, errors);
		printf("queue to picture: min %.0f us, avg %.0f us, max %.0f us\n",
		       tmin, tsum / loops, tmax);
		printf("copy of the JPEG into the OUTPUT buffer: avg %.0f us\n",
		       csum / loops);
		if (rd)
			printf("CPU read of the picture (%zu bytes): avg %.0f us\n",
			       cb[0].len, rsum / loops);
		printf("wall %.0f ms, %.1f tiles/s; this process: user %.0f ms, sys %.0f ms (%.0f%% of the wall)\n",
		       (w1 - w0) / 1e3, loops / ((w1 - w0) / 1e6), u / 1e3, s / 1e3,
		       100 * (u + s) / (w1 - w0));
		printf("system CPU busy over the loop: %.0f%%\n",
		       t1 > t0 ? 100.0 * (b1 - b0) / (t1 - t0) : 0.0);
	}
	return errors ? 1 : 0;
}
