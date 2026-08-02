#!/bin/bash
#
# camera-rgb-rescue.sh — RGB privacy LED stuck on: stop it, find out why,
# and optionally roll back to the previous known-good bridge.
#
#   bash camera-rgb-rescue.sh              stop the LED + diagnose
#   bash camera-rgb-rescue.sh --rollback   also restore the pre-settings
#                                          bridge service (inline pipeline)
#
# Run as your normal user (it uses your user services); it will call sudo
# only where it must.
#
set -u
TAG="rgb-rescue"
log() { echo "[$TAG] $*"; }
[[ $EUID -ne 0 ]] || { echo "run WITHOUT sudo: bash $0 $*"; exit 1; }
UHOME="$HOME"

############################################################################
log "=== 1. stopping the RGB camera (LED off) ==="
systemctl --user stop camera-ondemand 2>/dev/null
systemctl --user stop camera-webcam-bridge 2>/dev/null
sleep 1
if pgrep -af "gst-launch.*libcamerasrc" >/dev/null 2>&1; then
    log "a libcamera pipeline is still running; stopping it"
    pkill -f "gst-launch.*libcamerasrc"
    sleep 1
fi
pgrep -af "gst-launch.*libcamerasrc" >/dev/null 2>&1 \
    && log "WARN: still running - check: pgrep -af gst-launch" \
    || log "PASS: no libcamera pipeline running (LED should be OFF now)"

############################################################################
log "=== 2. who was holding /dev/video42? ==="
if command -v fuser >/dev/null; then
    HOLD="$(sudo fuser -v /dev/video42 2>&1 | tail -n +2)"
    if [[ -n "$HOLD" ]]; then
        echo "$HOLD" | sed 's/^/    /'
    else
        log "nothing is holding it now"
    fi
fi
log "processes that opened it (by /proc scan):"
for p in /proc/[0-9]*; do
    pid="${p#/proc/}"
    for fd in "$p"/fd/*; do
        [[ -e "$fd" ]] || continue
        if [[ "$(readlink -f "$fd" 2>/dev/null)" == "/dev/video42" ]]; then
            printf "    pid %-7s %s\n" "$pid" "$(cat "$p/comm" 2>/dev/null)"
            break
        fi
    done
done 2>/dev/null

############################################################################
log "=== 3. watcher state ==="
systemctl --user status camera-ondemand --no-pager -n 12 2>/dev/null | sed 's/^/    /'
log "recent watcher decisions:"
journalctl --user -u camera-ondemand -n 15 --no-pager 2>/dev/null | sed 's/^/    /'

############################################################################
log "=== 4. current bridge definition ==="
BR="$UHOME/.config/systemd/user/camera-webcam-bridge.service"
[[ -f "$BR" ]] && grep -E '^ExecStart' "$BR" | sed 's/^/    /'
[[ -f /etc/default/camera-rgb ]] && {
    log "/etc/default/camera-rgb:"
    grep -vE '^\s*#|^\s*$' /etc/default/camera-rgb | sed 's/^/    /'
}

############################################################################
if [[ "${1:-}" == "--rollback" ]]; then
    log "=== 5. rolling back to the previous inline bridge ==="
    cat > "$BR" <<'EOF'
[Unit]
Description=Surface Laptop 2 webcam bridge (libcamera -> v4l2loopback)
Conflicts=camera-idle-feed.service
After=graphical-session.target

[Service]
ExecStart=/usr/bin/gst-launch-1.0 -q libcamerasrc ! videoconvert ! videoscale \
    ! video/x-raw,format=YUY2,width=1280,height=720 \
    ! v4l2sink device=/dev/video42 sync=false
Restart=no
EOF
    systemctl --user daemon-reload
    log "restored the original ExecStart (no RGB_CONTROLS wrapper)"
fi

############################################################################
log "=== 6. restarting in the safe state ==="
systemctl --user start camera-ondemand 2>/dev/null
sleep 3
if systemctl --user is-active camera-idle-feed >/dev/null 2>&1; then
    log "PASS: idle feed running - camera off, /dev/video42 still enumerable"
else
    log "WARN: idle feed not running; start it with:"
    log "    systemctl --user start camera-idle-feed"
fi
if systemctl --user is-active camera-webcam-bridge >/dev/null 2>&1; then
    log "PROBLEM: the real bridge started again with no app using the camera."
    log "Something is holding /dev/video42 open - see section 2 above."
else
    log "PASS: real bridge is stopped (LED off)"
fi
echo
log "Send me sections 2, 3 and 4 and I will fix the cause properly."
