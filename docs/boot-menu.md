# Boot menu and boot settings

U-Boot on the SD card shows a menu for 3 seconds before it boots:

| Entry | What it does |
|---|---|
| Boot | Boots with the saved settings (the default after 3 s) |
| Settings | Opens the settings form on the LCD |
| U-Boot console | The U-Boot prompt |

On a card shared with LEHU OS (its root on p6, see `lehu-os`
`docs/dual-boot.md`), **Boot** becomes two entries, **Buildroot** and
**LEHU OS**, and the countdown boots the "Default system" setting. The
menu shows LEHU OS only when `/boot/zImage` exists on p6.

Use the serial console (115200 baud, the board's USB-C serial) to move:
arrow keys and Enter. The menu shows on the serial console and the LCD. The
settings form shows **only on the LCD**: U-Boot's form editor (cedit) has no
serial text mode yet.

## Settings

| Setting | Choices | Kernel argument |
|---|---|---|
| CPU speed (MHz) | 408 (default), 528, 600, 648, 720, 792 | `f1c.cpu_mhz=N` |
| Safe mode | Off, On | `f1c.safe=1` |
| Kernel messages | Normal, Quiet, Verbose | none, `quiet`, `loglevel=8` |
| Boot from | Auto (SD, then NAND), SD card, NAND | chooses the boot path |
| Default system | Buildroot (default), LEHU OS | which system the countdown boots (dual-boot cards) |

- **CPU speed** is set by Linux (`/etc/init.d/S04bootopts`, cpufreq-dt)
  once the filesystems are mounted. U-Boot and the early boot always run at
  the stock 408 MHz. A frequency outside the kernel's table is refused and
  logged.
- **Safe mode** boots at 408 MHz and keeps the head-unit app (S99carplay)
  from starting. The radios and SSH still come up.
- The result of each boot is logged in `/var/log/bootopts.log`.
- Settings apply to a kernel booted from the SD card. The NAND path keeps
  its own fixed arguments. LEHU OS gets the same arguments; "Boot from"
  is Buildroot's alone.
- **LEHU OS sets the CPU speed in the kernel**, with no init script. With a
  CPU speed chosen and safe mode off, U-Boot removes the operating points
  above that speed from the loaded device tree (`fdt rm
  /opp-table-cpu/opp-N`) and adds `cpufreq.default_governor=performance`.
  cpufreq-dt then runs the CPU at the highest operating point left as soon
  as it probes, before user space starts. Measured at 792 MHz: one 10 ms
  tick at 408 MHz in `cpufreq/stats/time_in_state`, the rest at 792. U-Boot
  and the kernel's first second still run at 408 MHz, which the SPL sets.
  With no CPU speed set, or in safe mode, LEHU OS stays at 408 MHz.

## Where the settings live

The form writes `f1c-settings.txt` on the SD card's boot partition (FAT, the
first partition). Nothing else is saved: U-Boot's environment is never
written, so U-Boot updates keep their own defaults.

To change a setting without the menu, edit `f1c-settings.txt` on any
computer. Change the `-str` line, for example `c.cpu-str=600`; the other
lines only tell the form which item to highlight. **Delete the file to go
back to the defaults**, which is also the fix when a CPU speed proves
unstable.

## Files

- `board/lctech/pi-f1c200s/uboot-menu/f1c-boot.cmd`: the boot script (menu
  entries, kernel arguments, saving). Built into `f1c-boot.scr`.
- `board/lctech/pi-f1c200s/uboot-menu/f1c-settings.dts` and
  `f1c-settings-ids.h`: the form, built by U-Boot's `tools/expo.py` into
  `f1c-settings.dtb`. The boot script matches the item labels, so change
  them in both places. Add new IDs at the end only: saved files refer to
  items by ID.
- `board/lctech/pi-f1c200s/uboot-sdcard.fragment`: enables the menu, the
  form and its device-tree support; PREBOOT loads the script. Without the
  script on the card the menu offers only Boot and the console, and the
  board boots as it always did.
- `board/lctech/pi-f1c200s/post-build.sh` builds both files and
  `genimage-sdcard.cfg` puts them on the boot partition.

## Buttons

U-Boot can drive the menu from GPIO buttons (`BUTTON_KEYBOARD`) once a board
has them and its U-Boot device tree describes them as `gpio-keys` with a
`button-kbd` node. The Lctech Pi has none, so it is not enabled yet.
