# Runs on root login. The VE driver (cedrus|cedar) is loaded at boot by
# /etc/init.d/S20ve-select per /etc/ve-driver. cedrus->/dev/video0; cedar->/dev/cedar_dev.
# FastCarPlay no longer auto-starts -- run it by hand with `carplay`.
alias carplay='SDL_AUDIODRIVER=dummy fastcarplay /etc/fastcarplay/settings_cedrus.txt'
