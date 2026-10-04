# On-chip audio codec (F1C200s)

The F1C200s has a stereo 16-bit DAC/ADC with a headphone driver and a mic
pre-amp at `0x01c23c00`, driven by mainline `sun4i-codec` (suniv variant) and
fed by the `sun4i-dma` normal-DMA engine (DRQ 12 both directions). The Lctech
Pi routes HPL/HPR through a PAM8301 class-D amplifier to the speaker header
(always on, no PA-enable GPIO) and MICIN to the on-board microphone.

Hardware-validated 2026-10-03 on the kernel-6.18 image: a 44.1 kHz / 16-bit
stereo WAV plays through the speaker, the ADC captures real audio (proven
2026-10-04 with a DAC→output-mixer→ADC-mixer loopback of a 1 kHz tone, and
with the on-board electret once its bias network was fixed), and both DMA
directions stay perfectly real-time paced over minutes of back-to-back
streams.

## What it took

| piece | where | why |
|---|---|---|
| enable `codec@1c23c00` + routing | `patches/linux-lctech/0026-…enable-the-audio-codec.patch` | the mainline suniv dtsi ships the node `status = "disabled"` and without `allwinner,audio-routing` DAPM never powers the output path |
| `CLK_SET_RATE_PARENT` on the codec module clock | `patches/linux-lctech/0027-suniv-f1c100s-codec-clk-set-rate-parent.patch` | without it the 44.1 kHz family runs at 48 kHz (see below) |
| tinyalsa + its tools | `BR2_PACKAGE_TINYALSA`, `BR2_PACKAGE_TINYALSA_TOOLS` | `tinymix`, `tinycap`, `tinyplay` — the tools are a sub-option, the library alone gives no binaries |
| mixer defaults at boot | `rootfs-overlay/etc/init.d/S41audio` | the codec powers up with everything muted |

`CONFIG_SND_SUN4I_CODEC=y` and `CONFIG_DMA_SUN4I=y` were already in
`board/lctech/pi-f1c200s/linux.fragment`.

### The sample-rate bug (patch 0027)

`sun4i-codec` asks for the module clock rate per stream: 24.576 MHz for the
48 kHz family, 22.5792 MHz for 44.1 kHz. In the suniv CCU the codec clock is a
bare gate on `pll-audio` with flags `0`, so `clk_set_rate()` on it cannot
reach the PLL: the call "succeeds" with whatever `pll-audio` already runs at
(the boot value, 24.57 MHz) and every 44.1 kHz stream is consumed at
48.0 kframes/s — measured with a 5.94 s file finishing in 5.42 s, 8.8 % fast
and sharp. The A10 CCU gives the same gate `CLK_SET_RATE_PARENT`; patch 0027
does the same for suniv. The VE is on `pll-ve` (patch 0002), so nothing else
is disturbed when PLL_AUDIO is retuned.

## Mixer

Exact `tinymix` (2.x syntax: `tinymix set NAME V..`) control names:

| control | values | what |
|---|---|---|
| `Headphone Source Playback Route` | `DAC` / `Mixer` | DAC straight to the HP driver |
| `Headphone Playback Switch` | `1 1` | unmute L/R |
| `Headphone Playback Volume` | 0–63 | output level (S41audio: 58) |
| `DAC Playback Volume` | 0–63 | digital volume (63) |
| `ADC Mixer Mic Capture Switch` | 1 | mic into the ADC (**not** "Mic Capture Switch") |
| `Mic Boost Volume` | 0–7 | mic pre-amp (4) |
| `ADC Capture Volume` | 0–7 | ADC gain (2) |

Gain gotcha: the ADC pre-gain amplifies the codec's own DC offset. ADC
Capture Volume 5 rails every sample at about +32600 even in silence; 2 keeps
the input centred (about −470 ± 90 LSB). Mic Boost 5 still clipped normal
speech, hence 4.

## CPU: decode AAC in fixed point (the real "struggles when music plays")

Wireless CarPlay's media stream is **AAC-LC 44.1 kHz stereo**, about 35 KB/s
on the wire (the Siri/nav channels are Opus or PCM). The expensive part is not
moving it but decoding it: the toolchain is soft-float (`BR2_SOFT_FLOAT=y`,
the ARM926 has no FPU) and ffmpeg's default `aac` decoder is floating point,
so every sample ran through float emulation. Measured 2026-10-03 with music
playing: FastCarPlay's main thread 61 %, core 0 % idle, 850 timer wakeups/s
from the frame loop overrunning its budget, UI unresponsive.

