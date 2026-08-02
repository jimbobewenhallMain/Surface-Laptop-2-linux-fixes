#!/bin/bash
# uninstall.sh — remove everything surface-laptop2-camera-fix installed
# and return to the distro state.
set -u
TAG="uninstall"
log() { echo "[$TAG] $*"; }
[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0"; exit 1; }
U="${SUDO_USER:-}"
if [[ -n "$U" ]]; then
    UUID=$(id -u "$U")
    sudo -u "$U" XDG_RUNTIME_DIR="/run/user/$UUID" systemctl --user \
        disable --now camera-ondemand camera-webcam-bridge camera-idle-feed 2>/dev/null
    UHOME=$(getent passwd "$U" | cut -d: -f6)
    rm -f "$UHOME/.config/systemd/user/"camera-{ondemand,webcam-bridge,idle-feed}.service
fi
systemctl disable --now camera-pipeline-setup.service 2>/dev/null
systemctl disable --now camera-ir.service camera-ir-watch.service \
    camera-ir-feed.service camera-ir-idle.service 2>/dev/null
rm -f /etc/systemd/system/camera-pipeline-setup.service
rm -f /etc/systemd/system/camera-ir{,-watch,-feed,-idle}.service
rm -f /usr/local/sbin/camera-pipeline-setup.sh /usr/local/bin/camera-ondemand-watch.sh
bash "$(dirname "$0")/scripts/setup-kde-login.sh" --revert 2>/dev/null
rm -f /usr/local/bin/camera-ir-daemon.py /usr/local/bin/camera-ir-{feed,watch}.sh \
      /usr/local/bin/camera-ir-unpack.py /etc/default/camera-ir
rm -f /usr/local/bin/surface-camera-ctl /usr/local/bin/surface-camera-settings
rm -f /usr/local/bin/camera-webcam-bridge-run.sh /etc/default/camera-rgb
rm -rf /usr/local/share/surface-camera
if [[ -n "${SUDO_USER:-}" ]]; then
    rm -f "$(getent passwd "$SUDO_USER" | cut -d: -f6)/.local/share/applications/surface-camera-settings.desktop"
fi
rm -f /etc/modprobe.d/{ipu3-camera-sl2,v4l2loopback-surface}.conf
rm -f /etc/modules-load.d/v4l2loopback-surface.conf
rm -f /etc/wireplumber/wireplumber.conf.d/99-disable-libcamera.conf
systemctl daemon-reload

modprobe -r isl29018 2>/dev/null
for pv in $(dkms status 2>/dev/null | awk -F'[/,]' '/^(ipu3-camera-sl2|ov9734-surface|isl29018-lsd9033)\//{print $1"/"$2}' | sort -u); do
    log "removing DKMS $pv"
    dkms remove "$pv" --all 2>/dev/null
done
rm -rf /usr/src/ipu3-camera-sl2-* /usr/src/ov9734-surface-2.0 /usr/src/isl29018-lsd9033-*
depmod -a

log "unholding libcamera packages (apt will restore distro builds on next upgrade)"
for p in $(apt-mark showhold | grep -iE "libcamera|gstreamer1.0-libcamera"); do
    apt-mark unhold "$p" >/dev/null
done
log "to restore distro libcamera immediately:"
log "    sudo apt install --reinstall --allow-downgrades libcamera0.7 libcamera-ipa libcamera-tools"
log "done - reboot to return fully to the pre-fix state (camera will be broken again, as before)"
