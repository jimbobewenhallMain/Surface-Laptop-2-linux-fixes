# Every bug found, with evidence

> Jump to: [kernel](#kernel) · [libcamera](#libcamera-all-in-scriptsbuild-libcamerash)
> · [integration](#integration) · [pitfalls in this project's own design](#pitfalls-in-this-projects-own-design)

Debugged on: Surface Laptop 2, linux-surface `6.19.8-surface-3`, Kubuntu
(libcamera 0.7.0-1ubuntu2, pipewire 1.6.2). Each item lists the failure
signature, root cause, and fix — several are upstreamable beyond Surface
hardware.

## Kernel

### 1. ipu-bridge has no OVTI9734 entry *(linux-surface / upstream)*
- **Symptom**: sensor probes `-ENXIO` ("failed to check HW configuration:
  -6") — no fwnode endpoint is ever created for it.
- **Cause**: `ipu_supported_sensors[]` in
  `drivers/media/pci/intel/ipu-bridge.c` lacks OVTI9734.
- **Fix**: `IPU_SENSOR_CONFIG("OVTI9734", 1, 180000000)`. Values verified
  against the machine's ACPI SSDB (CSI-2 link 1, 1 lane, 19.2 MHz MCLK)
  and `OV9734_LINK_FREQ_180MHZ` in the sensor driver.

### 2. A rebuilt ipu_bridge always breaks the stock ipu3-cio2
- **Symptom**: `ipu3_cio2: disagrees about version of symbol
  ipu_bridge_init` — even when the bridge is rebuilt from the *exact*
  matching linux-surface source (proven byte-identical source, same
  vermagic, still mismatched CRCs).
- **Cause**: out-of-tree builds do not reproduce the distro kernel
  build's symbol CRCs on this kernel/toolchain.
- **Fix**: build `ipu_bridge` and `ipu3-cio2` together in one DKMS
  package (`dkms/../ipu3-camera-sl2` assembled by
  `scripts/build-kernel-modules.sh`); modules built in the same kbuild
  invocation agree by construction. Their remaining imports come from the
  headers' `Module.symvers` and provably match (stock cio2 loads fine).

### 3. ov9734 probe: NULL-deref oops *(surface-laptop-2-camera driver)*
- **Symptom**: `RIP: ov9734_power_on+0x17 [ov9734]` at boot, first time
  probe ever got past the hwcfg check.
- **Cause**: probe calls `ov9734_power_on()` before
  `v4l2_i2c_subdev_init()`; power_on recovers state via
  `i2c_get_clientdata()`, which subdev_init is what sets.
- **Fix**: reorder — subdev_init, then power_on (matches upstream sensor
  driver practice). In `dkms/ov9734-surface/ov9734.c`.

### 4. ov9734 probe: runtime-PM usage count underflow
- **Symptom**: `Runtime PM usage count underflow!` at probe.
- **Cause**: `pm_runtime_put()` after `pm_runtime_set_active()` —
  set_active takes no usage reference.
- **Fix**: `pm_runtime_idle()` instead (upstream pattern).

### 5. Boot ordering + no probe retry
- **Symptom**: sensor absent after clean boots; works after manual rebind.
- **Cause**: ov9734 can probe before cio2/bridge created its endpoint;
  `-ENXIO` is never retried by the kernel.
- **Fix**: `softdep ov9734 pre: ipu3_cio2` + a boot service that detects
  the missing media entity, cycles the module, then configures the
  pipeline (`scripts/setup-boot.sh`).

### 6. cio2 creates the sensor link disabled
- **Symptom**: `VIDIOC_STREAMON: Link has been severed` (-ENOLINK).
- **Cause**: `cio2_notifier_complete()` calls
  `v4l2_create_fwnode_links_to_pad(..., 0)` — flags 0 = disabled; the
  csi2 sink pad is MUST_CONNECT.
- **Fix**: enable the link (+ align pad formats to the sensor's native
  `SGRBG10 1296x734`) at boot and after rebinds. Arguably an upstream
  papercut: a MUST_CONNECT pad fed only by a link created disabled.

## libcamera (all in `scripts/build-libcamera.sh`)

### 7. No OV9734 sensor helper → IPA init fails, camera invisible
- `ERROR IPAIPU3 ipu3: Failed to create camera sensor helper for ov9734`.
- **Fix**: helper with linear gain = code/16 (driver: gain code min 16 =
  1.0x), black level 0x10@10bit.

### 8. No static properties entry → stream start aborts
- `Camera sensor does not support test pattern modes` +
  `Failed to start capture`, despite the driver having full test-pattern
  support — the mapping table lives in libcamera's properties database.
- **Fix**: properties entry (1.4 µm unit cell; Off→0, ColorBars→1).

### 9. Four generic IPU3 bugs *(affect every IPU3 machine — upstreamable)*
1. `tone_mapping.cpp`: gamma hardcoded **1.1** ("\todo") → near-linear
   output on sRGB displays = image looks badly underexposed. Fix: 2.2.
2. `blc.cpp`: black level hardcoded **64** ("rough approximation") → 4×
   too much for OV9734 (16), crushes shadows. Fix: 16.
3. `agc.cpp`: AWB **blue gain assigned to green** and vice versa in
   `Agc::process()`. Fix: swap back.
4. `imgu.cpp` `calculateBDSHeight()`: `iif.height - kIFMaxCropHeight`
   wraps below zero (unsigned), feeding `std::clamp(lo > hi)` — UB;
   Ubuntu's `_GLIBCXX_ASSERTIONS` turns it into **abort()**, killing the
   whole PipeWire daemon when its plugin probes a non-native aspect
   ratio. Fix: guard the subtraction. **This is the highest-value
   upstream fix in the repo.**

## Integration

### 10. Browsers' PipeWire camera consumers crash on IPU3 buffers
- **Symptom**: Chromium-family `video_capture` utility process and
  Firefox both SIGTRAP (CHECK failure) a few frames into capture via
  `WebRtcPipeWireCamera` / `media.webrtc.camera.allow-pipewire`.
- **Cause**: the IPU3 delivers NV12 as two memory planes; the browsers'
  experimental PipeWire camera paths mis-handle it. Upstream browser bug.
- **Workaround**: serve the camera via v4l2loopback instead and disable
  WirePlumber's libcamera monitor (`scripts/setup-webcam.sh`).

### 11b. Serving the IR camera to authFace
Getting frames was not enough; four separate faults had to be fixed
before authFace could authenticate. All are visible in
`crates/face-auth-core/src/capture.rs` and `detector.rs`:

1. **Format must be GREY.** `capture.rs` deliberately never calls
   `VIDIOC_S_FMT` (to avoid the sensor-init delay) - it queries `G_FMT`
   and then reads the buffer as one byte per pixel:
   `data.iter().map(|&b| (b as u16) * 257)`. A YUYV loopback hands it
   614400 bytes for a 640x480 frame, so the image is garbage and no face
   can ever match. The daemon publishes GREY.
2. **No idle frames.** v4l2loopback re-serves the last frame written, so
   a continuously-running black "idle feed" meant the first frame every
   app received was black - which is what enrollment was matching
   against. The daemon writes nothing while idle (one priming frame
   only, which authFace's `raw_frame_has_content` variance check skips).
3. **Producer must not use streaming buffers.** authFace calls
   `VIDIOC_REQBUFS` with **count=1**; v4l2loopback then reallocates its
   buffer pool, which pulled the mmap buffers out from under a
   GStreamer/ffmpeg producer and killed it - the preview froze after one
   frame. `v4l2-ctl` never triggered this because it requests the
   default count. The daemon now writes with plain `write()` after a
   single `VIDIOC_S_FMT`, owning no streaming buffers (also lighter: no
   subprocess, no pipes).
4. **Frames must be rotated 180 degrees.** The OV7251 is mounted
   inverted on this machine, and the slim-320 detector only detects
   upright faces - so detection failed on otherwise perfect frames.
   `IR_ROTATE=180` (default) fixes it.

Also worth knowing: `detector.rs` normalises its input to `[0,1]`, while
slim-320 expects `(x-127)/128`. Detection still works but confidence
scores run low, so exposure matters more than usual - target a frame
mean of 80-160, and `detector_threshold` around 0.3 helps.

Consumer detection is done by scanning `/proc/*/fd` (~0.5 ms) 20x/second
rather than by spawning `fuser`, which was too slow to notice a
single-frame grab and left the sensor off.

### 11a. IR camera (OV7251) + emitter for face authentication
- **Facts established on this machine**: the IR sensor works with stock
  drivers but libcamera rejects greyscale on IPU3; the cio2 driver
  natively supports its packed Y10 format (`V4L2_PIX_FMT_IPU3_Y10`); the
  IR emitter is driven by the **sensor's strobe pin** - there is no
  emitter GPIO (both INT3472 GPIOs on the IR side are clk-enable and
  power-enable; the i2c device LSD9033 @I2C3/0x44 is unrelated).
- **Emitter recipe** (verified: mean brightness 34.8 -> 249.0): apply
  the Windows strobe register dump from
  [linux-surface#739](https://github.com/linux-surface/linux-surface/issues/739)
  (`0x3005=0x08` + the `0x3b80..0x3b97` block) over raw I2C while the
  sensor streams, with long exposure/vblank so the exposure-tracking
  strobe span produces real illumination. First confirmation on a
  Surface Laptop 2 (previously only Surface Go 2).
- **Integration** (`scripts/setup-ir.sh`): raw capture -> numpy Y10
  unpacker -> ffmpeg -> v4l2loopback `/dev/video43` (GREY 640x480), as
  system services (works at the login screen for PAM). The strobe config
  is applied post-stream-start and evaporates on sensor power-down, so
  the emitter physically cannot run outside capture.

### 11. Chromium rejects V4L2 devices advertising Video Output caps
- **Symptom**: loopback invisible to Chromium regardless of state;
  visible to Firefox but stream fails (format negotiated before any
  producer attached).
- **Fix**: the OBS-virtual-camera pattern — `exclusive_caps=1` **plus a
  producer attached at all times**: black `videotestsrc` frames when
  idle (sensor/LED off, device stays capture-only and enumerable),
  swapped for the libcamera feed by a watcher while an app captures.

## Pitfalls in this project's own design

Four bugs that were introduced *by these scripts* and cost real
debugging time. Recorded because they are easy to repeat in any
service-plus-helper-script project.

### A. Overwriting a shell script while it is running
`setup-webcam.sh` rewrote `/usr/local/bin/camera-ondemand-watch.sh` in
place. bash reads a script lazily **by byte offset**, so the running
instance carried on at its old offset in the new file and executed
misaligned content — leaving the camera and its privacy LED on.
*Fix:* write to `<file>.new` and `mv` it into place; the running copy
keeps the old inode.

### B. `systemctl enable --now` does not restart a running service
Both the IR daemon and the RGB watcher were "upgraded" while the old
code kept running, so fixes appeared to have no effect (the producer was
still the previous ffmpeg process an hour later). *Fix:* explicit
`restart` after installing new code, never `enable --now`.

### C. Excluding your own processes by MainPID
The watcher decided "is anyone using the camera?" by listing holders of
`/dev/video42` and skipping the bridge service's MainPID. That held only
while `ExecStart` was the pipeline itself; wrapping it in a runner script
made MainPID the wrapper, and the `gst-launch` **child** that actually
holds the device was counted as an external consumer — so the camera
never switched off after an app closed. *Fix:* exclude by systemd
**cgroup** (`/proc/PID/cgroup` contains the service name), which is
independent of process structure.

### D. Two scripts writing the same modprobe config differently
`setup-webcam.sh` wrote a one-device `v4l2loopback` config while
`setup-ir.sh` wrote a two-device one, and the webcam script reloaded the
module unconditionally. Whichever ran last won, so running them in the
wrong order would have deleted `/dev/video43` at the next boot and
pulled the device out from under the running IR daemon. *Fix:* both
write the identical canonical config, and reload only when the live
device state is actually wrong.
