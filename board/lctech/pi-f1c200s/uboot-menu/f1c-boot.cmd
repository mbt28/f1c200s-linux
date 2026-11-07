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
# Buildroot image (root on p2, kernel on the boot partition) and LEHU OS
# (root on p6, a logical partition, with its kernel and device tree in its
# own /boot). The menu offers LEHU OS only when p6 has it, and boots the
# "Default system" setting by itself. LEHU OS on p6 is either an OSTree
# system (/boot/loader/uEnv.txt, lehu-os/docs/ostree.md) or a plain root
# file system with /boot/zImage.

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

# LEHU OS as an OSTree system. ostree keeps /boot/loader/uEnv.txt on p6 up
# to date: kernel_image, fdt_file and bootargs (ostree=, the deployment) for
# the current deployment, and the same with the suffix 2 for the previous
# one. They are imported once, here; U-Boot's own bootargs is put back
# after. There is no initramfs: ostree's bootargs start the deployment's
# static ostree-prepare-root as init (init=<deployment>/usr/lib/ostree/...),
# which makes the deployment / and execs its /sbin/init. Before booting, the
# script checks that this program is there: the deployment's path is the
# ostree= value, cut out of the arguments in two steps (everything up to
# "ostree=", then everything from the next space).
setenv f1c_ostree
if test -e mmc 0:6 /boot/loader/uEnv.txt; then
	setenv kernel_image; setenv fdt_file; setenv kernel_image2; setenv fdt_file2; setenv bootargs2
	load mmc 0:6 0x80C00000 /boot/loader/uEnv.txt
	env import -t 0x80C00000 ${filesize} kernel_image fdt_file bootargs kernel_image2 fdt_file2 bootargs2
	setenv f1c_ostree 1
	setenv f1c_ostree_args "${bootargs}"
	setenv f1c_ostree_args2 "${bootargs2}"
	setenv bootargs "${f1c_base_args}"
fi
setenv f1c_lehu_ostree_boot 'run f1c_bt_reset; setenv f1c_extra; run f1c_args_safe; run f1c_args_log; setexpr f1c_odir sub ".*ostree=" "" "${f1c_oargs}"; setexpr f1c_odir sub " .*" "" "${f1c_odir}"; setenv bootargs "${f1c_lehu_base_args}${f1c_extra} ${f1c_oargs}"; if test -e mmc 0:6 ${f1c_odir}/usr/lib/ostree/ostree-prepare-root && load mmc 0:6 0x80008000 ${f1c_okernel} && load mmc 0:6 0x80C00000 ${f1c_ofdt}; then run f1c_lehu_cpu; echo "LEHU OS ${f1c_odir}, kernel arguments: ${bootargs}"; setenv fdt_high 0x81800000; bootz 0x80008000 - 0x80C00000; fi; echo "LEHU OS: cannot boot ${f1c_odir} (${f1c_okernel})"; bootmenu 10'
setenv f1c_lehu_ostree_cur 'setenv f1c_oargs "${f1c_ostree_args}"; setenv f1c_okernel "${kernel_image}"; setenv f1c_ofdt "${fdt_file}"; run f1c_lehu_ostree_boot'
setenv f1c_lehu_ostree_prev 'setenv f1c_oargs "${f1c_ostree_args2}"; setenv f1c_okernel "${kernel_image2}"; setenv f1c_ofdt "${fdt_file2}"; run f1c_lehu_ostree_boot'

# cedit read_env fails (-ENOENT, "Failed to read settings from environment:
# -2") if any menu of the form has no c.<name> variable, as in a
# f1c-settings.txt saved before that menu existed. So each menu added later
# gets its first item here when the file lacks it. The numbers are item IDs
# from f1c-settings-ids.h (EXPOID_BASE_ID is 5): ID_OS_BUILDROOT 29,
# ID_ZRAM_OFF 32. A menu added later gets a line here too.
setenv f1c_settings_defaults 'if test -z "${c.os}"; then setenv c.os 29; setenv c.os-str Buildroot; fi; if test -z "${c.zram}"; then setenv c.zram 32; setenv c.zram-str Off; fi'

# The settings form. ESC or "Exit" leaves without writing; "Save" writes
# f1c-settings.txt. Either way the menu comes back, and boots by itself
# after 10 s.
setenv f1c_settings 'if cedit load mmc 0:1 f1c-settings.dtb; then run f1c_settings_defaults; cedit read_env; if cedit run; then cedit write_env; env export -t 0x80C00000 c.os c.os-str c.cpu c.cpu-str c.safe c.safe-str c.zram c.zram-str c.loglevel c.loglevel-str c.bootsrc c.bootsrc-str; fatwrite mmc 0:1 0x80C00000 f1c-settings.txt ${filesize}; fi; else echo "f1c-settings.dtb missing from the boot partition"; fi; bootmenu 10'

# The menu. bootmenu_default is the entry the countdown boots, and bootcmd
# the same system, for "boot" typed at the console. An OSTree LEHU OS with
# a previous deployment gets an entry for it too: the version before the
# last update, picked by hand.
setenv bootmenu_3
if test -n "${f1c_ostree}"; then
	setenv bootmenu_0 'Buildroot=run f1c_boot'
	setenv bootmenu_1 'LEHU OS=run f1c_lehu_ostree_cur'
	if test -n "${kernel_image2}"; then
		setenv bootmenu_2 'LEHU OS, previous version=run f1c_lehu_ostree_prev'
		setenv bootmenu_3 'Settings=run f1c_settings'
	else
		setenv bootmenu_2 'Settings=run f1c_settings'
	fi
	if test "${c.os-str}" = "LEHU OS"; then
		setenv bootmenu_default 1
		setenv bootcmd 'run f1c_lehu_ostree_cur'
	else
		setenv bootmenu_default 0
		setenv bootcmd 'run f1c_boot'
	fi
elif test -e mmc 0:6 /boot/zImage; then
	setenv bootmenu_0 'Buildroot=run f1c_boot'
	setenv bootmenu_1 'LEHU OS=run f1c_lehu_boot'
	setenv bootmenu_2 'Settings=run f1c_settings'
	if test "${c.os-str}" = "LEHU OS"; then
		setenv bootmenu_default 1
		setenv bootcmd 'run f1c_lehu_boot'
	else
		setenv bootmenu_default 0
		setenv bootcmd 'run f1c_boot'
	fi
else
	setenv bootmenu_0 'Boot=run f1c_boot'
	setenv bootmenu_1 'Settings=run f1c_settings'
	setenv bootmenu_2
	setenv bootmenu_default 0
	setenv bootcmd 'run f1c_boot'
fi
