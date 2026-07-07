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

### Applied 2026-07-05 (`board/lctech/pi-f1c200s/linux.fragment`) — measured

-Os; NFS, SOUND/SND, PERF_EVENTS, SUSPEND/PM_SLEEP, HID and VT all off; USB
NIC drivers + g_ether to `=m` (`net on` / S41 / S42 modprobe them on demand).

**Amended 2026-07-06:** minimal ALSA restored (SOUND/SND/SND_SOC +
SND_SUN4I_CODEC =y) — CarPlay audio output through the internal codec is
planned, so dropping the whole stack was wrong. USB-audio class, I2S, SPDIF
and the dummy/loopback drivers stay off (~half the 302 KiB still saved).

**Amended 2026-07-07 (wireless):** ESP-Hosted-NG adds cfg80211 + bluetooth +
esp32_spi as modules — ~1–1.5 MiB resident plus wpa_supplicant RSS, but ONLY
while `wifi on`; `wifi off` unloads all three, so the diet is untouched in
the appliance's default state. SPI core (+sun6i) is built-in (~40 KiB).

| vmlinux (`size`) | before | after | saved |
|---|---:|---:|---:|
| text | 9,494,699 | 6,783,532 | 2.59 MiB |
| total (text+data+bss) | 12,885,551 | 9,800,492 | **2.94 MiB** |

Expected on-board effect: `Memory: ... available` rises from 33516K by
roughly 3 MB (confirm the boot line after flashing).

Kconfig gotcha that cost two rebuilds: `CONFIG_VT` is declared
`bool "Virtual terminal" if EXPERT` with `default y`, so without
`CONFIG_EXPERT=y` the fragment's `# CONFIG_VT is not set` line is *silently
ignored* — olddefconfig forces VT straight back on (nothing `select`s it; the
prompt is just invisible). The fragment now sets EXPERT=y, which only unhides
prompts (config-diff audited: no other built code changes) and selects
DEBUG_KERNEL as a bare menu gate, neutralized by keeping DEBUG_MISC off.

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

**Measured 2026-07-05 (streaming CarPlay): CmaTotal 16384 kB, CmaFree
2472 kB — 13.9 MiB in active use. CMA stays at 16 MiB; do NOT reduce.**
(The old guidance to consider 12 MiB is void; the pool is fully earning
its keep. The opposite ceiling still holds too: 32 MiB doesn't boot.)

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

1. ~~Measure CMA + FastCarPlay RSS on the board during streaming~~ — done,
   see §2: CMA is fully used, stays 16 MiB.
2. ~~Kernel diet fragment~~ — done, measured **2.94 MiB** off vmlinux (§1).
3. ~~CMA 16→12~~ — ruled out by the measurement (2472 kB free while streaming).
4. Still open: cap /tmp (`/tmp/carplay.log` grows unbounded); zram only if
   OOM is ever observed.

Combined realistic outcome: **~33 → ~41 MiB available to userspace** without
touching functionality.
