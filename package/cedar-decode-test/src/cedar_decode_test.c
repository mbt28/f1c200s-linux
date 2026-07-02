/*
 * cedar-decode-test — standalone Allwinner Cedar (libcedarc) H.264 decode test.
 *
 * Validates the kernel cedar/VE driver + /dev/ion + libcedarc chain WITHOUT
 * ffmpeg (ffmpeg cannot drive libcedarc). Feeds a raw H.264 Annex-B elementary
 * stream, assembling NAL units into access units (one picture per submit, as the
 * Cedar Frame-SBM expects), reports decoded frame count / resolution / fps, and
 * optionally renders frames to /dev/fb0 (--fb) as a minimal HW-decoded player.
 *
 *   cedar-decode-test clip.h264 [--fb] [--max N] [--loop]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/fb.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

#include "vdecoder.h"
#include "memoryAdapter.h"
#include "sc_interface.h"

/* exported from libcedarc (added by our build fixup): dma-buf fd for a frame */
extern int ion_alloc_get_dmabuf_fd(void *vir_addr);

static int64_t now_us(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

/* Dump the VE output-stage registers straight after a decode, while the config
 * is still live (before libcedarc's next ENGINE_REQ resets the engine). This is
 * how we read the BSP's real SDROT_CTRL for the cedrus chroma fix. */
static void ve_dump(void)
{
	static volatile uint32_t *ve;
	static int n;
	if (n++ >= 3)
		return;
	if (!ve) {
		int fd = open("/dev/mem", O_RDWR | O_SYNC);
		if (fd < 0) { perror("/dev/mem"); return; }
		ve = mmap(NULL, 0x1000, PROT_READ, MAP_SHARED, fd, 0x01c0e000);
		close(fd);
		if (ve == MAP_FAILED) { ve = NULL; return; }
	}
	fprintf(stderr,
		"VE-REGS: c4=%08x c8=%08x cc=%08x e8=%08x ec=%08x | "
		"SDROT_ctrl(240)=%08x luma(244)=%08x chroma(248)=%08x idx(24c)=%08x\n",
		ve[0xc4/4], ve[0xc8/4], ve[0xcc/4], ve[0xe8/4], ve[0xec/4],
		ve[0x240/4], ve[0x244/4], ve[0x248/4], ve[0x24c/4]);
}

/* find next Annex-B start code (00 00 01) at or after pos; -1 if none */
static long find_startcode(const uint8_t *d, long len, long pos)
{
	for (long i = pos; i + 3 <= len; i++)
		if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1)
			return i;
	return -1;
}

/* ---------------- framebuffer output ---------------- */
static int            fb_fd = -1;
static uint8_t       *fb_mem = NULL;
static struct fb_var_screeninfo fb_var;
static struct fb_fix_screeninfo fb_fix;
static struct ScMemOpsS *g_memops;

static int fb_open(void)
{
	fb_fd = open("/dev/fb0", O_RDWR);
	if (fb_fd < 0) { perror("open /dev/fb0"); return -1; }
	if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &fb_var) ||
	    ioctl(fb_fd, FBIOGET_FSCREENINFO, &fb_fix)) {
		perror("FBIOGET_*SCREENINFO"); return -1;
	}
	fb_mem = mmap(NULL, fb_fix.smem_len, PROT_READ | PROT_WRITE,
		      MAP_SHARED, fb_fd, 0);
	if (fb_mem == MAP_FAILED) { perror("mmap fb"); fb_mem = NULL; return -1; }
	printf("fb: %ux%u %ubpp, line=%u\n", fb_var.xres, fb_var.yres,
	       fb_var.bits_per_pixel, fb_fix.line_length);
	return 0;
}

static inline uint8_t clip8(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }

/* Render one decoded picture to /dev/fb0, de-tiling Allwinner MB32_420.
 *
 * MB32 layout: frame split into 32x32 macroblocks stored row-major; within a
 * macroblock, 32 lines of 32 bytes. Luma is one byte/pixel. Chroma uses the
 * same macroblock grid but each line holds 16 interleaved U,V pairs (so one
 * MB spans 16 chroma columns x 32 chroma rows).
 */
static uint8_t rowY[2048], rowU[1024], rowV[1024];   /* cached de-tile scratch */

