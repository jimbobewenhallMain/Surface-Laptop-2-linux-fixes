#!/bin/bash
#
# als-diagnose.sh — is the ambient light sensor present and working?
#
# BACKGROUND
# ----------
# ACPI\LSD9033 is the "Intersil Ambient Light Sensor" fitted to the
# Surface Laptop 1/2. At I2C address 0x44 that is an ISL29035, which
# Linux supports through drivers/iio/light/isl29018.c — but that driver's
# ACPI match table only lists ISL29018/ISL29023/ISL29035, not Microsoft's
# custom LSD9033 HID. So the device is enumerated, nothing binds to it,
# and no IIO device appears.
#
# This script proves (or disproves) that theory without changing
# anything permanent:
#   * finds the ACPI device and its I2C bus/address
#   * reads the chip's Device ID register (0x0F, bits 5:3 == 0b101 for
#     ISL29035)
#   * takes two live light readings so you can see the value change
#   * puts the chip back into power-down and leaves no configuration
#
# Nothing is installed and no driver is loaded or unloaded. The only
# writes are to the sensor's own registers, which are volatile and reset
# to power-down when it loses power.
#
# Usage: sudo bash als-diagnose.sh
#
set -u
TAG="als"
ADDR=0x44
log()  { echo "[$TAG] $*"; }
warn() { echo "[$TAG] WARN: $*"; }
die()  { echo "[$TAG] ERROR: $*"; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root: sudo bash $0"
command -v i2ctransfer >/dev/null || die "need i2c-tools: sudo apt install i2c-tools"

############################################################################
echo "=== 1. ACPI device ==="
ACPI_DIR=""
for d in /sys/bus/acpi/devices/LSD9033*; do
    [[ -e "$d" ]] && ACPI_DIR="$d" && break
done
if [[ -n "$ACPI_DIR" ]]; then
    log "PASS: $(basename "$ACPI_DIR") present"
    printf "    path   : %s\n" "$(cat "$ACPI_DIR/path" 2>/dev/null)"
    printf "    status : %s  (15 = present+enabled)\n" "$(cat "$ACPI_DIR/status" 2>/dev/null)"
    if [[ -e "$ACPI_DIR/physical_node" ]]; then
        log "an I2C client was created for it"
    else
        warn "no physical_node — ACPI device present but no I2C client"
    fi
else
    warn "no LSD9033 ACPI device. Other light-sensor HIDs present?"
    ls /sys/bus/acpi/devices/ | grep -iE "als|acpi0008|apds|isl|opt3|ltr" | sed 's/^/    /' \
        || echo "    (none)"
fi

echo
echo "=== 2. driver binding ==="
CLIENT=""
for c in /sys/bus/i2c/devices/i2c-LSD9033:*; do
    [[ -e "$c" ]] && CLIENT="$c" && break
done
if [[ -n "$CLIENT" ]]; then
    DRV="$(basename "$(readlink "$CLIENT/driver" 2>/dev/null)" 2>/dev/null || echo UNBOUND)"
    log "i2c client: $(basename "$CLIENT")   driver: $DRV"
    [[ "$DRV" == "UNBOUND" ]] && warn "nothing is driving it — this is the problem"
else
    warn "no i2c-LSD9033:* client found"
fi
if modinfo isl29018 >/dev/null 2>&1; then
    log "isl29018 driver is available on this system"
    log "its ACPI IDs: $(modinfo isl29018 2>/dev/null | grep -oE 'acpi[^ ]*' | head -5 | tr '\n' ' ')"
    modinfo isl29018 2>/dev/null | grep -q "LSD9033" \
        && log "  and it already knows LSD9033" \
        || warn "  it does NOT list LSD9033 — hence no match"
else
    warn "isl29018 module not found (CONFIG_ISL29018 not built?)"
fi
lsmod | grep -qE '^isl29018' && log "module loaded" || log "module not loaded (expected: nothing to bind)"

echo
echo "=== 3. locate the chip on the I2C bus ==="
BUS=""
if [[ -n "$CLIENT" ]]; then
    P="$(readlink -f "$CLIENT")"
    BUS="$(grep -oE 'i2c-[0-9]+' <<<"$P" | tail -1 | cut -d- -f2)"
fi
if [[ -z "$BUS" ]]; then
    for b in $(ls /dev/i2c-* 2>/dev/null | grep -oE '[0-9]+$'); do
        if i2ctransfer -f -y "$b" w1@$ADDR 0x0f r1 >/dev/null 2>&1; then
            BUS="$b"; break
        fi
    done
fi
[[ -n "$BUS" ]] || die "could not find the sensor on any I2C bus"
log "using /dev/i2c-$BUS address $ADDR"

echo
echo "=== 4. chip identity (register 0x0F) ==="
ID_RAW="$(i2ctransfer -f -y "$BUS" w1@$ADDR 0x0f r1 2>/dev/null | tr -d ' \n')"
[[ -n "$ID_RAW" ]] || die "no response from $ADDR on bus $BUS (chip not present or busy)"
ID_DEC=$((ID_RAW))
DEVID=$(( (ID_DEC >> 3) & 0x7 ))
printf "    raw 0x%02x -> device-id field = %d\n" "$ID_DEC" "$DEVID"
if [[ $DEVID -eq 5 ]]; then
    log "PASS: device ID 5 = ISL29035, exactly what isl29018 drives"
else
    warn "device ID $DEVID is not ISL29035 (expected 5)"
    warn "the chip may be a different Intersil part; continuing anyway"
fi

echo
echo "=== 5. live light reading ==="
# Per Intersil AN1534: clear TEST, clear CMD1, then configure.
i2ctransfer -f -y "$BUS" w2@$ADDR 0x08 0x00 2>/dev/null   # TEST = 0
i2ctransfer -f -y "$BUS" w2@$ADDR 0x00 0x00 2>/dev/null   # power-down
sleep 0.05
i2ctransfer -f -y "$BUS" w2@$ADDR 0x01 0x00 2>/dev/null   # 16-bit, range 0 (1000 lux)

read_lux() {
    # ALS once = mode 001 -> 0x20; conversion takes ~90 ms at 16-bit
    i2ctransfer -f -y "$BUS" w2@$ADDR 0x00 0x20 2>/dev/null
    sleep 0.2
    local lsb msb
    lsb="$(i2ctransfer -f -y "$BUS" w1@$ADDR 0x02 r1 2>/dev/null | tr -d ' \n')"
    msb="$(i2ctransfer -f -y "$BUS" w1@$ADDR 0x03 r1 2>/dev/null | tr -d ' \n')"
    [[ -n "$lsb" && -n "$msb" ]] || { echo "-1 -1"; return; }
    local counts=$(( (msb << 8) | lsb ))
    # range 0 + 16-bit resolution: 0.015258 lux per count
    local lux
    lux=$(python3 -c "print(f'{$counts * 0.015258:.1f}')" 2>/dev/null || echo "?")
    echo "$counts $lux"
}

read A1 L1 <<<"$(read_lux)"
if [[ "$A1" == "-1" ]]; then
    warn "could not read the data registers"
else
    log "reading 1: $A1 counts  ≈ $L1 lux"
fi
log "now COVER the sensor (top bezel, next to the camera) for 3 seconds..."
sleep 3
read A2 L2 <<<"$(read_lux)"
[[ "$A2" == "-1" ]] || log "reading 2: $A2 counts  ≈ $L2 lux"

i2ctransfer -f -y "$BUS" w2@$ADDR 0x00 0x00 2>/dev/null   # back to power-down
log "sensor returned to power-down (as found)"

echo
if [[ "$A1" != "-1" && "$A2" != "-1" ]]; then
    DIFF=$(( A1 > A2 ? A1 - A2 : A2 - A1 ))
    if [[ $DIFF -gt 20 ]]; then
        log "VERDICT: the sensor WORKS — the readings changed by $DIFF counts."
        log "It only needs a driver bound to it."
    else
        warn "readings barely changed ($A1 vs $A2)."
        warn "Either the sensor was not covered, the lighting is very dim,"
        warn "or this is not the light sensor. Try again in a bright room."
    fi
fi

echo
echo "=== 6. userspace light-sensor plumbing ==="
ls /sys/bus/iio/devices/ 2>/dev/null | sed 's/^/    iio: /' || echo "    (no IIO devices)"
for s in iio-sensor-proxy; do
    systemctl is-active "$s" >/dev/null 2>&1 && log "$s running" \
        || log "$s not running (needed for automatic screen brightness)"
done
command -v monitor-sensor >/dev/null && log "monitor-sensor available for testing" \
    || log "install iio-sensor-proxy for desktop integration"

echo
log "If section 4 said ISL29035 and section 5 showed changing values, the"
log "fix is a one-line ACPI ID addition to the isl29018 driver."
log "Send me this output and I will build it as a DKMS module."
