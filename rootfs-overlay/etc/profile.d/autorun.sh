# Runs on root login. The VE driver (cedrus|cedar) is loaded at boot by
# /etc/init.d/S20ve-select per /etc/ve-driver. cedrus->/dev/video0; cedar->/dev/cedar_dev.
# FastCarPlay AUTOSTARTS at boot (S99carplay; control with `autorun on|wireless|off`).
# Default is `wireless` -- settings_cedrus_wireless.txt, with S99carplay bringing
# wifi+bt+net up first. The manual `carplay` command replaces any running instance.
#
# `carplay` uses the active preset the same way S99carplay does: /etc/carplay-preset
# (e.g. cedrus_wireless, set by `autorun wireless`) if present, else the one matching
# the VE driver (cedar -> settings_cedar.txt, cedrus -> settings_cedrus.txt), falling
# back to settings.txt. $(...) is expanded at invocation, so it tracks the current
# selection at run time. NOTE: `carplay` only relaunches the app -- for a wireless
# preset bring wifi+bt+net up first (or just let the boot autostart do it).
alias carplay='killall fastcarplay 2>/dev/null && sleep 1; _p="$(cat /etc/carplay-preset 2>/dev/null)"; [ -n "$_p" ] || _p="$(tr -dc a-z < /etc/ve-driver 2>/dev/null)"; _s="/etc/fastcarplay/settings_${_p}.txt"; [ -f "$_s" ] || _s=/etc/fastcarplay/settings.txt; SDL_AUDIODRIVER=dummy fastcarplay "$_s"'
