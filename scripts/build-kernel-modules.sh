#!/bin/bash
#
# build-kernel-modules.sh — install the two DKMS packages that make the
# OV9734 work on linux-surface kernels:
#
#   ipu3-camera-sl2 : ipu_bridge (+ OVTI9734 sensor entry) AND ipu3-cio2
#                     built TOGETHER. Building them in one kbuild
#                     invocation makes their symbol CRCs agree by
#                     construction - out-of-tree builds cannot reproduce
#                     the distro kernel's CRCs, so replacing ipu_bridge
#                     alone always breaks the stock ipu3-cio2
#                     ("disagrees about version of symbol ipu_bridge_init").
#
#   ov9734-surface  : the sensor driver (not shipped by linux-surface),
#                     with two fixes over the surface-laptop-2-camera
#                     original: probe-order NULL-deref oops, and a
#                     runtime-PM usage count underflow. See PATCHES.md.
#
set -uo pipefail
TAG="kernel-modules"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="ipu3-camera-sl2"; VER="1.0"
SRCDIR="/usr/src/${PKG}-${VER}"
KVER="$(uname -r)"
BASEVER=$(echo "$KVER" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
MAJMIN=$(echo "$KVER" | grep -oE '^[0-9]+\.[0-9]+')
log()  { echo "[$TAG] $*"; }
die()  { echo "[$TAG] ERROR: $*"; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"
command -v dkms >/dev/null || die "dkms not installed (apt install dkms)"
command -v curl >/dev/null || die "curl not installed"
[[ -d "/lib/modules/$KVER/build" ]] || die "kernel headers missing for $KVER"

fetch() { # fetch <dest> <relpath> - linux-surface branches, then vanilla tag
    local dest="$1" rel="$2" url
    for url in \
        "https://raw.githubusercontent.com/linux-surface/kernel/v${MAJMIN}-surface/$rel" \
        "https://raw.githubusercontent.com/linux-surface/kernel/v${MAJMIN}-surface-devel/$rel" \
        "https://raw.githubusercontent.com/torvalds/linux/v${BASEVER}/$rel"; do
        curl -fsSL --connect-timeout 15 "$url" -o "$dest" 2>/dev/null \
            && head -1 "$dest" | grep -q SPDX && { log "fetched $(basename "$dest")"; return 0; }
    done
    return 1
}

### 1. ipu3-camera-sl2: bridge + cio2 from the matching kernel source ######
mkdir -p "$SRCDIR"
fetch "$SRCDIR/ipu-bridge.c" "drivers/media/pci/intel/ipu-bridge.c" || die "download ipu-bridge.c failed"
fetch "$SRCDIR/ipu3-cio2.c"  "drivers/media/pci/intel/ipu3/ipu3-cio2.c" \
    || fetch "$SRCDIR/ipu3-cio2.c" "drivers/media/pci/intel/ipu3/ipu3-cio2-main.c" \
    || die "download ipu3-cio2.c failed"
fetch "$SRCDIR/ipu3-cio2.h"  "drivers/media/pci/intel/ipu3/ipu3-cio2.h" || die "download ipu3-cio2.h failed"

if ! grep -q 'OVTI9734' "$SRCDIR/ipu-bridge.c"; then
    # 1 lane + 180 MHz link frequency: verified against the machine's ACPI
    # SSDB and the ov9734 driver (OV9734_LINK_FREQ_180MHZ)
    sed -i '/IPU_SENSOR_CONFIG("OVTI8856"/a\	/* Omnivision OV9734 - Surface Laptop 1/2 */\n\	IPU_SENSOR_CONFIG("OVTI9734", 1, 180000000),' \
        "$SRCDIR/ipu-bridge.c"
fi
grep -q 'IPU_SENSOR_CONFIG("OVTI9734", 1, 180000000)' "$SRCDIR/ipu-bridge.c" \
    || die "OVTI9734 entry missing after patch - upstream source layout changed"

cat > "$SRCDIR/Makefile" <<'EOF'
obj-m += ipu_bridge.o
ipu_bridge-y := ipu-bridge.o
obj-m += ipu3-cio2.o

KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF
cat > "$SRCDIR/dkms.conf" <<EOF
PACKAGE_NAME="$PKG"
PACKAGE_VERSION="$VER"
AUTOINSTALL="yes"
MAKE[0]="make KDIR=/lib/modules/\${kernelver}/build"
CLEAN="make KDIR=/lib/modules/\${kernelver}/build clean"
BUILT_MODULE_NAME[0]="ipu_bridge"
DEST_MODULE_LOCATION[0]="/kernel/drivers/media/pci/intel/"
BUILT_MODULE_NAME[1]="ipu3-cio2"
DEST_MODULE_LOCATION[1]="/kernel/drivers/media/pci/intel/ipu3/"
EOF

# retire the original bridge-only package if present (its lone ipu_bridge
# is what breaks the stock cio2)
while read -r ov; do
    [[ -n "$ov" ]] && dkms remove "ipu-bridge-ov9734/$ov" --all >/dev/null 2>&1
done < <(dkms status 2>/dev/null | awk -F'[/,]' '/^ipu-bridge-ov9734\//{print $2}' | sort -u)

dkms remove "$PKG/$VER" --all >/dev/null 2>&1 || true
dkms add "$PKG/$VER" && dkms build "$PKG/$VER" -k "$KVER" && dkms install "$PKG/$VER" -k "$KVER" \
    || die "ipu3-camera-sl2 build failed - /var/lib/dkms/$PKG/$VER/build/make.log"

### 2. ov9734-surface from the repo (already patched) ######################
OSRC="/usr/src/ov9734-surface-2.0"
mkdir -p "$OSRC"
cp "$REPO_DIR/dkms/ov9734-surface/"{ov9734.c,Makefile,dkms.conf} "$OSRC/"
# retire older versions of the package
while read -r ov; do
    [[ -n "$ov" ]] && dkms remove "ov9734-surface/$ov" --all >/dev/null 2>&1
done < <(dkms status 2>/dev/null | awk -F'[/,]' '/^ov9734-surface\//{print $2}' | sort -u)
dkms add "ov9734-surface/2.0" && dkms build "ov9734-surface/2.0" -k "$KVER" \
    && dkms install "ov9734-surface/2.0" -k "$KVER" \
    || die "ov9734-surface build failed - /var/lib/dkms/ov9734-surface/2.0/build/make.log"

depmod -a
for ko in ipu_bridge ipu3-cio2 ov9734; do
    [[ -e "/lib/modules/$KVER/updates/dkms/$ko.ko" ]] || die "$ko.ko missing after install"
done
modprobe -n --show-depends ipu3_cio2 | grep -q updates/dkms \
    || die "depmod does not resolve ipu3_cio2 to the DKMS pair"
log "all three modules installed for $KVER (DKMS AUTOINSTALL covers future kernels)"
