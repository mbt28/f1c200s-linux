# On-chip audio codec (F1C200s)

The F1C200s has a stereo 16-bit DAC/ADC with a headphone driver and a mic
pre-amp at `0x01c23c00`, driven by mainline `sun4i-codec` (suniv variant) and
fed by the `sun4i-dma` normal-DMA engine (DRQ 12 both directions). The Lctech
Pi routes HPL/HPR through a PAM8301 class-D amplifier to the speaker header
(always on, no PA-enable GPIO) and MICIN to the on-board microphone.

Hardware-validated 2026-10-03 on the kernel-6.18 image: a 44.1 kHz / 16-bit
stereo WAV plays through the speaker, the mic records real audio, and both
DMA directions stay perfectly real-time paced over minutes of back-to-back
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

## Memory footprint (matters on 64 MiB)

Audio is cheap in CPU (the DMA paces itself, about 50 interrupts/s) but not
free in memory, and this board runs at the edge: with the 24 MiB CMA fully
taken by 800x480 wireless CarPlay video, the rest of the system has about
28 MiB. Measured 2026-10-03 with CarPlay audio active: MemAvailable 2–3 MiB,
page cache squeezed to 3 MiB, 58 000 major page faults — the kernel evicted
executable pages and re-read them from the SD card on every call, which is
what "the UI freezes whenever audio plays" looks like. Audio makes it worse
because it pulls in several MiB of extra code (libasound, SDL audio, the
ffmpeg audio decoders) exactly when CMA is full.

Two levers ship in this tree:

* `snd_soc_core.prealloc_buffer_size_kbytes=64` on the kernel command line
  (`board/lctech/pi-f1c200s/uboot-sdcard.fragment`, SD and NAND branches):
  the ASoC dmaengine PCM otherwise preallocates 512 KiB per direction from
  CMA at boot, i.e. ~1 MiB of decoder memory held hostage by idle audio.
* zram swap (`S02swap`, zram tier only). It was measured and declined in
  August at 24 MiB available / 8.5 MiB anonymous; with audio + the 800x480
  display the numbers are 2–3 MiB / 14 MiB, and enabling it live moved
  2 MiB of idle FastCarPlay memory into 0.85 MiB of compressed RAM within
  ten seconds. See `docs/memory.md` §4 for the re-measurement.

## Testing

```sh
tinycap /tmp/c.wav -D 0 -d 0 -c 2 -r 48000 -b 16 -t 3   # 3 s from the mic
tinymix -D 0 set 'Headphone Playback Volume' 40
```

**`tinyplay` 2.0.0 (the version Buildroot ships) does not play a WAV file**:
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
