#!/usr/bin/env python3
"""Surface Camera Settings — a small Qt panel for the two config files.

STANDALONE AND NON-INVASIVE BY DESIGN
--------------------------------------
This installs nothing and rebuilds nothing. It only ever:
  * reads  /etc/default/camera-ir and /etc/default/camera-rgb
  * writes those two files (via pkexec, one graphical password prompt)
  * restarts camera-ir / camera-ondemand after a change you apply
  * optionally calls the existing setup-kde-login.sh --on/--off/--status

Nothing here can alter the kernel modules, libcamera, the loopback
devices or the services themselves, so it cannot break a working setup.
If a control is missing on your system the tab is simply disabled.

Usage:
    python3 surface-camera-settings.py              launch the GUI
    python3 surface-camera-settings.py --check      report environment only
    python3 surface-camera-settings.py --install-launcher
                                                    add it to the app menu
                                                    (a single file in
                                                    ~/.local/share/applications)
"""
import os
import shutil
import subprocess
import sys

IR_CONF = "/etc/default/camera-ir"
RGB_CONF = "/etc/default/camera-rgb"
LOGIN_CANDIDATES = [
    "/usr/local/share/surface-camera/setup-kde-login.sh",
    os.path.expanduser("~/Documents/camera fix/surface-laptop2-camera-fix/"
                       "scripts/setup-kde-login.sh"),
]
SNAP_CANDIDATES = [
    "/usr/local/share/surface-camera/camera-ir-snapshot.sh",
    os.path.expanduser("~/Documents/camera fix/surface-laptop2-camera-fix/"
                       "scripts/camera-ir-snapshot.sh"),
]

IR_DEFAULTS = {"IR_EXPOSURE": 1200, "IR_GAIN": 16, "IR_ROTATE": 180,
               "IR_GRACE": 8, "IR_VBLANK": 2000}
RGB_DEFAULTS = {"RGB_GRACE": 5, "RGB_CONTROLS": ""}


# --------------------------------------------------------------------- utils
def first_existing(paths):
    for p in paths:
        if os.path.isfile(p):
            return p
    return None


def read_conf(path, defaults):
    """Parse a shell-style key=value file. Missing keys fall back."""
    vals = dict(defaults)
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                if k not in vals:
                    continue
                v = v.split("#")[0].strip().strip('"').strip("'")
                if isinstance(defaults.get(k), int):
                    try:
                        vals[k] = int(v)
                    except ValueError:
                        pass
                else:
                    vals[k] = v
    except OSError:
        pass
    return vals


def render_conf(path, defaults, newvals):
    """Return the file's text with newvals applied, comments preserved."""
    try:
        lines = open(path).read().splitlines()
    except OSError:
        lines = []
    seen = set()
    out = []
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            k = stripped.split("=", 1)[0].strip()
            if k in newvals:
                val = newvals[k]
                out.append(f'{k}={val}' if not isinstance(val, str)
                           else f'{k}="{val}"')
                seen.add(k)
                continue
        out.append(line)
    for k, val in newvals.items():
        if k not in seen:
            out.append(f'{k}={val}' if not isinstance(val, str)
                       else f'{k}="{val}"')
    return "\n".join(out) + "\n"


