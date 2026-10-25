#!/usr/bin/env bash
# zen-conky launcher: finds the Zenbook Duo ScreenPad Plus and pins the
# dashboard to it.
#
#   ./start.sh [start]        start (or restart) on the ScreenPad
#   ./start.sh stop           stop
#   ./start.sh autostart      install a KDE login autostart entry
#   ./start.sh noautostart    remove it
#   sudo ./start.sh fan-access  let the plugdev group toggle fan boost (udev rule)
#
# Env: ZEN_OUTPUT=DP-1 forces the output; ZEN_WINDOW_TYPE=desktop|dock|normal.
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RUN="${XDG_RUNTIME_DIR:-/tmp}"
PIDFILE="$RUN/zen-conky.pid"
GPU_PIDFILE="$RUN/zen-conky-gpu.pid"
FAN_RULE=/etc/udev/rules.d/90-zen-conky-fans.rules
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/zen-conky.desktop"

stop() {
    local f
    for f in "$PIDFILE" "$GPU_PIDFILE"; do
        if [[ -f $f ]] && kill -0 "$(cat "$f")" 2>/dev/null; then kill "$(cat "$f")"; fi
        rm -f "$f"
    done
}

fan_access() {
    [[ $EUID -eq 0 ]] || { echo "needs root: sudo $0 fan-access" >&2; exit 1; }
    cat >"$FAN_RULE" <<'EOF'
# zen-conky: let the plugdev group toggle ASUS fan boost.
# pwm1_enable = CPU fan, pwm2_enable = GPU fan; 0 = full speed, 2 = automatic.
ACTION=="add", SUBSYSTEM=="hwmon", ATTR{name}=="asus", RUN+="/bin/sh -c 'cd /sys%p && chgrp plugdev pwm1_enable pwm2_enable && chmod g+w pwm1_enable pwm2_enable'"
EOF
    udevadm control --reload
    # Apply now as well, without waiting for a reboot.
    local d
    for d in /sys/class/hwmon/hwmon*; do
        if [[ $(cat "$d/name" 2>/dev/null) == asus ]]; then
            chgrp plugdev "$d"/pwm[12]_enable && chmod g+w "$d"/pwm[12]_enable
        fi
    done
    echo "installed $FAN_RULE (members of plugdev can now toggle fan boost)"
}

# Prints "WxH+X+Y" for an enabled output, nothing if disabled/absent.
geometry() {
    xrandr --query | awk -v o="$1" '$1 == o && $2 == "connected" {
        for (i = 3; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) { print $i; exit }
    }'
}

# The ScreenPad Plus is the connected output whose preferred mode is at
# least 3:1 (2880x864 on the UX8402 / UX582).
find_screenpad() {
    xrandr --query | awk '
        $2 == "connected" { out = $1; want = 1; next }
        /^[^ ]/           { want = 0; next }
        want && $1 ~ /^[0-9]+x[0-9]+$/ {
            split($1, m, "x"); if (m[1] >= 3 * m[2]) { print out; exit }; want = 0
        }'
}

start() {
    command -v conky >/dev/null || { echo "conky is not installed: sudo apt install conky-all" >&2; exit 1; }
    command -v xrandr >/dev/null || { echo "xrandr is required (x11-xserver-utils)" >&2; exit 1; }
    if [[ ${XDG_SESSION_TYPE:-x11} == wayland ]]; then
        echo "warning: Wayland session; conky's X11 window may not land on the right screen" >&2
    fi

    local out="${ZEN_OUTPUT:-$(find_screenpad)}"
    if [[ -z $out ]]; then
        echo "No ScreenPad Plus found (no connected output with a >=3:1 mode). Set ZEN_OUTPUT=..." >&2
        exit 1
    fi
    local geo
    geo="$(geometry "$out")"
    if [[ -z $geo ]]; then
        echo "$out is connected but disabled. Enable it in System Settings > Display & Monitor," >&2
        echo "or toggle it with the ScreenPad key, then run this again." >&2
        exit 1
    fi

    [[ $geo =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]]
    export ZEN_DIR="$DIR" ZEN_W="${BASH_REMATCH[1]}" ZEN_H="${BASH_REMATCH[2]}" \
           ZEN_X="${BASH_REMATCH[3]}" ZEN_Y="${BASH_REMATCH[4]}"

    stop
    echo "zen-conky -> $out ${ZEN_W}x${ZEN_H}+${ZEN_X}+${ZEN_Y}"
    setsid conky -c "$DIR/zen.conf" >"$RUN/zen-conky.log" 2>&1 &
    local cpid=$!
    echo $cpid >"$PIDFILE"
    # GPU temperature/load via NVML (exits on its own when conky does).
    if command -v python3 >/dev/null; then
        setsid python3 -I "$DIR/bin/zen-gpu.py" "$RUN/zen-conky-gpu" "$cpid" >>"$RUN/zen-conky.log" 2>&1 &
        echo $! >"$GPU_PIDFILE"
    fi
}

case "${1:-start}" in
    start|restart) start ;;
    stop) stop ;;
    autostart)
        mkdir -p "$(dirname "$AUTOSTART")"
        cat >"$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=zen-conky
Comment=System dashboard on the ScreenPad Plus
Exec=sh -c 'sleep 8; "$DIR/start.sh"'
X-KDE-autostart-phase=2
EOF
        echo "installed $AUTOSTART" ;;
    noautostart) rm -f "$AUTOSTART"; echo "removed $AUTOSTART" ;;
    fan-access) fan_access ;;
    *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
