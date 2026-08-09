# RAM research: where the 64 MiB goes, and what can be freed

Originally measured 2026-07-05 against the built kernel tree (`size` on vmlinux
and the per-directory `built-in.a`); **updated 2026-08-09 with on-board
measurements** — §§2–5 and the recommended order all carry newer numbers than
the §1 projections below.

Boot-time picture as first measured, before the kernel diet:

```
Memory: 33516K/65536K available
        (9216K kernel code, 781K rwdata, 2596K rodata, 1024K init, 220K bss,
         15024K reserved, 16384K cma-reserved)
```

Current, after the diet and the debug-block removal (2026-08-09):

```
Memory: 35788K/65536K available
        (7168K kernel code, 759K rwdata, 2256K rodata, 1024K init, 207K bss,
         12944K reserved, 16384K cma-reserved)
```

So of 64 MiB: **~35 MiB for userspace**, **16 MiB CMA** (decode + display
buffers), **~12.6 MiB resident kernel**. The kernel image and CMA were the two
places with real headroom; both have now been worked (§1, §2) and the largest
remaining lever is in userspace, not the kernel (§3).

**Caution on the boot line:** it is printed by `mem_init()` and therefore shows
only *static* footprint. Anything allocated at `core_initcall` or later —
`DMA_API_DEBUG`'s 4 MiB being the case in point — never appears in it. Do not
use it to measure runtime allocations; see §5 for the method that works.

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
roughly 3 MB. **Confirmed 2026-08-09: 34764K** — +1248K, well short of the
~3 MB projected from the 2.94 MiB vmlinux shrink, because a smaller vmlinux
frees text/rodata pages that were already counted as reserved rather than
handing that space to userspace one-for-one. (35788K after the §5 debug-block
removal.)

Kconfig gotcha that cost two rebuilds: `CONFIG_VT` is declared
`bool "Virtual terminal" if EXPERT` with `default y`, so without
`CONFIG_EXPERT=y` the fragment's `# CONFIG_VT is not set` line is *silently
ignored* — olddefconfig forces VT straight back on (nothing `select`s it; the
prompt is just invisible). The fragment now sets EXPERT=y, which only unhides
prompts (config-diff audited: no other built code changes) and selects
DEBUG_KERNEL as a bare menu gate, neutralized by keeping DEBUG_MISC off.

## 2. CMA: 16 MiB reserved, fully used, do not reduce

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

**Addendum 2026-08-09 — the pool is held by the app, and it is not a leak.**
`CmaFree` read **196 kB** with fastcarplay running and *no* CarPlay session,
which looked alarming next to the 2472 kB above. Killing the app returned it:
**8372 kB free** on one image and **11540 kB** on another, both with the app
stopped. So the LVGL UI and the decode path hold ~8–11 MiB of CMA for as long
as the app is alive, session or not, and release it cleanly on exit. Read
`CmaFree` with the app **stopped** if you want a baseline; a low number with
the app running is normal, not the CMA leak (that was fixed 2026-07-19, patch
0020). CMA remains unswappable, so no amount of swap addresses this pool.

## 3. Userspace: the app is 16 MiB, and ~11 MiB of daemons start unasked

- **FastCarPlay RSS, measured 2026-08-08** (app up, no CarPlay session):
  `VmRSS 16400 kB`, of which `RssAnon 7192 kB` and `RssFile 9208 kB`. The anon
  half is 84 % of the whole system's `AnonPages` — i.e. the app *is* the
  userspace memory story. Only `RssAnon` is swap-relevant; the file half is
  already evictable. Its `rendering-buffer` and `async-usb-calls` settings
  trade RAM for smoothness.
- **Idle userspace is NOT tiny any more, and this doc was wrong about it.**
  `rootfs-overlay/etc/init.d/S45aa-stack` has no gate and starts the radios and
  their daemons on every boot. Measured RSS: **bluealsa 4800 kB, bluetoothd
  3616 kB, dbus-daemon 1544 kB, dropbear 1396 kB ≈ 11 MiB** (RSS overcounts
  shared library pages, so the true anon cost is lower, but it is several MiB).
  The 2026-07-07 amendment in §1 assumes these are absent unless `wifi on` —
  that has been false since the gate was removed on 2026-07-19 (`b7b4c4e`).
  Re-gating is a **product decision, not a cleanup**: the script's header
  explains the gate was dropped deliberately because the LVGL UI offers the
  wireless sources at runtime.
- **tmpfs is capped as of 2026-08-08** (`post-build.sh`): `/tmp` 8M, `/run` 2M,
  `/dev/shm` 4M, all `noatime`. They defaulted to RAM/2 = 25.9 MiB *each*, so
  three mounts were entitled to 77.7 MiB against 52 MiB of RAM. Measured use at
  the time was 36 / 24 / 0 kB, so the caps free nothing — they bound blast
  radius, and they matter more if swap is ever enabled because tmpfs pages are
  swappable. `/tmp/carplay.log` is no longer a concern: every log writer moved
  to `/var/log` on its own SD partition (p3) in `4df4538`.