static void fb_show(VideoPicture *p)
{
	if (!fb_mem) return;
	int W = p->nWidth, H = p->nHeight;
	const uint8_t *Yp = (const uint8_t *)p->pData0;   /* MB32 luma   */
	const uint8_t *Cp = (const uint8_t *)p->pData1;   /* MB32 chroma */
	int mbW = ((W + 31) & ~31) / 32;                  /* macroblock columns */
	int cw = (W + 1) / 2;
	int last_cy = -1;

	int ox = ((int)fb_var.xres - W) / 2; if (ox < 0) ox = 0;
	int oy = ((int)fb_var.yres - H) / 2; if (oy < 0) oy = 0;
	int bpp = fb_var.bits_per_pixel;

	for (int y = 0; y < H && (oy + y) < (int)fb_var.yres; y++) {
		int my = y / 32, ly = y % 32;
		/* De-tile this luma row: mbW sequential 32-byte bursts from uncached
		 * memory into the cached row buffer. */
		for (int mx = 0; mx < mbW; mx++)
			memcpy(rowY + mx * 32,
			       Yp + ((long)(my * mbW + mx)) * 1024 + ly * 32, 32);

		/* Chroma changes only every 2nd output line; de-tile + de-interleave. */
		int cy = y / 2;
		if (cy != last_cy) {
			int cmy = cy / 32, cly = cy % 32;
			for (int mx = 0; mx < mbW; mx++) {
				uint8_t t[32];
				memcpy(t, Cp + ((long)(cmy * mbW + mx)) * 1024 + cly * 32, 32);
				for (int k = 0; k < 16; k++) {
					rowU[mx * 16 + k] = t[2 * k];
					rowV[mx * 16 + k] = t[2 * k + 1];
				}
			}
			last_cy = cy;
		}

		/* Convert from cached row buffers -> framebuffer. */
		uint8_t *row = fb_mem + (long)(oy + y) * fb_fix.line_length
				+ (long)ox * (bpp / 8);
		for (int x = 0; x < W && (ox + x) < (int)fb_var.xres; x++) {
			int cidx = x >> 1; if (cidx >= cw) cidx = cw - 1;
			int Yv = rowY[x], D = rowU[cidx] - 128, E = rowV[cidx] - 128;
			uint8_t r = clip8(Yv + ((1436 * E) >> 10));
			uint8_t g = clip8(Yv - ((352 * D + 731 * E) >> 10));
			uint8_t b = clip8(Yv + ((1814 * D) >> 10));
			if (bpp == 16) {
				((uint16_t *)row)[x] =
					((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3);
			} else { /* 32bpp BGRA/XRGB */
				row[x*4+0] = b; row[x*4+1] = g; row[x*4+2] = r; row[x*4+3] = 0xff;
			}
		}
	}
}

/* ---------------- DRM/KMS zero-copy display ----------------
 * The VE output (MB32 tiled NV21) is handed to the sun4i Display Engine as a
 * DRM framebuffer (DRM_FORMAT_NV12 + DRM_FORMAT_MOD_ALLWINNER_TILED). The
 * frontend de-tiles + converts YUV->RGB + scales to the panel in hardware --
 * no CPU per-pixel work at all.
 */
/* output mode flags (parsed in main); declared early so drm_init can branch */
static int g_fb, g_drm, g_be, g_noscale, g_hold;

static int      drm_fd = -1;
static uint32_t drm_crtc, drm_plane, drm_conn;
static uint32_t drm_cw, drm_ch;       /* panel (crtc) size */
static uint32_t drm_prev_fb;
static uint32_t drm_want_fmt = DRM_FORMAT_NV12;  /* plane format to look for */
static drmModeModeInfo drm_mode;      /* the connector mode we drive */
static uint32_t drm_mode_blob;        /* MODE_ID blob for the atomic modeset */
static int      drm_modeset_done;
/* property ids resolved once in drm_init() */
static uint32_t P_plane_fb, P_plane_crtc, P_plane_sx, P_plane_sy, P_plane_sw,
		P_plane_sh, P_plane_cx, P_plane_cy, P_plane_cw, P_plane_ch;
static uint32_t P_crtc_mode, P_crtc_active, P_conn_crtc;

/* Resolve a property id by name on a DRM object (plane/crtc/connector). The
 * front-end is only engaged through the ATOMIC api, so we drive everything via
 * object properties rather than the legacy SetCrtc/SetPlane calls. */
static uint32_t prop_id(uint32_t obj_id, uint32_t obj_type, const char *name)
{
	drmModeObjectProperties *props =
		drmModeObjectGetProperties(drm_fd, obj_id, obj_type);
	uint32_t id = 0;
	if (props) {
		for (uint32_t i = 0; i < props->count_props && !id; i++) {
			drmModePropertyRes *p = drmModeGetProperty(drm_fd, props->props[i]);
			if (p) {
				if (!strcmp(p->name, name)) id = p->prop_id;
				drmModeFreeProperty(p);
			}
		}
		drmModeFreeObjectProperties(props);
	}
	return id;
}

/* Plane "type" property value (PRIMARY/OVERLAY/CURSOR). */
static uint64_t plane_type(uint32_t plane_id)
{
	drmModeObjectProperties *props =
		drmModeObjectGetProperties(drm_fd, plane_id, DRM_MODE_OBJECT_PLANE);
	uint64_t type = (uint64_t)-1;
	if (props) {
		for (uint32_t i = 0; i < props->count_props; i++) {
			drmModePropertyRes *p = drmModeGetProperty(drm_fd, props->props[i]);
			if (p) {
				if (!strcmp(p->name, "type")) type = props->prop_values[i];
				drmModeFreeProperty(p);
			}
		}
		drmModeFreeObjectProperties(props);
	}
	return type;
}
static const char *be_fmt_name = "uyvy";         /* --fmt for the --be path  */

/* Map a packed-YUV422 name to its DRM fourcc. The bytes we write are always
 * U Y0 V Y1 (memory UYVY); changing the fourcc changes the hardware FBPS pixel
 * sequence, which is how we find the order the suniv DEBE actually wants. */
static uint32_t be_fmt_fourcc(const char *n)
{
	if (!strcasecmp(n, "uyvy")) return DRM_FORMAT_UYVY;
	if (!strcasecmp(n, "yvyu")) return DRM_FORMAT_YVYU;
	if (!strcasecmp(n, "yuyv")) return DRM_FORMAT_YUYV;
	if (!strcasecmp(n, "vyuy")) return DRM_FORMAT_VYUY;
	fprintf(stderr, "unknown --fmt '%s' (use uyvy|yvyu|yuyv|vyuy), defaulting uyvy\n", n);
	return DRM_FORMAT_UYVY;
}

static int drm_init(void)
{
	drm_fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (drm_fd < 0) { perror("open /dev/dri/card0"); return -1; }
	drmSetMaster(drm_fd);
	drmSetClientCap(drm_fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
	/* ATOMIC cap is what lets the kernel route a tiled plane onto the DEFE
	 * front-end (the decision is made in sun4i's atomic_check). The --be path
	 * still uses legacy SetPlane on the back-end, which is fine. */
	int atomic = (drmSetClientCap(drm_fd, DRM_CLIENT_CAP_ATOMIC, 1) == 0);
	if (g_drm && !atomic) { fprintf(stderr, "DRM_CLIENT_CAP_ATOMIC unavailable\n"); return -1; }

	drmModeRes *res = drmModeGetResources(drm_fd);
	if (!res) { fprintf(stderr, "drmModeGetResources failed\n"); return -1; }

	drmModeConnector *conn = NULL;
	for (int i = 0; i < res->count_connectors; i++) {
		drmModeConnector *c = drmModeGetConnector(drm_fd, res->connectors[i]);
		if (c && c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) {
			conn = c; break;
		}
		if (c) drmModeFreeConnector(c);
	}
	if (!conn) { fprintf(stderr, "no connected connector\n"); return -1; }
	drm_conn = conn->connector_id;
	drm_mode = conn->modes[0];                 /* preferred mode for the modeset */

	drmModeEncoder *enc = drmModeGetEncoder(drm_fd, conn->encoder_id);
	drm_crtc = enc ? enc->crtc_id : 0;
	if (!drm_crtc && res->count_crtcs) drm_crtc = res->crtcs[0];
	drmModeCrtc *crtc = drmModeGetCrtc(drm_fd, drm_crtc);
	drm_cw = crtc->mode.hdisplay ? crtc->mode.hdisplay : drm_mode.hdisplay;
	drm_ch = crtc->mode.vdisplay ? crtc->mode.vdisplay : drm_mode.vdisplay;

	int crtc_idx = 0;
	for (int i = 0; i < res->count_crtcs; i++)
		if (res->crtcs[i] == drm_crtc) { crtc_idx = i; break; }

	/* For --drm we do a full atomic modeset, so use the PRIMARY plane that can
	 * take our format; for --be (legacy) any matching plane is fine. */
	uint32_t want = drm_want_fmt;
	uint32_t fallback_plane = 0;
	drmModePlaneRes *pr = drmModeGetPlaneResources(drm_fd);
	for (uint32_t i = 0; i < pr->count_planes && !drm_plane; i++) {
		drmModePlane *pl = drmModeGetPlane(drm_fd, pr->planes[i]);
		if (pl && (pl->possible_crtcs & (1 << crtc_idx))) {
			int ok = 0;
			for (uint32_t f = 0; f < pl->count_formats; f++)
				if (pl->formats[f] == want) { ok = 1; break; }
			if (ok) {
				if (!fallback_plane) fallback_plane = pl->plane_id;
				if (!g_drm || plane_type(pl->plane_id) == DRM_PLANE_TYPE_PRIMARY)
					drm_plane = pl->plane_id;
			}
		}
		if (pl) drmModeFreePlane(pl);
	}
	if (!drm_plane) drm_plane = fallback_plane;
	if (!drm_plane) { fprintf(stderr, "no plane supporting fmt 0x%x\n", want); return -1; }

	if (g_drm) {
		/* Resolve the property ids we set every commit + the modeset ones. */
		P_plane_fb   = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "FB_ID");
		P_plane_crtc = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "CRTC_ID");
		P_plane_sx   = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "SRC_X");
		P_plane_sy   = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "SRC_Y");
		P_plane_sw   = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "SRC_W");
		P_plane_sh   = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "SRC_H");
		P_plane_cx   = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "CRTC_X");
		P_plane_cy   = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "CRTC_Y");
		P_plane_cw   = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "CRTC_W");
		P_plane_ch   = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "CRTC_H");
		P_crtc_mode  = prop_id(drm_crtc,  DRM_MODE_OBJECT_CRTC,  "MODE_ID");
		P_crtc_active= prop_id(drm_crtc,  DRM_MODE_OBJECT_CRTC,  "ACTIVE");
		P_conn_crtc  = prop_id(drm_conn,  DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID");
		if (!P_plane_fb || !P_plane_crtc || !P_crtc_mode || !P_crtc_active || !P_conn_crtc) {
			fprintf(stderr, "missing atomic properties (fb=%u crtc=%u mode=%u act=%u conn=%u)\n",
				P_plane_fb, P_plane_crtc, P_crtc_mode, P_crtc_active, P_conn_crtc);
			return -1;
		}
		if (drmModeCreatePropertyBlob(drm_fd, &drm_mode, sizeof(drm_mode), &drm_mode_blob)) {
			perror("CreatePropertyBlob(mode)"); return -1;
		}
	}

	printf("drm: crtc=%u %ux%u, plane=%u (%s), conn=%u, mode %ux%u\n",
	       drm_crtc, drm_cw, drm_ch, drm_plane,
	       g_drm ? "primary/atomic" : "legacy", drm_conn,
	       drm_mode.hdisplay, drm_mode.vdisplay);
	return 0;
}