def apply_as_root(path, text, restart_cmd):
    """One pkexec prompt: write the file, then restart the service."""
    tmp = f"/tmp/.surface-camera-{os.path.basename(path)}.{os.getpid()}"
    with open(tmp, "w") as fh:
        fh.write(text)
    script = f'cp "$1" "{path}" && chmod 644 "{path}" && {restart_cmd}'
    try:
        r = subprocess.run(["pkexec", "/bin/sh", "-c", script, "sh", tmp],
                           capture_output=True, text=True, timeout=120)
        return r.returncode == 0, (r.stderr or r.stdout).strip()
    except FileNotFoundError:
        return False, "pkexec not found (install policykit-1)"
    except subprocess.TimeoutExpired:
        return False, "timed out waiting for authentication"
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def parse_gst_props(text):
    """Parse `gst-inspect-1.0 libcamerasrc` into structured property info.

    Returns a list of dicts: name, desc, kind, min, max, default, enum.
    Ranges and defaults come from the element itself, so nothing here is
    guessed.
    """
    props = []
    cur = None
    for raw in text.splitlines():
        if raw.startswith("  ") and not raw.startswith("    ") and ":" in raw:
            head = raw.strip()
            name = head.split(":", 1)[0].strip()
            if not name or " " in name:
                continue
            cur = {"name": name, "desc": head.split(":", 1)[1].strip(),
                   "kind": None, "min": None, "max": None,
                   "default": None, "enum": []}
            props.append(cur)
            continue
        if cur is None or not raw.strip():
            continue
        s = raw.strip()
        low = s.lower()

        def _num(tok):
            try:
                return float(tok.replace(",", ""))
            except ValueError:
                return None

        if low.startswith("boolean."):
            cur["kind"] = "bool"
            cur["default"] = "true" in low.split("default:")[-1]
        elif low.startswith(("integer.", "unsigned integer.", "integer64.",
                             "unsigned integer64.", "float.", "double.")):
            cur["kind"] = "float" if low.startswith(("float.", "double.")) else "int"
            if "range:" in low:
                rng = s.split("Range:", 1)[1] if "Range:" in s else ""
                rng = rng.split("Default:")[0].strip()
                # values may be negative and the separator is also '-', so
                # split on ' - ' with surrounding spaces, which gst always emits
                halves = [h.strip() for h in rng.split(" - ") if h.strip()]
                nums = [_num(h) for h in halves]
                nums = [n for n in nums if n is not None]
                if len(nums) >= 2:
                    cur["min"], cur["max"] = nums[0], nums[1]
            if "default:" in low:
                d = _num(s.split("Default:", 1)[1].strip().split()[0]
                         if s.split("Default:", 1)[1].strip() else "")
                cur["default"] = d
        elif low.startswith("enum"):
            cur["kind"] = "enum"
            if "default:" in low:
                tail = s.split("Default:", 1)[1].strip()
                cur["default"] = _num(tail.split(",")[0].strip())
        elif low.startswith("string."):
            cur["kind"] = "str"
            if "default:" in low:
                cur["default"] = s.split("Default:", 1)[1].strip().strip('"')
        elif s.startswith("(") and ")" in s and cur.get("kind") == "enum":
            try:
                val = int(s[1:s.index(")")])
                label = s[s.index(")") + 1:].lstrip(": ").strip()
                cur["enum"].append((val, label))
            except ValueError:
                pass
    return [p for p in props if p["kind"]]


def camera_supported_controls(timeout=25):
    """Controls this camera really implements, as kebab-case names.

    Asks libcamera itself (`cam --list-controls`); anything absent here is
    ignored by the pipeline even if the GStreamer element accepts it.
    Returns None if it could not be determined (e.g. camera busy).
    """
    if not shutil.which("cam"):
        return None
    try:
        r = subprocess.run(["cam", "-c", "1", "--list-controls"],
                           capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None
    names = set()
    for line in (r.stdout + r.stderr).splitlines():
        if "Control:" not in line:
            continue
        part = line.split("Control:", 1)[1].strip()
        part = part.lstrip("[rw] ").split(":")[0].strip()
        part = part.split()[-1] if part else ""
        if not part or not part[0].isalpha():
            continue
        kebab = ""
        for i, ch in enumerate(part):
            if ch.isupper() and i:
                kebab += "-"
            kebab += ch.lower()
        names.add(kebab)
    return names or None


def svc_active(unit, user=False):
    cmd = ["systemctl"] + (["--user"] if user else []) + ["is-active", unit]
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=5).stdout.strip() == "active"
    except Exception:
        return False


