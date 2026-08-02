#!/bin/bash
#
# build-libcamera.sh — rebuild the distro libcamera with OV9734 support
# and four IPU3 fixes (see PATCHES.md). All patches are exact-match and
# fail loudly if the packaged source has drifted.
#
# Laptop-safe: parallel=2 by default (-jN to override), temporary
# swapfile, memory-capped build scope, idle priority, incremental reuse.
#
set -uo pipefail
TAG="libcamera"
WORK="/usr/local/src/libcamera-ov9734"
log()  { echo "[$TAG] $*"; }
warn() { echo "[$TAG] WARN: $*"; }
die()  { echo "[$TAG] ERROR: $*"; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"
PARALLEL="${PARALLEL:-2}"
for arg in "$@"; do case "$arg" in -j*) PARALLEL="${arg#-j}" ;; esac; done

### sources + build deps ###################################################
if ! apt-get source --download-only libcamera >/dev/null 2>&1; then
    log "enabling deb-src..."
    S=/etc/apt/sources.list.d/ubuntu.sources
    [[ -f "$S" ]] && { cp "$S" "$S.bak-ov9734"; sed -i 's/^Types: deb$/Types: deb deb-src/' "$S"; }
    apt-get update -qq || die "apt update failed after enabling deb-src"
fi
log "installing build dependencies..."
apt-get install -y -qq devscripts dpkg-dev >/dev/null || die "devscripts install failed"
apt-get build-dep -y -qq libcamera >/dev/null || die "apt build-dep libcamera failed"

mkdir -p "$WORK" && cd "$WORK"
REUSE=0
SRCDIR=$(ls -d libcamera-*/ 2>/dev/null | head -1 || true)
if [[ -n "$SRCDIR" ]] && grep -q 'ov9734' "$SRCDIR/src/ipa/libipa/camera_sensor_helper.cpp" 2>/dev/null; then
    REUSE=1; log "reusing existing source tree (incremental rebuild)"
else
    rm -rf libcamera-*
    apt-get source libcamera >/dev/null || die "apt-get source libcamera failed"
    SRCDIR=$(ls -d libcamera-*/ | head -1)
fi
cd "$SRCDIR" || die "source dir missing"
log "source: $WORK/$SRCDIR"

### patches (see PATCHES.md for rationale) #################################
python3 - <<'EOF' || die "patches failed - libcamera source layout changed; see PATCHES.md"
import sys
def patch(path, old, new, done):
    src=open(path).read()
    if done in src:
        print(f"[libcamera] {path}: already patched"); return
    n=src.count(old)
    if n!=1:
        sys.stderr.write(f"{path}: pattern found {n}x, expected 1\n"); sys.exit(1)
    open(path,'w').write(src.replace(old,new))
    print(f"[libcamera] {path}: patched")

# 1. sensor gain helper (gain = code/16, from the ov9734 kernel driver)
patch("src/ipa/libipa/camera_sensor_helper.cpp",
      "class CameraSensorHelperOv13858",
      """class CameraSensorHelperOv9734 : public CameraSensorHelper
{
public:
	CameraSensorHelperOv9734()
	{
		/*
		 * From the Linux kernel driver: analogue gain code min 16
		 * = 1.0x, step 1, so gain = code / 16. Black level: 0x10
		 * at 10 bits, scaled to 16 bits.
		 */
		blackLevel_ = 1024;
		gain_ = AnalogueGainLinear{ 1, 0, 0, 16 };
	}
};
REGISTER_CAMERA_SENSOR_HELPER("ov9734", CameraSensorHelperOv9734)

class CameraSensorHelperOv13858""",
      'REGISTER_CAMERA_SENSOR_HELPER("ov9734"')

# 2. static properties (unit cell + test pattern mapping; without this the
#    IPU3 pipeline aborts stream start: "does not support test pattern modes")
patch("src/libcamera/sensor/camera_sensor_properties.cpp",
      '\t\t{ "ov13858", {',
      '''\t\t{ "ov9734", {
\t\t\t.unitCellSize = { 1400, 1400 },
\t\t\t.testPatternModes = {
\t\t\t\t{ controls::draft::TestPatternModeOff, 0 },
\t\t\t\t{ controls::draft::TestPatternModeColorBars, 1 },
\t\t\t},
\t\t\t.sensorDelays = { },
\t\t} },
\t\t{ "ov13858", {''',
      '"ov9734"')

# 3. display gamma (upstream hardcodes 1.1 -> image looks badly underexposed
#    on sRGB displays; 2.2 approximates sRGB)
patch("src/ipa/ipu3/algorithms/tone_mapping.cpp",
      "\tgamma_ = 1.1;", "\tgamma_ = 2.2;", "gamma_ = 2.2;")