FastCarPlay (branch `f1c200s-cedrus`) now asks libavcodec for `aac_fixed`
first — integer-only, full-scale S32P output, so the sample conversion takes
the top 16 bits (reading those as floats was the "noisy audio" first
attempt). Same board, same music: main thread 16 %, core 43 % idle, zero
ALSA underruns, 240 timer wakeups/s. `CONFIG_AAC_FIXED_DECODER=1` is already
in the image's ffmpeg; `libopus` (fixed-point) is not built, so Opus
channels still use the float decoder — `BR2_PACKAGE_OPUS` + ffmpeg
`--enable-libopus` is the follow-up if Siri/nav audio ever shows the same
symptom. Two follow-ups measured with exact scheduler runtimes (`/proc/<tid>/sched`,
not the tick-sampled `stat` fields, which on this HZ=100 kernel over-charge a
thread that wakes on the DMA period interrupt):

* SDL's audio output thread (`SDLAudioP2`) costs **1.4 %**, not the 16–20 %
  the tick counters suggested — it is blocked in the ALSA write 99 % of the
  time at ~22 wakeups/s. A plain tinyalsa writer on the same path costs ~4 %.
  Nothing to fix there.
* SDL's ALSA **hotplug poller** (`SDLHotplugALSA`) re-enumerated every PCM
  device through `snd_device_name_hint()` every 5 s, ~300 ms per scan on this
  core = **6 %** permanently, for an event that cannot happen with a soldered
  codec. `patches/sdl2/0001-audio-alsa-no-hotplug-poll-thread.patch` turns the
  compile-time switch off (devices are still enumerated once at start-up).
* Opus channels (Siri, nav, telephony) now decode through fixed-point
  `libopus`: `BR2_PACKAGE_OPUS=y` in the defconfig (Buildroot forces
  `--enable-fixed-point` on soft-float targets and `ffmpeg.mk` adds
  `--enable-libopus`), and FastCarPlay asks for `libopus` by name before the
  float decoder.

Related, outside the audio path but found with the same tooling: with no
phone connected FastCarPlay's main thread ran at **99 %** because the LVGL home
screen was cleared, copied and presented every loop iteration (longer than
the frame budget on the software renderer, so the pacing branch never
slept). FastCarPlay now presents only when LVGL flushed something.

## Memory footprint (matters on 64 MiB)

Audio is cheap in link bandwidth but not free in memory, and this board runs
at the edge: with the 24 MiB CMA fully taken by 800x480 wireless CarPlay
video, the rest of the system has about 28 MiB. Measured 2026-10-03:
MemAvailable 2–3 MiB, page cache squeezed to 3 MiB, 58 000 major page faults
— the kernel evicted executable pages and re-read them from the SD card on
every call, which compounded the decode cost above. Two levers ship in this
tree:

* `snd_soc_core.prealloc_buffer_size_kbytes=64` on the kernel command line
  (`board/lctech/pi-f1c200s/uboot-sdcard.fragment`, SD and NAND branches):
  the ASoC dmaengine PCM otherwise preallocates 512 KiB per direction from
  CMA at boot, i.e. ~1 MiB of decoder memory held hostage by idle audio.
* zram swap (`S02swap`, zram tier only). It was measured and declined in
  August at 24 MiB available / 8.5 MiB anonymous; with audio + the 800x480
  display the numbers are 2–3 MiB / 14 MiB, and enabling it live moved
  2 MiB of idle FastCarPlay memory into 0.85 MiB of compressed RAM within
  ten seconds. See `docs/memory.md` §4 for the re-measurement.

## Mixing two streams: ALSA dmix (since 2026-10-04)

The codec has a single playback PCM. FastCarPlay drives two sinks (music,
and Siri/nav/telephony), and with a plain `hw` default device the second
open got `EBUSY`, so the app closed the device on every idle gap and chopped
live calls. `rootfs-overlay/etc/asound.conf` (same file as FastCarPlay's
`board/asound.conf`) makes `default` an `asym` device: playback goes to a
`dmix` slave on `hw:0,0` at 48 kHz S16 stereo (the app streams everything at
48 kHz on purpose: Opus decodes to 48 k, PCM voice upsamples by an integer
factor, media is advertised at 48 k), capture stays a plain `plug:hw:0,0`.

