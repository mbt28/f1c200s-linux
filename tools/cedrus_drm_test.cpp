// cedrus_drm_test — decode an H.264 elementary stream through the mainline
// cedrus decoder (ffmpeg V4L2-Request hwaccel) and present each frame on the
// sun4i DEFE front-end (atomic NV12 + ALLWINNER_TILED plane). No USB/CarPlay,
// no libcedarc — a minimal repro of FastCarPlay's CedrusDecoder for debugging
// the suniv DEFE chroma (green) issue.
//
//   cedrus_drm_test <file.h264> [loops]   (loops=0 -> forever)
//
// Cross-compile against the buildroot sysroot (see build line at bottom).

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cerrno>
#include <cstdlib>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_drm.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <linux/dma-buf.h>
}
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>
#include <sys/mman.h>

// ---- DEFE atomic display (identical to FastCarPlay CedrusDecoder) ----
namespace {
int drm_fd = -1;
uint32_t drm_crtc = 0, drm_plane = 0, drm_conn = 0, drm_cw = 0, drm_ch = 0;
uint32_t drm_prev_fb = 0, drm_mode_blob = 0;
uint32_t g_force_fmt = 0;   // override the FB fourcc (e.g. NV21 to test U/V swap)
bool g_dump = false;        // --dump: print full DRM descriptor + write raw planes (once)
int g_dumpframe = 30;       // which frame# to dump (env DF overrides)
drmModeModeInfo drm_mode;
bool drm_modeset_done = false;
uint32_t P_plane_fb, P_plane_crtc, P_plane_sx, P_plane_sy, P_plane_sw, P_plane_sh,
    P_plane_cx, P_plane_cy, P_plane_cw, P_plane_ch, P_crtc_mode, P_crtc_active, P_conn_crtc;

uint32_t prop_id(uint32_t obj_id, uint32_t obj_type, const char *name)
{
    drmModeObjectProperties *props = drmModeObjectGetProperties(drm_fd, obj_id, obj_type);
    uint32_t id = 0;
    if (props) {
        for (uint32_t i = 0; i < props->count_props && !id; i++) {
            drmModePropertyRes *pr = drmModeGetProperty(drm_fd, props->props[i]);
            if (pr) {
                if (!strcmp(pr->name, name)) id = pr->prop_id;
                drmModeFreeProperty(pr);
            }
        }
        drmModeFreeObjectProperties(props);
    }
    return id;
}

uint64_t plane_type(uint32_t plane_id)
{
    drmModeObjectProperties *props = drmModeObjectGetProperties(drm_fd, plane_id, DRM_MODE_OBJECT_PLANE);
    uint64_t type = (uint64_t)-1;
    if (props) {
        for (uint32_t i = 0; i < props->count_props; i++) {
            drmModePropertyRes *pr = drmModeGetProperty(drm_fd, props->props[i]);
            if (pr) {
                if (!strcmp(pr->name, "type")) type = props->prop_values[i];
                drmModeFreeProperty(pr);
            }
        }
        drmModeFreeObjectProperties(props);
    }
    return type;
}

bool drm_open()
{
    drm_fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (drm_fd < 0) { perror("open card0"); return false; }
    drmSetMaster(drm_fd);
    drmSetClientCap(drm_fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
    if (drmSetClientCap(drm_fd, DRM_CLIENT_CAP_ATOMIC, 1)) { fprintf(stderr, "no atomic\n"); return false; }

    drmModeRes *res = drmModeGetResources(drm_fd);
    if (!res) return false;
    drmModeConnector *conn = nullptr;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(drm_fd, res->connectors[i]);
        if (c && c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) { conn = c; break; }
        if (c) drmModeFreeConnector(c);
    }
    if (!conn) { fprintf(stderr, "no connector\n"); return false; }
    drm_conn = conn->connector_id;
    drm_mode = conn->modes[0];

    drmModeEncoder *enc = drmModeGetEncoder(drm_fd, conn->encoder_id);
    drm_crtc = enc ? enc->crtc_id : (res->count_crtcs ? res->crtcs[0] : 0);
    drmModeCrtc *crtc = drmModeGetCrtc(drm_fd, drm_crtc);
    drm_cw = (crtc && crtc->mode.hdisplay) ? crtc->mode.hdisplay : drm_mode.hdisplay;
    drm_ch = (crtc && crtc->mode.vdisplay) ? crtc->mode.vdisplay : drm_mode.vdisplay;

    int crtc_idx = 0;
    for (int i = 0; i < res->count_crtcs; i++)
        if (res->crtcs[i] == drm_crtc) { crtc_idx = i; break; }

    uint32_t fallback = 0;
    drmModePlaneRes *prr = drmModeGetPlaneResources(drm_fd);
    for (uint32_t i = 0; i < prr->count_planes && !drm_plane; i++) {
        drmModePlane *pl = drmModeGetPlane(drm_fd, prr->planes[i]);
        if (pl && (pl->possible_crtcs & (1 << crtc_idx))) {
            bool ok = false;
            for (uint32_t f = 0; f < pl->count_formats; f++)
                if (pl->formats[f] == DRM_FORMAT_NV12) { ok = true; break; }
            if (ok) {
                if (!fallback) fallback = pl->plane_id;
                if (plane_type(pl->plane_id) == DRM_PLANE_TYPE_PRIMARY) drm_plane = pl->plane_id;
            }
        }
        if (pl) drmModeFreePlane(pl);
    }
    if (!drm_plane) drm_plane = fallback;
    if (!drm_plane) { fprintf(stderr, "no NV12 plane\n"); return false; }

    P_plane_fb    = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "FB_ID");
    P_plane_crtc  = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "CRTC_ID");
    P_plane_sx    = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "SRC_X");
    P_plane_sy    = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "SRC_Y");
    P_plane_sw    = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "SRC_W");
    P_plane_sh    = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "SRC_H");
    P_plane_cx    = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "CRTC_X");
    P_plane_cy    = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "CRTC_Y");
    P_plane_cw    = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "CRTC_W");
    P_plane_ch    = prop_id(drm_plane, DRM_MODE_OBJECT_PLANE, "CRTC_H");
    P_crtc_mode   = prop_id(drm_crtc,  DRM_MODE_OBJECT_CRTC,  "MODE_ID");
    P_crtc_active = prop_id(drm_crtc,  DRM_MODE_OBJECT_CRTC,  "ACTIVE");
    P_conn_crtc   = prop_id(drm_conn,  DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID");
    if (!P_plane_fb || !P_crtc_mode || !P_conn_crtc) { fprintf(stderr, "missing props\n"); return false; }
    if (drmModeCreatePropertyBlob(drm_fd, &drm_mode, sizeof(drm_mode), &drm_mode_blob)) { perror("blob"); return false; }

    fprintf(stderr, "[test] DRM crtc=%u %ux%u plane=%u\n", drm_crtc, drm_cw, drm_ch, drm_plane);
    return true;
}

