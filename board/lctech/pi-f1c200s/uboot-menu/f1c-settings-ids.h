/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * IDs for the boot settings form (f1c-settings.dts), read by U-Boot's
 * tools/expo.py. Keep the order: `cedit read_env` restores a menu from the
 * item ID saved in f1c-settings.txt, so renumbering makes old files point at
 * the wrong item. Add new IDs at the end only.
 */

enum {
	/* cedit acts on these two reserved IDs: save and exit, or just exit */
	ID_SAVE = 1,
	ID_DISCARD,

	ID_PROMPT = EXPOID_BASE_ID,

	ID_SCENE,
	ID_SCENE_TITLE,

	ID_CPU,
	ID_CPU_408,
	ID_CPU_528,
	ID_CPU_600,
	ID_CPU_648,
	ID_CPU_720,
	ID_CPU_792,

	ID_SAFE,
	ID_SAFE_OFF,
	ID_SAFE_ON,

	ID_LOG,
	ID_LOG_NORMAL,
	ID_LOG_QUIET,
	ID_LOG_VERBOSE,

	ID_SRC,
	ID_SRC_AUTO,
	ID_SRC_SD,
	ID_SRC_NAND,

	ID_SAVE_ITEM,
	ID_DISCARD_ITEM,

	/* added 2026-11-04: which system the menu boots by itself */
	ID_OS,
	ID_OS_BUILDROOT,
	ID_OS_LEHU,

	ID_DYNAMIC_START,
};