/* ---------------- backend (de-be) YUV422 display ----------------
 * The mainline sun4i *backend* does YUV->RGB in hardware for PACKED YUV422
 * (UYVY), without the (broken-on-suniv) frontend. We de-tile the VE's MB32
 * YUV420 into a linear UYVY DRM dumb buffer (a cheap rearrange + chroma row
 * duplication -- no RGB math) and let the backend convert + scan it out.
 */
static uint8_t *be_map[2];
static uint32_t be_handle[2], be_fb[2], be_pitch;
static int be_bw, be_bh, be_cur;

static int be_create(int W, int H)
{
	for (int i = 0; i < 2; i++) {
		uint64_t size = 0, off = 0;
		if (drmModeCreateDumbBuffer(drm_fd, W, H, 16, 0, &be_handle[i], &be_pitch, &size)) {
			perror("CreateDumbBuffer"); return -1;
		}
		uint32_t handles[4] = { be_handle[i], 0, 0, 0 };
		uint32_t pitches[4] = { be_pitch, 0, 0, 0 };
		uint32_t offsets[4] = { 0, 0, 0, 0 };
		if (drmModeAddFB2(drm_fd, W, H, drm_want_fmt, handles, pitches, offsets, &be_fb[i], 0)) {
			perror("AddFB2 (be)"); return -1;
		}
		if (drmModeMapDumbBuffer(drm_fd, be_handle[i], &off)) { perror("MapDumb"); return -1; }
		be_map[i] = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, drm_fd, off);
		if (be_map[i] == MAP_FAILED) { perror("mmap dumb"); be_map[i] = NULL; return -1; }
	}
	be_bw = W; be_bh = H;
	printf("be: %s dumb %dx%d pitch=%u x2 -> backend HW YUV->RGB\n", be_fmt_name, W, H, be_pitch);
	return 0;
}