def environment_report():
    login_sh = first_existing(LOGIN_CANDIDATES)
    return {
        "IR config": IR_CONF if os.path.exists(IR_CONF) else "MISSING",
        "RGB config": RGB_CONF if os.path.exists(RGB_CONF) else "MISSING",
        "IR device": "/dev/video43" if os.path.exists("/dev/video43") else "absent",
        "RGB device": "/dev/video42" if os.path.exists("/dev/video42") else "absent",
        "camera-ir": "running" if svc_active("camera-ir") else "stopped",
        "camera-ondemand": "running" if svc_active("camera-ondemand", user=True) else "stopped",
        "face login script": login_sh or "not found",
        "pkexec": shutil.which("pkexec") or "MISSING",
    }


# ------------------------------------------------------------------ Qt shim
def load_qt():
    for mod in ("PyQt6", "PySide6", "PyQt5", "PySide2"):
        try:
            if mod == "PyQt6":
                from PyQt6 import QtWidgets, QtCore, QtGui
            elif mod == "PySide6":
                from PySide6 import QtWidgets, QtCore, QtGui
            elif mod == "PyQt5":
                from PyQt5 import QtWidgets, QtCore, QtGui
            else:
                from PySide2 import QtWidgets, QtCore, QtGui
            return mod, QtWidgets, QtCore, QtGui
        except ImportError:
            continue
    return None, None, None, None


