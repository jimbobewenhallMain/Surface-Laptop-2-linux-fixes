# surface-laptop2-camera-fix

Both cameras working on the Microsoft Surface Laptop 1/2 under
[linux-surface](https://github.com/linux-surface/linux-surface):

- **RGB camera (OV9734)** — a normal webcam in browsers and video-call
  apps, no flags, with the privacy LED lit only while capturing.
- **IR camera (OV7251) + IR emitter** — Windows Hello–style face unlock
  through [authFace](https://github.com/pfalkingham/authFace), including
  at the login screen.

The linux-surface Camera-Support wiki lists the OV9734 as not working,
and the IR emitter had only ever been driven on a Surface Go 2. Every
fix here was derived on real hardware (Surface Laptop 2, kernel
`6.19.8-surface-3`, Kubuntu, libcamera 0.7.0) from captured evidence —
symbol-CRC dumps, ACPI SSDB decodes, kernel oopses, coredumps, and
frame-level analysis. All of it is documented in [PATCHES.md](PATCHES.md).

## Requirements

| Requirement | Notes |
|---|---|
| Surface Laptop 1 or 2 | OV9734 RGB + OV7251 IR on the Intel IPU3 |
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

**RGB:** restart your browser and pick **"Surface Camera"**. Keep the
experimental PipeWire-camera browser flags **off** (PATCHES.md #10).

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

authFace's own installer only covers `sudo`, GDM and swaylock, so KDE
gets nothing by default. This adds `sufficient` `pam_exec` entries to
`sddm` and — on Plasma 6 — to the `kde-fingerprint` stack the lock
screen runs in parallel with the password one.

Usage: pick your user, leave the password box **empty**, press Enter.
PAM only starts when the form is submitted, so Enter is what triggers
the camera. Failure falls straight through to the password prompt.

Test it with a root TTY open (Ctrl+Alt+F3) as a safety net;
`sudo bash scripts/setup-kde-login.sh --revert` undoes everything.
Full procedure and the password-fallback guarantee: **[LOGIN-SAFETY.md](LOGIN-SAFETY.md)**.

Two limits, both inherent: **KWallet** is unlocked with your login
password, so a face login leaves it locked and it will prompt
separately; and **full-disk encryption** is unaffected, since that
prompt happens pre-boot.

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

Tabs for the IR camera (exposure, gain, emitter off-delay, rotation, and
a live test capture), the RGB camera, face-login on/off, and an
**Advanced (RGB)** tab that reads the real property list, ranges and
defaults from `gst-inspect-1.0 libcamerasrc`, cross-checks them against
what the camera actually implements (`cam --list-controls`), and offers
only the controls that genuinely change the picture. It needs a Qt
binding (`python3-pyqt6` or `python3-pyqt5`); nothing else.

The GUI only ever writes the two config files below and restarts the
affected service — it cannot touch the kernel modules, libcamera or the
loopback devices.

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

It edits two plain files, which you can also change by hand:

**`/etc/default/camera-ir`** (`sudo systemctl restart camera-ir` after)

```
IR_EXPOSURE=1200     # main brightness knob; 800≈mean 106, 1200≈mean 140
IR_VBLANK=2000
IR_GAIN=16           # 16 is the sensor minimum; raising it saturates fast
IR_ROTATE=180        # sensor is mounted inverted; 0 disables
IR_GRACE=8           # seconds sensor+emitter stay on after last use
```

**`/etc/default/camera-rgb`** (`systemctl --user restart camera-ondemand`)

```
RGB_GRACE=5          # seconds camera+privacy LED stay on after last use
RGB_CONTROLS=""      # gstlibcamerasrc properties, e.g.
                     #   ae-enable=false exposure-time=20000 analogue-gain=2.0
```

### What the IPU3 can and cannot be told to do

The IPU3 IPA implements only five algorithms — auto exposure/gain, auto
white balance (greyworld), black level, gamma and autofocus — so the
runtime-adjustable set is small:

| Adjustable at runtime | Not adjustable |
|---|---|
| `ae-enable`, `exposure-time`, `analogue-gain` | denoising / smoothing |
| frame duration limits | sharpness, demosaic tuning |
| autofocus controls (unused — no VCM here) | brightness, contrast, saturation |
| | colour gains (AWB is greyworld) |

The ImgU hardware *does* have bayer and temporal noise-reduction blocks
and a sharpening/demosaic stage, but libcamera never programs them —
upstream states this plainly in `src/ipa/ipu3/ipu3.cpp`, and they run at
the kernel driver's defaults. Exposing them is a libcamera IPA patch and
rebuild, not a setting. Gamma and black level are the same story (this
project already patches those — PATCHES.md #9).

An invalid property cannot break capture: the bridge notices the
pipeline failing within two seconds and restarts without controls.

Pick IR values with `surface-camera-ctl tune`, which sweeps exposure and
writes a PGM per step. Aim for a mean of roughly 80–160: face detection
fails on washed-out frames.

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

## Upstreaming

Several fixes are not Surface-specific. The libcamera IPU3
gamma/black-level/AGC fixes and the `abort()` in `imgu.cpp` affect every
IPU3 machine; the browsers' PipeWire-camera crash on multi-plane buffers
reproduces on any IPU3 laptop; and this is the first confirmation of the
OV7251 strobe recipe on a Surface Laptop 2
([linux-surface#739](https://github.com/linux-surface/linux-surface/issues/739)
previously had it only on a Go 2). See [PATCHES.md](PATCHES.md) for
submission-ready descriptions.

## Credits

- [tomgood18/surface-laptop-2-camera](https://github.com/tomgood18/surface-laptop-2-camera) — original groundwork
- [linux-surface](https://github.com/linux-surface) — the kernel
- [libcamera](https://libcamera.org) — IPU3 pipeline and IPA
- [pfalkingham/authFace](https://github.com/pfalkingham/authFace) — face authentication
- [linux-surface#739](https://github.com/linux-surface/linux-surface/issues/739) — the Windows strobe register dump

## License

GPL-2.0 for kernel code (`dkms/`), LGPL-2.1-or-later for the libcamera
patches, MIT for the scripts. See [LICENSE](LICENSE).
