# Cedar VE + ION driver (BSP decode path)

The Allwinner **Cedar** VideoEngine + ION kernel driver is **not vendored** here —
it lives in its own repo and is fetched into `cedar/src/` by
`scripts/fetch-sources.sh`:

    CEDAR_GIT = https://github.com/mbt28/cedar.git   (config.env)
    CEDAR_REF = master

## How it gets into the kernel

`external.mk` runs a Buildroot `LINUX_POST_PATCH_HOOK` (`CEDAR_INTEGRATE`) that,
on every kernel (re)configure, copies `cedar/src/.` into the kernel staging tree
at `drivers/staging/media/sunxi/cedar/` and hooks its `Kconfig` + `Makefile`.
This survives `make linux-dirclean`. The config fragment
(`board/lctech/pi-f1c200s/linux.fragment`) then turns on:

    CONFIG_VIDEO_SUNXI_CEDAR_VE=m   # builds cedar_dev.ko
    CONFIG_VIDEO_SUNXI_CEDAR_ION=y

Userspace uses the **libcedarc** blobs (`package/libcedarc`, arm9-glibc) +
`cedar-decode-test`. At boot, `/etc/init.d/S20ve-select` reads `/etc/ve-driver`
and modprobes cedar **or** cedrus.

Cedar is the **colour-correct, working** decoder on the F1C200s — see
`docs/cedrus-status.md` for why mainline cedrus is not (yet).

## Local hacking

To iterate on the driver without pushing to the cedar repo, point the hook at a
working clone:

    make -C buildroot BR2_EXTERNAL=.. O=../output \
         CEDAR_SRC_DIR=/path/to/cedar linux-rebuild
