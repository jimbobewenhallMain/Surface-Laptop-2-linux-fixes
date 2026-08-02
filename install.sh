#!/bin/bash
#
# install.sh — surface-laptop2-camera-fix
#
# Installs, over an existing linux-surface system, everything needed for a
# working browser-usable camera on the Surface Laptop 1/2 (OV9734):
#
#   stage 1  kernel modules  (DKMS: paired ipu_bridge+ipu3-cio2, fixed ov9734)
#   stage 2  boot self-healing (softdep + link/format service)
#            -> REBOOT usually required here; re-run install.sh after
#   stage 3  libcamera rebuild (OV9734 support + IPU3 fixes; 30-60 min)
#   stage 4  browser webcam    (v4l2loopback + on-demand watcher)
#
# Safe to re-run at any time: completed stages are detected and skipped.
# Coexists with / supersedes prior installs of tomgood18's
# surface-laptop-2-camera (its bridge-only DKMS package is retired).
#
set -u
TAG="install"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo; echo "[$TAG] ===== $* ====="; }
die() { echo "[$TAG] ERROR: $*"; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root: sudo bash $0"
[[ -n "${SUDO_USER:-}" ]] || die "run via sudo from your desktop user session"
uname -r | grep -q surface || echo "[$TAG] WARN: not a -surface kernel; this fix targets linux-surface"
KVER="$(uname -r)"

### stage 1: kernel modules ################################################
if dkms status 2>/dev/null | grep -q "ipu3-camera-sl2/.*$KVER.*installed" \
   && dkms status 2>/dev/null | grep -q "ov9734-surface/2.0.*$KVER.*installed"; then
    log "stage 1: kernel modules already installed - skipping"
else
    log "stage 1: building kernel modules"
    bash "$DIR/scripts/build-kernel-modules.sh" || die "stage 1 failed"
fi

### stage 2: boot self-healing #############################################
log "stage 2: boot configuration"
bash "$DIR/scripts/setup-boot.sh" || {
    echo "[$TAG] The sensor did not come up live - this is NORMAL on the"
    echo "[$TAG] first install (stale kernel state). Do this now:"
    echo "[$TAG]     1. sudo reboot"
    echo "[$TAG]     2. re-run: sudo bash $0"
    exit 0
}

### stage 3: libcamera #####################################################
if sudo -u "$SUDO_USER" cam -l 2>/dev/null | grep -q "ov9734"; then
    log "stage 3: libcamera already supports ov9734 - skipping"
else
    log "stage 3: rebuilding libcamera (30-60 min first time; laptop-safe)"
    apt-get install -y -qq libcamera-tools >/dev/null 2>&1
    bash "$DIR/scripts/build-libcamera.sh" || die "stage 3 failed"
    sudo -u "$SUDO_USER" cam -l 2>/dev/null | grep -q "ov9734" \
        || die "libcamera still does not list the camera - run: cam -l"
fi

### stage 4: browser webcam ################################################
log "stage 4: browser-facing webcam (on-demand)"
bash "$DIR/scripts/setup-webcam.sh" || die "stage 4 failed"

### stage 5: IR camera + emitter (Windows Hello style auth) ###############
log "stage 5: IR camera + emitter"
if bash "$DIR/scripts/setup-ir.sh"; then
    log "IR camera installed (/dev/video43; sensor + emitter only during capture)"
    if command -v face-enroll >/dev/null 2>&1; then
        log "authFace detected and pointed at /dev/video43. To finish:"
        log "    sudo bash $DIR/scripts/camera-ir-snapshot.sh   # check framing"
        log "    face-enroll --user \$USER"
    else
        log "authFace not installed - the IR camera is still available as"
        log "/dev/video43. For face unlock install https://github.com/pfalkingham/authFace"
        log "then re-run: sudo bash $DIR/scripts/setup-ir.sh"
    fi
else
    echo "[$TAG] WARN: IR setup failed (non-fatal - RGB camera unaffected);"
    echo "[$TAG] run separately: sudo bash $DIR/scripts/setup-ir.sh"
fi

### stage 6: ambient light sensor #########################################
log "stage 6: ambient light sensor"
if bash "$DIR/scripts/als-enable.sh"; then
    log "ALS bound (isl29018 + LSD9033 ACPI ID)"
else
    echo "[$TAG] WARN: ALS setup failed (non-fatal - cameras unaffected);"
    echo "[$TAG] diagnose: sudo bash $DIR/scripts/als-diagnose.sh"
fi

### done ###################################################################
log "INSTALL COMPLETE"
cat <<EOF
[install] Verify:    sudo bash $DIR/scripts/camera-doctor.sh --capture
[install] Browsers:  restart them fully; select 'Surface Camera'.
[install]   - keep PipeWire-camera flags/prefs DISABLED (that path crashes
[install]     on IPU3 buffers - see PATCHES.md #10)
[install]   - snap Firefox: sudo snap connect firefox:camera
[install] The sensor LED lights only while an app actually captures.
EOF
