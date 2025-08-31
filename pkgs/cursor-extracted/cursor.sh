#!/bin/bash

XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-~/.config}

if [[ -f "${XDG_CONFIG_HOME}/cursor-flags.conf" ]]; then
    mapfile -t CURSOR_USER_FLAGS <<<"$(grep -v '^#' "${XDG_CONFIG_HOME}/cursor-flags.conf")"
    echo "User flags:" "${CURSOR_USER_FLAGS[@]}"
fi

exec /opt/cursor/usr/share/cursor/cursor "${CURSOR_USER_FLAGS[@]}" "$@"
