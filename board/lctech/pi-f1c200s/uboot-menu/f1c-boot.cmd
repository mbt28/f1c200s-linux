# Boot menu and boot settings for the Lctech Pi F1C200s (U-Boot script).
#
# post-build.sh compiles this into f1c-boot.scr on the boot partition. The
# PREBOOT in uboot-sdcard.fragment defines sd_boot / nand_boot, a plain
# "Boot" menu entry, and then sources this file, so a card without it still
# boots exactly as before. U-Boot's environment is never saved (no saveenv):
# a saved environment would pin today's bootargs and boot command over every
# later U-Boot update. The only thing written is f1c-settings.txt.
#
# f1c-settings.txt holds the form's choices as name=value lines. To change a
# setting on a PC, edit the matching "-str" line, e.g. c.cpu-str=600; the
# other lines only tell the form which item to highlight. Delete the file to
# go back to the defaults.
#
# Hush quirks: a value spans one line, ${...} takes any name (c.cpu-str is
# fine), and the item labels below must match f1c-settings.dts.
#
# Two systems can share the card (lehu-os/docs/dual-boot.md): this
# Buildroot image (root on p2) and LEHU OS (root on p6, a logical partition).
# The menu offers LEHU OS only when p6 has it, and boots the "Default system"
# setting by itself. Each is an OSTree system with its kernel and device tree
# on its own partition (/boot/loader/uEnv.txt, docs/ostree.md), or a plain root
# file system: Buildroot with its kernel on the boot partition, LEHU OS with
# /boot/zImage.

if load mmc 0:1 0x80C00000 f1c-settings.txt; then env import -t 0x80C00000 ${filesize}; fi

# The kernel arguments from U-Boot's own default, before anything is added.
setenv f1c_base_args "${bootargs}"

# Kernel arguments for each setting, collected in f1c_extra.
setenv f1c_args_cpu 'if test -n "${c.cpu-str}"; then setenv f1c_extra "${f1c_extra} f1c.cpu_mhz=${c.cpu-str}"; fi'
# zram swap (a compressed swap tier in RAM, kept out of CMA by kernel patch
# 0037): f1c.zram=1, which Buildroot's S03swap honours. Safe mode leaves it
# off, as it leaves the CPU speed.
setenv f1c_args_zram 'if test "${c.zram-str}" = "On"; then setenv f1c_extra "${f1c_extra} f1c.zram=1"; fi'
setenv f1c_args_safe 'if test "${c.safe-str}" = "On"; then setenv f1c_extra "${f1c_extra} f1c.safe=1"; else run f1c_args_cpu; run f1c_args_zram; fi'
setenv f1c_args_log 'if test "${c.loglevel-str}" = "Quiet"; then setenv f1c_extra "${f1c_extra} quiet"; elif test "${c.loglevel-str}" = "Verbose"; then setenv f1c_extra "${f1c_extra} loglevel=8"; fi'

# Reset the Bluetooth ESP32 (EN on PE4). It keeps its 5 V across a reboot of
# the board, so a controller that hung stays hung, and hciattach then times
# out on HCI Reset (0x1003) forever. 100 ms low, then released: the module's
# own pull-up raises EN, and the controller has booted long before hciattach.
# The Wi-Fi C3 needs none of this; esp32_spi resets it (PE5).
setenv f1c_bt_reset 'gpio clear PE4; sleep 0.1; gpio input PE4'

