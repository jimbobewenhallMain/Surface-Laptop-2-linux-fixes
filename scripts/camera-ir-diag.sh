#!/bin/bash
#
# camera-ir-diag.sh (v3) — verify /dev/video43 the way authFace uses it.
#
# v3 changes: the ffmpeg consumer test is GONE. It wedged in an
# uninterruptible VIDIOC_DQBUF, which even `timeout -k` cannot kill, and
# it told us nothing authFace cares about. Instead this checks the two
# things authFace's capture.rs actually depends on:
#   * G_FMT must report GREY (it never calls S_FMT and reads one byte
#     per pixel - YUYV produces garbage and can never match a face)
#   * the FIRST frame delivered must already be illuminated (it captures
#     a single frame and authenticates against it)
#
# Usage: sudo bash camera-ir-diag.sh
# Output: /tmp/ir-diag/report.txt + first-frame.pgm
#
set -u
TAG="ir-diag"
OUT=/tmp/ir-diag
DEV=/dev/video43
log() { echo "[$TAG] $*"; }
[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0"; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"
exec > >(tee "$OUT/report.txt") 2>&1
TMO() { timeout -k 3 "$@"; }
PASS=1

echo "=== 1. DAEMON ==="
systemctl is-active camera-ir >/dev/null 2>&1 \
    && log "PASS: camera-ir active" \
    || { log "FAIL: camera-ir not active (sudo bash camera-ir-setup.sh)"; PASS=0; }
log "producer process:"
ps -o pid=,args= -C gst-launch-1.0 -C ffmpeg 2>/dev/null | grep -F "$DEV" | sed 's/^/    /' \
    || log "    (no producer holding $DEV - daemon may have failed)"
for s in camera-ir-watch camera-ir-feed camera-ir-idle; do
    systemctl is-enabled "$s" >/dev/null 2>&1 && log "WARN: obsolete $s still enabled"
done

echo
echo "=== 2. FORMAT (authFace reads G_FMT and never sets it) ==="
[[ -e "$DEV" ]] || { log "FAIL: $DEV missing"; exit 1; }
NAME=$(cat /sys/class/video4linux/"$(basename $DEV)"/name 2>/dev/null)
log "device name: '$NAME'"
grep -qi "ir\|infrared" <<<"$NAME" \
    && log "PASS: name matches authFace's IR auto-detection (contains 'ir')" \
    || log "WARN: name has no 'ir' - authFace auto-detect will skip it (set device= in config)"
FMT="$(TMO 10 v4l2-ctl -d "$DEV" --get-fmt-video 2>&1)"
echo "$FMT" | sed 's/^/    /'
if grep -q "'GREY'" <<<"$FMT"; then
    log "PASS: device reports GREY - one byte per pixel, what authFace needs"
else
    log "FAIL: device is NOT GREY. authFace will read the buffer as 1 byte/pixel"
    log "      and get garbage. Re-run camera-ir-setup.sh with the current daemon."
    PASS=0
fi

echo
echo "=== 3. SCAN-WINDOW CAPTURE (mirrors authFace's 5s scan) ==="
# authFace does not grab one frame and give up: it scans for
# scan_duration_ms (5s default), re-capturing every scan_interval_ms.
# A single grab only ever returns the stale priming frame, so hold the
# device the way a real authentication does and watch the frames change.
log "holding $DEV for ~5s (emitter should light within ~2s)..."
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
rm -f "$OUT/scan.raw"
TMO 25 v4l2-ctl -d "$DEV" --stream-mmap --stream-count=150 --stream-poll \
    --stream-to="$OUT/scan.raw" >"$OUT/scan.log" 2>&1
RC=$?
SZ=0; [[ -f "$OUT/scan.raw" ]] && SZ=$(stat -c%s "$OUT/scan.raw")
log "exit=$RC  bytes=$SZ  frames=$((SZ / (640*480)))"
sed 's/^/    /' "$OUT/scan.log" 2>/dev/null | head -4
if [[ "$SZ" -ge $((640*480)) ]]; then
    python3 - "$OUT" <<'PYEOF'
import sys
import numpy as np
out = sys.argv[1]
FS = 640*480
d = open(out + "/scan.raw", "rb").read()
n = len(d)//FS
means = []
for i in range(n):
    means.append(np.frombuffer(d[i*FS:(i+1)*FS], dtype=np.uint8).mean())
print(f"    {n} frames; brightness over the scan window:")
step = max(1, n//10)
for i in range(0, n, step):
    print(f"      frame {i:3d}: mean={means[i]:6.1f}")
last = np.frombuffer(d[(n-1)*FS:n*FS], dtype=np.uint8).reshape(480, 640)
open(out + "/last-frame.pgm", "wb").write(b"P5\n640 480\n255\n" + last.tobytes())
lit = [i for i, m in enumerate(means) if m > 20]
print()
if not lit:
    print("    VERDICT: ALL FRAMES BLACK - the daemon never started the sensor.")
    print("             Check section 4: is there a 'consumers now:' line?")
else:
    print(f"    frames went live at frame {lit[0]} (~{lit[0]/30:.1f}s in)")
    m = means[-1]
    if m > 230:
        print(f"    VERDICT: ILLUMINATED but SATURATED (mean {m:.0f}) -")
        print("             lower IR_EXPOSURE in /etc/default/camera-ir")
    else:
        print(f"    VERDICT: WORKING - final frame mean {m:.0f}, view last-frame.pgm")
PYEOF
else
    log "FAIL: no usable capture ($SZ bytes)"
    PASS=0
fi

echo
echo "=== 4. DAEMON LOG ==="
echo "    --- during the capture above ---"
journalctl -u camera-ir --since "$SINCE" --no-pager 2>/dev/null | sed 's/^/    /'
echo "    --- last 15 lines this boot ---"
journalctl -u camera-ir -b --no-pager 2>/dev/null | tail -15 | sed 's/^/    /'
journalctl -u camera-ir --since "$SINCE" --no-pager 2>/dev/null | grep -q "consumers now" \
    || { log "FAIL: daemon never logged a consumer - detection is broken"; PASS=0; }

echo
echo "=== 5. AUTHFACE CONFIG ==="
for f in /etc/face-auth.toml ~/.config/face-auth.toml \
         "$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)/.config/face-auth.toml"; do
    [[ -f "$f" ]] || continue
    echo "    --- $f ---"; sed 's/^/    /' "$f"
    grep -q 'video43' "$f" && log "PASS: $f points at $DEV" \
        || log "WARN: $f does not select $DEV"
done
ls /var/lib/face-auth/*/ >/dev/null 2>&1 \
    && log "enrolled users: $(ls /var/lib/face-auth/ | tr '\n' ' ')" \
    || log "WARN: no enrollments found in /var/lib/face-auth (run face-enroll)"

echo
echo "=== 6. LIVE face-auth TEST ==="
if command -v face-auth >/dev/null && [[ -n "${SUDO_USER:-}" ]]; then
    log "running face-auth with debug logging (look at the camera)..."
    TMO 25 env PAM_USER="$SUDO_USER" USER="$SUDO_USER" \
        HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)" \
        RUST_LOG=face_auth_core=debug face-auth 2>&1 | tail -25 | sed 's/^/    /'
    log "face-auth exit: ${PIPESTATUS[0]} (0 = authenticated)"
else
    log "face-auth not installed or SUDO_USER unset - skipping"
fi

echo
[[ $PASS -eq 1 ]] && log "ALL CHECKS PASSED" || log "FAILURES above"
log "report: $OUT/report.txt   frame: $OUT/first-frame.pgm"