# 4. black level (upstream hardcodes 64; ov9734's is 16 - 64 crushes shadows)
patch("src/ipa/ipu3/algorithms/blc.cpp",
      """	params->obgrid_param.gr = 64;
	params->obgrid_param.r = 64;
	params->obgrid_param.b = 64;
	params->obgrid_param.gb = 64;""",
      """	params->obgrid_param.gr = 16;
	params->obgrid_param.r = 16;
	params->obgrid_param.b = 16;
	params->obgrid_param.gb = 16;""",
      "obgrid_param.gr = 16;")

# 5. AGC channel swap (upstream assigns blue gain to green and vice versa)
patch("src/ipa/ipu3/algorithms/agc.cpp",
      """	rGain_ = context.activeState.awb.gains.red;
	gGain_ = context.activeState.awb.gains.blue;
	bGain_ = context.activeState.awb.gains.green;""",
      """	rGain_ = context.activeState.awb.gains.red;
	gGain_ = context.activeState.awb.gains.green;
	bGain_ = context.activeState.awb.gains.blue;""",
      "gGain_ = context.activeState.awb.gains.green;")

# 6. unsigned wrap -> std::clamp(lo>hi) -> abort() on hardened libstdc++
#    (crashed pipewire whenever it probed a non-native aspect ratio)
patch("src/libcamera/pipeline/ipu3/imgu.cpp",
      "\tunsigned int minIFHeight = iif.height - ImgUDevice::kIFMaxCropHeight;",
      """	unsigned int minIFHeight = iif.height > ImgUDevice::kIFMaxCropHeight
				 ? iif.height - ImgUDevice::kIFMaxCropHeight : 1;""",
      "iif.height > ImgUDevice::kIFMaxCropHeight")
EOF

### build (laptop-safe) ####################################################
export DEBEMAIL="sl2camfix@localhost" DEBFULLNAME="SL2 Camera Fix"
grep -q "+ov9734" debian/changelog 2>/dev/null \
    || dch --local "+ov9734" "OV9734 support + IPU3 fixes (surface-laptop2-camera-fix)." 2>/dev/null \
    || warn "dch failed - building with unchanged version"

SWAPFILE=""
if [[ $(awk '/SwapTotal/{print $2}' /proc/meminfo) -lt 2000000 ]]; then
    SWAPFILE=/swapfile-libcamera-build
    fallocate -l 4G "$SWAPFILE" && chmod 600 "$SWAPFILE" && mkswap "$SWAPFILE" >/dev/null \
        && swapon "$SWAPFILE" || { warn "swapfile failed - continuing"; SWAPFILE=""; }
fi
cleanup_swap() { [[ -n "$SWAPFILE" ]] && swapoff "$SWAPFILE" 2>/dev/null && rm -f "$SWAPFILE"; }
trap cleanup_swap EXIT

NC=""; [[ $REUSE -eq 1 ]] && NC="-nc"
build_once() {
    systemd-run --scope --same-dir -p MemoryMax=80% -p MemorySwapMax=3800M --quiet \
        env DEB_BUILD_OPTIONS="nocheck parallel=$PARALLEL" \
        nice -n 19 ionice -c 3 dpkg-buildpackage -B $NC -uc -us >"$WORK/build.log" 2>&1
}
log "building (parallel=$PARALLEL, memory-capped; 30-60 min first time)..."
if ! build_once; then
    MISSING="$(grep -oP 'dh_missing: (warning: )?\K\S+(?= exists in debian/tmp)' "$WORK/build.log" | sort -u || true)"
    if [[ -n "$MISSING" ]]; then
        log "marking $(wc -l <<<"$MISSING") unclaimed file(s) not-installed, retrying..."
        printf '%s\n' "$MISSING" >> debian/not-installed
        build_once || die "build failed again - $WORK/build.log"
    else
        die "build failed - $WORK/build.log"
    fi
fi
cleanup_swap; trap - EXIT

### install matching debs + hold ###########################################
cd "$WORK"
TO_INSTALL=()
for deb in ./*.deb; do
    pkg=$(dpkg-deb -f "$deb" Package)
    dpkg -s "$pkg" >/dev/null 2>&1 && TO_INSTALL+=("$deb")
done
[[ ${#TO_INSTALL[@]} -gt 0 ]] || die "no matching debs built"
dpkg -i "${TO_INSTALL[@]}" || die "dpkg -i failed"
for deb in "${TO_INSTALL[@]}"; do apt-mark hold "$(dpkg-deb -f "$deb" Package)" >/dev/null; done

IPADIR=/usr/share/libcamera/ipa/ipu3
[[ -f "$IPADIR/uncalibrated.yaml" && ! -f "$IPADIR/ov9734.yaml" ]] \
    && cp "$IPADIR/uncalibrated.yaml" "$IPADIR/ov9734.yaml"
log "installed and held; verify with: cam -l"