# Memory (DRAM) speed. The SPL sets it, long before U-Boot reads this file,
# from the last word of its own eGON header (patches/uboot/0008), which the
# boot ROM has copied to SRAM: 445200b4 for 180 MHz, 0 (as built) for the
# default 156. f1c_dram_sync keeps that word in step with the "Memory speed"
# setting (safe mode asks for 156). When they differ it rewrites the header
# sector, card sector 16 where the SPL starts, with the word and the header
# checksum adjusted by the same amount, reads it back, and restarts the board
# if the memory runs at another clock than the setting, so the SPL takes it.
# Before writing it checks that the sector is this SPL's header (eGON.BT0,
# length 0x6000, 0x50-0x5b free); a read-back mismatch writes the old sector
# back. A torn write leaves a header the boot ROM refuses: it then boots the
# SPI NAND, not this card, and the card needs the U-Boot written again.
#
# It runs on every boot, which also applies an f1c-settings.txt edited on a PC,
# and after the form is saved; a U-Boot written to the card later has the word
# at 0 again and gets it back on the next boot. A clock the SPL could not use
# (it then falls back to 156) prints a warning and never restarts. The clock
# running now is PLL_DDR's N: 12 MHz x (N + 1), with K = M = 1 as the SPL sets
# it. setexpr works in hex: 9c = 156, b4 = 180.
#
# f1c_dram_dry=1 (a line in f1c-settings.txt) writes the new header to card
# sector 15, between the MBR and the SPL, instead, and never restarts: to check
# the arithmetic from Linux before the real sector is touched.
setenv f1c_dram_want 'setenv f1c_dw 0; setenv f1c_dc 9c; setenv f1c_dwd 156; if test "${c.dram-str}" = 180 && test "${c.safe-str}" != On; then setenv f1c_dw 445200b4; setenv f1c_dc b4; setenv f1c_dwd 180; fi'
setenv f1c_dram_now 'setexpr.l f1c_pll *0x01c20020; setexpr f1c_dr ${f1c_pll} / 100; setexpr f1c_dr ${f1c_dr} % 20; setexpr f1c_dr ${f1c_dr} + 1; setexpr f1c_dr ${f1c_dr} * c'
setenv f1c_dram_hdr 'setenv f1c_hok; if mmc read 0x80C00000 10 1; then setexpr.l f1c_h1 *0x80C00004; setexpr.l f1c_h2 *0x80C00008; setexpr.l f1c_hl *0x80C00010; setexpr.l f1c_p0 *0x80C00050; setexpr.l f1c_p1 *0x80C00054; setexpr.l f1c_p2 *0x80C00058; setexpr.l f1c_ow *0x80C0005c; setexpr.l f1c_cs *0x80C0000c; if test "${f1c_h1}" = 4e4f4765 && test "${f1c_h2}" = 3054422e && test "${f1c_hl}" = 6000 && test "${f1c_p0}" = 0 && test "${f1c_p1}" = 0 && test "${f1c_p2}" = 0; then setenv f1c_hok 1; fi; fi'
setenv f1c_dram_write 'cp.l 0x80C00000 0x80C02000 80; setexpr f1c_cs ${f1c_cs} - ${f1c_ow}; setexpr f1c_cs ${f1c_cs} + ${f1c_dw}; mw.l 0x80C0005c ${f1c_dw}; mw.l 0x80C0000c ${f1c_cs}; setenv f1c_dsec 10; if test -n "${f1c_dram_dry}"; then setenv f1c_dsec f; fi; if mmc write 0x80C00000 ${f1c_dsec} 1 && mmc read 0x80C01000 ${f1c_dsec} 1 && cmp.l 0x80C00000 0x80C01000 80; then true; else echo "Memory speed: the header did not read back, writing the old one"; mmc write 0x80C02000 ${f1c_dsec} 1; false; fi'
setenv f1c_dram_sync 'run f1c_dram_want; run f1c_dram_now; run f1c_dram_hdr; if test -z "${f1c_hok}"; then echo "Memory speed: card sector 16 is not the expected SPL header, setting not applied"; elif test "${f1c_ow}" != "${f1c_dw}"; then if run f1c_dram_write; then if test -n "${f1c_dram_dry}"; then echo "Memory speed: dry run, header for ${f1c_dwd} MHz written to sector 15"; else echo "Memory speed: set to ${f1c_dwd} MHz"; if test "${f1c_dr}" != "${f1c_dc}"; then echo "Memory speed: restarting to apply it"; reset; fi; fi; fi; elif test "${f1c_dr}" != "${f1c_dc}"; then echo "Memory speed: the setting is ${f1c_dwd} MHz but the memory runs at 0x${f1c_dr} MHz (the SPL fell back)"; fi'
run f1c_dram_sync

# Boot Buildroot with the settings. "Auto" is the order the board always
# had: the SD card, then the on-board NAND. nand_boot sets its own bootargs, so the
# settings only reach a kernel booted from the SD card.
setenv f1c_boot 'run f1c_bt_reset; setenv f1c_extra;run f1c_args_safe; run f1c_args_log; setenv bootargs "${f1c_base_args}${f1c_extra}"; echo "Kernel arguments: ${bootargs}"; if test "${c.bootsrc-str}" = "NAND"; then run nand_boot; elif test "${c.bootsrc-str}" = "SD card"; then run sd_boot; else run sd_boot; run nand_boot; fi'

