#!/bin/bash
#
# camera-doctor.sh — one-shot health check of every layer. Read-only
# except an optional 5-frame raw capture. Run: sudo bash camera-doctor.sh
#
set -u
TAG="doctor"
KVER="$(uname -r)"
PASS=1
ok()   { echo "[$TAG] PASS: $*"; }
bad()  { echo "[$TAG] FAIL: $*"; PASS=0; }
info() { echo "[$TAG] $*"; }
[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0"; exit 1; }

info "kernel: $KVER"
dkms status 2>/dev/null | grep -E "ipu3-camera-sl2|ov9734-surface" | sed 's/^/    /'

LSMOD="$(lsmod)"
for m in ipu_bridge ipu3_cio2 ov9734 ipu3_imgu; do
    grep -q "^${m}[[:space:]]" <<<"$LSMOD" && ok "$m loaded" || bad "$m NOT loaded"
done
modprobe -n --show-depends ipu3_cio2 2>/dev/null | grep -q updates/dkms \
    && ok "ipu3_cio2 resolves to the DKMS pair" || bad "ipu3_cio2 resolves to stock module"

KL="$(journalctl -k -b --no-pager 2>/dev/null || dmesg)"
grep -q "Found supported sensor OVTI9734" <<<"$KL" && ok "bridge registered OVTI9734 this boot" \
    || bad "bridge did not register OVTI9734 this boot"
grep -qE "disagrees about version|Unknown symbol ipu_bridge" <<<"$KL" \
    && bad "symbol version errors present" || ok "no symbol version errors"
grep -qE "RIP:.*ov9734" <<<"$KL" && bad "ov9734 crashed this boot" || ok "no ov9734 crash"

MDEV=""; SENSOR=""; PORT=""
for m in /dev/media*; do
    [[ -e "$m" ]] || continue
    TOPO="$(media-ctl -d "$m" -p 2>/dev/null)" || continue
    S="$(sed -n 's/^- entity [0-9]*: \(ov9734 [^ ]*\).*/\1/p' <<<"$TOPO" | head -1)"
    [[ -n "$S" ]] && MDEV="$m" && SENSOR="$S" \
        && PORT="$(grep -A6 ": $S " <<<"$TOPO" | sed -n 's/.*-> "ipu3-csi2 \([0-9]\)".*/\1/p' | head -1)"
done
if [[ -n "$SENSOR" ]]; then
    ok "sensor entity '$SENSOR' on csi2 port $PORT ($MDEV)"
else
    bad "no ov9734 entity in any media graph (try: systemctl restart camera-pipeline-setup)"
fi

systemctl is-enabled camera-pipeline-setup.service >/dev/null 2>&1 \
    && ok "boot service enabled" || bad "camera-pipeline-setup.service not enabled"

if [[ -e /dev/video42 ]]; then
    CAPS="$(v4l2-ctl -d /dev/video42 --info 2>/dev/null | grep -A4 'Device Caps')"
    grep -q "Video Capture" <<<"$CAPS" && ! grep -q "Video Output" <<<"$CAPS" \
        && ok "loopback /dev/video42 capture-only (browser-compatible)" \
        || bad "loopback caps wrong (is the idle feed running? systemctl --user status camera-idle-feed)"
else
    bad "/dev/video42 missing (v4l2loopback not loaded?)"
fi

if [[ "${1:-}" == "--capture" && -n "$SENSOR" ]]; then
    info "capture test (5 raw frames)..."
    FMT="SGRBG10_1X10/1296x734"
    media-ctl -d "$MDEV" -V "\"$SENSOR\":0 [fmt:$FMT]" >/dev/null
    media-ctl -d "$MDEV" -V "\"ipu3-csi2 $PORT\":0 [fmt:$FMT]" >/dev/null
    media-ctl -d "$MDEV" -V "\"ipu3-csi2 $PORT\":1 [fmt:$FMT]" >/dev/null
    media-ctl -d "$MDEV" -l "\"$SENSOR\":0 -> \"ipu3-csi2 $PORT\":0 [1]" >/dev/null
    VDEV="$(media-ctl -d "$MDEV" -e "ipu3-cio2 $PORT")"
    F=/tmp/doctor-frames.bin; rm -f "$F"
    v4l2-ctl -d "$VDEV" --set-fmt-video=width=1296,height=734,pixelformat=ip3G >/dev/null
    timeout 20 v4l2-ctl -d "$VDEV" --stream-mmap --stream-count=5 --stream-poll --stream-to="$F"
    SZ=0; [[ -f "$F" ]] && SZ=$(stat -c%s "$F")
    [[ $SZ -gt 100000 ]] && ok "captured $SZ bytes of raw frames" || bad "capture produced $SZ bytes"
fi

echo
info "== IR camera (face authentication) =="
if [[ -e /dev/video43 ]]; then
    systemctl is-active camera-ir >/dev/null 2>&1 \
        && ok "camera-ir daemon active" || bad "camera-ir daemon not active"
    IRNAME=$(cat /sys/class/video4linux/video43/name 2>/dev/null)
    [[ "$IRNAME" == "Surface IR Camera" ]] \
        && ok "IR loopback labelled correctly" \
        || bad "IR loopback name is '$IRNAME' (expected 'Surface IR Camera')"
    IRFMT=$(v4l2-ctl -d /dev/video43 --get-fmt-video 2>/dev/null | grep -o "'[A-Z]*'" | head -1)
    [[ "$IRFMT" == "'GREY'" ]] \
        && ok "IR device reports GREY (authFace requirement)" \
        || bad "IR device reports $IRFMT, authFace needs 'GREY'"
    grep -q '^IR_ROTATE=' /etc/default/camera-ir 2>/dev/null \
        && ok "IR rotation configured ($(grep '^IR_ROTATE=' /etc/default/camera-ir))" \
        || info "    IR_ROTATE not set in /etc/default/camera-ir (defaults to 180)"
    if command -v face-auth >/dev/null; then
        ok "authFace installed"
        for f in /etc/face-auth.toml "$HOME/.config/face-auth.toml"; do
            [[ -f "$f" ]] && { grep -q video43 "$f" \
                && ok "$f points at /dev/video43" \
                || bad "$f does not select /dev/video43"; }
        done
        ls /var/lib/face-auth/*/ >/dev/null 2>&1 \
            && ok "enrolled: $(ls /var/lib/face-auth/ | tr '\n' ' ')" \
            || info "    no enrollment yet - run: face-enroll --user \$USER"
    else
        info "    authFace not installed (IR face unlock optional)"
    fi
else
    info "    /dev/video43 absent - IR support not installed"
    info "    install with: sudo bash scripts/setup-ir.sh"
fi

echo
[[ $PASS -eq 1 ]] && info "ALL CHECKS PASSED" || info "FAILURES above - include this output in bug reports"
