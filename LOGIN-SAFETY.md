# Face login: safety, and the exact install/test procedure

Read this before running `scripts/setup-kde-login.sh`.

## 1. Yes — the password always still works

Face auth is **added**, never substituted. The line inserted is:

```
auth       sufficient  pam_exec.so /usr/local/bin/face-auth
```

`sufficient` has one specific meaning in PAM:

- module **succeeds** → authentication is granted immediately
- module **fails, errors, is missing, or cannot even be loaded** → the
  result is **ignored** and PAM continues to the next line, which is
  your normal password stack (`common-auth` → `pam_unix`)

There is no path where a failing face scan can *deny* login. Every
failure mode ends at the password prompt:

| What goes wrong | Result |
|---|---|
| Face doesn't match / wrong person | password prompt |
| Not enrolled, or embeddings deleted | password prompt |
| Camera busy, `camera-ir` daemon stopped | password prompt |
| IR emitter dead, frame black | password prompt |
| Capture times out (bounded by `capture_timeout_ms`) | password prompt |
| `face-auth` binary missing or crashes | password prompt |
| `pam_exec.so` itself unloadable | password prompt |

The one cost of a failure is **time**: PAM waits for face-auth to give
up (~2–10 s, bounded by `capture_timeout_ms` and `scan_duration_ms`)
before showing the password prompt. It is a delay, never a lockout.

## 2. What is touched — and what is deliberately not

| File | Touched? | Used by |
|---|---|---|
| `/etc/pam.d/sddm` | **yes** | graphical login screen |
| `/etc/pam.d/kde-fingerprint` | **yes** (created on Plasma 6) | lock screen, parallel stack |
| `/etc/pam.d/kde` | yes, only on Plasma 5 | lock screen |
| `/etc/pam.d/login` | **NO** | **text console (Ctrl+Alt+F3)** |
| `/etc/pam.d/sudo` | no (authFace already did) | `sudo` |
| `/etc/pam.d/common-auth` | **NO** | shared password stack |

The console login stack is never modified. **Even in the worst case —
a corrupted `sddm` file that refuses every login — Ctrl+Alt+F3 still
gives you a working text login with your password**, from which one
command undoes everything.

## 3. Install and test, step by step

**Step 0 — open a safety net first.**
Press `Ctrl+Alt+F3`, log in with your username and password, and leave
that session logged in. Return to the desktop with `Ctrl+Alt+F2` (or
F1/F7 depending on your setup). Do not skip this; it is what makes
every later step recoverable.

**Step 1 — preview the changes, without applying any.**
```
sudo bash scripts/setup-kde-login.sh --dry-run
```
Prints each file with the exact line that would be inserted (marked
`+++`). Nothing is written.

**Step 2 — apply.**
```
sudo bash scripts/setup-kde-login.sh
```
It refuses to modify PAM until it has actually authenticated your face
once, backs up every file it edits to `<file>.pre-face-login`, and
verifies its own edit landed (restoring the backup if not).

**Step 3 — test the LOCK screen first.** This is the reversible test:
if it misbehaves you are still logged in.
```
Super+L        # lock
# leave the password box empty, press Enter -> emitter lights, ~2 s
```
Also confirm the fallback deliberately: lock again, cover the camera,
press Enter, wait for it to fail, then type your password. It must let
you in.

**Step 4 — only now test the LOGIN screen.** Log out (do not reboot —
your TTY session survives a logout). At SDDM: pick your user, leave the
password box empty, press Enter. Confirm the password still works too,
by logging out again and typing it normally.

**Step 5 — reboot test.** Only once steps 3 and 4 both pass.

## 4. Undo

From the desktop, a TTY, or an SSH session:

```
sudo bash scripts/setup-kde-login.sh --revert
```

Restores every backup byte-for-byte and removes the generated
`kde-fingerprint`. No reboot needed — PAM re-reads its config on each
authentication. `uninstall.sh` calls this automatically.

### If you somehow cannot log in graphically at all

1. `Ctrl+Alt+F3` → log in with your password → run the revert command
   above → `sudo systemctl restart sddm`.
2. If even the console login fails (this would require damage beyond
   what this script does), reboot, hold `Shift` for the GRUB menu, pick
   *Advanced options* → *recovery mode* → *root shell*, then:
   ```
   mount -o remount,rw /
   cd /etc/pam.d && for f in *.pre-face-login; do mv -f "$f" "${f%.pre-face-login}"; done
   rm -f /etc/pam.d/kde-fingerprint
   reboot
   ```

## 5. Turning it on and off later

```
surface-camera-ctl face-login status
surface-camera-ctl face-login off      # comments the PAM lines out
surface-camera-ctl face-login on       # puts them back
```

`off` comments the lines rather than deleting them, so toggling is
instant and the original backups stay intact for a full `--revert`.

## 6. Can face unlock run *before* pressing Enter?

**Lock screen: yes, already.** On Plasma 6 the lock screen runs the
`kde-fingerprint` stack in parallel with the password one, so the camera
starts the moment the lock screen appears — no keypress. That is what
this project configures.

**Login screen (SDDM): no, not currently possible.** SDDM starts PAM
only when the login form is submitted, so a keypress is required; this
is a known SDDM limitation, and parallel PAM sessions are being
implemented in the new
[Plasma Login Manager](https://invent.kde.org/plasma/plasma-login-manager/-/work_items/1)
that becomes the default in Plasma 6.6. When your distro ships it, the
same PAM entry should start working without Enter — nothing here will
need changing.

There is one workaround, deliberately **not** enabled by this project:
configure SDDM to auto-login and immediately lock the session, so you
land on the lock screen (which does support automatic face unlock). It
works, but it moves your security boundary from the display manager to
the lock screen and briefly exposes the desktop while the lock takes
effect. If you want it, it is a two-file change you can make yourself;
this project will not do it silently.

## 7. Honest limitations

- **KWallet stays locked.** It is unlocked with your login *password*,
  which face auth never supplies, so it prompts separately after a face
  login. Howdy has the same limitation.
- **Full-disk encryption is unaffected** — that passphrase is entered
  pre-boot, long before PAM exists.
- **No liveness detection.** IR resists casual photo spoofing, but this
  is not a structured-light sensor like Windows Hello's; a determined
  attacker with an IR-visible print may defeat it. authFace documents
  this too. If that matters to you, keep face auth for the lock screen
  and `sudo` only, and leave `sddm` on password.
- **Timing.** A failed scan delays the password prompt by a few
  seconds. Lower `scan_duration_ms` in `~/.config/face-auth.toml` if
  that annoys you.
