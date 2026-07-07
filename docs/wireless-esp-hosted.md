# Roadmap: WiFi + Bluetooth via ESP32 (ESP-Hosted FG / NG)

Goal: give the appliance a radio. An ESP32 runs Espressif's **ESP-Hosted**
firmware and acts as a WiFi+BT co-processor for the F1C200s over SPI (+ UART
for Bluetooth HCI). End state, in order of value:

1. **Wireless Android Auto** — the native `aa-usb` backend already vendors
   `WirelessTcpConfiguration.pb`; wireless AA = BT (RFCOMM) handshake +
   phone joins our SoftAP + the same AA protocol over TCP :5277.
2. Dev networking without the USB NIC (`net on` over `wlan0`).
3. Later, maybe: BT audio out, phone-as-hotspot internet, OTA updates.

## FG vs NG in one table

| | **esp_hosted_fg** | **esp_hosted_ng** |
|---|---|---|
| Linux interface | plain netdev (`ethsta0`/`ethap0`), no wireless stack | real `wlan0` via **cfg80211** (fullmac) |
| WiFi control | Espressif control API (protobuf over the transport) — no wpa_supplicant | standard: wpa_supplicant / iw / nl80211 |
| SoftAP | yes (`ethap0` + control API) | verify current status (STA is the mature path) |
| Kernel needs | none beyond the module (tiniest footprint) | CFG80211 (~0.5 MiB, `=m`) |
| BT | HCI over dedicated UART (or vHCI over SPI) | same — BT is orthogonal to the FG/NG choice |
| Fit here | fallback / AP-mode insurance | **primary**: standard stack, standard tools |

Plan: **NG first** (standard Linux WiFi is worth the 0.5 MiB), keep **FG as
the AP-mode fallback** — wireless AA needs the head unit to be the SoftAP,
and if NG's AP support turns out immature, FG's `ethap0` covers exactly that
gap. With BT on its own UART, the BT stack is identical under both.

## Hardware constraints (audited against our DT, 2026-07-07)

- Chip: **original ESP32 — confirmed hardware: ESP32-WROOM-32 on an
  ESP32-DevKitC** — the only ESP family member with **BT Classic (BR/EDR)**,
  which the wireless-AA RFCOMM handshake needs (C3/C6/S3/C5 are BLE-only).
  Consequence: **2.4 GHz-only WiFi** (see Risks). DevKitC bonuses: onboard
  USB-UART (flash the NG firmware from any PC with esptool — no target-side
  tooling) and its own 5 V→3V3 regulator (feed **5 V + GND** from the board's
  5 V rail; the 3V3-budget risk is retired).
Verified against the CherryPi-F1C200S schematic (`~/projects/f1c200s/docs/`),
which is the Lctech Pi design. The board exposes two GPIO headers:
**P1 (12-pin) = PE0–PE11** and **P3 (18-pin) = PA0–PA3 + TWI0 + analog**.

- **PC0–PC3 (SPI0) are NOT on any header** — they run to the SPI-flash
  footprint only (10 k pull-ups + the boot-skip button on MISO). SPI0 is out.
- **SDIO is out too**: SDC1 muxes on PC0–PC2 (same flash pads) — dead end.
- **Transport: SPI1 on PE7 (CS) / PE8 (MOSI) / PE9 (CLK) / PE10 (MISO)** —
  all four on header P1 (they double as UART2/CSI; the camera footprint must
  stay unpopulated, which it is on standard Lctech units).
- Handshake / data-ready / reset host GPIOs: **PE2 / PE3 / PE4**, also on P1
  (PE5 spare). PE0/PE1 = console UART0, PE6 = backlight EN, PE12 = touch IRQ.
- **UART1 on PA2/PA3 (header P3)** remains the optional BT-HCI upgrade
  (2-line, no flow control — PA0 is the touch reset, PA1 free). Using SPI1
  costs us UART2 (same PE7/PE8 pins), which is why BT-over-SPI comes first.
- Power: DevKitC VIN takes the board's 5 V rail; its own regulator makes the
  3V3 budget a non-issue.

## P0 findings (analyzed 2026-07-07, NG driver @ master v1.0.5, release ng-1.0.6)

- **(a) SPI on classic ESP32: SUPPORTED** — the NG feature matrix lists
  ESP32 + SPI with WiFi *and* BT, including our exact combo
  `SPI (WiFi) + UART (BT)`.
- **(b) SoftAP: IMPLEMENTED** — `esp_cfg80211.c` provides
  `.start_ap/.stop_ap/.change_beacon` and advertises `NL80211_IFTYPE_AP`;
  the README documents the hostapd flow. Needs hardware validation, but FG
  is no longer *required* for AP mode.
- **Compiles clean against our 6.6.143**: built `esp32_spi.ko` (88 KiB,
  ARM ELF32) with our Buildroot toolchain — zero driver warnings. (Full
  modpost needs the real built kernel; the Buildroot package will have it.)
