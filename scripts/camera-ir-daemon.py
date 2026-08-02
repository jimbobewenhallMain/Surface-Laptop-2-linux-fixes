#!/usr/bin/env python3
"""camera-ir-daemon — /dev/video43 producer tuned for authFace/Howdy.

DESIGN NOTES (all three learned the hard way)
---------------------------------------------
1. ONE persistent producer. Swapping producers (the old three-service
   design) tears the stream away from a consumer that has already
   negotiated buffers -> "camera detected, no feed".

2. Output must be GREY, one byte per pixel. authFace's capture.rs never
   calls VIDIOC_S_FMT - it only queries G_FMT and then treats every byte
   of the buffer as a pixel:
       data_slice.iter().map(|&b| (b as u16) * 257)
   With YUYV that reads 614400 bytes as pixels for a 640x480 frame, so
   the image is garbage and no face can ever match.

3. NO frames are written while idle. authFace captures a SINGLE frame
   (poll, 5 s default timeout) and uses whatever arrives first. If the
   device is serving black idle frames, that is what it authenticates
   against. Instead the producer stays attached (device stays
   enumerable) but writes nothing until the sensor is streaming AND the
   emitter is configured - so the first frame any app receives is a
   properly IR-lit one. A consumer simply blocks in poll() meanwhile,
   which is exactly how a real camera behaves.

Sensor + emitter therefore run only while an app holds the device, and
the whole emitter register block is written in a single i2ctransfer call
(~50 ms) so the first frame arrives well inside authFace's timeout.
"""
import fcntl
import glob
import os
import re
import signal
import struct
import subprocess
import sys
import threading
import time

import numpy as np

DEV = "/dev/video43"
W, H = 640, 480
BPLB = (W + 24) // 25
RAWFRAME = BPLB * 32 * H           # packed ip3y frame from the sensor
BLACK = bytes(W * H)
FPS = 15.0                         # authFace samples every 200 ms; 15 fps is
                                   # ample and halves the unpack CPU cost
GRACE_DEFAULT = 8.0                # covers authFace's 5 s scan window
POLL_FAST = 0.05                   # catches even a single-frame grab (~0.15 s)
POLL_SLOW = 0.20                   # after a long idle period, to save CPU
BUSY_WINDOW = 120.0                # stay on POLL_FAST for this long after use