static void be_show(VideoPicture *p)
{
	int W = p->nWidth, H = p->nHeight;
	int dispW = (p->nRightOffset  > 0 && p->nRightOffset  <= W) ? p->nRightOffset  : W;
	int dispH = (p->nBottomOffset > 0 && p->nBottomOffset <= H) ? p->nBottomOffset : H;
	if (!be_map[0] && be_create(dispW, dispH) != 0) return;

	uint8_t *dst = be_map[be_cur];
	const uint8_t *Yp = (const uint8_t *)p->pData0;
	const uint8_t *Cp = (const uint8_t *)p->pData1;
	int mbW = ((W + 31) & ~31) / 32;
	int last_cy = -1;

	for (int y = 0; y < dispH; y++) {
		int my = y / 32, ly = y % 32;
		for (int mx = 0; mx < mbW; mx++)
			memcpy(rowY + mx * 32, Yp + ((long)(my * mbW + mx)) * 1024 + ly * 32, 32);

		int cy = y / 2;
		if (cy != last_cy) {
			int cmy = cy / 32, cly = cy % 32;
			for (int mx = 0; mx < mbW; mx++) {
				uint8_t t[32];
				memcpy(t, Cp + ((long)(cmy * mbW + mx)) * 1024 + cly * 32, 32);
				for (int k = 0; k < 16; k++) {
					rowU[mx * 16 + k] = t[2 * k];
					rowV[mx * 16 + k] = t[2 * k + 1];
				}
			}
			last_cy = cy;
		}

		/* pack UYVY: U Y0 V Y1 (one U/V shared by two luma samples) */
		uint8_t *o = dst + (long)y * be_pitch;
		for (int x = 0; x < dispW; x += 2) {
			int c = x >> 1;
			o[x * 2 + 0] = rowU[c]; o[x * 2 + 1] = rowY[x];
			o[x * 2 + 2] = rowV[c]; o[x * 2 + 3] = rowY[x + 1];
		}
	}

	int dx = ((int)drm_cw - dispW) / 2; if (dx < 0) dx = 0;
	int dy = ((int)drm_ch - dispH) / 2; if (dy < 0) dy = 0;
	if (drmModeSetPlane(drm_fd, drm_plane, drm_crtc, be_fb[be_cur], 0,
			    dx, dy, dispW, dispH,
			    0, 0, dispW << 16, dispH << 16))
		perror("drmModeSetPlane(be)");
	be_cur ^= 1;
}

