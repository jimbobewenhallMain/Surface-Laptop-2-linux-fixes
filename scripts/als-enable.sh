#!/bin/bash
#
# als-enable.sh — bind the Surface Laptop 1/2 ambient light sensor.
#
# WHAT AND WHY
# ------------
# The sensor is an Intersil ISL29018-family part at I2C 0x44, exposed by
# firmware as \_SB_.PCI0.I2C3.ALSD with the custom ACPI HID "LSD9033".
# Linux's drivers/iio/light/isl29018.c drives exactly this chip, but its
# ACPI match table only lists ISL29018 / ISL29023 / ISL29035, so nothing
# ever binds and no IIO device appears.
#
# This builds that same driver as a DKMS module with one extra line:
#
#     {"LSD9033", isl29023},   /* Microsoft Surface Laptop 1/2 */
#
# IT MAPS TO isl29023, NOT isl29035 — deliberately. On this machine
# register 0x0F reads 0x00, so the chip has no ISL29035 device-ID
# register; the isl29035 code path checks that register and would abort
# with -ENODEV. isl29023 uses the register map this chip actually
# answers to (verified live: 918 counts in room light, 188 covered).
#
# RISK: essentially none for the rest of the system. It adds one IIO
# driver; if it fails, the light sensor simply stays unavailable. The
# cameras, kernel modules and login are untouched.
#
#   sudo bash als-enable.sh                       build, install, verify
#   sudo bash als-enable.sh --with-auto-brightness  also install iio-sensor-proxy
#   sudo bash als-enable.sh --remove              undo completely
#
set -uo pipefail
TAG="als-enable"
PKG="isl29018-lsd9033"
VER="1.0"
SRCDIR="/usr/src/${PKG}-${VER}"
KVER="$(uname -r)"
BASEVER=$(grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' <<<"$KVER")
MAJMIN=$(grep -oE '^[0-9]+\.[0-9]+' <<<"$KVER")
log()  { echo "[$TAG] $*"; }
warn() { echo "[$TAG] WARN: $*"; }
die()  { echo "[$TAG] ERROR: $*"; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root: sudo bash $0 $*"

############################################################################
if [[ "${1:-}" == "--remove" ]]; then
    modprobe -r isl29018 2>/dev/null
    while read -r v; do
        [[ -n "$v" ]] && dkms remove "$PKG/$v" --all 2>/dev/null
    done < <(dkms status 2>/dev/null | awk -F'[/,]' -v p="$PKG" '$1==p{print $2}' | sort -u)
    rm -rf "$SRCDIR"
    depmod -a
    log "removed. The in-tree isl29018 is back in charge (which simply"
    log "will not bind to LSD9033, i.e. the state you started in)."
    exit 0
fi

command -v dkms >/dev/null || die "dkms not installed"
command -v curl >/dev/null || die "curl not installed"
[[ -d "/lib/modules/$KVER/build" ]] || die "kernel headers missing for $KVER"
log "kernel $KVER"

############################################################################
log "fetching the isl29018 driver source matching this kernel"
mkdir -p "$SRCDIR"
REL="drivers/iio/light/isl29018.c"
GOT=""
for url in \
    "https://raw.githubusercontent.com/linux-surface/kernel/v${MAJMIN}-surface/$REL" \
    "https://raw.githubusercontent.com/linux-surface/kernel/v${MAJMIN}-surface-devel/$REL" \
    "https://raw.githubusercontent.com/torvalds/linux/v${BASEVER}/$REL"; do
    if curl -fsSL --connect-timeout 15 "$url" -o "$SRCDIR/isl29018.c" 2>/dev/null \
       && head -3 "$SRCDIR/isl29018.c" | grep -q SPDX; then
        GOT="$url"; break
    fi
done
[[ -n "$GOT" ]] || die "could not download $REL for kernel $KVER"
log "source: $GOT"

############################################################################
log "adding the LSD9033 ACPI ID"
python3 - "$SRCDIR/isl29018.c" <<'PYEOF' || die "patch failed - driver source layout changed"
import re, sys
p = sys.argv[1]
src = open(p).read()
if "LSD9033" in src:
    print("[als-enable] already patched")
    sys.exit(0)
m = re.search(r'(static const struct acpi_device_id isl29018_acpi_match\[\] = \{.*?)(\n\s*\{\s*\}\s*,?\s*\n\};)',
              src, re.S)
if not m:
    sys.stderr.write("acpi_device_id table not found\n"); sys.exit(1)
if "ISL29035" not in m.group(1):
    sys.stderr.write("unexpected table contents\n"); sys.exit(1)
# isl29023, NOT isl29035: this chip has no 0x0F device-ID register, and the
# isl29035 path aborts with -ENODEV when that register does not read 0x5.
entry = '\n\t{"LSD9033", isl29023},\t/* Microsoft Surface Laptop 1/2 */'
src = src[:m.end(1)] + entry + src[m.end(1):]
open(p, "w").write(src)
print("[als-enable] ACPI table patched")
PYEOF
grep -q 'LSD9033' "$SRCDIR/isl29018.c" || die "verification failed: LSD9033 not in source"

############################################################################
cat > "$SRCDIR/Makefile" <<'EOF'
obj-m := isl29018.o

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
BUILT_MODULE_NAME[0]="isl29018"
DEST_MODULE_LOCATION[0]="/kernel/drivers/iio/light/"
EOF

log "building"
dkms remove "$PKG/$VER" --all >/dev/null 2>&1 || true
dkms add "$PKG/$VER" >/dev/null || die "dkms add failed"
dkms build "$PKG/$VER" -k "$KVER" \
    || die "build failed - see /var/lib/dkms/$PKG/$VER/build/make.log"
dkms install "$PKG/$VER" -k "$KVER" --force || die "dkms install failed"
depmod -a
log "installed (AUTOINSTALL rebuilds it for future kernels)"

############################################################################
log "loading"
modprobe -r isl29018 2>/dev/null
modprobe isl29018 || die "modprobe isl29018 failed"
sleep 2

DRV=""
for c in /sys/bus/i2c/devices/i2c-LSD9033:*; do
    [[ -e "$c" ]] && DRV="$(basename "$(readlink "$c/driver" 2>/dev/null)" 2>/dev/null)"
done
if [[ "$DRV" == "isl29018" ]]; then
    log "PASS: driver bound to the sensor"
else
    warn "not bound yet (driver='${DRV:-none}'); kernel log:"
    journalctl -k -b --no-pager 2>/dev/null | grep -i isl29018 | tail -5 | sed 's/^/    /'
fi

IIO=""
for d in /sys/bus/iio/devices/iio:device*; do
    [[ -e "$d/name" ]] || continue
    grep -qiE 'isl29|LSD9033' "$d/name" 2>/dev/null && IIO="$d"
done
if [[ -n "$IIO" ]]; then
    log "PASS: IIO device $IIO ($(cat "$IIO/name"))"
    for f in "$IIO"/in_illuminance*; do
        [[ -f "$f" ]] && printf "    %-42s %s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
    done
    L="$(cat "$IIO"/in_illuminance_input 2>/dev/null || cat "$IIO"/in_illuminance_raw 2>/dev/null)"
    [[ -n "$L" ]] && log "current light reading: $L"
else
    warn "no IIO device appeared - see the kernel log above"
fi

############################################################################
if [[ "${1:-}" == "--with-auto-brightness" ]]; then
    log "installing iio-sensor-proxy for automatic screen brightness"
    apt-get install -y -qq iio-sensor-proxy >/dev/null 2>&1 \
        && systemctl enable --now iio-sensor-proxy >/dev/null 2>&1 \
        && log "iio-sensor-proxy running" \
        || warn "install failed - try: sudo apt install iio-sensor-proxy"
fi

echo
log "Test it live:   monitor-sensor        (shows lux as you cover the sensor)"
log "Raw value:      cat ${IIO:-/sys/bus/iio/devices/iio:device0}/in_illuminance_input"
log "Auto brightness in KDE: install iio-sensor-proxy, then"
log "  System Settings > Power Management > 'Adjust screen brightness'"
log "Undo everything: sudo bash $0 --remove"