def build_gui(mod, QtWidgets, QtCore, QtGui):
    Qt = QtCore.Qt
    HORIZ = getattr(Qt, "Horizontal", None) or Qt.Orientation.Horizontal

    class Panel(QtWidgets.QWidget):
        def __init__(self):
            super().__init__()
            self.setWindowTitle("Surface Camera Settings")
            self.resize(560, 430)
            self.ir = read_conf(IR_CONF, IR_DEFAULTS)
            self.rgb = read_conf(RGB_CONF, RGB_DEFAULTS)
            self.login_sh = first_existing(LOGIN_CANDIDATES)

            self.adv_widgets = {}       # name -> (override_cb, getter)
            tabs = QtWidgets.QTabWidget()
            tabs.addTab(self._ir_tab(), "IR camera")
            tabs.addTab(self._rgb_tab(), "RGB camera")
            tabs.addTab(self._adv_tab(), "Advanced (RGB)")
            tabs.addTab(self._login_tab(), "Face login")
            tabs.addTab(self._status_tab(), "Status")

            self.msg = QtWidgets.QLabel("")
            self.msg.setWordWrap(True)
            lay = QtWidgets.QVBoxLayout(self)
            lay.addWidget(tabs)
            lay.addWidget(self.msg)

        # -- helpers
        def _slider(self, lo, hi, val, suffix="", step=1):
            row = QtWidgets.QHBoxLayout()
            s = QtWidgets.QSlider(HORIZ)
            s.setMinimum(lo)
            s.setMaximum(hi)
            s.setSingleStep(step)
            s.setValue(int(val))
            lab = QtWidgets.QLabel(f"{int(val)}{suffix}")
            lab.setMinimumWidth(70)
            s.valueChanged.connect(lambda v: lab.setText(f"{v}{suffix}"))
            row.addWidget(s)
            row.addWidget(lab)
            return row, s

        def _note(self, text):
            lab = QtWidgets.QLabel(text)
            lab.setWordWrap(True)
            f = lab.font()
            f.setPointSize(max(7, f.pointSize() - 1))
            lab.setFont(f)
            return lab

        def flash(self, text, ok=True):
            self.msg.setText(("✓ " if ok else "✗ ") + text)

        # -- IR
        def _ir_tab(self):
            w = QtWidgets.QWidget()
            form = QtWidgets.QFormLayout(w)
            r1, self.s_exp = self._slider(150, 1704, self.ir["IR_EXPOSURE"])
            r2, self.s_gain = self._slider(16, 1023, self.ir["IR_GAIN"])
            r3, self.s_grace = self._slider(1, 60, self.ir["IR_GRACE"], " s")
            form.addRow("Exposure (brightness)", self._wrap(r1))
            form.addRow("Analogue gain", self._wrap(r2))
            form.addRow("Emitter off delay", self._wrap(r3))
            self.c_rot = QtWidgets.QCheckBox("Rotate image 180° (required on this laptop)")
            self.c_rot.setChecked(int(self.ir["IR_ROTATE"]) == 180)
            form.addRow("", self.c_rot)
            form.addRow("", self._note(
                "Exposure is the main knob; aim for a frame mean of 80–160. "
                "Gain saturates quickly above ~32. Changes restart the IR "
                "daemon only — the camera itself is untouched."))
            btns = QtWidgets.QHBoxLayout()
            b_apply = QtWidgets.QPushButton("Apply IR settings")
            b_apply.clicked.connect(self.apply_ir)
            b_snap = QtWidgets.QPushButton("Capture test frame")
            b_snap.clicked.connect(self.snapshot)
            b_snap.setEnabled(bool(first_existing(SNAP_CANDIDATES)))
            btns.addWidget(b_apply)
            btns.addWidget(b_snap)
            form.addRow("", self._wrap(btns))
            return w

        def _wrap(self, layout):
            box = QtWidgets.QWidget()
            box.setLayout(layout)
            return box

        def apply_ir(self):
            vals = {
                "IR_EXPOSURE": self.s_exp.value(),
                "IR_GAIN": self.s_gain.value(),
                "IR_GRACE": self.s_grace.value(),
                "IR_ROTATE": 180 if self.c_rot.isChecked() else 0,
            }
            text = render_conf(IR_CONF, IR_DEFAULTS, vals)
            ok, err = apply_as_root(IR_CONF, text, "systemctl restart camera-ir")
            self.flash("IR settings applied" if ok else f"failed: {err}", ok)

        def snapshot(self):
            snap = first_existing(SNAP_CANDIDATES)
            self.flash("capturing… look at the camera")
            QtWidgets.QApplication.processEvents()
            try:
                subprocess.run(["pkexec", "/bin/bash", snap],
                               capture_output=True, timeout=90)
            except Exception as e:
                self.flash(f"capture failed: {e}", False)
                return
            png = "/tmp/ir-snap/ir.png"
            if os.path.exists(png):
                dlg = QtWidgets.QDialog(self)
                dlg.setWindowTitle("IR test frame")
                v = QtWidgets.QVBoxLayout(dlg)
                lab = QtWidgets.QLabel()
                lab.setPixmap(QtGui.QPixmap(png))
                v.addWidget(lab)
                dlg.exec() if hasattr(dlg, "exec") else dlg.exec_()
                self.flash("captured /tmp/ir-snap/ir.png")
            else:
                self.flash("no frame produced — see /tmp/ir-snap/", False)

        # -- RGB
        def _rgb_tab(self):
            w = QtWidgets.QWidget()
            form = QtWidgets.QFormLayout(w)
            r1, self.s_rgb_grace = self._slider(1, 60, self.rgb["RGB_GRACE"], " s")
            form.addRow("Privacy LED off delay", self._wrap(r1))

            ctl = self.rgb["RGB_CONTROLS"]
            self.c_ae = QtWidgets.QCheckBox(
                "Auto exposure / gain (uncheck to set them manually below)")
            self.c_ae.setChecked("ae-enable=false" not in ctl)
            form.addRow("", self.c_ae)

            def cur(key, default=0):
                for p in ctl.split():
                    if p.startswith(key + "="):
                        try:
                            return int(float(p.split("=", 1)[1]))
                        except ValueError:
                            return default
                return default

            self.sp_exp = QtWidgets.QSpinBox()
            self.sp_exp.setRange(0, 200000)
            self.sp_exp.setSingleStep(1000)
            self.sp_exp.setSuffix(" µs   (0 = leave to auto)")
            self.sp_exp.setValue(cur("exposure-time"))
            form.addRow("Manual exposure time", self.sp_exp)

            self.sp_gain = QtWidgets.QDoubleSpinBox()
            self.sp_gain.setRange(0.0, 16.0)
            self.sp_gain.setSingleStep(0.5)
            self.sp_gain.setSuffix("×   (0 = leave to auto)")
            self.sp_gain.setValue(float(cur("analogue-gain")))
            form.addRow("Manual analogue gain", self.sp_gain)

            self.e_ctl = QtWidgets.QLineEdit(ctl)
            self.e_ctl.setPlaceholderText("extra gstlibcamerasrc properties")
            form.addRow("Advanced (raw)", self.e_ctl)

            b_probe = QtWidgets.QPushButton("List properties this build supports…")
            b_probe.clicked.connect(self.probe_props)
            form.addRow("", b_probe)

            form.addRow("", self._note(
                "The IPU3 pipeline only implements auto-exposure/gain, "
                "auto-white-balance (greyworld), black level, gamma and AF. "
                "It does NOT expose denoising, sharpness, brightness, "
                "contrast or saturation: the ImgU has bayer and temporal "
                "noise-reduction blocks, but libcamera never programs them, "
                "so they run at the kernel driver's defaults. Those would "
                "need a libcamera IPA patch and rebuild, not a setting. "
                "Gamma and black level are likewise compiled in (this "
                "project already patches them). An invalid property here "
                "cannot break capture — the bridge falls back to defaults."))
            b = QtWidgets.QPushButton("Apply RGB settings")
            b.clicked.connect(self.apply_rgb)
            form.addRow("", b)
            return w

        def probe_props(self):
            """Ask gstlibcamerasrc itself; never guesses, never opens the camera."""
            try:
                out = subprocess.run(["gst-inspect-1.0", "libcamerasrc"],
                                     capture_output=True, text=True,
                                     timeout=30).stdout
            except Exception as e:
                self.flash(f"gst-inspect failed: {e}", False)
                return
            props = []
            for line in out.splitlines():
                s = line.strip()
                if ":" in line and line.startswith("  ") and not line.startswith("    "):
                    name = s.split(":", 1)[0].strip()
                    if name and " " not in name and name != "Element Properties":
                        props.append(name)
            dlg = QtWidgets.QDialog(self)
            dlg.setWindowTitle("Properties supported by libcamerasrc")
            v = QtWidgets.QVBoxLayout(dlg)
            t = QtWidgets.QPlainTextEdit("\n".join(sorted(set(props))) or out[:4000])
            t.setReadOnly(True)
            v.addWidget(t)
            v.addWidget(QtWidgets.QLabel(
                "Note: this lists what the element accepts. Controls the IPU3\n"
                "pipeline does not implement are silently ignored by libcamera."))
            dlg.resize(420, 460)
            dlg.exec() if hasattr(dlg, "exec") else dlg.exec_()

        def apply_rgb(self):
            extra = self.e_ctl.text().strip()
            drop = ("ae-enable=", "exposure-time=", "analogue-gain=")
            parts = [p for p in extra.split() if not p.startswith(drop)]
            auto = self.c_ae.isChecked()
            parts.insert(0, "ae-enable=" + ("true" if auto else "false"))
            if not auto:
                if self.sp_exp.value() > 0:
                    parts.append(f"exposure-time={self.sp_exp.value()}")
                if self.sp_gain.value() > 0:
                    parts.append(f"analogue-gain={self.sp_gain.value():g}")
            vals = {"RGB_GRACE": self.s_rgb_grace.value(),
                    "RGB_CONTROLS": " ".join(parts)}
            text = render_conf(RGB_CONF, RGB_DEFAULTS, vals)
            user = os.environ.get("USER", "")
            restart = (f"runuser -u {user} -- env XDG_RUNTIME_DIR=/run/user/{os.getuid()} "
                       f"systemctl --user restart camera-ondemand || true")
            ok, err = apply_as_root(RGB_CONF, text, restart)
            self.flash("RGB settings applied" if ok else f"failed: {err}", ok)

        # -- advanced: every real control, with its real range and value
        def _adv_tab(self):
            w = QtWidgets.QWidget()
            v = QtWidgets.QVBoxLayout(w)
            self.l_adv = QtWidgets.QLabel(
                "Reads the actual property list, ranges and defaults from "
                "gstlibcamerasrc, then keeps only the controls the IPU3 "
                "pipeline really implements — so every row here changes the "
                "picture. Tick a row to override it; unticked rows are left "
                "to libcamera.")
            self.l_adv.setWordWrap(True)
            v.addWidget(self.l_adv)

            row = QtWidgets.QHBoxLayout()
            b_scan = QtWidgets.QPushButton("Scan controls")
            b_scan.clicked.connect(lambda: self.adv_scan(verify=True))
            self.c_showall = QtWidgets.QCheckBox("Show controls the IPU3 ignores")
            self.c_showall.stateChanged.connect(lambda _: self.adv_scan(verify=False))
            row.addWidget(b_scan)
            row.addWidget(self.c_showall)
            row.addStretch()
            v.addLayout(row)

            self.adv_area = QtWidgets.QScrollArea()
            self.adv_area.setWidgetResizable(True)
            v.addWidget(self.adv_area, 1)

            b = QtWidgets.QPushButton("Apply advanced controls")
            b.clicked.connect(self.apply_adv)
            v.addWidget(b)
            self._adv_scanned = False
            return w

        def _current_ctl_map(self):
            out = {}
            for tok in self.rgb["RGB_CONTROLS"].split():
                if "=" in tok:
                    k, val = tok.split("=", 1)
                    out[k] = val
            return out

        def adv_scan(self, verify=True):
            self.flash("reading control list…")
            QtWidgets.QApplication.processEvents()
            try:
                out = subprocess.run(["gst-inspect-1.0", "libcamerasrc"],
                                     capture_output=True, text=True,
                                     timeout=30).stdout
            except Exception as e:
                self.l_adv.setText(f"gst-inspect-1.0 unavailable: {e}")
                return
            props = parse_gst_props(out)
            supported = None
            if verify and not self.c_showall.isChecked():
                supported = camera_supported_controls()
            skip = {"name", "parent", "camera-name", "auto-focus-mode"}
            cur = self._current_ctl_map()

            body = QtWidgets.QWidget()
            form = QtWidgets.QFormLayout(body)
            self.adv_widgets = {}
            shown = 0
            for p in props:
                n = p["name"]
                if n in skip:
                    continue
                if supported is not None and n not in supported \
                        and not self.c_showall.isChecked():
                    continue
                cb = QtWidgets.QCheckBox()
                cb.setChecked(n in cur)
                widget, getter = self._adv_widget(p, cur.get(n))
                line = QtWidgets.QHBoxLayout()
                line.addWidget(cb)
                line.addWidget(widget, 1)
                hint = QtWidgets.QLabel(self._range_hint(p))
                hint.setStyleSheet("color: gray")
                line.addWidget(hint)
                form.addRow(n, self._wrap(line))
                self.adv_widgets[n] = (cb, getter)
                shown += 1
            self.adv_area.setWidget(body)
            self._adv_scanned = True
            src = ("verified against the camera"
                   if supported is not None else
                   "not verified — camera busy or 'cam' missing")
            self.flash(f"{shown} controls shown ({src})")

        def _range_hint(self, p):
            if p["kind"] in ("int", "float") and p["min"] is not None:
                lo, hi = p["min"], p["max"]
                fmt = (lambda x: f"{x:g}")
                if abs(lo) > 1e9 or abs(hi) > 1e9:
                    return "any"
                return f"{fmt(lo)} … {fmt(hi)}"
            if p["kind"] == "bool":
                return f"default {p['default']}"
            return ""

        def _adv_widget(self, p, current):
            kind = p["kind"]
            if kind == "bool":
                cb = QtWidgets.QCheckBox()
                val = (current.lower() == "true") if current is not None \
                    else bool(p["default"])
                cb.setChecked(val)
                return cb, (lambda: "true" if cb.isChecked() else "false")
            if kind == "enum" and p["enum"]:
                combo = QtWidgets.QComboBox()
                for val, label in p["enum"]:
                    combo.addItem(f"{val}: {label}", val)
                want = None
                if current is not None:
                    try:
                        want = int(current)
                    except ValueError:
                        want = None
                if want is None and p["default"] is not None:
                    want = int(p["default"])
                for i in range(combo.count()):
                    if combo.itemData(i) == want:
                        combo.setCurrentIndex(i)
                        break
                return combo, (lambda: str(combo.currentData()))
            if kind == "float":
                sb = QtWidgets.QDoubleSpinBox()
                lo = p["min"] if p["min"] is not None and abs(p["min"]) < 1e9 else -1e6
                hi = p["max"] if p["max"] is not None and abs(p["max"]) < 1e9 else 1e6
                sb.setRange(lo, hi)
                sb.setDecimals(3)
                try:
                    sb.setValue(float(current) if current is not None
                                else float(p["default"] or 0))
                except (TypeError, ValueError):
                    pass
                return sb, (lambda: f"{sb.value():g}")
            if kind == "int":
                sb = QtWidgets.QSpinBox()
                lo = int(p["min"]) if p["min"] is not None and abs(p["min"]) < 2**31 else -2**31 + 1
                hi = int(p["max"]) if p["max"] is not None and abs(p["max"]) < 2**31 else 2**31 - 1
                sb.setRange(max(lo, -2**31 + 1), min(hi, 2**31 - 1))
                try:
                    sb.setValue(int(float(current)) if current is not None
                                else int(p["default"] or 0))
                except (TypeError, ValueError):
                    pass
                return sb, (lambda: str(sb.value()))
            le = QtWidgets.QLineEdit(current or str(p["default"] or ""))
            return le, (lambda: le.text().strip())

        def apply_adv(self):
            if not self._adv_scanned:
                self.flash("scan the controls first", False)
                return
            parts = []
            for name, (cb, getter) in self.adv_widgets.items():
                if not cb.isChecked():
                    continue
                val = getter()
                if val != "":
                    parts.append(f"{name}={val}")
            vals = {"RGB_GRACE": self.rgb["RGB_GRACE"],
                    "RGB_CONTROLS": " ".join(parts)}
            text = render_conf(RGB_CONF, RGB_DEFAULTS, vals)
            user = os.environ.get("USER", "")
            restart = (f"runuser -u {user} -- env XDG_RUNTIME_DIR=/run/user/{os.getuid()} "
                       f"systemctl --user restart camera-ondemand || true")
            ok, err = apply_as_root(RGB_CONF, text, restart)
            if ok:
                self.rgb["RGB_CONTROLS"] = vals["RGB_CONTROLS"]
            self.flash(f"applied: {vals['RGB_CONTROLS'] or '(none)'}" if ok
                       else f"failed: {err}", ok)

        # -- login
        def _login_tab(self):
            w = QtWidgets.QWidget()
            v = QtWidgets.QVBoxLayout(w)
            self.l_login = QtWidgets.QLabel("checking…")
            self.l_login.setWordWrap(True)
            v.addWidget(self.l_login)
            row = QtWidgets.QHBoxLayout()
            b_on = QtWidgets.QPushButton("Enable face login")
            b_off = QtWidgets.QPushButton("Disable face login")
            b_on.clicked.connect(lambda: self.login_toggle("--on"))
            b_off.clicked.connect(lambda: self.login_toggle("--off"))
            for b in (b_on, b_off):
                b.setEnabled(bool(self.login_sh))
                row.addWidget(b)
            v.addLayout(row)
            v.addWidget(self._note(
                "Toggling comments the PAM lines in and out; your backups "
                "stay intact. The password always remains available as a "
                "fallback. See LOGIN-SAFETY.md."))
            v.addStretch()
            self.refresh_login()
            return w

        def login_toggle(self, flag):
            try:
                subprocess.run(["pkexec", "/bin/bash", self.login_sh, flag],
                               capture_output=True, timeout=60)
                self.flash("face login " + ("enabled" if flag == "--on" else "disabled"))
            except Exception as e:
                self.flash(f"failed: {e}", False)
            self.refresh_login()

        def refresh_login(self):
            if not self.login_sh:
                self.l_login.setText("setup-kde-login.sh not found — face "
                                     "login is not installed on this system.")
                return
            try:
                out = subprocess.run(["/bin/bash", self.login_sh, "--status"],
                                     capture_output=True, text=True,
                                     timeout=15).stdout.strip()
            except Exception as e:
                out = f"(status unavailable: {e})"
            self.l_login.setText(out or "(no status)")

        # -- status
        def _status_tab(self):
            w = QtWidgets.QWidget()
            v = QtWidgets.QVBoxLayout(w)
            self.t_status = QtWidgets.QPlainTextEdit()
            self.t_status.setReadOnly(True)
            v.addWidget(self.t_status)
            b = QtWidgets.QPushButton("Refresh")
            b.clicked.connect(self.refresh_status)
            v.addWidget(b)
            self.refresh_status()
            return w

        def refresh_status(self):
            rep = environment_report()
            self.t_status.setPlainText(
                "\n".join(f"{k:<20} {v}" for k, v in rep.items()))

    return Panel