static void drm_show(VideoPicture *p)
{
	/* Y and chroma are SEPARATE ION buffers -> import both, one handle each. */
	uint32_t hy = 0, hc = 0;
	int fy = ion_alloc_get_dmabuf_fd(p->pData0);
	int fc = ion_alloc_get_dmabuf_fd(p->pData1);
	if (fy < 0 || fc < 0) { fprintf(stderr, "no dma-buf fd for frame\n"); return; }
	if (drmPrimeFDToHandle(drm_fd, fy, &hy) ||
	    drmPrimeFDToHandle(drm_fd, fc, &hc)) {
		perror("drmPrimeFDToHandle"); return;
	}
	int W = p->nWidth, H = p->nHeight;
	uint32_t pitch = (W + 31) & ~31;
	uint32_t handles[4] = { hy, hc, 0, 0 };
	uint32_t pitches[4] = { pitch, pitch, 0, 0 };
	uint32_t offsets[4] = { 0, 0, 0, 0 };  /* each plane at the start of its buffer */
	uint64_t mods[4]    = { DRM_FORMAT_MOD_ALLWINNER_TILED,
				DRM_FORMAT_MOD_ALLWINNER_TILED, 0, 0 };
	uint32_t fb = 0;
	{
		static int once = 0;
		if (!once) {
			once = 1;
			fprintf(stderr, "DRMDIAG W=%d H=%d pitch=%u Ybuf=%ld Cbuf=%ld "
			    "needY=%u needC=%u\n", W, H, pitch,
			    (long)lseek(fy, 0, SEEK_END), (long)lseek(fc, 0, SEEK_END),
			    pitch * H, pitch * (H / 2));
		}
	}
	if (drmModeAddFB2WithModifiers(drm_fd, W, H, DRM_FORMAT_NV12,
				       handles, pitches, offsets, mods, &fb,
				       DRM_MODE_FB_MODIFIERS)) {
		perror("drmModeAddFB2WithModifiers"); return;
	}

	/* Source crop = the visible region (drop the MB32 padding); scale it to the
	 * whole panel using the DEFE scaler. SRC_* are 16.16 fixed point. */
	int dispW = (p->nRightOffset  > 0 && p->nRightOffset  <= W) ? p->nRightOffset  : W;
	int dispH = (p->nBottomOffset > 0 && p->nBottomOffset <= H) ? p->nBottomOffset : H;

	drmModeAtomicReq *req = drmModeAtomicAlloc();
	uint32_t flags = 0;
	if (!drm_modeset_done) {                    /* bring the pipeline up once */
		drmModeAtomicAddProperty(req, drm_conn, P_conn_crtc,  drm_crtc);
		drmModeAtomicAddProperty(req, drm_crtc, P_crtc_mode,  drm_mode_blob);
		drmModeAtomicAddProperty(req, drm_crtc, P_crtc_active, 1);
		flags = DRM_MODE_ATOMIC_ALLOW_MODESET;
	}
	drmModeAtomicAddProperty(req, drm_plane, P_plane_fb,   fb);
	drmModeAtomicAddProperty(req, drm_plane, P_plane_crtc, drm_crtc);
	drmModeAtomicAddProperty(req, drm_plane, P_plane_sx,   0);
	drmModeAtomicAddProperty(req, drm_plane, P_plane_sy,   0);
	drmModeAtomicAddProperty(req, drm_plane, P_plane_sw,   (uint64_t)dispW << 16);
	drmModeAtomicAddProperty(req, drm_plane, P_plane_sh,   (uint64_t)dispH << 16);
	/* Default: scale the cropped source to fill the panel (uses the DEFE
	 * scaler). --noscale: present 1:1, centered (no scaling) -- this is the
	 * real CarPlay case (480x272 source on a 480x272 panel) and avoids the
	 * suniv chroma-scaler limitation. */
	uint32_t cw = g_noscale ? (uint32_t)dispW : drm_cw;
	uint32_t ch = g_noscale ? (uint32_t)dispH : drm_ch;
	uint32_t cx = (drm_cw > cw) ? (drm_cw - cw) / 2 : 0;
	uint32_t cy = (drm_ch > ch) ? (drm_ch - ch) / 2 : 0;
	drmModeAtomicAddProperty(req, drm_plane, P_plane_cx,   cx);
	drmModeAtomicAddProperty(req, drm_plane, P_plane_cy,   cy);
	drmModeAtomicAddProperty(req, drm_plane, P_plane_cw,   cw);
	drmModeAtomicAddProperty(req, drm_plane, P_plane_ch,   ch);

	int rc = drmModeAtomicCommit(drm_fd, req, flags, NULL);
	drmModeAtomicFree(req);
	if (rc) {
		static int warned = 0;
		if (!warned) {
			warned = 1;
			fprintf(stderr, "atomic commit failed: %s (plane=%u crtc=%u src=%dx%d->%ux%u)\n",
				strerror(errno), drm_plane, drm_crtc, dispW, dispH, drm_cw, drm_ch);
		}
		drmModeRmFB(drm_fd, fb);
		return;
	}
	drm_modeset_done = 1;
	if (drm_prev_fb) drmModeRmFB(drm_fd, drm_prev_fb);
	drm_prev_fb = fb;
}

