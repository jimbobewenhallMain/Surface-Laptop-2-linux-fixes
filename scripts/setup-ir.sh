#!/bin/bash
#
# camera-ir-setup.sh (v2) — OV7251 IR camera as a standard V4L2 webcam
# (/dev/video43 "Surface IR Camera") WITH the IR emitter, for authFace /
# Howdy-style authentication.
#
# EMITTER: driven by the sensor's strobe pin, configured with the Windows
# register dump from linux-surface/linux-surface#739 plus long
# exposure/vblank (the strobe span tracks the exposure window - verified
# on this machine: baseline 34.8 -> 249.0 mean brightness).
# Because the config is applied to the sensor AFTER streaming starts and
# evaporates on sensor power-down, the emitter is physically incapable of
# running outside capture: off before, on during, off after.
#
# ON-DEMAND + BOOT: same pattern as the RGB camera - a black idle feed
# keeps /dev/video43 enumerable with the sensor off; a watcher swaps in
# the real feed while any app (authFace) reads the device. All SYSTEM
# services: works at the login screen, enabled at every boot.
#
# Usage:
#   sudo bash camera-ir-setup.sh           install / update everything
#   sudo bash camera-ir-setup.sh --test    one illuminated frame -> PGM
#   sudo bash camera-ir-setup.sh --tune    brightness at 5 gain levels
#
# Tuning: /etc/default/camera-ir (IR_EXPOSURE, IR_VBLANK, IR_GAIN)
#
set -u
TAG="ir-setup"
log()  { echo "[$TAG] $*"; }
warn() { echo "[$TAG] WARN: $*"; }
die()  { echo "[$TAG] ERROR: $*"; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root: sudo bash $0 $*"

find_ir() {
    MDEV=""; SENSOR=""; PORT=""; VDEV=""; SUBDEV=""; IBUS=""
    for m in /dev/media*; do
        [[ -e "$m" ]] || continue
        TOPO="$(media-ctl -d "$m" -p 2>/dev/null)" || continue
        S="$(sed -n 's/^- entity [0-9]*: \(ov7251 [^ ]*\).*/\1/p' <<<"$TOPO" | head -1)"
        [[ -n "$S" ]] || continue
        P="$(grep -A14 ": $S " <<<"$TOPO" | sed -n 's/.*-> "ipu3-csi2 \([0-9]\)".*/\1/p' | head -1)"
        [[ -n "$P" ]] || continue
        MDEV="$m"; SENSOR="$S"; PORT="$P"
        VDEV="$(media-ctl -d "$m" -e "ipu3-cio2 $P")"
        SUBDEV="$(media-ctl -d "$m" -e "$S")"
        IBUS="${S#ov7251 }"; IBUS="${IBUS%%-*}"
        return 0
    done
    return 1
}

configure_pipe() {
    local FMT="Y10_1X10/640x480"
    media-ctl -d "$MDEV" -V "\"$SENSOR\":0 [fmt:$FMT]" >/dev/null
    media-ctl -d "$MDEV" -V "\"ipu3-csi2 $PORT\":0 [fmt:$FMT]" >/dev/null
    media-ctl -d "$MDEV" -V "\"ipu3-csi2 $PORT\":1 [fmt:$FMT]" >/dev/null
    media-ctl -d "$MDEV" -l "\"$SENSOR\":0 -> \"ipu3-csi2 $PORT\":0 [1]" >/dev/null
    v4l2-ctl -d "$VDEV" --set-fmt-video=width=640,height=480,pixelformat=ip3y >/dev/null
}

apply_emitter() {  # apply_emitter <exposure> <vblank> <gain> - sensor must be streaming
    v4l2-ctl -d "$SUBDEV" --set-ctrl vertical_blanking="$2" 2>/dev/null
    v4l2-ctl -d "$SUBDEV" --set-ctrl exposure="$1" 2>/dev/null
    v4l2-ctl -d "$SUBDEV" --set-ctrl analogue_gain="$3" 2>/dev/null
    local W="i2ctransfer -f -y $IBUS w3@0x60"
    $W 0x30 0x05 0x08
    for rv in "80 00" "81 aa" "82 10" "83 00" "84 08" "85 00" "86 01" "87 00" \
              "8e 05" "8f f2" "90 01" "91 b4" "92 00" "93 10" "94 05" "95 f2" \
              "96 c0" "97 00"; do
        set -- $rv
        $W 0x3b "0x$1" "0x$2"
    done
}

mean_of() {
    python3 - "$1" "$2" <<'PYEOF'
import sys, numpy as np
W,H=640,480; BPLB=26; BPL=BPLB*32; FRAME=BPL*H
data=open(sys.argv[1],'rb').read()
if len(data) < FRAME: print(-1); sys.exit()
a=np.frombuffer(data[-FRAME:],dtype=np.uint8).reshape(H,BPLB,32).astype(np.uint16)
px=np.empty((H,BPLB,25),dtype=np.uint16)
for i in range(25):
    b0,s=(10*i)//8,(10*i)%8
    lo=a[:,:,b0]; hi=a[:,:,b0+1] if b0+1<32 else 0
    px[:,:,i]=((lo>>s)|(hi<<(8-s)))&0x3FF
img=(px.reshape(H,BPLB*25)[:,:W]>>2).astype(np.uint8)
open(sys.argv[2],'wb').write(b'P5\n640 480\n255\n'+img.tobytes())
print(f"{img.mean():.1f}")
PYEOF
}

illuminated_capture() {  # illuminated_capture <frames> <out.pgm> <exp> <vbl> <gain>
    rm -f /tmp/ir-cap.bin
    timeout 25 v4l2-ctl -d "$VDEV" --stream-mmap --stream-count="$1" --stream-poll \
        --stream-to=/tmp/ir-cap.bin >/dev/null 2>&1 &
    local SPID=$!
    sleep 0.8
    apply_emitter "$3" "$4" "$5"
    wait "$SPID" 2>/dev/null
    mean_of /tmp/ir-cap.bin "$2"
}

############################################################################
if [[ "${1:-}" == "--test" || "${1:-}" == "--tune" ]]; then
    source /etc/default/camera-ir 2>/dev/null || true
    IR_EXPOSURE="${IR_EXPOSURE:-1500}"; IR_VBLANK="${IR_VBLANK:-2000}"; IR_GAIN="${IR_GAIN:-256}"
    systemctl stop camera-ir camera-ir-feed camera-ir-idle 2>/dev/null
    find_ir || die "no ov7251 in media graph"
    log "IR: '$SENSOR' port $PORT node $VDEV (i2c bus $IBUS)"
    configure_pipe
    if [[ "${1}" == "--test" ]]; then
        M="$(illuminated_capture 60 /tmp/ir-test.pgm "$IR_EXPOSURE" "$IR_VBLANK" "$IR_GAIN")"
        log "illuminated frame mean=$M (exp=$IR_EXPOSURE vbl=$IR_VBLANK gain=$IR_GAIN)"
        log "view /tmp/ir-test.pgm - ideal for face auth: mean 80-160, face clearly lit"
    else
        # At gain 32 this machine already reads ~220 (near saturation), so
        # sweep EXPOSURE at minimum gain first - that is the effective knob.
        log "exposure sweep at gain=16 (vbl=$IR_VBLANK); target mean 80-160"
        for E in 150 300 500 800 1200 1500; do
            M="$(illuminated_capture 45 "/tmp/ir-exp$E.pgm" "$E" "$IR_VBLANK" 16)"
            log "  exposure=$E gain=16 -> mean=$M   (/tmp/ir-exp$E.pgm)"
        done
        log "gain sweep at exposure=$IR_EXPOSURE (for reference)"
        for G in 16 64 256; do
            M="$(illuminated_capture 45 "/tmp/ir-gain$G.pgm" "$IR_EXPOSURE" "$IR_VBLANK" "$G")"
            log "  exposure=$IR_EXPOSURE gain=$G -> mean=$M   (/tmp/ir-gain$G.pgm)"
        done
        log "pick the combination nearest mean 120 whose PGM shows your face"
        log "clearly, then edit /etc/default/camera-ir (IR_EXPOSURE / IR_GAIN)"
        log "and run: sudo systemctl restart camera-ir"
    fi
    systemctl start camera-ir 2>/dev/null
    exit 0
fi

############################################################################
# install
############################################################################
apt-get install -y -qq ffmpeg python3-numpy i2c-tools >/dev/null 2>&1
command -v ffmpeg >/dev/null || die "ffmpeg required"
command -v i2ctransfer >/dev/null || die "i2c-tools required"
python3 -c "import numpy" 2>/dev/null || die "python3-numpy required"

# 1. two loopback devices (42 = RGB, 43 = IR)
U="${SUDO_USER:-}"
[[ -n "$U" ]] && UUID=$(id -u "$U")
userctl() { [[ -n "$U" ]] && sudo -u "$U" XDG_RUNTIME_DIR="/run/user/$UUID" systemctl --user "$@"; }
cat > /etc/modprobe.d/v4l2loopback-surface.conf <<'EOF'
options v4l2loopback devices=2 video_nr=42,43 card_label="Surface Camera,Surface IR Camera" exclusive_caps=1,1
EOF
echo v4l2loopback > /etc/modules-load.d/v4l2loopback-surface.conf
# Reload the module when the device is missing OR when its parameters are
# stale (e.g. a previously mangled card_label). Without this check a
# re-run silently keeps the old module configuration.
NEED_RELOAD=0
[[ -e /dev/video43 ]] || NEED_RELOAD=1
CURNAME="$(cat /sys/class/video4linux/video43/name 2>/dev/null)"
[[ "$CURNAME" == "Surface IR Camera" ]] || NEED_RELOAD=1
if [[ $NEED_RELOAD -eq 1 ]]; then
    log "reloading v4l2loopback (device missing or stale label: '${CURNAME:-none}')"
    systemctl stop camera-ir 2>/dev/null            # releases /dev/video43
    userctl stop camera-ondemand camera-webcam-bridge camera-idle-feed 2>/dev/null
    sleep 1
    for d in /dev/video42 /dev/video43; do
        [[ -e "$d" ]] && fuser -k "$d" 2>/dev/null
    done
    sleep 1
    modprobe -r v4l2loopback 2>/dev/null || die "v4l2loopback busy - close all camera apps and re-run"
    modprobe v4l2loopback || die "v4l2loopback reload failed"
    udevadm settle 2>/dev/null; sleep 1
    [[ -e /dev/video43 ]] || die "/dev/video43 missing after reload"
    log "label now: '$(cat /sys/class/video4linux/video43/name 2>/dev/null)'"
    userctl start camera-ondemand 2>/dev/null
fi
log "loopback devices: /dev/video42 (RGB) + /dev/video43 (IR)"

# 2. tuning defaults (edit + restart camera-ir-watch to adjust)
[[ -f /etc/default/camera-ir ]] || cat > /etc/default/camera-ir <<'EOF'
# Surface IR camera exposure tuning (applies while the IR feed runs).
# Larger IR_GAIN = brighter; run 'camera-ir-setup.sh --tune' to choose.
IR_EXPOSURE=1200
IR_VBLANK=2000
IR_GAIN=16
# The OV7251 is mounted inverted on this machine: frames arrive upside
# down and the face detector only recognises upright faces. 0 disables.
IR_ROTATE=180
# Seconds the sensor + IR emitter stay on after the last app closes
# the device (surface-camera-ctl ir-grace <n>).
IR_GRACE=8
EOF
# make sure an existing config gains the rotation key
grep -q '^IR_ROTATE=' /etc/default/camera-ir 2>/dev/null || \
    echo 'IR_ROTATE=180' >> /etc/default/camera-ir

# 3. the daemon: ONE persistent producer, content-switched (fixes the
# producer-swap flaw that broke authFace: consumers negotiate once and
# never lose the stream; output YUYV for maximum app compatibility)
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$DIR/camera-ir-daemon.py" ]] || die "camera-ir-daemon.py not found next to this script"
install -m 755 "$DIR/camera-ir-daemon.py" /usr/local/bin/camera-ir-daemon.py
install -d /usr/local/share/surface-camera
for f in setup-kde-login.sh setup-ir.sh camera-ir-diag.sh camera-ir-snapshot.sh; do
    [[ -f "$DIR/$f" ]] && install -m 755 "$DIR/$f" /usr/local/share/surface-camera/$f
done
[[ -f "$DIR/surface-camera-ctl" ]] && install -m 755 "$DIR/surface-camera-ctl" /usr/local/bin/surface-camera-ctl \
    && log "settings tool installed: surface-camera-ctl"
# Graphical settings panel (optional; needs a Qt binding at runtime, but
# installing the file itself pulls in nothing and touches nothing else)
if [[ -f "$DIR/surface-camera-settings.py" ]]; then
    install -m 755 "$DIR/surface-camera-settings.py" /usr/local/bin/surface-camera-settings
    log "settings GUI installed: surface-camera-settings"
    if [[ -n "${SUDO_USER:-}" ]]; then
        APPD="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.local/share/applications"
        install -d -o "$SUDO_USER" -g "$SUDO_USER" "$APPD"
        cat > "$APPD/surface-camera-settings.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=Surface Camera Settings
Comment=IR and RGB camera settings for Surface Laptop
Exec=/usr/local/bin/surface-camera-settings
Icon=camera-web
Categories=Settings;HardwareSettings;Qt;
Terminal=false
DESK
        chown "$SUDO_USER:$SUDO_USER" "$APPD/surface-camera-settings.desktop"
        log "app-menu entry added (remove: rm $APPD/surface-camera-settings.desktop)"
    fi
fi

# retire the old three-service architecture
systemctl disable --now camera-ir-watch camera-ir-feed camera-ir-idle 2>/dev/null
rm -f /etc/systemd/system/camera-ir-{watch,feed,idle}.service
rm -f /usr/local/bin/camera-ir-{watch,feed}.sh /usr/local/bin/camera-ir-unpack.py

cat > /etc/systemd/system/camera-ir.service <<'UNIT'
[Unit]
Description=Surface IR camera daemon (continuous producer, on-demand sensor+emitter)
After=multi-user.target

[Service]
ExecStart=/usr/local/bin/camera-ir-daemon.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# 3b. point authFace at the device and give it a realistic timeout.
# Its capture.rs only does G_FMT (never S_FMT) and reads one byte per
# pixel, so it needs our GREY device; the default 5s timeout is tight
# while the sensor powers up, so raise it.
for CFG in /etc/face-auth.toml; do
    [[ -f "$CFG" ]] || continue
    cp -n "$CFG" "$CFG.bak-camera-ir" 2>/dev/null
    if grep -q '^device' "$CFG"; then
        sed -i 's|^device.*|device = "/dev/video43"|' "$CFG"
    else
        echo 'device = "/dev/video43"' >> "$CFG"
    fi
    if grep -q '^capture_timeout_ms' "$CFG"; then
        sed -i 's|^capture_timeout_ms.*|capture_timeout_ms = 10000|' "$CFG"
    else
        echo 'capture_timeout_ms = 10000' >> "$CFG"
    fi
    log "configured $CFG (device=/dev/video43, capture_timeout_ms=10000; backup at $CFG.bak-camera-ir)"
done
if [[ -n "${SUDO_USER:-}" ]]; then
    UCFG="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.config/face-auth.toml"
    if [[ -f "$UCFG" ]]; then
        cp -n "$UCFG" "$UCFG.bak-camera-ir" 2>/dev/null
        grep -q '^device' "$UCFG" \
            && sed -i 's|^device.*|device = "/dev/video43"|' "$UCFG" \
            || echo 'device = "/dev/video43"' >> "$UCFG"
        log "configured $UCFG (user config overrides the system one)"
    fi
fi

systemctl daemon-reload
systemctl enable camera-ir.service >/dev/null 2>&1
# restart, not "enable --now": an already-running daemon would otherwise
# keep serving from the OLD script file after an upgrade
systemctl restart camera-ir.service || die "camera-ir daemon failed to start"
sleep 4
systemctl is-active camera-ir >/dev/null || die "daemon not running: journalctl -u camera-ir -b"

# verify what the daemon actually published
PRODLINE="$(ps -o args= -C gst-launch-1.0 -C ffmpeg 2>/dev/null | grep -F /dev/video43 | head -1)"
log "producer: ${PRODLINE:-none}"
GOTFMT="$(v4l2-ctl -d /dev/video43 --get-fmt-video 2>/dev/null | grep -o "'[A-Z0-9]*'" | head -1)"
if [[ "$GOTFMT" == "'GREY'" ]]; then
    log "INSTALLED. /dev/video43 'Surface IR Camera' (GREY 640x480) - authFace-compatible"
else
    warn "device reports $GOTFMT, expected 'GREY' - authFace reads 1 byte/pixel"
    warn "check: journalctl -u camera-ir -b --no-pager | tail -20"
fi
echo
log "NEXT:"
log "  1. sanity:   sudo bash $0 --test    (view /tmp/ir-test.pgm)"
log "  2. verify:   sudo bash camera-ir-diag.sh   (must report GREY + lit frame)"
log "  3. tune:     sudo bash $0 --tune    (last --test read 220; aim ~120)"
log "  4. RE-ENROLL: face-enroll --user \$USER"
log "     (previous embeddings were captured from black/garbage frames)"
log "  5. logs:     journalctl -u camera-ir -b --no-pager | tail"
