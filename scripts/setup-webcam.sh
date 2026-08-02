#!/bin/bash
#
# setup-webcam.sh — expose the camera to browsers/apps as a standard V4L2
# webcam with on-demand sensor activation (OBS-virtual-camera pattern).
#
# Why not PipeWire-native cameras: Chromium's and Firefox's PipeWire
# camera consumers crash (CHECK/SIGTRAP) on the IPU3's two-plane NV12
# buffers. Why exclusive_caps=1 + an always-attached producer: Chromium
# skips V4L2 devices that advertise Video Output capability, and
# consumers that connect before a producer negotiate a bogus format.
#
# Result: /dev/video42 "Surface Camera", always enumerable; a black-frame
# idle feed keeps it capture-only with the sensor (and LED) OFF; a watcher
# swaps in the real libcamera feed only while an app captures.
#
set -u
TAG="setup-webcam"
log()  { echo "[$TAG] $*"; }
die()  { echo "[$TAG] ERROR: $*"; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root (with sudo, from your desktop session)"
[[ -n "${SUDO_USER:-}" ]] || die "run via sudo from your user session (SUDO_USER needed)"
U="$SUDO_USER"
UUID=$(id -u "$U")
UHOME=$(getent passwd "$U" | cut -d: -f6)
userctl() { sudo -u "$U" XDG_RUNTIME_DIR="/run/user/$UUID" systemctl --user "$@"; }

apt-get install -y -qq gstreamer1.0-plugins-good gstreamer1.0-tools gstreamer1.0-libcamera >/dev/null 2>&1

userctl stop camera-ondemand camera-webcam-bridge camera-idle-feed 2>/dev/null
sleep 1

### loopback ###############################################################
for f in /etc/modprobe.d/*.conf; do
    grep -ql v4l2loopback "$f" 2>/dev/null || continue
    [[ "$f" == /etc/modprobe.d/v4l2loopback-surface.conf ]] && continue
    log "removing conflicting v4l2loopback config: $f"; rm -f "$f"
done
# Canonical two-device config: 42 = RGB, 43 = IR. Both setup scripts write
# the same thing, so whichever runs last cannot delete the other's device
# at the next boot.
cat > /etc/modprobe.d/v4l2loopback-surface.conf <<'EOF'
options v4l2loopback devices=2 video_nr=42,43 card_label="Surface Camera,Surface IR Camera" exclusive_caps=1,1
EOF
echo v4l2loopback > /etc/modules-load.d/v4l2loopback-surface.conf

# Only reload when something is actually wrong - an unconditional reload
# would tear the device out from under the running IR daemon.
NEED_RELOAD=0
[[ -e /dev/video42 ]] || NEED_RELOAD=1
[[ "$(cat /sys/class/video4linux/video42/name 2>/dev/null)" == "Surface Camera" ]] || NEED_RELOAD=1
if [[ $NEED_RELOAD -eq 1 ]]; then
    log "reloading v4l2loopback (device missing or stale label)"
    systemctl stop camera-ir 2>/dev/null          # releases /dev/video43
    sleep 1
    for d in /dev/video42 /dev/video43; do
        [[ -e "$d" ]] && fuser -k "$d" 2>/dev/null
    done
    sleep 1
    modprobe -r v4l2loopback 2>/dev/null || die "v4l2loopback busy - close all camera apps and re-run"
    modprobe v4l2loopback || die "v4l2loopback load failed (is the DKMS module installed?)"
    udevadm settle 2>/dev/null; sleep 1
    [[ -e /dev/video42 ]] || die "/dev/video42 missing after reload"
    systemctl start camera-ir 2>/dev/null
else
    log "loopback devices already correct; not reloading"
fi

### keep PipeWire from offering the crashing native camera ################
rm -f "$UHOME/.config/wireplumber/wireplumber.conf.d/99-libcamera.conf"
mkdir -p /etc/wireplumber/wireplumber.conf.d
cat > /etc/wireplumber/wireplumber.conf.d/99-disable-libcamera.conf <<'EOF'
# Browsers' PipeWire-camera consumers crash on IPU3 multi-plane buffers;
# the camera is served via v4l2loopback instead (surface-laptop2-camera-fix).
wireplumber.profiles = {
  main = {
    monitor.libcamera = disabled
  }
}
EOF

### producers + watcher ####################################################
mkdir -p "$UHOME/.config/systemd/user"
cat > "$UHOME/.config/systemd/user/camera-idle-feed.service" <<'EOF'
[Unit]
Description=Surface camera idle feed (black frames, keeps device enumerable)
Conflicts=camera-webcam-bridge.service
After=graphical-session.target

[Service]
ExecStart=/usr/bin/gst-launch-1.0 -q videotestsrc pattern=black is-live=true \
    ! video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1 \
    ! v4l2sink device=/dev/video42 sync=true
Restart=on-failure
RestartSec=2
EOF
# RGB tuning: grace period and libcamera controls.
[[ -f /etc/default/camera-rgb ]] || cat > /etc/default/camera-rgb <<'EOF'
# Surface RGB camera settings.  Apply with:
#   systemctl --user restart camera-ondemand
# or use the GUI:  surface-camera-settings
#
# Seconds the camera + privacy LED stay on after the last app closes it.
RGB_GRACE=5
#
# Properties passed to gstlibcamerasrc. The IPU3 pipeline implements only
# AGC, AWB (greyworld), black level, gamma and AF, so the controls that
# actually change the picture are:
#   ae-enable=false                 turn auto exposure/gain off
#   exposure-time=20000             manual exposure, microseconds
#   analogue-gain=2.0               manual gain
# Denoising, sharpness, brightness, contrast and saturation are NOT
# available: the ImgU has the hardware blocks but libcamera never
# programs them (see src/ipa/ipu3/ipu3.cpp upstream).
# An invalid property makes the pipeline fail; the bridge detects that and
# automatically falls back to no controls, so a typo cannot break capture.
RGB_CONTROLS=""
EOF

# NOTE: shell scripts are written to a temp file and moved into place.
# bash reads a script lazily by byte offset, so overwriting one that is
# currently running makes the running copy execute garbage. mv gives the
# new file a new inode and leaves the running instance untouched.
cat > /usr/local/bin/camera-webcam-bridge-run.sh.new <<'EOF'
#!/bin/bash
# libcamera -> /dev/video42, applying RGB_CONTROLS with a safe fallback.
set -u
source /etc/default/camera-rgb 2>/dev/null || true
RGB_CONTROLS="${RGB_CONTROLS:-}"
run() {   # run <controls>
    exec_line=(gst-launch-1.0 -q libcamerasrc)
    [[ -n "$1" ]] && read -r -a extra <<<"$1" && exec_line+=("${extra[@]}")
    exec_line+=(! videoconvert ! videoscale
                ! video/x-raw,format=YUY2,width=1280,height=720
                ! v4l2sink device=/dev/video42 sync=false)
    "${exec_line[@]}" &
    PIPE=$!
    sleep 2
    if ! kill -0 "$PIPE" 2>/dev/null; then
        return 1
    fi
    wait "$PIPE"
    return 0
}
if [[ -n "$RGB_CONTROLS" ]]; then
    echo "starting with RGB_CONTROLS: $RGB_CONTROLS"
    run "$RGB_CONTROLS" && exit 0
    echo "WARN: pipeline failed with those controls - falling back to defaults"
fi
run ""
EOF
chmod 755 /usr/local/bin/camera-webcam-bridge-run.sh.new
mv -f /usr/local/bin/camera-webcam-bridge-run.sh.new /usr/local/bin/camera-webcam-bridge-run.sh

cat > "$UHOME/.config/systemd/user/camera-webcam-bridge.service" <<'EOF'
[Unit]
Description=Surface Laptop 2 webcam bridge (libcamera -> v4l2loopback)
Conflicts=camera-idle-feed.service
After=graphical-session.target

[Service]
ExecStart=/usr/local/bin/camera-webcam-bridge-run.sh
Restart=no
EOF

cat > /usr/local/bin/camera-ondemand-watch.sh.new <<'EOF'
#!/bin/bash
# Keep exactly one producer on /dev/video42:
#   no consumers -> camera-idle-feed (black frames, LED off)
#   consumers    -> camera-webcam-bridge (real camera, LED on)
set -u
DEV=/dev/video42
for i in $(seq 1 30); do [[ -e $DEV ]] && break; sleep 1; done
[[ -e $DEV ]] || { echo "$DEV never appeared"; exit 1; }
systemctl --user start camera-idle-feed
echo "watching $DEV (cgroup-aware)"
IDLE=0
while sleep 1; do
    # Identify our own processes by systemd cgroup, not MainPID: the
    # bridge runs a wrapper script and the gst-launch child that actually
    # holds the device has a different PID. Excluding only MainPID made
    # the watcher count its own pipeline as a consumer, so the camera and
    # privacy LED stayed on after the real app exited.
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
chmod 755 /usr/local/bin/camera-ondemand-watch.sh.new
mv -f /usr/local/bin/camera-ondemand-watch.sh.new /usr/local/bin/camera-ondemand-watch.sh

cat > "$UHOME/.config/systemd/user/camera-ondemand.service" <<'EOF'
[Unit]
Description=Surface Laptop 2 camera on-demand watcher
After=graphical-session.target

[Service]
ExecStart=/usr/local/bin/camera-ondemand-watch.sh
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
chown -R "$U:$U" "$UHOME/.config/systemd"

userctl daemon-reload
userctl restart wireplumber pipewire 2>/dev/null
userctl enable camera-ondemand >/dev/null 2>&1
# restart, not "enable --now": an already-running watcher would otherwise
# keep executing the previous script and can be left holding the camera on
userctl stop camera-webcam-bridge 2>/dev/null
userctl restart camera-ondemand || die "watcher failed to start"
sleep 4
userctl is-active camera-idle-feed >/dev/null || die "idle feed not running"
sudo -u "$U" v4l2-ctl -d /dev/video42 --info 2>/dev/null | grep -A3 "Device Caps" | grep -q "Video Output" \
    && die "device still shows Video Output - send v4l2-ctl -d /dev/video42 --info" \
    || log "verified: capture-only caps (Chromium-compatible)"
log "done - 'Surface Camera' always visible; LED only during actual capture"
log "browsers: keep PipeWire-camera flags/prefs OFF; snap Firefox needs:"
log "    sudo snap connect firefox:camera"
