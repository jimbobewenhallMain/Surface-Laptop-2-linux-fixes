# surface-laptop-2-fixes

## AI Usage
This entire package was written by Claude AI after lots of back and forth on my hardware. DO NOT blindly trust this code, it works on MY hardware with MY fresh kubuntu install

## Basics

Both cameras working on the Microsoft Surface Laptop 2 under
[linux-surface](https://github.com/linux-surface/linux-surface):

- **RGB camera (OV9734)** — a normal webcam in browsers and video-call
  apps, no flags, with the privacy LED lit only while capturing.
- **IR camera (OV7251) + IR emitter** — Windows Hello–style face unlock
  through [authFace](https://github.com/pfalkingham/authFace), includes
  new harnesses for the login screen.

Every fix here was derived on real hardware Surface Laptop 2, kernel
`6.19.8-surface-3`, Kubuntu, libcamera 0.7.0 (no promises it works on anything else, this is shared as is).

## Requirements

| Requirement | Notes |
|---|---|
| Surface Laptop 2 | OV9734 RGB + OV7251 IR on the Intel IPU3 |
| [linux-surface](https://github.com/linux-surface/linux-surface) kernel | developed on 6.19.x; sources are fetched to match *your* running kernel, with vanilla fallback |
| Kernel headers, `dkms`, `curl` | `sudo apt install dkms linux-headers-$(uname -r) curl` |
| `v4l2loopback-dkms`, `v4l-utils`, `i2c-tools` | `sudo apt install v4l2loopback-dkms v4l-utils i2c-tools` |
| Ubuntu-family with `deb-src` | needed to rebuild libcamera; the installer enables it |
| **Optional:** [authFace](https://github.com/pfalkingham/authFace) | only for IR face unlock. Install it *first* — this project then points it at the IR device and tunes it |

Everything else (ffmpeg, gstreamer, python3-numpy, build deps) is
installed automatically.

## Quick start

```
sudo bash install.sh        # stages 1+2, then asks you to reboot
sudo reboot
sudo bash install.sh        # resumes: libcamera (30-60 min), webcam, IR
sudo bash scripts/camera-doctor.sh --capture
```

Re-running `install.sh` is always safe — finished stages are skipped.

### IR Setup

**IR face unlock** (needs authFace installed):

```
sudo bash scripts/camera-ir-snapshot.sh   # confirm you are upright and lit
face-enroll --user $USER
sudo -k && sudo true                      # emitter lights, no password
```

**Face login at SDDM / KDE lock screen** (optional, KDE only):

```
sudo bash scripts/setup-kde-login.sh      # verifies face auth, then patches PAM
```
### IR Info

- **Usage**: pick your user, leave the password box **empty**, press Enter. Failure falls straight through to the password prompt.
- **Safety**: Test it with a root TTY open (Ctrl+Alt+F3) as a safety net; `sudo bash scripts/setup-kde-login.sh --revert` undoes everything.
- Full procedure and the password-fallback guarantee: **[LOGIN-SAFETY.md](LOGIN-SAFETY.md)**.
- **Limitations**: KWallet is unlocked with your login password, so a face login leaves it locked and it will prompt separately; and **full-disk encryption** is unaffected.

### RGB Info

- Appears as **"Surface Camera"** in software and browsers.
- Privacy LED should function as expected.

## What gets installed

| Component | What / why |
|---|---|
| DKMS `ipu3-camera-sl2` | `ipu_bridge` (+ OVTI9734 entry) **and** `ipu3-cio2` built together so their symbol CRCs agree by construction. Replacing the bridge alone can never work — out-of-tree builds don't reproduce the distro kernel's CRCs. |
| DKMS `ov9734-surface` 2.0 | RGB sensor driver (linux-surface ships none) with two fixes over the [surface-laptop-2-camera](https://github.com/tomgood18/surface-laptop-2-camera) original: a probe-order NULL deref and a runtime-PM underflow. |
| `camera-pipeline-setup.service` | Boot self-healing: retries the sensor probe if it races the bridge, enables the sensor→CSI-2 link (cio2 creates it *disabled*), aligns pad formats. |
| Patched libcamera (held debs) | OV9734 gain helper + properties entry, plus four generic IPU3 fixes: display gamma, black level, an AWB channel swap, and an `abort()` that killed PipeWire. |
| `/dev/video42` "Surface Camera" | RGB via v4l2loopback + on-demand watcher. Idle = black frames (device stays enumerable — Chromium rejects devices advertising Video Output caps); in use = live libcamera feed. |
| `/dev/video43` "Surface IR Camera" + `camera-ir.service` | IR via a single write()-based producer. Sensor **and emitter** run only while an app holds the device; frames are rotated 180° and served as GREY, which is what authFace requires. |

## Settings

A graphical panel is installed as **Surface Camera Settings** (also in
the application menu under Settings):

```
surface-camera-settings          # GUI
surface-camera-settings --check  # report environment, change nothing
```

Everything is equally adjustable from the command line:

```
surface-camera-ctl                       # interactive menu
surface-camera-ctl status                # everything at a glance
surface-camera-ctl ir-grace 12           # emitter off-delay (seconds)
surface-camera-ctl rgb-grace 3           # privacy LED off-delay
surface-camera-ctl ir-exposure 1200      # IR brightness (main knob)
surface-camera-ctl rgb-controls "ae-enable=false exposure-time=20000"
surface-camera-ctl face-login on|off
surface-camera-ctl tune                  # IR exposure sweep
```

## Troubleshooting

```
sudo bash scripts/camera-doctor.sh --capture   # RGB + kernel pipeline
sudo bash scripts/camera-ir-diag.sh            # IR, mirrors authFace's access
sudo bash scripts/camera-ir-snapshot.sh        # writes a viewable IR PNG
journalctl -u camera-ir -b --no-pager | tail   # IR daemon decisions
```

Common cases:

- **Camera missing after a kernel update** — DKMS `AUTOINSTALL` rebuilds
  the modules; if the new kernel moved the ipu-bridge source, re-run
  `sudo bash scripts/build-kernel-modules.sh`.
- **libcamera replaced by apt** — the packages are held; if unheld,
  re-run `sudo bash scripts/build-libcamera.sh` (incremental).
- **authFace finds no face** — check `camera-ir-snapshot.sh` output: the
  face must be upright (set `IR_ROTATE`), centred, and not saturated. If
  it still fails, lower `detector_threshold` to ~0.3 in
  `~/.config/face-auth.toml`; authFace normalises detector input to
  `[0,1]` where slim-320 expects `(x-127)/128`, which depresses scores.
- **Only one app at a time** — each sensor has one consumer; `qcam` and
  a browser (or two IR consumers) cannot stream simultaneously.


## Credits

- [tomgood18/surface-laptop-2-camera](https://github.com/tomgood18/surface-laptop-2-camera) — original groundwork
- [linux-surface](https://github.com/linux-surface) — the kernel
- [libcamera](https://libcamera.org) — IPU3 pipeline and IPA
- [pfalkingham/authFace](https://github.com/pfalkingham/authFace) — face authentication
- [linux-surface#739](https://github.com/linux-surface/linux-surface/issues/739) — the Windows strobe register dump

## License

GPL-2.0 for kernel code (`dkms/`), LGPL-2.1-or-later for the libcamera
patches, MIT for the scripts. See [LICENSE](LICENSE).