dmix keeps its mix ring in System V shared memory guarded by a SysV
semaphore, so the kernel needs `CONFIG_SYSVIPC=y` (added to
`linux.fragment`); without it every dmix open fails with
`unable to create IPC semaphore: Function not implemented`. SYSVIPC adds
fields to `task_struct`, so a kernel built with it must be installed together
with its module tree. Check it is working with `ls /proc/sysvipc`, `ipcs`,
and `/proc/asound/card0/pcm0p/sub0/hw_params` showing `rate: 48000` while
the app plays.

### Full-duplex robustness (patches 0028, 0029)

Found while running 48 kHz dmix playback together with the 24 kHz mic
uplink:

* `0028-sun4i-codec-…`: the DAC holds the **last sample** on a TX FIFO
  underrun (`SEND_LASAT`) instead of sending zeros, so a DMA hiccup is a
  brief glitch rather than silence plus a pop; the TX FIFO empty **trigger
  level** goes from 15 to 64 of 128 samples (full 7-bit field) so refills
  start with half a FIFO of margin when the ADC channel is being serviced
  at the same time; and because both directions share **PLL_AUDIO**, a
  stream opened while the other direction runs is constrained to the same
  clock family (24.576 MHz: 8/12/16/24/32/48/96/192 k; 22.5792 MHz:
  11.025/22.05/44.1 k) and a clashing rate is refused in `hw_params`
  instead of retuning the PLL under the running stream. Keep playback and
  capture in one family: 48 k play + 24 k capture is fine, 48 k play +
  44.1 k capture is not.
* `0029-sun4i-dma-…`: NDMA arbitrates by channel index (0 wins). Device-to-
  memory transfers now take the highest free channel, so the DAC (memory-
  to-device) keeps the better channel in full duplex no matter which side
  was started first.

## Testing

```sh
tinymix -D 0 set 'Headphone Playback Volume' 40
```

**Neither `tinyplay` nor `tinycap` 2.0.0 (the versions Buildroot ships) is
usable for testing.** `tinycap` reads a whole buffer per call, overruns, and
then returns instantly: a "120 s" capture finishes in 3 s and the file is
garbage with a DC-settling transient that looks like speech in level stats.
Use a real tinyalsa or alsa-lib client (`/root/xcap` and `/root/xquiet` on the
bench card, or any program that reads/writes the device itself).

**`tinyplay` 2.0.0 does not play a WAV file**:
it parses the RIFF header only when told `-i wav`, otherwise it treats the
file as raw with an uninitialised data length, so it opens the device,
powers the amplifier (the ~1 s "hiss"), writes nothing and exits with
status 0. With the header parsed its argument handling is still broken on
this build. Use `aplay` if alsa-utils is in the image, or any alsa-lib /
tinyalsa client that writes the data itself; FastCarPlay goes through SDL2's
ALSA backend (`PcmAudio` → `SDL_OpenAudioDevice` → device `default`), which
is unaffected.

Low-level facts, useful when poking with `devmem`: the DAC TX FIFO is 128 ×
32-bit words (two 16-bit samples per word, `DAC_FIFOC` FIFO_MODE 1), the
driver stops issuing DRQ with 16 words free (`DRQ_CLR_CNT` 3, TX trigger
level 15), and `sun4i-dma` programs the whole 2-period ring as one 8 KiB
NDMA promise with half+end interrupts. Registers: `DAC_DPC 0x00` (bit 31
EN_DA), `DAC_FIFOC 0x04`, `DAC_FIFOS 0x08`, `DAC_TXDATA 0x0c`,
`ADC_FIFOC 0x10`, `ADC_FIFOS 0x14`, `ADC_RXDATA 0x18`, `DAC_MIXER_CTRL 0x20`;
CCU `PLL_AUDIO 0x01c20008` (bit 31 enable, bit 28 lock; N/M at 15:8 / 4:0),
`AUDIO_CODEC_CLK 0x01c20140` (bit 31), bus gate `0x01c20068` bit 0, reset
`0x01c202d0` bit 0.