void drm_show(AVFrame *frame)
{
    AVDRMFrameDescriptor *d = (AVDRMFrameDescriptor *)frame->data[0];
    if (!d || d->nb_objects < 1 || d->nb_layers < 1) return;
    const AVDRMLayerDescriptor *layer = &d->layers[0];

    uint32_t handles[4] = {0}, pitches[4] = {0}, offsets[4] = {0};
    uint64_t mods[4] = {0};
    int np = layer->nb_planes < 4 ? layer->nb_planes : 4;
    for (int i = 0; i < np; i++) {
        int oi = layer->planes[i].object_index;
        uint32_t h = 0;
        if (drmPrimeFDToHandle(drm_fd, d->objects[oi].fd, &h)) { perror("FDToHandle"); return; }
        handles[i] = h;
        pitches[i] = layer->planes[i].pitch;
        offsets[i] = layer->planes[i].offset;
        mods[i] = d->objects[oi].format_modifier;
    }
    static bool logged = false;
    if (!logged) {
        logged = true;
        fprintf(stderr, "[test] frame %dx%d fmt=%.4s objs=%d layers=%d\n",
                frame->width, frame->height, (const char *)&layer->format,
                d->nb_objects, d->nb_layers);
        for (int o = 0; o < d->nb_objects; o++)
            fprintf(stderr, "  obj[%d] fd=%d size=%zu mod=0x%llx\n", o, d->objects[o].fd,
                    (size_t)d->objects[o].size, (unsigned long long)d->objects[o].format_modifier);
        for (int l = 0; l < d->nb_layers; l++) {
            fprintf(stderr, "  layer[%d] fmt=%.4s planes=%d\n", l,
                    (const char *)&d->layers[l].format, d->layers[l].nb_planes);
            for (int pl = 0; pl < d->layers[l].nb_planes; pl++)
                fprintf(stderr, "    plane[%d] obj=%d offset=%td pitch=%td\n", pl,
                        d->layers[l].planes[pl].object_index,
                        (ptrdiff_t)d->layers[l].planes[pl].offset,
                        (ptrdiff_t)d->layers[l].planes[pl].pitch);
        }
    }

    static int fc = 0;
    if (g_dump && ++fc == g_dumpframe) {
        for (int o = 0; o < d->nb_objects; o++) {
            size_t sz = d->objects[o].size;
            int ofd = d->objects[o].fd;
            void *m = mmap(nullptr, sz, PROT_READ, MAP_SHARED, ofd, 0);
            if (m == MAP_FAILED) { perror("  [dump] mmap"); continue; }
            struct dma_buf_sync s; s.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ;
            ioctl(ofd, DMA_BUF_IOCTL_SYNC, &s);   // CPU cache invalidate so we see DMA data
            char fn[64]; snprintf(fn, sizeof fn, "/root/cedrus_dump_obj%d.bin", o);
            FILE *df = fopen(fn, "wb");
            if (df) { fwrite(m, 1, sz, df); fclose(df);
                fprintf(stderr, "  [dump] frame#%d wrote %s (%zu bytes)\n", fc, fn, sz); }
            s.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
            ioctl(ofd, DMA_BUF_IOCTL_SYNC, &s);
            munmap(m, sz);
        }
    }

    uint32_t fbfmt = g_force_fmt ? g_force_fmt : layer->format;
    static bool fmtlogged = false;
    if (!fmtlogged) { fmtlogged = true; fprintf(stderr, "[test] using FB fourcc %.4s\n", (const char *)&fbfmt); }
    uint32_t fb = 0;
    if (drmModeAddFB2WithModifiers(drm_fd, frame->width, frame->height, fbfmt,
                                   handles, pitches, offsets, mods, &fb, DRM_MODE_FB_MODIFIERS)) { perror("AddFB2"); return; }

    drmModeAtomicReq *req = drmModeAtomicAlloc();
    uint32_t flags = 0;
    if (!drm_modeset_done) {
        drmModeAtomicAddProperty(req, drm_conn, P_conn_crtc,  drm_crtc);
        drmModeAtomicAddProperty(req, drm_crtc, P_crtc_mode,  drm_mode_blob);
        drmModeAtomicAddProperty(req, drm_crtc, P_crtc_active, 1);
        flags = DRM_MODE_ATOMIC_ALLOW_MODESET;
    }
    drmModeAtomicAddProperty(req, drm_plane, P_plane_fb,   fb);
    drmModeAtomicAddProperty(req, drm_plane, P_plane_crtc, drm_crtc);
    drmModeAtomicAddProperty(req, drm_plane, P_plane_sx,   0);
    drmModeAtomicAddProperty(req, drm_plane, P_plane_sy,   0);
    drmModeAtomicAddProperty(req, drm_plane, P_plane_sw,   (uint64_t)frame->width  << 16);
    drmModeAtomicAddProperty(req, drm_plane, P_plane_sh,   (uint64_t)frame->height << 16);
    /* 1:1, centered on the panel (no DE scaling) -- rules out the scaler path */
    uint32_t cw = frame->width  < drm_cw ? frame->width  : drm_cw;
    uint32_t ch = frame->height < drm_ch ? frame->height : drm_ch;
    drmModeAtomicAddProperty(req, drm_plane, P_plane_cx,   (drm_cw - cw) / 2);
    drmModeAtomicAddProperty(req, drm_plane, P_plane_cy,   (drm_ch - ch) / 2);
    drmModeAtomicAddProperty(req, drm_plane, P_plane_cw,   cw);
    drmModeAtomicAddProperty(req, drm_plane, P_plane_ch,   ch);

    int crc = drmModeAtomicCommit(drm_fd, req, flags, nullptr);
    drmModeAtomicFree(req);
    if (crc) { static bool w=false; if(!w){w=true;fprintf(stderr,"commit failed: %s\n",strerror(errno));} drmModeRmFB(drm_fd, fb); return; }
    drm_modeset_done = true;
    if (drm_prev_fb) drmModeRmFB(drm_fd, drm_prev_fb);
    drm_prev_fb = fb;
}