- Shared libs (ffmpeg ~9 MiB on disk) cost only their *used* code pages
  (file-backed, evictable) — not a real RAM lever.

## 4. zram swap — MEASURED AND DECLINED 2026-08-08

The gate this section used to set ("only worth it if userspace actually hits
OOM") was finally evaluated on hardware. **It is not met, and swap ships
disabled** (`/etc/swap-disable`). Measured on the board, app running, no
CarPlay session:

| | measured | why it settles the question |
| --- | ---: | --- |
| OOM events, ever | **0** | this section's own gate, never tripped |
| **AnonPages, whole system** | **8520 kB** | the entire swappable working set |
| MemAvailable | 23936 kB | healthy |
| `allocstall_*` | 1 total | essentially no reclaim pressure |
| `pgscan_direct` / `pgsteal_direct` | 63 / 55 | since boot |
| `compact_stall` / `compact_fail` | 0 / 0 | no fragmentation stalls |

A 24 MiB zram would have been ~3× the entire anonymous working set. Even
swapping all of it at 2.5× compression nets ~5 MiB, and realistically far less
because most of those 8.5 MiB are hot — while spending CPU on the single
408 MHz core that is already the video bottleneck. An SD swap tier is worse
still: card wear for a tier these numbers say would never be reached.

The machinery exists and is tested, so this is a decision rather than a
limitation: `rootfs-overlay/etc/init.d/S02swap`, `/etc/sysctl.conf`, busybox
`swapon -p` support, and a reserved 64 MiB p4 (type 0x82). To enable:

```sh
rm /etc/swap-disable && touch /etc/swap-sd && reboot   # zram + SD tier
rm /etc/swap-disable && reboot                         # zram only
```

Neither needs a rebuild. **Re-measure the table above before enabling** — if it
still looks like this, the answer is still no.

## 5. Debug instrumentation removed — controlled A/B, 2026-08-09

`DMA_API_DEBUG`, `FTRACE`, `DYNAMIC_DEBUG` and `CMA_DEBUGFS` were a TEMPORARY
block for the CMA leak (fixed 2026-07-19) and the MUSB DDMA bring-up (parked).
`kernel/dma/debug.c` preallocates `1<<16` = 65536 `dma_debug_entry` at
`core_initcall` and never frees them; on this target (32-bit, UP, no
STACKTRACE) that is ~56–64 B each.

Measured by flashing both images and running an identical script at ~170–195 s
uptime with the app killed and caches dropped (`AnonPages` came out identical
at 1400 kB in both runs, confirming the states matched):

| kB | debug on | debug off | delta |
| --- | ---: | ---: | ---: |
| MemTotal | 53016 | 53616 | **+600** |
| MemFree | 23208 | 30432 | +7224 |
| **MemAvailable** | 28420 | 28492 | **+72** |
| Slab | 6244 | 6008 | −236 |
| CmaFree | 8372 | 11540 | +3168 |
| **unaccounted kernel** | **13820** | **7476** | **−6344** |

"Unaccounted" = `MemTotal` minus MemFree/Buffers/Cached/AnonPages/Slab/
KernelStack/PageTables — the bucket raw `get_zeroed_page()` allocations land
in. It also captures CMA held by drivers, which differed by 3168 kB between
runs (residual noise the protocol did not pin down), so the attributable
figure is **−6344 + 3168 ≈ −3.1 MiB of non-CMA kernel memory**, just under the
3.5–4 MiB predicted. Boot line moved 34764K → 35788K (+1 MiB), which is the
static rodata/rwdata/bss shrink only.

**Two honest caveats.** The `Memory: … available` boot line was never going to
show the 4 MiB — `dma_debug_init()` is a `core_initcall` and runs *after* that
line is printed. And **`MemAvailable` did not improve** (+72 kB) despite ~3 MiB
being returned and `MemFree` rising 7.2 MiB; on the new image `MemAvailable` is
actually *below* `MemFree`, which is unexplained. Free CMA pages inflating
`MemFree` without counting toward `si_mem_available()` is the likely cause but
has not been verified in the source.

So: keep it (free kernel memory, zero runtime cost, instrumentation both
investigations are finished with) but do not claim a userspace-visible win.

Reviving the MUSB DMA work means reverting that hunk; `musb-mux-trace` degrades
cleanly, checking for the tracepoints and exiting with a message.

## Recommended order

1. ~~Measure CMA + FastCarPlay RSS on the board during streaming~~ — done, §2/§3.
2. ~~Kernel diet fragment~~ — done, measured **2.94 MiB** off vmlinux (§1).
3. ~~CMA 16→12~~ — ruled out by the measurement (§2).
4. ~~Cap /tmp~~ — done 2026-08-08, and logs moved off tmpfs entirely (§3).
5. ~~zram~~ — measured and declined (§4).
6. ~~Remove the TEMPORARY debug block~~ — done, ~3 MiB (§5).
7. **Still open, and now the largest single lever:** `S45aa-stack` starts
   ~11 MiB of daemons on every boot (§3). Needs a product decision, not a
   cleanup — see the caveat there.
