#!/bin/bash
#
# setup-boot.sh — make the camera come up on every boot without help.
#
# Two boot-time problems this solves:
#   1. module order: ov9734 must load after ipu3_cio2 (whose probe runs
#      the ipu-bridge that creates the sensor's fwnode endpoint) -> softdep
#   2. even so, the sensor can probe before the bridge finished and fail
#      with -ENXIO; the kernel never retries -> a boot service detects the
#      missing media entity, cycles the ov9734 module, then aligns pad
#      formats and enables the sensor->CSI2 link (which cio2 creates
#      DISABLED by default)
#
set -u
TAG="setup-boot"
log() { echo "[$TAG] $*"; }
die() { echo "[$TAG] ERROR: $*"; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"

cat > /etc/modprobe.d/ipu3-camera-sl2.conf <<'EOF'
# Surface Laptop 2 camera: ov9734 needs the fwnode endpoint that
# ipu_bridge (via ipu3_cio2) creates. Load order matters.
softdep ov9734 pre: ipu3_cio2
EOF

install -d /usr/local/sbin
cat > /usr/local/sbin/camera-pipeline-setup.sh <<'EOF'
#!/bin/bash
# Self-healing boot setup for the Surface Laptop 2 camera.
set -u
FMT="SGRBG10_1X10/1296x734"
say() { echo "camera-pipeline-setup: $*"; }

find_sensor() {  # sets MDEV SENSOR PORT
    for m in /dev/media*; do
        [[ -e "$m" ]] || continue
        TOPO="$(media-ctl -d "$m" -p 2>/dev/null)" || continue
        SENSOR="$(sed -n 's/^- entity [0-9]*: \(ov9734 [^ ]*\).*/\1/p' <<<"$TOPO" | head -1)"
        [[ -n "$SENSOR" ]] || continue
        PORT="$(grep -A6 ": $SENSOR " <<<"$TOPO" | sed -n 's/.*-> "ipu3-csi2 \([0-9]\)".*/\1/p' | head -1)"
        [[ -n "$PORT" ]] && MDEV="$m" && return 0
    done
    return 1
}

for attempt in 1 2 3 4 5; do
    for i in $(seq 1 10); do
        find_sensor && break 2
        sleep 1
    done
    if [[ -e /sys/bus/i2c/devices/i2c-OVTI9734:00 ]]; then
        say "attempt $attempt: sensor entity missing - cycling ov9734 module"
        modprobe -r ov9734 2>/dev/null; sleep 1; modprobe ov9734 2>/dev/null; sleep 2
    else
        say "attempt $attempt: i2c-OVTI9734:00 not present yet, waiting"; sleep 2
    fi
done
find_sensor || { say "FAILED: ov9734 entity never appeared"; exit 1; }
media-ctl -d "$MDEV" -V "\"$SENSOR\":0 [fmt:$FMT]"
media-ctl -d "$MDEV" -V "\"ipu3-csi2 $PORT\":0 [fmt:$FMT]"
media-ctl -d "$MDEV" -V "\"ipu3-csi2 $PORT\":1 [fmt:$FMT]"
media-ctl -d "$MDEV" -l "\"$SENSOR\":0 -> \"ipu3-csi2 $PORT\":0 [1]"
say "configured '$SENSOR' on csi2 port $PORT ($MDEV)"
EOF
chmod 755 /usr/local/sbin/camera-pipeline-setup.sh

cat > /etc/systemd/system/camera-pipeline-setup.service <<'EOF'
[Unit]
Description=Surface Laptop 2 camera: self-healing sensor link + formats
After=systemd-modules-load.service systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/camera-pipeline-setup.sh
RemainAfterExit=yes
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable camera-pipeline-setup.service >/dev/null 2>&1 || die "enable failed"
command -v update-initramfs >/dev/null && update-initramfs -u >/dev/null 2>&1
# disable the old project's boot workaround if present (its stale reload
# logic unloads the new module pair)
systemctl disable --now camera-driver-fixup.service >/dev/null 2>&1
log "boot service installed; applying to the live system now..."
/usr/local/sbin/camera-pipeline-setup.sh || die "live apply failed (a reboot may be needed first)"
log "done"