/* ---------------- decode ---------------- */
static VideoDecoder *g_dec;
static int g_frames, g_W, g_H, g_maxframes;

static int drain(void)
{
	int got = 0;
	VideoPicture *p;
	while ((p = RequestPicture(g_dec, 0)) != NULL) {
		if (!g_W) {
			g_W = p->nWidth; g_H = p->nHeight;
			/* one-shot diagnostic: is pData readable after flush? */
			if (g_memops)
				CdcMemFlushCache(g_memops, (void *)p->pData0,
					(long)p->nLineStride * p->nHeight * 3 / 2);
			const unsigned char *yb = (const unsigned char *)p->pData0;
			const unsigned char *cb = yb + (long)p->nLineStride * p->nHeight;
			fprintf(stderr, "DIAG fmt=%d %dx%d stride=%d crop t%d b%d l%d r%d "
				"pData0=%p pData1=%p phyY=0x%lx\nDIAG Y:",
				p->ePixelFormat, p->nWidth, p->nHeight, p->nLineStride,
				p->nTopOffset, p->nBottomOffset, p->nLeftOffset,
				p->nRightOffset, (void *)p->pData0, (void *)p->pData1,
				(unsigned long)p->phyYBufAddr);
			for (int k = 0; k < 16; k++) fprintf(stderr, " %02x", yb[k]);
			fprintf(stderr, "\nDIAG C:");
			for (int k = 0; k < 16; k++) fprintf(stderr, " %02x", cb[k]);
			fprintf(stderr, "\n");
		}
		if (g_be) { be_show(p); usleep(30000); }        /* pace ~30 fps */
		else if (g_drm) { drm_show(p); usleep(30000); }
		else if (g_fb) fb_show(p);
		g_frames++; got++;
		ReturnPicture(g_dec, p);
		if (g_hold && g_drm) {
			/* Stop committing so the driver's per-frame update_coord no
			 * longer rewrites the DEFE scaler regs -- they stay stable for
			 * live devmem experiments on the displayed frame. */
			fprintf(stderr, "HELD frame %d on screen; DEFE regs frozen. "
				"Poke via devmem (clear EN bit31 first). Ctrl-C to exit.\n",
				g_frames);
			for (;;) sleep(3600);
		}
		if (g_maxframes && g_frames >= g_maxframes) break;
	}
	return got;
}

