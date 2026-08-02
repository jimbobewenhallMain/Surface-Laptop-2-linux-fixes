#!/bin/bash
#
# camera-rgb-watcher-patch.sh — fix: RGB camera/LED stays on after the
# app using it exits.
#
# CAUSE
# -----
# The bridge used to be a bare ExecStart=gst-launch..., so the service's
# MainPID was the process holding /dev/video42, and the watcher excluded
# it correctly. Adding RGB_CONTROLS support wrapped it in a runner
# script: MainPID is now the wrapper and gst-launch is a CHILD with a
# different PID. The watcher only excluded MainPID, so it counted its own
# pipeline as a consumer -> "someone is using the camera" forever -> the
# bridge is never stopped and the privacy LED stays lit.
#
# FIX
# ---
# Exclude by systemd cgroup instead of PID: any process belonging to
# camera-webcam-bridge.service or camera-idle-feed.service is ours,
# whatever its PID or depth. (The IR watcher already does this.)
#
# This patch touches ONE file - /usr/local/bin/camera-ondemand-watch.sh -
# and restarts the watcher. It does not reinstall anything, does not
# touch the kernel modules, libcamera, the loopback devices or the IR
# camera. The previous file is backed up.
#
#   bash camera-rgb-watcher-patch.sh            diagnose, patch, verify
#   bash camera-rgb-watcher-patch.sh --revert   put the old watcher back
#
set -u
TAG="rgb-patch"
WATCH=/usr/local/bin/camera-ondemand-watch.sh
BAK="$WATCH.pre-cgroup-fix"
log()  { echo "[$TAG] $*"; }
die()  { echo "[$TAG] ERROR: $*"; exit 1; }
[[ $EUID -ne 0 ]] || die "run WITHOUT sudo (it uses your user services)"

if [[ "${1:-}" == "--revert" ]]; then
    sudo test -f "$BAK" || die "no backup at $BAK"
    sudo cp -f "$BAK" "$WATCH"
    systemctl --user restart camera-ondemand
    log "reverted and watcher restarted"
    exit 0
fi

############################################################################
log "=== 1. who holds /dev/video42 right now ==="
FOUND=0
for p in /proc/[0-9]*; do
    pid="${p#/proc/}"
    for fd in "$p"/fd/*; do
        [[ -e "$fd" ]] || continue
        if [[ "$(readlink -f "$fd" 2>/dev/null)" == "/dev/video42" ]]; then
            cg="$(tr '\n' ' ' < "$p/cgroup" 2>/dev/null)"
            tag="EXTERNAL (a real app)"
            case "$cg" in
                *camera-webcam-bridge*) tag="ours: bridge" ;;
                *camera-idle-feed*)     tag="ours: idle feed" ;;
            esac
            printf "    pid %-7s %-18s %s\n" "$pid" "$(cat "$p/comm" 2>/dev/null)" "$tag"
            FOUND=1
            break
        fi
    done
done 2>/dev/null
[[ $FOUND -eq 1 ]] || log "    (nothing holding it)"

log "=== 2. current watcher exclusion logic ==="
if sudo grep -q 'camera-webcam-bridge\*' "$WATCH" 2>/dev/null; then
    log "already cgroup-aware - this patch is applied"
    ALREADY=1
else
    sudo grep -n 'READERS=1' "$WATCH" 2>/dev/null | head -3 | sed 's/^/    /'
    ALREADY=0
fi

############################################################################
if [[ ${ALREADY:-0} -eq 0 ]]; then
    log "=== 3. patching $WATCH ==="
    sudo test -f "$WATCH" || die "$WATCH not found - is the RGB setup installed?"
    sudo cp -n "$WATCH" "$BAK" 2>/dev/null || true
    log "backup: $BAK"

    # Write to a temp file and move it into place: bash reads a running
    # script lazily by byte offset, so overwriting it in place corrupts
    # the running instance.
    TMP=$(mktemp)
    cat > "$TMP" <<'EOF'
#!/bin/bash
# Keep exactly one producer on /dev/video42:
#   no consumers -> camera-idle-feed (black frames, LED off)
#   consumers    -> camera-webcam-bridge (real camera, LED on)
#
# Consumers are identified by systemd cgroup, not PID: the bridge runs a
# wrapper script whose gst-launch child holds the device under a
# different PID, and excluding only MainPID made the watcher treat its
# own pipeline as a consumer (camera and LED stuck on).
set -u
DEV=/dev/video42
for i in $(seq 1 30); do [[ -e $DEV ]] && break; sleep 1; done
[[ -e $DEV ]] || { echo "$DEV never appeared"; exit 1; }
systemctl --user start camera-idle-feed
echo "watching $DEV (cgroup-aware)"
IDLE=0
while sleep 1; do
    READERS=0
    for p in $(fuser "$DEV" 2>/dev/null | tr -cd '0-9 '); do
        [[ -n "$p" ]] || continue
        [[ -d "/proc/$p" ]] || continue
        CG="$(tr '\n' ' ' < "/proc/$p/cgroup" 2>/dev/null)"
        case "$CG" in
            *camera-webcam-bridge*|*camera-idle-feed*) continue ;;
        esac
        READERS=1
        break
    done
    BRIDGE_ON="$(systemctl --user is-active camera-webcam-bridge 2>/dev/null)"
    if [[ $READERS -eq 1 && "$BRIDGE_ON" != "active" ]]; then
        echo "consumer detected -> real camera ON"
        systemctl --user start camera-webcam-bridge
        IDLE=0
    elif [[ $READERS -eq 0 && "$BRIDGE_ON" == "active" ]]; then
        IDLE=$((IDLE + 1))
        GRACE=5
        # shellcheck disable=SC1091
        source /etc/default/camera-rgb 2>/dev/null && GRACE="${RGB_GRACE:-5}"
        if [[ $IDLE -ge $GRACE ]]; then
            echo "no consumers -> camera OFF, back to idle feed"
            systemctl --user start camera-idle-feed
            IDLE=0
        fi
    else
        IDLE=0
        if [[ "$BRIDGE_ON" != "active" ]] \
           && [[ "$(systemctl --user is-active camera-idle-feed)" != "active" ]]; then
            systemctl --user start camera-idle-feed
        fi
    fi
done
EOF
    bash -n "$TMP" || die "generated watcher failed syntax check - nothing changed"
    sudo install -m 755 "$TMP" "$WATCH.new"
    sudo mv -f "$WATCH.new" "$WATCH"
    rm -f "$TMP"
    log "patched (atomically - the running copy was not corrupted)"
fi

############################################################################
log "=== 4. restarting the watcher ==="
systemctl --user stop camera-webcam-bridge 2>/dev/null
systemctl --user restart camera-ondemand
sleep 3

log "=== 5. verifying ==="
BR="$(systemctl --user is-active camera-webcam-bridge 2>/dev/null)"
ID="$(systemctl --user is-active camera-idle-feed 2>/dev/null)"
log "bridge=$BR  idle-feed=$ID"
if [[ "$BR" == "active" ]]; then
    log "WARN: bridge is running with no app using the camera."
    log "Something external still holds /dev/video42 - see section 1."
else
    log "PASS: camera off, idle feed serving the device (LED should be OFF)"
fi
echo
log "Now test: open the camera in your browser, confirm it works, then"
log "close the browser window. Within RGB_GRACE seconds (currently"
log "$(grep -s '^RGB_GRACE=' /etc/default/camera-rgb | cut -d= -f2 || echo 5)s)"
log "the LED should go out. Watch it live with:"
log "    journalctl --user -u camera-ondemand -f"
log
log "Undo: bash $0 --revert"