# Boot LEHU OS with the same settings (CPU speed, safe mode, zram, kernel
# messages; "Boot from" is Buildroot's alone). Its kernel arguments are
# U-Boot's default ones with the root moved to p6. A missing kernel prints
# why and brings the menu back.
setexpr f1c_lehu_base_args sub "root=/dev/mmcblk0p2" "root=/dev/mmcblk0p6" "${f1c_base_args}"
# LEHU OS has no S04bootopts: the kernel sets the CPU speed itself. With a
# "CPU speed" setting and safe mode off, the loaded device tree loses the
# operating points above that speed, and the kernel starts cpufreq with the
# performance governor, which takes the highest one left. The CPU runs at
# that speed from the moment cpufreq-dt probes, before user space starts.
# Without a setting, or in safe mode, it stays at the 408 MHz U-Boot set.
setenv f1c_lehu_cpu 'if test -n "${c.cpu-str}" && test "${c.safe-str}" != "On"; then fdt addr 0x80C00000; for f in 528 600 648 720 792; do if test ${f} -gt ${c.cpu-str}; then fdt rm /opp-table-cpu/opp-${f}000000; fi; done; setenv bootargs "${bootargs} cpufreq.default_governor=performance"; fi'
setenv f1c_lehu_boot 'run f1c_bt_reset; setenv f1c_extra; run f1c_args_safe; run f1c_args_log; setenv bootargs "${f1c_lehu_base_args}${f1c_extra}"; if load mmc 0:6 0x80008000 /boot/zImage; then load mmc 0:6 0x80C00000 /boot/suniv-f1c200s-lctech-pi.dtb; run f1c_lehu_cpu; echo "LEHU OS, kernel arguments: ${bootargs}"; setenv fdt_high 0x81800000; bootz 0x80008000 - 0x80C00000; fi; echo "LEHU OS: no /boot/zImage on mmc 0:6"; bootmenu 10'

# Both systems are OSTree systems: Buildroot on p2 and LEHU OS on p6, or either
# one still a plain root file system. ostree keeps /boot/loader/uEnv.txt on the
# system's partition up to date: kernel_image, fdt_file and bootargs (ostree=,
# the deployment) for the current deployment, and the same with the suffix 2
# for the previous one. They are imported once, here; U-Boot's own bootargs is
# put back after. There is no initramfs: ostree's bootargs start the
# deployment's static ostree-prepare-root as init
# (init=<deployment>/usr/lib/ostree/...), which makes the deployment / and execs
# its /sbin/init. Before booting, the script checks that this program is there:
# the deployment's path is the ostree= value, cut out of the arguments in two
# steps (everything up to "ostree=", then everything from the next space).
#
# The update boot: lehu-os-update leaves /boot/lehu-update on the partition when
# an update is to be installed with the RAM to itself. The menu then boots the
# current deployment with f1c.update=1 by default, whatever the "Default system"
# setting: LEHU does not start, the update is installed, the file removed, and
# the board reboots.
setenv f1c_br_ostree
setenv f1c_br_update
if test -e mmc 0:2 /boot/loader/uEnv.txt; then
	if test -e mmc 0:2 /boot/lehu-update; then setenv f1c_br_update 1; fi
	setenv kernel_image; setenv fdt_file; setenv kernel_image2; setenv fdt_file2; setenv bootargs2
	load mmc 0:2 0x80C00000 /boot/loader/uEnv.txt
	env import -t 0x80C00000 ${filesize} kernel_image fdt_file bootargs kernel_image2 fdt_file2 bootargs2
	setenv f1c_br_ostree 1
	setenv f1c_br_args "${bootargs}"
	setenv f1c_br_args2 "${bootargs2}"
	setenv f1c_br_kernel "${kernel_image}"
	setenv f1c_br_fdt "${fdt_file}"
	setenv f1c_br_kernel2 "${kernel_image2}"
	setenv f1c_br_fdt2 "${fdt_file2}"
	setenv bootargs "${f1c_base_args}"
fi
setenv f1c_ostree
setenv f1c_ostree_update
if test -e mmc 0:6 /boot/loader/uEnv.txt; then
	if test -e mmc 0:6 /boot/lehu-update; then setenv f1c_ostree_update 1; fi
	setenv kernel_image; setenv fdt_file; setenv kernel_image2; setenv fdt_file2; setenv bootargs2
	load mmc 0:6 0x80C00000 /boot/loader/uEnv.txt
	env import -t 0x80C00000 ${filesize} kernel_image fdt_file bootargs kernel_image2 fdt_file2 bootargs2
	setenv f1c_ostree 1
	setenv f1c_ostree_args "${bootargs}"
	setenv f1c_ostree_args2 "${bootargs2}"
	setenv bootargs "${f1c_base_args}"