IDX0 = [(10 * i) // 8 for i in range(25)]
SHIFT = [(10 * i) % 8 for i in range(25)]


def log(msg):
    print(f"camera-ir: {msg}", flush=True)


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def load_rotation():
    """Degrees to rotate frames. The OV7251 is mounted inverted on the
    Surface Laptop 2: captured frames are upside-down, and the face
    detector (slim-320) only detects upright faces, so this is required
    for authentication to work at all."""
    try:
        for line in open("/etc/default/camera-ir"):
            line = line.strip()
            if line.startswith("IR_ROTATE="):
                return int(line.split("=", 1)[1].split("#")[0].strip()) % 360
    except (FileNotFoundError, ValueError):
        pass
    return 180


def load_grace():
    """Seconds the sensor + emitter stay on after the last consumer."""
    try:
        for line in open("/etc/default/camera-ir"):
            line = line.strip()
            if line.startswith("IR_GRACE="):
                return max(0.5, float(line.split("=", 1)[1].split("#")[0].strip()))
    except (FileNotFoundError, ValueError):
        pass
    return GRACE_DEFAULT


def load_tuning():
    exp, vbl, gain = 1500, 2000, 256
    try:
        for line in open("/etc/default/camera-ir"):
            line = line.strip()
            if line.startswith("IR_EXPOSURE="):
                exp = int(line.split("=", 1)[1].split("#")[0].strip())
            elif line.startswith("IR_VBLANK="):
                vbl = int(line.split("=", 1)[1].split("#")[0].strip())
            elif line.startswith("IR_GAIN="):
                gain = int(line.split("=", 1)[1].split("#")[0].strip())
    except (FileNotFoundError, ValueError) as e:
        log(f"tuning unreadable ({e}); using defaults")
    return exp, vbl, gain


def find_ir():
    for m in sorted(glob.glob("/dev/media*")):
        r = sh(f"media-ctl -d {m} -p")
        if r.returncode:
            continue
        mt = re.search(r"^- entity \d+: (ov7251 [^ ]+)", r.stdout, re.M)
        if not mt:
            continue
        sensor = mt.group(1)
        blk = r.stdout[mt.start():mt.start() + 900]
        pl = re.search(r'-> "ipu3-csi2 (\d)"', blk)
        if not pl:
            continue
        port = pl.group(1)
        vdev = sh(f'media-ctl -d {m} -e "ipu3-cio2 {port}"').stdout.strip()
        sub = sh(f'media-ctl -d {m} -e "{sensor}"').stdout.strip()
        bus = sensor.split()[1].split("-")[0]
        if vdev and sub:
            return m, sensor, port, vdev, sub, bus
    return None


def configure_pipe(mdev, sensor, port, vdev):
    fmt = "Y10_1X10/640x480"
    sh(f'media-ctl -d {mdev} -V \'"{sensor}":0 [fmt:{fmt}]\'')
    sh(f'media-ctl -d {mdev} -V \'"ipu3-csi2 {port}":0 [fmt:{fmt}]\'')
    sh(f'media-ctl -d {mdev} -V \'"ipu3-csi2 {port}":1 [fmt:{fmt}]\'')
    sh(f'media-ctl -d {mdev} -l \'"{sensor}":0 -> "ipu3-csi2 {port}":0 [1]\'')
    sh(f"v4l2-ctl -d {vdev} --set-fmt-video=width=640,height=480,pixelformat=ip3y")


EMITTER_REGS = [(0x80, 0x00), (0x81, 0xAA), (0x82, 0x10), (0x83, 0x00),
                (0x84, 0x08), (0x85, 0x00), (0x86, 0x01), (0x87, 0x00),
                (0x8E, 0x05), (0x8F, 0xF2), (0x90, 0x01), (0x91, 0xB4),
                (0x92, 0x00), (0x93, 0x10), (0x94, 0x05), (0x95, 0xF2),
                (0x96, 0xC0), (0x97, 0x00)]


def apply_emitter(sub, bus):
    """Sensor must already be streaming. One i2ctransfer call (~50 ms)."""
    t0 = time.time()
    exp, vbl, gain = load_tuning()
    sh(f"v4l2-ctl -d {sub} --set-ctrl vertical_blanking={vbl}")
    sh(f"v4l2-ctl -d {sub} --set-ctrl exposure={exp}")
    sh(f"v4l2-ctl -d {sub} --set-ctrl analogue_gain={gain}")
    msgs = ["w3@0x60 0x30 0x05 0x08"]
    msgs += [f"w3@0x60 0x3b 0x{r:02x} 0x{v:02x}" for r, v in EMITTER_REGS]
    r = sh(f"i2ctransfer -f -y {bus} " + " ".join(msgs))
    if r.returncode:
        log(f"WARN: batched emitter write failed ({r.stderr.strip()}); "
            "falling back to individual writes")
        for reg, val in [(0x05, 0x08)] + EMITTER_REGS:
            page = "0x30" if reg == 0x05 else "0x3b"
            sh(f"i2ctransfer -f -y {bus} w3@0x60 {page} 0x{reg:02x} 0x{val:02x}")
    log(f"emitter configured in {time.time() - t0:.2f}s "
        f"(exp={exp} vbl={vbl} gain={gain})")


def unpack(raw, rotate=180):
    a = np.frombuffer(raw, dtype=np.uint8).reshape(H, BPLB, 32).astype(np.uint16)
    px = np.empty((H, BPLB, 25), dtype=np.uint16)
    for i in range(25):
        b0, s = IDX0[i], SHIFT[i]
        lo = a[:, :, b0]
        hi = a[:, :, b0 + 1] if b0 + 1 < 32 else 0
        px[:, :, i] = ((lo >> s) | (hi << (8 - s))) & 0x3FF
    img = (px.reshape(H, BPLB * 25)[:, :W] >> 2).astype(np.uint8)
    if rotate == 180:
        img = img[::-1, ::-1]          # sensor is mounted inverted
    return np.ascontiguousarray(img).tobytes()


class Capture:
    """Sensor capture + unpack in a thread. `ready` gates frame output."""

    def __init__(self, vdev, sub, bus):
        self.proc = subprocess.Popen(
            ["v4l2-ctl", "-d", vdev, "--stream-mmap", "--stream-poll",
             "--stream-count=0", "--stream-to=-"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.latest = None
        self.frames = 0
        self.alive = True
        self.ready = False          # True once the emitter is lit
        self.sub, self.bus = sub, bus
        self.rotate = load_rotation()
        self.t0 = time.time()
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        started = False
        seen = 0
        while self.alive:
            raw = self.proc.stdout.read(RAWFRAME)
            if len(raw) != RAWFRAME:
                break
            self.frames += 1
            if not started:
                started = True
                log(f"first sensor frame at {time.time() - self.t0:.2f}s; "
                    "configuring emitter")
                apply_emitter(self.sub, self.bus)
                self.ready = True
                log(f"serving illuminated frames at {time.time() - self.t0:.2f}s")
                continue            # skip the un-lit frame
            # The sensor runs at 30 fps; unpacking every frame costs far more
            # CPU than anything downstream needs. Drain the pipe but only
            # unpack every second frame.
            seen += 1
            if seen % 2:
                continue
            self.latest = unpack(raw, self.rotate)
        self.alive = False

    def stop(self):
        self.alive = False
        try:
            self.proc.kill()
            self.proc.wait(timeout=3)
        except Exception:
            pass


VIDIOC_S_FMT = 0xC0D05605          # _IOWR('V', 5, struct v4l2_format), 208 B
V4L2_BUF_TYPE_VIDEO_OUTPUT = 2
V4L2_FIELD_NONE = 1
V4L2_PIX_FMT_GREY = int.from_bytes(b"GREY", "little")


class DirectProducer:
    """Write frames straight into v4l2loopback with plain write().

    This replaces the GStreamer/ffmpeg producer. Those hold the device
    with streaming (mmap) buffers, and when a consumer such as
    face-auth-gtk called VIDIOC_REQBUFS with count=1 the loopback's
    buffer pool was reallocated underneath them - the producer errored
    out and the preview froze after one frame ("the camera crashes").
    A write()-based producer owns no streaming buffers, so a consumer's
    buffer negotiation cannot disturb it. It is also lighter: no extra
    process, no pipes, no format negotiation.
    """

    pid = -1                        # daemon's own fd; already excluded

    def __init__(self):
        self.fd = os.open(DEV, os.O_WRONLY)
        pix = struct.pack("<12I", W, H, V4L2_PIX_FMT_GREY, V4L2_FIELD_NONE,
                          W, W * H, 0, 0, 0, 0, 0, 0)
        fmt = bytearray(struct.pack("<I4x", V4L2_BUF_TYPE_VIDEO_OUTPUT)
                        + pix + bytes(200 - len(pix)))
        fcntl.ioctl(self.fd, VIDIOC_S_FMT, fmt)
        self.dead = False
        self.stdin = self           # keep the producer interface identical

    def write(self, data):
        os.write(self.fd, data)

    def flush(self):
        pass

    def poll(self):
        return 1 if self.dead else None

    def kill(self):
        if not self.dead:
            self.dead = True
            try:
                os.close(self.fd)
            except OSError:
                pass

    terminate = kill


def start_producer():
    """Attach a persistent GREY producer to DEV.

    Preferred path is DirectProducer (plain write()); the GStreamer and
    ffmpeg pipelines remain as fallbacks.

    GStreamer's v4l2sink is used rather than ffmpeg's v4l2 output: the RGB
    loopback serves apps correctly through v4l2sink on this machine, and
    an ffmpeg-produced loopback wedged ffmpeg-based consumers in an
    uninterruptible VIDIOC_DQBUF.
    """
    try:
        p = DirectProducer()
        p.write(BLACK)              # establishes the format for consumers
        log(f"producer: direct v4l2 write() to {DEV} (GREY {W}x{H})")
        return p
    except OSError as e:
        log(f"direct v4l2 producer unavailable ({e}); trying pipelines")

    caps = f"video/x-raw,format=GRAY8,width={W},height={H},framerate=30/1"
    candidates = [
        ["gst-launch-1.0", "-q", "fdsrc", "fd=0",
         "!", "rawvideoparse", f"width={W}", f"height={H}",
         "format=gray8", "framerate=30/1",
         "!", "v4l2sink", f"device={DEV}", "sync=false"],
        ["gst-launch-1.0", "-q", "fdsrc", "fd=0", f"blocksize={W * H}",
         "!", caps,
         "!", "v4l2sink", f"device={DEV}", "sync=false"],
        ["ffmpeg", "-loglevel", "error", "-f", "rawvideo", "-pixel_format", "gray",
         "-video_size", f"{W}x{H}", "-framerate", "30", "-i", "-",
         "-f", "v4l2", "-pix_fmt", "gray", DEV],
    ]
    for cmd in candidates:
        try:
            p = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
        except FileNotFoundError:
            continue
        ok = True
        # a short burst of black establishes the GREY format on the device;
        # after this the daemon stays silent until real frames exist
        for _ in range(10):
            if p.poll() is not None:
                ok = False
                break
            try:
                p.stdin.write(BLACK)
                p.stdin.flush()
            except (BrokenPipeError, ValueError):
                ok = False
                break
            time.sleep(1.0 / FPS)
        if ok and p.poll() is None:
            log(f"producer attached to {DEV} via {cmd[0]} (GREY {W}x{H})")
            return p
        log(f"producer candidate '{cmd[0]}' failed; trying next")
        try:
            p.kill()
        except Exception:
            pass
    return None


def consumers(exclude):
    """PIDs holding DEV open, found by scanning /proc directly.

    fuser was previously used and proved unreliable here: spawning a shell
    every poll was slow enough to miss short-lived openers entirely (a
    single-frame grab returns in ~0.15 s), so the sensor was never started
    and apps received only the stale priming frame. This is ~5 ms, needs
    no subprocess, and cannot be defeated by PATH or shell issues.
    """
    found = []
    try:
        target = os.path.realpath(DEV)
    except OSError:
        target = DEV
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) in exclude:
            continue
        fddir = f"/proc/{pid}/fd"
        try:
            for fd in os.listdir(fddir):
                try:
                    if os.readlink(f"{fddir}/{fd}") == target:
                        found.append(int(pid))
                        break
                except OSError:
                    continue
        except OSError:
            continue
    return found


def main():
    running = True

    def stop(_s, _f):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    for _ in range(30):
        if os.path.exists(DEV):
            break
        time.sleep(1)
    else:
        log(f"{DEV} never appeared")
        return 1

    prod = start_producer()
    if prod is None:
        log("ERROR: no working producer pipeline")
        return 1

    log(f"producer pid={prod.pid}, daemon pid={os.getpid()} (excluded from "
        "consumer detection)")
    cap = None
    starting = False
    last_seen = 0.0
    last_poll = 0.0
    next_frame = time.time()
    prev_consumers = []

    def start_capture():
        nonlocal cap, starting
        ir = find_ir()
        if not ir:
            log("ERROR: no ov7251 in media graph")
            starting = False
            return
        mdev, sensor, port, vdev, sub, bus = ir
        configure_pipe(mdev, sensor, port, vdev)
        cap = Capture(vdev, sub, bus)
        log(f"consumer detected -> sensor ON ({sensor} via {vdev})")
        starting = False

    def stop_capture(reason):
        nonlocal cap
        if cap:
            n = cap.frames
            cap.stop()
            cap = None
            log(f"sensor + emitter OFF ({reason}; {n} frames)")

    try:
        while running:
            now = time.time()
            # Poll fast while the camera is in recent use, slower when it has
            # been idle for a while - keeps the daemon near-zero cost at rest
            # without delaying detection when it matters.
            poll_int = POLL_FAST if (now - last_seen) < BUSY_WINDOW else POLL_SLOW
            if now - last_poll >= poll_int:
                last_poll = now
                pids = consumers({prod.pid, os.getpid()})
                if pids != prev_consumers:
                    if pids:
                        names = []
                        for p in pids:
                            try:
                                names.append(f"{p}:"
                                             f"{open(f'/proc/{p}/comm').read().strip()}")
                            except OSError:
                                names.append(str(p))
                        log(f"consumers now: {', '.join(names)}")
                    else:
                        log("consumers: none")
                    prev_consumers = pids
                have = bool(pids)
                if have:
                    last_seen = now
                    if cap is None and not starting:
                        starting = True
                        threading.Thread(target=start_capture, daemon=True).start()
                elif cap is not None and now - last_seen > load_grace():
                    stop_capture("no consumers")
                if cap is not None and not cap.alive:
                    stop_capture("capture ended")

            # Only real, illuminated frames are ever written. While idle the
            # producer stays attached but silent, so a consumer blocks in
            # poll() instead of receiving a black frame it would try to
            # authenticate against.
            # Self-healing: a dead producer used to end the daemon, leaving
            # the loopback with no writer - apps saw the stream simply stop
            # mid-preview. Restart it instead.
            if prod.poll() is not None:
                log("producer exited; restarting it")
                newp = start_producer()
                if newp is None:
                    log("producer restart failed; retrying in 2 s")
                    time.sleep(2)
                    continue
                prod = newp
                log(f"producer restarted (pid={prod.pid})")

            if cap is not None and cap.ready and cap.latest:
                try:
                    prod.stdin.write(cap.latest)
                    prod.stdin.flush()
                except (BrokenPipeError, ValueError):
                    log("producer pipe broke; will restart on next pass")
                    try:
                        prod.kill()
                    except Exception:
                        pass
                    continue
                next_frame += 1.0 / FPS
                delay = next_frame - time.time()
                time.sleep(delay if delay > 0 else 0)
                if delay <= 0:
                    next_frame = time.time()
            else:
                next_frame = time.time()
                time.sleep(0.02)
    finally:
        stop_capture("shutting down")
        try:
            prod.stdin.close()
        except Exception:
            pass
        prod.terminate()
    log("exiting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
