#!/bin/bash
#
# camera-ir-snapshot.sh — grab what authFace sees, as a viewable PNG.
#
# Face detection can fail for reasons the brightness statistics cannot
# show: the sensor being mounted rotated (slim-320 will not detect an
# upside-down face), the face being out of frame, or blur. This captures
# through the app path and writes PNGs, including rotated variants, so
# the image can actually be looked at.
#
# Usage: sudo bash camera-ir-snapshot.sh
# Output: /tmp/ir-snap/  (ir.png plus rot180/flip variants)
#
set -u
TAG="ir-snap"
OUT=/tmp/ir-snap
DEV=/dev/video43
log() { echo "[$TAG] $*"; }
[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0"; exit 1; }
python3 -c "import numpy" 2>/dev/null || { echo "need python3-numpy"; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"

log "look at the camera - capturing for 5 s..."
timeout -k 3 20 v4l2-ctl -d "$DEV" --stream-mmap --stream-count=120 --stream-poll \
    --stream-to="$OUT/raw.bin" >/dev/null 2>&1
SZ=0; [[ -f "$OUT/raw.bin" ]] && SZ=$(stat -c%s "$OUT/raw.bin")
[[ "$SZ" -ge $((640*480)) ]] || { log "FAIL: captured $SZ bytes"; exit 1; }

python3 - "$OUT" <<'PYEOF'
import sys
import numpy as np
out = sys.argv[1]
FS = 640 * 480
d = open(out + "/raw.bin", "rb").read()
n = len(d) // FS
img = np.frombuffer(d[(n - 1) * FS:n * FS], dtype=np.uint8).reshape(480, 640)
print(f"    {n} frames captured; using the last")
print(f"    mean={img.mean():.1f} min={img.min()} max={img.max()} "
      f"std={img.std():.1f}")
sat = (img >= 250).mean() * 100
print(f"    saturated pixels: {sat:.1f}%  (over ~5% washes out facial detail)")

# what authFace's detector effectively receives, after its histogram
# equalisation and downscale to 320x240
try:
    from PIL import Image
    im = Image.fromarray(img, mode="L")
    im.save(out + "/ir.png")
    im.rotate(180).save(out + "/ir-rot180.png")
    im.transpose(Image.FLIP_LEFT_RIGHT).save(out + "/ir-mirrored.png")
    im.resize((320, 240)).save(out + "/ir-320x240-as-detector-sees.png")
    print(f"    wrote {out}/ir.png (+ rot180, mirrored, 320x240 variants)")
except ImportError:
    open(out + "/ir.pgm", "wb").write(b"P5\n640 480\n255\n" + img.tobytes())
    print(f"    python3-pil missing; wrote {out}/ir.pgm instead")
    print("    install with: sudo apt install python3-pil")

# crude check: is there a bright blob (a face) in the middle third?
c = img[120:360, 160:480].astype(float)
print(f"    centre region mean={c.mean():.1f} vs whole-frame {img.mean():.1f}")
if c.mean() < img.mean() * 0.9:
    print("    NOTE: centre is darker than the frame - you may be out of shot")
PYEOF

log "open $OUT/ir.png - check: is your face upright, centred, in focus,"
log "and not washed out? If it is upside-down, that alone explains why"
log "face detection fails (the model only detects upright faces)."