fi
# The boot itself, for either system: f1c_opart, f1c_oname and f1c_obase say
# which, f1c_oargs, f1c_okernel and f1c_ofdt which deployment, f1c_oupd whether
# it is the update boot. Only LEHU OS needs f1c_lehu_cpu: Buildroot's S04bootopts
# reads f1c.cpu_mhz.
setenv f1c_ostree_boot 'run f1c_bt_reset; setenv f1c_extra; run f1c_args_safe; run f1c_args_log; setexpr f1c_odir sub ".*ostree=" "" "${f1c_oargs}"; setexpr f1c_odir sub " .*" "" "${f1c_odir}"; setenv bootargs "${f1c_obase}${f1c_extra}${f1c_oupd} ${f1c_oargs}"; if test -e mmc 0:${f1c_opart} ${f1c_odir}/usr/lib/ostree/ostree-prepare-root && load mmc 0:${f1c_opart} 0x80008000 ${f1c_okernel} && load mmc 0:${f1c_opart} 0x80C00000 ${f1c_ofdt}; then if test "${f1c_opart}" = 6; then run f1c_lehu_cpu; fi; echo "${f1c_oname} ${f1c_odir}, kernel arguments: ${bootargs}"; setenv fdt_high 0x81800000; bootz 0x80008000 - 0x80C00000; fi; echo "${f1c_oname}: cannot boot ${f1c_odir} (${f1c_okernel})"; bootmenu 10'
setenv f1c_lehu_ostree 'setenv f1c_opart 6; setenv f1c_oname "LEHU OS"; setenv f1c_obase "${f1c_lehu_base_args}"'
setenv f1c_lehu_ostree_cur 'run f1c_lehu_ostree; setenv f1c_oupd; setenv f1c_oargs "${f1c_ostree_args}"; setenv f1c_okernel "${kernel_image}"; setenv f1c_ofdt "${fdt_file}"; run f1c_ostree_boot'
setenv f1c_lehu_ostree_upd 'run f1c_lehu_ostree; setenv f1c_oupd " f1c.update=1"; setenv f1c_oargs "${f1c_ostree_args}"; setenv f1c_okernel "${kernel_image}"; setenv f1c_ofdt "${fdt_file}"; run f1c_ostree_boot'
setenv f1c_lehu_ostree_prev 'run f1c_lehu_ostree; setenv f1c_oupd; setenv f1c_oargs "${f1c_ostree_args2}"; setenv f1c_okernel "${kernel_image2}"; setenv f1c_ofdt "${fdt_file2}"; run f1c_ostree_boot'
# "Boot from" is Buildroot's: NAND is the NAND image, as without OSTree.
setenv f1c_br_ostree_set 'setenv f1c_opart 2; setenv f1c_oname Buildroot; setenv f1c_obase "${f1c_base_args}"'
setenv f1c_br_ostree_cur 'if test "${c.bootsrc-str}" = "NAND"; then run f1c_boot; fi; run f1c_br_ostree_set; setenv f1c_oupd; setenv f1c_oargs "${f1c_br_args}"; setenv f1c_okernel "${f1c_br_kernel}"; setenv f1c_ofdt "${f1c_br_fdt}"; run f1c_ostree_boot'
setenv f1c_br_ostree_upd 'run f1c_br_ostree_set; setenv f1c_oupd " f1c.update=1"; setenv f1c_oargs "${f1c_br_args}"; setenv f1c_okernel "${f1c_br_kernel}"; setenv f1c_ofdt "${f1c_br_fdt}"; run f1c_ostree_boot'
setenv f1c_br_ostree_prev 'run f1c_br_ostree_set; setenv f1c_oupd; setenv f1c_oargs "${f1c_br_args2}"; setenv f1c_okernel "${f1c_br_kernel2}"; setenv f1c_ofdt "${f1c_br_fdt2}"; run f1c_ostree_boot'

# cedit read_env fails (-ENOENT, "Failed to read settings from environment:
# -2") if any menu of the form has no c.<name> variable, as in a
# f1c-settings.txt saved before that menu existed. So each menu added later
# gets its first item here when the file lacks it. The numbers are item IDs
# from f1c-settings-ids.h (EXPOID_BASE_ID is 5): ID_OS_BUILDROOT 29,
# ID_ZRAM_OFF 32, ID_DRAM_156 35. A menu added later gets a line here too.
setenv f1c_settings_defaults 'if test -z "${c.os}"; then setenv c.os 29; setenv c.os-str Buildroot; fi; if test -z "${c.zram}"; then setenv c.zram 32; setenv c.zram-str Off; fi; if test -z "${c.dram}"; then setenv c.dram 35; setenv c.dram-str 156; fi'

