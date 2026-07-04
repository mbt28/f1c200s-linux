# Runs on root login. The VE driver (cedrus|cedar) is loaded at boot by
# /etc/init.d/S20ve-select per /etc/ve-driver. cedrus->/dev/video0; cedar->/dev/cedar_dev.
# FastCarPlay no longer auto-starts -- run it by hand with `carplay`.
#
# `carplay` uses the settings preset matching the active VE driver: cedar ->
# settings_cedar.txt (CedarDecoder, working), cedrus -> settings_cedrus.txt.
# $(...) is expanded at invocation, so it tracks /etc/ve-driver at run time.
alias carplay='psplash-write QUIT 2>/dev/null; SDL_AUDIODRIVER=dummy fastcarplay /etc/fastcarplay/settings_$(tr -dc a-z < /etc/ve-driver 2>/dev/null).txt'