DESKTOP = """[Desktop Entry]
Type=Application
Name=Surface Camera Settings
Comment=IR and RGB camera settings for Surface Laptop
Exec=python3 "{path}"
Icon=camera-web
Categories=Settings;HardwareSettings;Qt;
Terminal=false
"""


def install_launcher():
    d = os.path.expanduser("~/.local/share/applications")
    os.makedirs(d, exist_ok=True)
    target = os.path.join(d, "surface-camera-settings.desktop")
    with open(target, "w") as fh:
        fh.write(DESKTOP.format(path=os.path.abspath(__file__)))
    os.chmod(target, 0o755)
    print(f"Launcher written to {target}")
    print("It will appear in the application menu under Settings.")
    print(f"Remove it any time with: rm {target}")


def main():
    if "--install-launcher" in sys.argv:
        install_launcher()
        return 0
    mod, QtWidgets, QtCore, QtGui = load_qt()
    if "--check" in sys.argv:
        print("Qt binding    :", mod or "NONE FOUND")
        for k, v in environment_report().items():
            print(f"{k:<20}: {v}")
        if not mod:
            print("\nNo Qt binding available. Install one of:")
            print("  sudo apt install python3-pyqt6    (or python3-pyqt5)")
            print("Nothing else is required; this tool installs nothing.")
        return 0
    if not mod:
        print("No Qt binding found (PyQt6/PySide6/PyQt5/PySide2).")
        print("Install one:  sudo apt install python3-pyqt6")
        print("Or keep using: surface-camera-ctl")
        return 1
    app = QtWidgets.QApplication(sys.argv)
    Panel = build_gui(mod, QtWidgets, QtCore, QtGui)
    win = Panel()
    win.show()
    return (app.exec() if hasattr(app, "exec") else app.exec_())


if __name__ == "__main__":
    sys.exit(main())