enum AVPixelFormat get_drm_format(AVCodecContext *, const enum AVPixelFormat *fmts)
{
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++)
        if (*p == AV_PIX_FMT_DRM_PRIME) return *p;
    return fmts[0];
}
} // namespace

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "/root/videos/test.h264";
    int loops = argc > 2 ? atoi(argv[2]) : 0; // 0 = forever
    if (argc > 3) { // FB fourcc override: nv21 (swap U/V) / nv12 / nv16 / yuv420 ...
        if (!strcmp(argv[3], "nv21")) g_force_fmt = DRM_FORMAT_NV21;
        else if (!strcmp(argv[3], "nv12")) g_force_fmt = DRM_FORMAT_NV12;
        else if (!strcmp(argv[3], "yuv420")) g_force_fmt = DRM_FORMAT_YUV420;
        else if (!strcmp(argv[3], "yvu420")) g_force_fmt = DRM_FORMAT_YVU420;
    }
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--dump")) g_dump = true;
    if (getenv("DF")) g_dumpframe = atoi(getenv("DF"));

    if (!drm_open()) return 1;

    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_H264);
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    AVBufferRef *hw = nullptr;
    if (av_hwdevice_ctx_create(&hw, AV_HWDEVICE_TYPE_DRM, nullptr, nullptr, 0) < 0) { fprintf(stderr, "no DRM hwdevice\n"); return 1; }
    ctx->hw_device_ctx = av_buffer_ref(hw);
    ctx->get_format = get_drm_format;
    if (avcodec_open2(ctx, codec, nullptr) < 0) { fprintf(stderr, "open2 failed\n"); return 1; }

    AVCodecParserContext *parser = av_parser_init(AV_CODEC_ID_H264);
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 1; }

    uint8_t buf[65536];
    int iter = 0;
    bool run = true;
    while (run) {
        size_t n = fread(buf, 1, sizeof(buf), f);
        if (n == 0) {
            if (loops && ++iter >= loops) break;
            fseek(f, 0, SEEK_SET);
            continue;
        }
        uint8_t *p = buf;
        int rem = (int)n;
        while (rem > 0) {
            uint8_t *pd; int ps;
            int len = av_parser_parse2(parser, ctx, &pd, &ps, p, rem, AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);
            if (len < 0) break;
            p += len; rem -= len;
            if (ps <= 0) continue;
            av_packet_unref(pkt); pkt->data = pd; pkt->size = ps;
            if (avcodec_send_packet(ctx, pkt) == 0) {
                while (avcodec_receive_frame(ctx, frame) == 0) {
                    if (frame->format == AV_PIX_FMT_DRM_PRIME) drm_show(frame);
                    av_frame_unref(frame);
                    usleep(33000); // ~30 fps so the picture is watchable
                }
            }
        }
    }

    av_frame_free(&frame);
    av_packet_free(&pkt);
    av_parser_close(parser);
    avcodec_free_context(&ctx);
    av_buffer_unref(&hw);
    return 0;
}

/*
Cross-compile (from carplay-linux/buildroot):
  SR=output-lctech/host/arm-buildroot-linux-gnueabi/sysroot
  output-lctech/host/bin/arm-buildroot-linux-gnueabi-g++ -O2 -std=c++17 \
    --sysroot=$SR -I$SR/usr/include/libdrm \
    cedrus_drm_test.cpp -o cedrus_drm_test \
    -lavcodec -lavutil -ldrm
*/
