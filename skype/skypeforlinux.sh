#!/bin/sh

SKYPE_PATH="/usr/share/skypeforlinux/skypeforlinux"
SKYPE_LOGS="$HOME/.config/skypeforlinux/logs"

[ -e "$SKYPE_LOGS" ] || mkdir -p "$SKYPE_LOGS"
exec "$SKYPE_PATH" --executed-from="$PWD" "$@" \
	> "$SKYPE_LOGS/skype-startup.log" 2>&1
