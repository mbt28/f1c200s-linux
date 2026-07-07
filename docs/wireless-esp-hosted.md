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

- Chip: **original ESP32 (WROOM-32E)** — the only ESP with **BT Classic
  (BR/EDR)**, which the wireless-AA RFCOMM handshake needs. C3/C6/S3/C5 are
  BLE-only. Consequence: **2.4 GHz-only WiFi** (see Risks).
- **SDIO is out**: SDC1 muxes on PA0–PA3, but PA0 is the touch reset and
  PA2/PA3 are UART1. mmc0 is the boot SD card.
- **SPI0 on PC0–PC3** is the transport candidate — the Lctech SPI-flash pads
  (we boot from SD). *Verify the flash footprint is unpopulated / liftable.*
- **UART1 on PA2/PA3** for Bluetooth HCI (`hciattach`, 921600+ baud), keeping
  BT off the data link. UART2 (PE7/PE8) is the alternate if PA is contended.
- ESP-Hosted SPI needs 3 extra GPIOs (handshake, data-ready, reset): the DVP
  port PE2–PE5 / PE7–PE11 pins are free (PE6 backlight, PE12 touch IRQ in use).
- Power: ESP32 TX bursts ~400–500 mA @3V3 — check the board regulator budget;
  a dedicated 3V3 LDO off 5V is the safe default.

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
Still open: (c) SPI0 flash pads free on our board rev; (d) wireless AA on a
**2.4 GHz** AP with the phones we care about (test with any laptop-hosted
2.4-only AP + head-unit emulator before buying hardware).
Exit: pin map frozen, 2.4 GHz risk retired.

**P1 — wiring + DT**
Wire WROOM-32E: SPI0 (PC0–3) + handshake/data-ready/reset GPIOs (PE) + UART1
(PA2/3) + 3V3. DT patch: enable `&spi0` with the esp32 node (`spidev` first
for probing), `&uart1`. Exit: `spidev_test` loopback + ESP boot log on UART1.

**P2 — ESP firmware**
Pin an esp-hosted release in `config.env` (like the cedar pin); flash the
prebuilt NG (and FG) firmware from the Pi with esptool over the ESP's own
USB/UART. Document in this file. Exit: firmware banner, handshake GPIO toggles.

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
