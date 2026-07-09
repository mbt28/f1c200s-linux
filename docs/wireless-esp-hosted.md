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
- **UART1 (PA2/PA3) is the serial console** — correction found in the DTS
  (`serial0 = &uart1`, and the working console proves the CH340 is wired to
  PA on production boards, not to PE0/PE1 as the CherryPi schematic's default
  resistor population suggests). So there is **no free UART for BT HCI**:
  UART2's pins are consumed by SPI1, UART1 is the console. BT runs over the
  same SPI link (fully supported by NG). PE0/PE1 (UART0, on header P1, unused
  by the DTS) are a *potential* future HCI UART, pending an electrical check
  of what the CH340 alternate-routing resistors actually do to those pins.
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

**P0 — decision spikes: ALL RETIRED**
(c) resolved by the schematic: PC pins aren't on headers at all — the pin
map moved to SPI1/PE. **(d) retired 2026-07-09**: FastCarPlay's own
aa-wireless backend ran on the Pi 5 dev box with a **2.4 GHz-only AP**
(ch 6) and a Samsung SM-G991B connected end-to-end — BT bootstrap → AP
join → TCP :5277 → service discovery → live video stream (~20 % CPU at
800×480/30 sw-decode, link 72/24 Mbit/s). The ESP32's 2.4 GHz limitation
is confirmed workable with the target phone.

**P1 — wiring + DT**

Pin-to-pin (ESP32 side fixed by the NG firmware, `docs/setup.md` §2.1):

