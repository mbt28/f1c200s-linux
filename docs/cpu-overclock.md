# CPU frequency and overclocking (cpufreq-dt)

The F1C200s runs its ARM926 at **408 MHz**, set by U-Boot at boot. The kernel
can switch it at runtime: `cpufreq-dt` drives `pll-cpu` from the OPP table in
the board device tree (patch `0035`), with the steps **408 / 528 / 600 / 648 /
720 / 792 MHz**. Everything above 408 MHz is an overclock.

Nothing changes on its own: the default governor is `userspace`, so the CPU
stays at 408 MHz until a frequency is written (see `linux.fragment` for why
the default must not be `performance`).

## Using it

```sh
C=/sys/devices/system/cpu/cpu0/cpufreq
cat $C/scaling_available_frequencies     # 408000 528000 600000 648000 720000 792000
echo 600000 > $C/scaling_setspeed        # kHz; takes effect immediately
cat $C/cpuinfo_cur_freq
cat $C/stats/time_in_state               # time spent at each step (10 ms units)
echo 408000 > $C/scaling_setspeed        # back to stock
```

A setting lasts until the next reboot; every boot starts at 408 MHz.

## Finding this chip's limit

Step up one OPP at a time and hold each step for at least 30 minutes under
real load (wireless CarPlay video and music, plus the UI), watching for
crashes, segfaults or kernel errors (`dmesg`). At the first failure, go back
one step and stay there. A crash at an overclock is not permanent: a power
cycle restarts at 408 MHz.

What to expect:

- Reports for the same chip (Hantek DSO2x1x scopes, EEVblog): 600 MHz is a
  safe start, most chips manage ~648 MHz, some 720 MHz at stock voltage; one
  reached 792 MHz with +60 mV on the core.
- There is **no voltage scaling**: the board's core rail is fixed at 1.2 V
  (EA3036 buck, schematic "CORE 1.2V"), already the top of Allwinner's
  recommended 1.0-1.2 V (absolute maximum 1.3 V).
- Gains are smaller than the clock ratio for memory-bound work: the DRAM
  stays at 156 MHz. A shell loop measured 1.19x at 528 MHz and 1.28x at
  600 MHz (ideal 1.29x / 1.47x) with FastCarPlay running.

## How it works, and what not to do

- The AHB/APB buses (200/100 MHz) come from `pll-periph`, not the CPU PLL, so
  SPI, MMC, the LCD and the TV decoder are unaffected by the CPU clock.
- The suniv CCU parks the CPU on osc24M while `pll-cpu` relocks; cpufreq
  rescales `loops_per_jiffy` on every switch (BogoMIPS follows the clock).
- **Do not change `pll-cpu` with `devmem`.** This SoC has no timer-based
  delay, so `udelay()` is a loop calibrated at boot: a clock change behind
  the kernel's back silently shortens every driver delay.
- The DRAM clock (`CONFIG_DRAM_CLK=156` in U-Boot) is left alone: reports put
  the DRAM as the pickier part, and a marginal DRAM corrupts data silently.
- The NAND boot uses the same kernel and DT, so cpufreq works there too.