/* submit one access unit [data, data+len) and decode */
static void feed_au(const uint8_t *data, long len)
{
	char *b0, *b1; int s0, s1;
	if (len <= 0) return;
	/* The stream-buffer-manager (SBM) ring can be momentarily full when the
	 * decoder is waiting on a free output frame. Don't drop the access unit
	 * (that corrupts the stream) -- drain displayed frames to release output
	 * buffers and retry, so we back-pressure instead. */
	int tries = 0;
	while (RequestVideoStreamBuffer(g_dec, (int)len, &b0, &s0, &b1, &s1, 0) != 0
	       || (s0 + s1) < len) {
		if (drain() == 0) usleep(2000);
		if (++tries > 500) return;   /* ~1s with no progress: give up */
	}
	if (len <= s0) memcpy(b0, data, len);
	else { memcpy(b0, data, s0); memcpy(b1, data + s0, len - s0); }
	VideoStreamDataInfo di;
	memset(&di, 0, sizeof(di));
	di.pData = b0; di.nLength = (int)len;
	di.bIsFirstPart = 1; di.bIsLastPart = 1;
	di.nPts = (int64_t)g_frames * 33000; di.bValid = 1;
	SubmitVideoStreamData(g_dec, &di, 0);

	for (;;) {
		int r = DecodeVideoStream(g_dec, 0, 0, 0, 0);
		if (r == VDECODE_RESULT_FRAME_DECODED ||
		    r == VDECODE_RESULT_KEYFRAME_DECODED ||
		    r == VDECODE_RESULT_OK) {
			ve_dump();
			drain();
			if (g_maxframes && g_frames >= g_maxframes) return;
		} else if (r == VDECODE_RESULT_NO_FRAME_BUFFER) {
			if (drain() == 0) break;
		} else if (r == VDECODE_RESULT_RESOLUTION_CHANGE) {
			continue;
		} else { /* NO_BITSTREAM / CONTINUE / UNSUPPORTED */
			break;
		}
	}
}

