---
name: board-serial
description: Run commands on the F1C200s board over its serial console and read the results. Use whenever you need to inspect or drive the running board — dmesg, config checks, starting or stopping fastcarplay, network/i2c/usb state. Encodes the DTR/RTS reset hazard and the BusyBox/tty gotchas that otherwise cost a debugging session.
---

# Driving the F1C200s over serial

`/dev/ttyUSB0` is the board console (CH341, 115200 8N1). `/dev/ttyUSB1`, when
present, is the ESP32 DevKitC (CP2102) — **not** the board.

## The one rule that matters

**Never let DTR or RTS be asserted.** On this wiring either line resets the
board. pyserial defaults them to `True`, so they must be set `False` *before*
`open()`. `scripts/sercmd.py` in this skill directory does that; use it rather
than `screen`, `minicom` or a hand-rolled `serial.Serial("/dev/ttyUSB0")`.

## Usage

```sh
python3 .claude/skills/board-serial/scripts/sercmd.py "uname -r" "uptime"
```

Each argument is one shell command; output is printed per command. Environment
knobs: `SERPORT` (default `/dev/ttyUSB0`), `SERTIMEOUT` (max seconds per
command, default 25), `SERQUIET` (seconds of silence that ends a read, default
1.5).

Raise both when the console is chatty or the command is slow:
`SERQUIET=4 SERTIMEOUT=60 python3 … "long-running-thing"`.

## Before blaming the board

1. **Is something else holding the port?** `sudo fuser -v /dev/ttyUSB0`. A
   PuTTY/screen session will silently steal bytes and produce
   `device reports readiness to read but returned no data`. Ask the owner to
   close it — do not fight over the port.
2. **Is the shell alive?** Send a marker: `echo ZZ-MARK-$(date +%s)-ZZ` and
   grep for it. No echo at all means the shell is not reading your input.
3. **Has a foreground app taken the tty?** If output streams but input does
   nothing, an app owns the console — send `\x03` (Ctrl-C) to kill it and the
   prompt returns. This happens with `fastcarplay` when it is not fully
   detached.

## Gotchas that have already cost time

- **No flow control.** Long single lines (a base64 blob of a file) overrun the
  board's UART, get truncated mid-quote and leave the shell at a `>`
  continuation prompt. Write files in **short lines** (`printf '%s\n' '...' >>
  file`, one line per command), or reconstruct on the board. To recover from
  `>`, send a lone `'` to close the quote, then clean up.
- **Launch long-running apps fully detached**, or they grab the tty and your
  session goes deaf:
  `setsid sh -c 'exec fastcarplay /tmp/x.txt >/tmp/x.log 2>&1' </dev/null >/dev/null 2>&1 &`
- **BusyBox is not GNU.** `ip` has no `-br` (use `ip addr show usb0`), `grep`
  has no `--line-buffered`, `dmesg` has no `-w`. To watch for an event, write a
  small polling loop to a file with `setsid` and read the file later.
- **debugfs is not mounted** by default: `mount -t debugfs none /sys/kernel/debug`.
- Commands that produce a lot of output can outrun the read window; prefer
  `grep`/`tail` on the board over dumping whole files.

## Recipes

```sh
# kernel + uptime + is the app running
… sercmd.py "uname -r; cut -d. -f1 /proc/uptime; pidof fastcarplay || echo none"

# what the app is doing (app logs to /tmp/carplay.log via S99carplay)
… sercmd.py "tail -15 /tmp/carplay.log"

# usb0 / NCM link state (wired CarPlay)
… sercmd.py "ip addr show usb0; cat /sys/class/net/usb0/carrier"

# MFi coprocessor — NOTE: use read-mode probing, the chip NAKs the default
# write probe and i2cdetect will wrongly show nothing at 0x10
… sercmd.py "i2cdetect -y -r 0 | grep '^10:'; i2cget -y 0 0x10 0x00"

# verify a kernel symbol on the running board
… sercmd.py "zcat /proc/config.gz | grep -E '^CONFIG_IPV6='"
```

## Board facts worth remembering

- The console shell is respawned by BusyBox init (`ttyS0::respawn:-/bin/sh` in
  `/etc/inittab`, added by `board/lctech/pi-f1c200s/post-build.sh`), auto-login
  as root, no password.
- `/tmp` is a tmpfs — anything written there is lost on reboot, including
  hand-installed helpers. Durable changes belong in `rootfs-overlay/`.
- Only `/dev/i2c-0` exists (single `mv64xxx_i2c` adapter). GT911 touch sits at
  `0x5d` (shows `UU`, driver-bound); the MFi chip is at `0x10`.