# The settings form. ESC or "Exit" leaves without writing; "Save" writes
# f1c-settings.txt. Either way the menu comes back, and boots by itself
# after 10 s.
setenv f1c_settings 'if cedit load mmc 0:1 f1c-settings.dtb; then run f1c_settings_defaults; cedit read_env; if cedit run; then cedit write_env; env export -t 0x80C00000 c.os c.os-str c.cpu c.cpu-str c.dram c.dram-str c.safe c.safe-str c.zram c.zram-str c.loglevel c.loglevel-str c.bootsrc c.bootsrc-str; fatwrite mmc 0:1 0x80C00000 f1c-settings.txt ${filesize}; run f1c_dram_sync; fi; else echo "f1c-settings.dtb missing from the boot partition"; fi; bootmenu 10'

# The menu. bootmenu_default is the entry the countdown boots, and bootcmd
# the same system, for "boot" typed at the console. An OSTree system with a
# previous deployment gets an entry for it too: the version before the last
# update, picked by hand; and one for the update boot when an update waits,
# which is then the default. The entries are numbered as they are added (f1c_n):
# at most Buildroot's three, LEHU OS's three and Settings. A card with one
# plain system has "Boot" and "Settings", as before there were two.
for f1c_i in 0 1 2 3 4 5 6 7; do setenv bootmenu_${f1c_i}; done
setenv f1c_upd_entry
setenv f1c_upd_cmd
setenv f1c_lehu_entry
setenv f1c_lehu_cmd
setenv f1c_n 0
if test -n "${f1c_br_ostree}"; then
	setenv f1c_br_cmd 'run f1c_br_ostree_cur'
	setenv bootmenu_0 'Buildroot=run f1c_br_ostree_cur'
	setenv f1c_n 1
	if test -n "${f1c_br_kernel2}"; then
		setenv bootmenu_${f1c_n} 'Buildroot, previous version=run f1c_br_ostree_prev'
		setexpr f1c_n ${f1c_n} + 1
	fi
	if test -n "${f1c_br_update}"; then
		setenv bootmenu_${f1c_n} 'Buildroot, install the update=run f1c_br_ostree_upd'
		setenv f1c_upd_entry ${f1c_n}
		setenv f1c_upd_cmd 'run f1c_br_ostree_upd'
		setexpr f1c_n ${f1c_n} + 1
	fi
else
	setenv f1c_br_cmd 'run f1c_boot'
	setenv bootmenu_0 'Buildroot=run f1c_boot'
	setenv f1c_n 1
fi
if test -n "${f1c_ostree}"; then
	setenv bootmenu_${f1c_n} 'LEHU OS=run f1c_lehu_ostree_cur'
	setenv f1c_lehu_entry ${f1c_n}
	setenv f1c_lehu_cmd 'run f1c_lehu_ostree_cur'
	setexpr f1c_n ${f1c_n} + 1
	if test -n "${kernel_image2}"; then
		setenv bootmenu_${f1c_n} 'LEHU OS, previous version=run f1c_lehu_ostree_prev'
		setexpr f1c_n ${f1c_n} + 1
	fi
	if test -n "${f1c_ostree_update}" && test -z "${f1c_upd_entry}"; then
		setenv bootmenu_${f1c_n} 'LEHU OS, install the update=run f1c_lehu_ostree_upd'
		setenv f1c_upd_entry ${f1c_n}
		setenv f1c_upd_cmd 'run f1c_lehu_ostree_upd'
		setexpr f1c_n ${f1c_n} + 1
	fi
elif test -e mmc 0:6 /boot/zImage; then
	setenv bootmenu_${f1c_n} 'LEHU OS=run f1c_lehu_boot'
	setenv f1c_lehu_entry ${f1c_n}
	setenv f1c_lehu_cmd 'run f1c_lehu_boot'
	setexpr f1c_n ${f1c_n} + 1
elif test -z "${f1c_br_ostree}"; then
	setenv bootmenu_0 'Boot=run f1c_boot'
fi
setenv bootmenu_${f1c_n} 'Settings=run f1c_settings'
if test -n "${f1c_upd_entry}"; then
	setenv bootmenu_default ${f1c_upd_entry}
	setenv bootcmd "${f1c_upd_cmd}"
elif test "${c.os-str}" = "LEHU OS" && test -n "${f1c_lehu_entry}"; then
	setenv bootmenu_default ${f1c_lehu_entry}
	setenv bootcmd "${f1c_lehu_cmd}"
else
	setenv bootmenu_default 0
	setenv bootcmd "${f1c_br_cmd}"
fi