- **kernel-7.1 needs a compat patch**: 7.1 moved a batch of `cfg80211_ops`
  from `net_device *` to `wireless_dev *` (add/del/change_station, key ops)
  and changed `ieee80211_ptr` access; the driver's version guards stop at
  6.17. Bounded, cedar-style work — only if we ever need WiFi on that track.
- **SPI glue is Raspberry-Pi-hardcoded** (the real porting task): the driver
  registers a `spi_board_info` itself (no DT match), handshake/data-ready
  pins are compile-time defines in BCM numbering, reset pin is the
  `resetpin=` module param, all legacy-GPIO API. Port = small patch giving
  suniv GPIO numbers (global numbering: PE2 = 4·32+2 = 130, …) + SPI bus 0,
  and keep spidev off CS0. Carry it as `patches/esp-hosted/`.
- **Prebuilt firmware exists per release** (`release.ng-<ver>.tgz` asset) —
  no ESP-IDF build needed; pin the release tag in `config.env`, flash with
  esptool.
- **Kernel config required**: `CONFIG_CFG80211=m` + `CONFIG_BT=m` — esp_bt.o
  is compiled into the module unconditionally, so BT core is a load-time
  dependency even with BT routed over UART (then + `CONFIG_BT_HCIUART=m`).

## Phases

**P0 — remaining decision spikes (no code)**
(c) is resolved by the schematic: PC pins aren't on headers at all — the pin
map moved to SPI1/PE (frozen above; only sanity-check that the camera
footprint on your unit is unpopulated). Still open: (d) wireless AA on a
**2.4 GHz** AP with the phones we care about (test with any laptop-hosted
2.4-only AP + head-unit emulator before wiring anything).
Exit: 2.4 GHz risk retired.

**P1 — wiring + DT**

Pin-to-pin (ESP32 side fixed by the NG firmware, `docs/setup.md` §2.1):

All F1C200s pins below sit on the P1 header (schematic-verified):

| F1C200s (header P1) | dir | ESP32-DevKitC | function |
|---|:---:|---|---|
| PE9 (SPI1_CLK) | → | IO14 | SCLK |
| PE7 (SPI1_CS) | → | IO15 | CS0 (optional ext. 10 kΩ pull-up) |
| PE10 (SPI1_MISO) | ← | IO12 | MISO — **no pull-up: IO12 is the flash-voltage strap** |
| PE8 (SPI1_MOSI) | → | IO13 | MOSI |
| PE2 (gpio 130) | ← | IO2 | handshake |
| PE3 (gpio 131) | ← | IO4 | data ready (IRQ on host) |
| PE4 (gpio 132) | → | EN | ESP reset (`resetpin=132`) |
| 5 V rail + GND | → | VIN/5V + GND | power (DevKitC regulator) |

Short jumpers (SPI @ ~10 MHz to start, raise later). BT initially runs over
the same SPI (NG "SPI only" mode) — zero extra wires; UART1 (PA2/PA3, header
P3) BT is the optional P4 upgrade (ESP32 supports 2-line HCI UART, no
RTS/CTS needed — good, PA has none; exact ESP-side UART pins per setup.md
§2.3). DT patch: enable `&spi1` with a new `spi1_pe_pins` pinctrl group
(mainline suniv dtsi has none) — and the driver glue patch must register the
`spi_board_info` on **bus 1**. Exit: ESP boot log on its USB console +
handshake/data-ready toggling.

