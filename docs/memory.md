# RAM research: where the 64 MiB goes, and what can be freed

Measured 2026-07-05 against the built kernel tree (`size` on vmlinux and the
per-directory `built-in.a`). Boot-time picture on the board:

```
Memory: 33516K/65536K available
        (9216K kernel code, 781K rwdata, 2596K rodata, 1024K init, 220K bss,
         15024K reserved, 16384K cma-reserved)
```

So of 64 MiB: **~33 MiB for userspace**, **16 MiB CMA** (decode + display
buffers), **~13 MiB resident kernel**, ~2 MiB other reservations. The two
places with real headroom are the kernel image and the CMA pool.

## 1. The kernel is fat: 9.5 MiB text + 3.2 MiB data

The base `sunxi` defconfig is a multi-platform config; our fragment disables
MULTI_V7 but inherits piles of unneeded built-ins. Measured offenders:

| subsystem | built-in text | verdict |
|---|---:|---|
| drivers/ | 4.58 MiB | trim below |
| fs/ | 1.82 MiB | **fs/nfs = 436 KiB — pure waste** (plus ~sunrpc in net/); ext4 439K + fat 63K stay |
| net/ | 1.81 MiB | ipv4 517K + core 528K stay (needed for `net on`); the rest is sunrpc/etc for NFS |
| kernel/ | 0.93 MiB | PERF_EVENTS on — droppable (~200K) |
| drivers/gpu | 846 KiB | sun4i DRM needed; other panels/bridges trimmable |
| drivers/net | 493 KiB | **USB NIC drivers are =y** (our fragment!) — make =m, loaded by `net on` |
| drivers/media | 436 KiB | V4L2 core needed for cedrus (=m); audit sub-drivers |
| sound/ | 302 KiB | **SND entirely unused** (FastCarPlay audio-driver = dummy) — drop |
| drivers/tty | 251 KiB | serial console stays; CONFIG_VT (~100K) droppable (no fbcon by design) |
| drivers/hid | 171 KiB | no HID devices on the appliance — droppable or =m |

**Single biggest lever: `CONFIG_CC_OPTIMIZE_FOR_SIZE` (-Os)** — currently
FOR_PERFORMANCE. Typical ARM32 text reduction 15–20 % ≈ **1.4–1.9 MiB**, at a
small (usually irrelevant here — the hot paths are hardware engines) CPU cost.

Realistic total from a config diet:

| action | est. resident saving |
|---|---:|
| -Os | 1.4–1.9 MiB |
| drop NFS client (+sunrpc) | 0.7–0.9 MiB |
| drop SND stack | 0.3 MiB |
| USB NIC drivers -> =m (`net on` modprobes) | 0.3 MiB |
| drop PERF_EVENTS, SUSPEND, VT, HID | 0.4–0.5 MiB |
| audit DRM panels / media sub-drivers | 0.2–0.4 MiB |
| **total** | **~3.3–4.3 MiB** (→ userspace ~37 MiB) |

## 2. CMA: 16 MiB reserved, actual use unmeasured

The pool serves cedrus/cedar decode buffers, ffmpeg's right-sized coded
buffers (~1 MiB × DPB), the DRM dumb buffers (UI overlay 2×510 KiB + fb0
~510 KiB), and DEFE scanout. Earlier estimates put streaming use at
~8–12 MiB. **Measure before cutting** — on the board, while streaming
CarPlay (worst case: video + UI overlay visible):

```sh
grep -i cma /proc/meminfo          # CmaTotal / CmaFree
cat /sys/kernel/debug/dma_buf/bufinfo 2>/dev/null   # per-buffer, if debugfs on
```

If CmaFree stays ≥ 5 MiB under load, `CONFIG_CMA_SIZE_MBYTES=12` frees 4 MiB
for userspace. Keep margin for fragmentation on long runs; remember the
hard-won ceiling in the other direction (32 MiB CMA doesn't boot).

## 3. Userspace: mostly fine, three notes

- Idle userspace is tiny (busybox init + getty; dropbear only with `net on`).
  FastCarPlay's RSS is the main consumer — measure with `cat /proc/$(pidof
  fastcarplay)/status | grep VmRSS` while streaming; its `rendering-buffer`
  and `async-usb-calls` settings trade RAM for smoothness.
- tmpfs (`/tmp`, `/run`) has no size cap by default (limit = RAM/2); the only
  writer is `/tmp/carplay.log`, which grows unbounded on long sessions —
  worth capping (`mount -o size=4m` in fstab) or rotating.
- Shared libs (ffmpeg ~9 MiB on disk) cost only their *used* code pages
  (file-backed, evictable) — not a real RAM lever.

## 4. Optional: zram swap

A 8–16 MiB zram device (~2–3× compression on typical anon pages) adds
effective headroom for peak moments at some CPU cost on the 408 MHz core.
Only worth it if userspace actually hits OOM after the kernel diet — check
`dmesg | grep -i oom` history first.

## Recommended order

1. Measure CMA + FastCarPlay RSS on the board during streaming (commands above).
2. Kernel diet fragment: -Os, no NFS/sunrpc, no SND, no PERF/SUSPEND/VT/HID,
   USB NICs to =m (net-on modprobes them). Expected: **+3.5–4 MiB userspace**.
3. If step 1 shows ≥5 MiB CmaFree under worst-case load: CMA 16→12. **+4 MiB.**
4. Cap /tmp; consider zram only if OOM is ever observed.

Combined realistic outcome: **~33 → ~41 MiB available to userspace** without
touching functionality.