All F1C200s pins below sit on the P1 header (schematic-verified). The
ESP32-side pins are from the **firmware's own boot log** (`FW_SPI: ... HS: 3
DR: 4`) — the setup.md table upstream says IO2 for handshake and is WRONG for
the ng-1.0.6 esp32 build; it cost a debugging round (2026-07-08: data-ready
IRQ count 1, handshake stuck at 0 until the wire moved to IO3). When in
doubt, trust the `FW_SPI:` line on the ESP console.

| F1C200s (header P1) | dir | ESP32-DevKitC | function |
|---|:---:|---|---|
| PE9 (SPI1_CLK) | → | IO14 | SCLK |
| PE7 (SPI1_CS) | → | IO15 | CS0 (optional ext. 10 kΩ pull-up) |
| PE10 (SPI1_MISO) | ← | IO12 | MISO — **no pull-up: IO12 is the flash-voltage strap** |
| PE8 (SPI1_MOSI) | → | IO13 | MOSI |
| PE2 (gpio 130) | ← | **IO3** | handshake (yes, the ESP console RX pin — console output still works, input doesn't; **USB must stay unplugged in operation**: the CP2102 fights this line) |
| PE3 (gpio 131) | ← | IO4 | data ready (IRQ on host) |
| PE4 (gpio 132) | → | EN | ESP reset (`resetpin=132`) |
| PE0 (UART0_RX, ttyS1) | ← | IO5 | BT HCI: ESP TX (custom spi+uart firmware, 230400) |
| PE1 (UART0_TX, ttyS1) | → | IO18 | BT HCI: ESP RX |
| ~~GND → IO23~~ | | | CTS strap RETIRED 2026-07-09: the custom 230400/no-flow firmware makes the UART a true 2-line link — remove the strap wire |
| 5 V rail + GND | → | VIN/5V + GND | power (DevKitC regulator) |

Short jumpers (SPI @ ~10 MHz to start, raise later). BT runs over the same
SPI (NG "SPI only" mode) — zero extra wires, and with UART1 hosting the
console there is no free UART anyway (see constraints). DT patch: enable
`&spi1` with a new `spi1_pe_pins` pinctrl group (mainline suniv dtsi has
none) — and the driver glue patch must register the `spi_board_info` on
**bus 1**. Exit: ESP boot log on its USB console + handshake/data-ready
toggling.

*Status: implemented as `patches/linux-lctech/0012` (pinctrl group + `&spi1`
+ the load-bearing `spi1` DT alias that pins bus number 1).*

**P2 — ESP firmware**
Pin the esp-hosted release in `config.env` (like the cedar pin) and flash the
prebuilt NG firmware over the DevKitC's own USB — full procedure in the
[appendix](#appendix-flashing-the-devkitc-with-esp-hosted-ng). Exit: firmware
banner on the DevKitC serial monitor, handshake GPIO toggles.

**P3 — WiFi/NG on the host** — *IMPLEMENTED 2026-07-07 (this commit)*
- Kernel fragment: `CONFIG_SPI(_SUN6I)=y`, `CONFIG_CFG80211=m`, `CONFIG_BT=m`
  (esp32_spi links esp_bt.o unconditionally — BT core is a modprobe dep).
- Buildroot: `package/esp-hosted-ng/` (kernel-module infra, pinned to the
  release/ng-1.0.6 commit, `target=spi CONFIG_AP_SUPPORT=y`, per-package
  patch moves handshake/data-ready to PE2/PE3 and the bus to 1);
  wpa_supplicant (nl80211) + iw + wireless-regdb; bluez5-utils incl. the
  deprecated tools (hciconfig/hcitool work without bluetoothd).
- Runtime switch, same shape as `net`: **`wifi on|off|status`** +
  `/etc/init.d/S43wifi`, flag `/etc/wifi-enabled`, STA config in
  `/etc/wpa_supplicant.conf` (placeholder shipped). `wifi off` unloads the
  modules — zero resident cost when off.

**On-board test procedure (P3 exit checklist):**

```sh
wifi on                      # modprobe esp32_spi + wpa_supplicant + udhcpc
dmesg | tail -20             # expect transport init + fw version, wlan0 + hci0
wifi status                  # transport / association / IP in one look
iw dev wlan0 scan | grep SSID     # WiFi RF proof (works with placeholder conf)
vi /etc/wpa_supplicant.conf  # real SSID/PSK, then: wifi off; wifi on
ping -c3 8.8.8.8             # full STA path
# Bluetooth (same module, manual for now):
hciconfig hci0 up && hciconfig
hcitool scan                 # BR/EDR inquiry — make a phone discoverable
hcitool lescan               # BLE proof (ctrl-C to stop)
```

Failure triage: no dmesg activity on modprobe → wiring/handshake pins;
`Failed to obtain SPI master handle` → DT alias/bus-number problem (patch
0012 missing from the kernel); handshake OK but timeouts/garbage → ESP
firmware not from release/ng-1.0.6 or SPI clock too high (`clockspeed=`);
wlan0 up but hci0 missing → CONFIG_BT didn't land (check
`/lib/modules/*/kernel/net/bluetooth`).
Remaining exit gate (hardware): **iperf3 ≥ 15 Mbit/s**, then raise
`clockspeed=` from the conservative 10 toward 30 MHz.

**P4 — Bluetooth on its own UART** — *IMPLEMENTED + HARDWARE-VALIDATED
2026-07-08: `bt on` → hci0 UP RUNNING, BD address over the UART, and
`hcitool lescan` returns a full BLE neighborhood with names — the 921600
link at −3.1% divisor error works in practice on short jumpers. (Empty
`hcitool scan` just means no discoverable BR/EDR device nearby: phones
only answer inquiry while their Bluetooth-settings page is open.)*
BT-over-SPI was field-tested and is **flaky on this setup**: HCI commands
time out at random depths (0x1005/0x0c23/0x0c03, `-110`) while WLAN runs
error-free on the very same link — one session even delivered 40 HCI events
before stalling. Upstream has no post-1.0.6 fix. Decision: BT moves to a
dedicated UART (the release's `esp32/spi+uart` firmware):

- ESP32 side: HCI H4 on its UART1 @ **921600 fixed**, flow control ON in
  the prebuilt sdkconfig → its CTS (IO23) is strapped to GND, RTS ignored.
- Host side: UART0 on PE0/PE1 = `ttyS1` (patch 0013 — usable because
  production boards route the CH340 console to PA2/PA3, not PE0/PE1);
  `CONFIG_BT_HCIUART(+H4)=m`; **`bt on|off|status`** runs
  `hciattach /dev/ttyS1 any 230400 noflow` + brings hci0 up.
- **HARDWARE-VALIDATED 2026-07-09 (custom firmware)**: clean HCI init at
  230400 (zero timeouts vs. always-within-3s at 921600), 50+ BLE
  advertisements decoded in one lescan, and **bluetoothd adoption works**
  (`/org/bluez/hci0`, `bluetoothctl list` shows the controller) — the
  mgmt-hidden-adapter trap only ever triggered on failed init, which no
  longer happens.
- **Baud + flow control resolved by a custom firmware build (2026-07-09)**:
  the prebuilt spi+uart binary runs 921600 with flow control ON — on the
  suniv that's a −3.1% integer divisor (APB 100 MHz, verified via
  clk_summary) AND an RTS the host cannot honor (its deassertions drop
  host→ESP bytes → the intermittent `Opcode 0x1003 -110` timeouts). The
  custom build (appendix) sets 230400 (+0.47%) with flow control OFF.

What remains for P6: bluetoothd-based pairing for the wireless-AA RFCOMM
handshake (enable `BR2_PACKAGE_BLUEZ5_UTILS_CLIENT` for bluetoothctl, start
the daemons `bt on` deliberately leaves off).

**P5 — SoftAP (the wireless-AA prerequisite)** — *IMPLEMENTED 2026-07-08,
hardware validation pending*
hostapd (nl80211) on the NG driver's AP mode (compiled in via
CONFIG_AP_SUPPORT) + dnsmasq for leases. Runtime switch **`ap on|off|status`**
+ S44ap, flag `/etc/ap-enabled`, configs `/etc/hostapd.conf` (SSID
`f1c200s-ap`, WPA2, ch6, placeholder passphrase — edit first) and
`/etc/dnsmasq-ap.conf` (192.168.9.1/24, leases .10–.50). **STA and AP are
mutually exclusive on the single wlan0**: `ap on` disables `wifi` mode and
vice versa (each clears the other's flag and daemons); `wifi off`/`ap off`
only unload the modules when the other mode is off too. The FG fallback
plan is retired unless this fails on hardware.

Test procedure (P5 exit): edit the passphrase → `ap on` → SSID visible on a
phone → join → phone gets a 192.168.9.x lease (`ap status` shows the
station + lease) → `ping 192.168.9.1` from the phone works. Triage:
hostapd fails to start → `hostapd -dd /etc/hostapd.conf` in the foreground
shows the cfg80211 conversation; ESP-side AP limits are NG-firmware
territory (beacons/assoc handled on the ESP).

**P6 — wireless AA in FastCarPlay (+ SPI DMA for the AV headroom)**
App side (FastCarPlay `protocol = aa-wireless`, largely implemented there):
BT RFCOMM advertise via BlueZ D-Bus → SSID/PSK/IP over the AA
wifi-projection messages (`WirelessTcpConfiguration`) → TCP :5277 session →
same protocol as wired. The app orchestrates its own hostapd/dnsmasq
(`/tmp/fcp-*.conf`, 192.168.53.1/24) and bluetoothd; `bt on` provides the
adoption-safe adapter underneath. Exit: phone in pocket, AA on screen.

Repo side — **SPI DMA** (hardware-verified possible, User Manual V1.2):
wireless AA streams the whole AV feed over the ESP SPI link, which today is
PIO (90k+ IRQs observed; ~25 per 1600-byte transfer, no `dmas` in DT, no
suniv support in any mainline DMA driver). The manual says the silicon is
ready: §3.6 system DMA (4 NDMA + 4 DDMA channels @ 0x01C02000) with **NDMA
DRQ type 0x05 = SPI1 Tx/Rx**, and §7.3.7.5 SPI FIFO Control has per-
direction DRQ enables + trigger levels (+ NDMA/DDMA mode select, default
NDMA). The engine is the A10-class NDMA/DDMA design → port `sun4i-dma.c`
(suniv compatible, 4+4 channels, suniv endpoint map) + dtsi node + `dmas`
on `&spi1`; spi-sun6i is already a dmaengine consumer and needs no changes.
Exit: `sun6i-spi` IRQ rate collapses (~1/transfer), iperf CPU drops.

*Status 2026-07-09: PARKED after three hardware iterations (patch 0016
reverts the `dmas` wiring; the engine + fixes stay in-tree). Backport done
(0014, upstream state = current master), burst clamped to INCR4 and TX beat
dropped to byte width (0015) -- reads work with DMA (boot-up event +
version arrive), but host→ESP command frames are never answered; irq
counters show transfers completing mechanically. Next step is bench
instrumentation (scope on MOSI during a command, printk of the TX
descriptor path), not more blind CI cycles. The ESP link runs PIO, which
is fully proven.*

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
   - `release:ng-1.0.6/esp32/spi+uart/` — WiFi over SPI, BT on UART —
     **the production build** (BT-over-SPI proved flaky, see P4)
   - `release:ng-1.0.6/esp32/spi_only/` — everything over SPI (first
     bring-up used this; keep for transport debugging only)

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

### Custom spi+uart build (230400, no flow control) — the production BT firmware

The shipped spi+uart binary fixes HCI at 921600 with flow control on; both
hurt on this host (see P4). Reproduce the custom build:

```sh
cd esp_hosted_ng/esp/esp_driver && ./setup.sh   # pinned IDF fcae3288 + rom.patch + patched wifi blobs
cp "release:ng-1.0.6/esp32/spi+uart/sdkconfig" network_adapter/sdkconfig
# two changes: CONFIG_BTDM_CTRL_HCI_UART_BAUDRATE=230400
#              CONFIG_BTDM_CTRL_HCI_UART_FLOW_CTRL_EN unset
cd network_adapter && idf.py build              # do NOT run set-target (wipes sdkconfig)
```

The version stays NG-1.0.6.0.1 (SPI handshake unaffected). Gotcha met in
practice: building against a stock IDF fails with undefined
`esp_wifi_*_internal`/`ieee80211_*` symbols — the setup.sh blob/patch step
is mandatory. Host side pairs with `hciattach ... 230400 noflow` (bt
script) and no CTS strap.