**P2 — ESP firmware**
Pin the esp-hosted release in `config.env` (like the cedar pin) and flash the
prebuilt NG firmware over the DevKitC's own USB — full procedure in the
[appendix](#appendix-flashing-the-devkitc-with-esp-hosted-ng). Exit: firmware
banner on the DevKitC serial monitor, handshake GPIO toggles.

**P3 — WiFi/NG on the host**
- Kernel fragment: `CONFIG_CFG80211=m` (+ rfkill); nothing else — fullmac.
- New Buildroot packages: `esp-hosted-ng` (out-of-tree kernel module, same
  pattern as the cedar/fastcarplay packages), `wpa_supplicant`, `iw`,
  `wireless-regdb`.
- Runtime switch, same shape as `net`/`ve-driver`: `wifi on|off|status`
  modprobes the module + starts wpa_supplicant from `/etc/wpa_supplicant.conf`;
  flag file `/etc/wifi-enabled`; disabled by default.
Exit: scan + STA associate + DHCP + **iperf3 ≥ 15 Mbit/s** (SPI @ ~30 MHz);
`net on` dev loop works over wlan0.

**P4 — Bluetooth**
Kernel: `CONFIG_BT=m`, `CONFIG_BT_HCIUART(+H4)=m`. Rootfs: bluez5-utils
(headless set). `bt on` runs `hciattach /dev/ttyS1 any 921600` + bluetoothd.
Exit: `hciconfig up`, inquiry scan, pair a phone, open an RFCOMM socket.

**P5 — SoftAP (the wireless-AA prerequisite)**
NG path: hostapd if NG's AP mode is real; FG path: `feature/esp-hosted-fg`
branch — FG module + control lib bringing up `ethap0`. Either way + udhcpd
for DHCP. Exit: phone joins the appliance's 2.4 GHz AP and gets a lease.

**P6 — wireless AA in FastCarPlay**
Extend `AaConnection`: BT RFCOMM advertise → send SSID/PSK/IP via the AA
wifi-projection messages (`WirelessTcpConfiguration`) → accept the TCP :5277
session → same protocol as wired from there. Exit: phone in pocket, AA on
screen.

**P7 — productize**
Re-measure RAM (docs/memory.md — expect ~3–5 MiB for module+supplicant+
bluetoothd, post-diet headroom covers it); CI builds the new packages; docs;
promote dev → main + tag.

## Risks

- **2.4 GHz-only wireless AA** (ESP32 has no 5 GHz; the only 5 GHz ESP —
  C5 — has no BT Classic). Many phones accept 2.4 GHz projection, some
  refuse or degrade. P0(d) de-risks this before any soldering.
- NG gaps on classic ESP32 (SPI transport / AP mode) — hence FG stays in
  scope as the fallback with zero kernel-stack cost.
- **WiFi/BT coexistence** on the shared ESP32 radio: streaming video while
  BT is active costs throughput; AA at 480×272 (~2–6 Mbit/s H.264) leaves
  margin, but measure in P6.
- ARM926 @ 408 MHz interrupt latency may cap SPI throughput below the
  theoretical link rate; the iperf gate in P3 catches it early.
- SPI-flash pads may be populated on some board revisions (P0(c)).

## Appendix: flashing the DevKitC with ESP-Hosted-NG

Verified against the actual `release/ng-1.0.6` artifact (2026-07-07). The
DevKitC flashes over its **own micro-USB** (CP2102 → `/dev/ttyUSB0` on the
PC) — the F1C200s board is not involved at all.

1. **Download + unpack the release** (any Linux PC):

   ```sh
   gh release download release/ng-1.0.6 --repo espressif/esp-hosted -p "*.tgz" -O ng.tgz
   # or: browser -> github.com/espressif/esp-hosted -> Releases -> release/ng-1.0.6
   tar xzf ng.tgz    # -> "release:ng-1.0.6/" (Apple-xattr tar warnings are harmless)
   ```

   Each chip/transport combo is one directory with 6 files (`bootloader.bin`,
   `partition-table.bin`, `ota_data_initial.bin`, `network_adapter.bin`,
   `flash_cmd`, `md5sum.txt`). Ours:
   - `release:ng-1.0.6/esp32/spi_only/` — WiFi + BT over SPI (start here)
   - `release:ng-1.0.6/esp32/spi+uart/` — WiFi over SPI, BT on UART (the P4 upgrade; a re-flash away)

2. **Install esptool**: `pipx install esptool`, then use the **`esptool.py`
   command** (pipx puts it on PATH; `python -m esptool` won't find it — pipx
   venvs aren't importable; `pipx ensurepath` + new shell if the command is
   missing). Avoid the Debian/Ubuntu `python3-esptool` package: it strips
   the precompiled stub-flasher blobs (DFSG), so it crashes with
   `FileNotFoundError: ... stub_flasher_32.json` right after connecting
   (seen 2026-07-07). If you must use it, add `--no-stub` to every esptool
   command — works, just flashes slower.

3. **Flash** — plug in the DevKitC, then run the release's own command
   (contents of `flash_cmd`) plus the port; `erase_flash` first clears any
   previous firmware on a used devkit:

   ```sh
   cd "release:ng-1.0.6/esp32/spi_only"
   md5sum -c md5sum.txt                       # integrity check
   esptool.py -p /dev/ttyUSB0 --chip esp32 erase_flash
   esptool.py -p /dev/ttyUSB0 --chip esp32 -b 460800 \
       --before default_reset --after hard_reset write_flash \
       --flash_mode dio --flash_size 4MB --flash_freq 40m \
       0x1000 bootloader.bin 0x8000 partition-table.bin \
       0xd000 ota_data_initial.bin 0x10000 network_adapter.bin
   ```

   (The shipped `flash_cmd` file uses the `python -m esptool` spelling — same
   arguments, only valid for a pip/site-packages install.)

   If esptool loops on "Connecting...", hold the **BOOT** button until it
   syncs (most DevKitC units auto-reset fine without it).

4. **Verify**: stay on the same USB port with a serial monitor at
   **115200** (`picocom -b 115200 /dev/ttyUSB0`), press the **EN** button —
   the NG `network_adapter` boot banner should appear. Done; from here the
   host side (P3) takes over.

Version rule: the ESP firmware and the host kernel module must come from the
**same release tag** — on a mismatch the transport handshake fails in
confusing ways. Both pins live in `config.env`. (Later re-flashes can also go
over the air via the driver's `ota_file=` module parameter — USB is simpler
while the DevKitC is on jumpers.)