int main(int argc, char **argv)
{
	const char *path = NULL;
	int loop = 0;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--fb")) g_fb = 1;
		else if (!strcmp(argv[i], "--drm")) g_drm = 1;
		else if (!strcmp(argv[i], "--be")) g_be = 1;
		else if (!strcmp(argv[i], "--fmt") && i + 1 < argc) be_fmt_name = argv[++i];
		else if (!strcmp(argv[i], "--noscale")) g_noscale = 1;
		else if (!strcmp(argv[i], "--hold")) g_hold = 1;
		else if (!strcmp(argv[i], "--loop")) loop = 1;
		else if (!strcmp(argv[i], "--max") && i + 1 < argc) g_maxframes = atoi(argv[++i]);
		else path = argv[i];
	}
	if (!path) {
		fprintf(stderr, "usage: %s clip.h264 [--fb|--be|--drm] [--fmt uyvy|yvyu|yuyv|vyuy] [--max N] [--loop]\n", argv[0]);
		return 1;
	}

	FILE *f = fopen(path, "rb");
	if (!f) { perror("open input"); return 1; }
	fseek(f, 0, SEEK_END); long flen = ftell(f); fseek(f, 0, SEEK_SET);
	uint8_t *fdata = malloc(flen);
	if (!fdata || fread(fdata, 1, flen, f) != (size_t)flen) {
		fprintf(stderr, "read failed\n"); return 1;
	}
	fclose(f);
	printf("input: %s (%ld bytes)\n", path, flen);

	if (g_fb && fb_open() != 0) g_fb = 0;
	if (g_be) drm_want_fmt = be_fmt_fourcc(be_fmt_name);
	if ((g_drm || g_be) && drm_init() != 0) {
		fprintf(stderr, "drm init failed\n"); g_drm = g_be = 0;
	}

	AddVDPlugin();
	g_dec = CreateVideoDecoder();
	if (!g_dec) { fprintf(stderr, "CreateVideoDecoder failed\n"); return 1; }

	VideoStreamInfo si; memset(&si, 0, sizeof(si));
	si.eCodecFormat = VIDEO_CODEC_FORMAT_H264;

	VConfig vc; memset(&vc, 0, sizeof(vc));
	/* The F1C200S VE can ONLY output its native MB32 tiled format (not YV12);
	 * requesting YV12 yields an empty buffer. We de-tile MB32 in fb_show. */
	vc.eOutputPixelFormat = PIXEL_FORMAT_YUV_MB32_420;
	vc.bDispErrorFrame = 1;
	/* Budget output frames for the ones the display path holds while showing
	 * (drain() keeps a picture across the present), otherwise the decoder runs
	 * dry, DecodeVideoStream returns NO_FRAME_BUFFER, and we'd drop input AUs. */
	vc.nDisplayHoldingFrameBufferNum = 2;
	vc.nDecodeSmoothFrameBufferNum = 2;
	vc.memops = MemAdapterGetOpsS();
	if (!vc.memops) { fprintf(stderr, "MemAdapterGetOpsS failed (/dev/ion?)\n"); return 1; }
	g_memops = vc.memops;
	CdcMemOpen(vc.memops);

	if (InitializeVideoDecoder(g_dec, &si, &vc) != 0) {
		fprintf(stderr, "InitializeVideoDecoder failed\n");
		DestroyVideoDecoder(g_dec); return 1;
	}
	printf("decoder initialized (H.264); decoding%s...\n",
	       g_be ? " to DRM backend (UYVY, HW YUV->RGB)" :
	       g_drm ? " to DRM frontend plane" : g_fb ? " to /dev/fb0" : "");

	int64_t t0 = now_us();
	do {
		long au_start = -1; int au_has_vcl = 0;
		long pos = find_startcode(fdata, flen, 0);
		while (pos >= 0) {
			if (au_start < 0) au_start = pos;
			int nal_type = fdata[pos + 3] & 0x1F;
			int is_vcl = (nal_type >= 1 && nal_type <= 5);
			if (is_vcl) {
				int first_mb0 = (pos + 4 < flen) && (fdata[pos + 4] & 0x80);
				if (au_has_vcl && first_mb0) {
					feed_au(fdata + au_start, pos - au_start);
					au_start = pos;
				}
				au_has_vcl = 1;
			}
			if (g_maxframes && g_frames >= g_maxframes) break;
			pos = find_startcode(fdata, flen, pos + 3);
		}
		if (au_start >= 0 && (!g_maxframes || g_frames < g_maxframes))
			feed_au(fdata + au_start, flen - au_start);
	} while (loop && (!g_maxframes || g_frames < g_maxframes));

	/* flush */
	for (int i = 0; i < 1000; i++) {
		int r = DecodeVideoStream(g_dec, 1, 0, 0, 0);
		drain();
		if (r == VDECODE_RESULT_NO_BITSTREAM) break;
	}

	double secs = (now_us() - t0) / 1e6;
	printf("\nRESULT: decoded %d frames, %dx%d, %.2fs => %.1f fps (HW)\n",
	       g_frames, g_W, g_H, secs, secs > 0 ? g_frames / secs : 0.0);

	DestroyVideoDecoder(g_dec);
	CdcMemClose(vc.memops);
	if (fb_mem) munmap(fb_mem, fb_fix.smem_len);
	if (fb_fd >= 0) close(fb_fd);
	return g_frames > 0 ? 0 : 2;
}
