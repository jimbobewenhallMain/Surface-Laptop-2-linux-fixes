#!/bin/bash
#
# setup-kde-login.sh — face unlock at the SDDM login screen and the KDE
# lock screen, using authFace + the IR camera from this project.
#
# authFace's own deploy.sh only patches sudo, gdm-password and swaylock,
# so a KDE/SDDM system gets nothing at login. This adds it.
#
# HOW IT BEHAVES (read this before running)
# ------------------------------------------
# PAM authentication starts when you SUBMIT the login form, so the flow
# is: pick your user, leave the password box empty, press Enter -> the
# IR emitter lights, and you are in within ~2 s. If your face is not
# recognised, PAM falls through to the password prompt exactly as now.
# Nothing is ever *replaced*; face auth is added as `sufficient`.
#
# On Plasma 6 the lock screen runs a second PAM stack in parallel
# (service `kde-fingerprint`), which is where non-password methods
# belong; this script uses it when Plasma 6 is detected and falls back
# to `/etc/pam.d/kde` on Plasma 5.
#
# WHAT IT CANNOT DO
#   * full-disk encryption: unaffected - that unlock happens pre-boot
#   * KWallet: it is unlocked with your login *password*. Logging in by
#     face means the wallet stays locked and will prompt separately.
#     (Same limitation Howdy has; see README.)
#
# SAFETY
#   * every file is backed up to <file>.pre-face-login
#   * face-auth is verified to work BEFORE any PAM file is touched
#   * `sudo bash setup-kde-login.sh --revert` restores everything
#   * keep a root terminal open (Ctrl+Alt+F3) until you have tested
#
set -u
TAG="kde-login"
PAMD=/etc/pam.d
BIN=/usr/local/bin/face-auth
SUFFIX=.pre-face-login
LINE='auth       sufficient  pam_exec.so '"$BIN"
log()  { echo "[$TAG] $*"; }
warn() { echo "[$TAG] WARN: $*"; }
die()  { echo "[$TAG] ERROR: $*"; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root: sudo bash $0 $*"

DRYRUN=0
[[ "${1:-}" == "--dry-run" ]] && DRYRUN=1
TARGETS_LOGIN=(sddm)
detect_lock_service() {
    # Plasma 6 runs kde-fingerprint as a parallel PAM session for
    # non-password auth; Plasma 5 only has kde.
    if [[ -f "$PAMD/kde-fingerprint" ]]; then
        echo "kde-fingerprint"
    elif command -v plasmashell >/dev/null 2>&1 && \
         plasmashell --version 2>/dev/null | grep -qE '\b6\.'; then
        echo "kde-fingerprint:create"
    elif [[ -f "$PAMD/kde" ]]; then
        echo "kde"
    else
        echo ""
    fi
}

############################################################################
# --status / --off : quick toggles that do not disturb the backups
############################################################################
if [[ "${1:-}" == "--status" ]]; then
    any=0
    for f in "$PAMD"/sddm "$PAMD"/kde "$PAMD"/kde-fingerprint; do
        [[ -f "$f" ]] || continue
        if grep -q "^[^#]*pam_exec\.so.*face-auth" "$f"; then
            echo "  ENABLED   $f"; any=1
        elif grep -q "pam_exec\.so.*face-auth" "$f"; then
            echo "  disabled  $f (line present but commented)"
        fi
    done
    [[ $any -eq 1 ]] || echo "  face login is OFF"
    exit 0
fi

if [[ "${1:-}" == "--off" ]]; then
    # Comment the line out rather than deleting it, so --on is instant and
    # the original backups stay untouched for a full --revert.
    n=0
    for f in "$PAMD"/sddm "$PAMD"/kde "$PAMD"/kde-fingerprint; do
        [[ -f "$f" ]] || continue
        if grep -q "^[^#]*pam_exec\.so.*face-auth" "$f"; then
            sed -i 's|^\([^#].*pam_exec\.so.*face-auth.*\)$|#FACEOFF \1|' "$f"
            log "disabled in $f"; n=$((n+1))
        fi
    done
    [[ $n -gt 0 ]] && log "face login OFF (re-enable: $0 --on)" || log "already off"
    exit 0
fi

if [[ "${1:-}" == "--on" ]]; then
    n=0
    for f in "$PAMD"/sddm "$PAMD"/kde "$PAMD"/kde-fingerprint; do
        [[ -f "$f" ]] || continue
        if grep -q "^#FACEOFF " "$f"; then
            sed -i 's|^#FACEOFF ||' "$f"
            log "enabled in $f"; n=$((n+1))
        fi
    done
    if [[ $n -eq 0 ]]; then
        log "nothing to re-enable - run without arguments to install"
    else
        log "face login ON"
    fi
    exit 0
fi

############################################################################
if [[ "${1:-}" == "--revert" ]]; then
    n=0
    for f in "$PAMD"/*"$SUFFIX"; do
        [[ -e "$f" ]] || continue
        orig="${f%$SUFFIX}"
        mv -f "$f" "$orig" && log "restored $orig" && n=$((n+1))
    done
    # remove a kde-fingerprint we created ourselves
    if [[ -f "$PAMD/kde-fingerprint" ]] && \
       grep -q "created by setup-kde-login.sh" "$PAMD/kde-fingerprint"; then
        rm -f "$PAMD/kde-fingerprint" && log "removed generated kde-fingerprint"
        n=$((n+1))
    fi
    [[ $n -gt 0 ]] && log "reverted $n file(s)" || log "nothing to revert"
    exit 0
fi

############################################################################
# 1. preconditions - never touch PAM unless face auth actually works
############################################################################
[[ -x "$BIN" ]] || die "$BIN not found - install authFace first"
PAMEXEC="$(find /lib /usr/lib -name pam_exec.so 2>/dev/null | head -1)"
[[ -n "$PAMEXEC" ]] || die "pam_exec.so not present on this system"
log "pam_exec.so: $PAMEXEC"

systemctl is-active camera-ir >/dev/null 2>&1 \
    || die "camera-ir daemon not running - run scripts/setup-ir.sh first"

U="${SUDO_USER:-}"
[[ -n "$U" ]] || die "run via sudo from your normal user session"
[[ -s /var/lib/face-auth/$U/embeddings.bin || -d /var/lib/face-auth/$U ]] \
    || die "no enrollment for $U - run: face-enroll --user $U"

if [[ "${1:-}" != "--force" && $DRYRUN -eq 0 ]]; then
    log "verifying face authentication works (look at the camera)..."
    if timeout -k 3 25 env PAM_USER="$U" USER="$U" \
        HOME="$(getent passwd "$U" | cut -d: -f6)" "$BIN"; then
        log "PASS: face-auth authenticated $U"
    else
        die "face-auth did not authenticate (exit $?). Fix that first:
       sudo bash scripts/camera-ir-diag.sh
       (bypass this check with --force if you are sure)"
    fi
fi

############################################################################
# 2. patch the login screen (SDDM)
############################################################################
patch_service() {   # patch_service <service-file>
    local conf="$PAMD/$1"
    [[ -f "$conf" ]] || { warn "$conf not found, skipping"; return 1; }
    grep -q "pam_exec.so.*face-auth" "$conf" && {
        log "$conf already has face auth"; return 0; }
    if [[ $DRYRUN -eq 1 ]]; then
        echo "    --- would change $conf ---"
        awk -v line="$LINE" '
            !done && /^[[:space:]]*(auth[[:space:]]+include|@include[[:space:]]+common-auth)/ {
                print "+++ " line; done=1
            } { print "    " $0 }' "$conf"
        return 0
    fi
    cp -f "$conf" "$conf$SUFFIX"
    # Insert BEFORE the password stack is included, but AFTER any
    # nologin / "user != root" guards, so those still apply.
    if grep -qE '^\s*(auth\s+include|@include\s+common-auth)' "$conf"; then
        awk -v line="$LINE" '
            !done && /^[[:space:]]*(auth[[:space:]]+include|@include[[:space:]]+common-auth)/ {
                print line; done=1
            } { print }' "$conf" > "$conf.tmp" && mv "$conf.tmp" "$conf"
    else
        sed -i "1a $LINE" "$conf"
    fi
    grep -q "pam_exec.so.*face-auth" "$conf" \
        && { log "patched $conf (backup: $conf$SUFFIX)"; return 0; } \
        || { mv -f "$conf$SUFFIX" "$conf"; warn "patch failed on $conf, restored"; return 1; }
}

for svc in "${TARGETS_LOGIN[@]}"; do patch_service "$svc"; done

############################################################################
# 3. patch the lock screen
############################################################################
LOCK="$(detect_lock_service)"
case "$LOCK" in
    kde-fingerprint:create)
        if [[ $DRYRUN -eq 1 ]]; then
            log "would CREATE $PAMD/kde-fingerprint (Plasma 6 parallel auth stack)"
            LOCK=""
            break 2>/dev/null || true
        fi
        log "Plasma 6 detected; creating $PAMD/kde-fingerprint (parallel auth stack)"
        cat > "$PAMD/kde-fingerprint" <<EOF
#%PAM-1.0
# created by setup-kde-login.sh (surface-laptop2-camera-fix)
# Plasma 6 runs this stack alongside the password one, so the lock
# screen can accept a face while still offering the password field.
auth       [success=done default=die]  pam_exec.so $BIN
auth       required                    pam_deny.so
@include common-account
@include common-session-noninteractive
EOF
        log "created $PAMD/kde-fingerprint"
        ;;
    kde-fingerprint)
        patch_service kde-fingerprint
        ;;
    kde)
        log "Plasma 5 style lock screen"
        patch_service kde
        ;;
    *)
        warn "no KDE lock-screen PAM service found; login screen only"
        ;;
esac

############################################################################
# 4. summary
############################################################################
if [[ $DRYRUN -eq 1 ]]; then
    echo
    log "DRY RUN - nothing was changed. Run without --dry-run to apply."
    exit 0
fi
echo
log "DONE. How to use it:"
log "  LOGIN  : pick your user, leave the password box EMPTY, press Enter"
log "  LOCK   : same - press Enter on an empty field (Plasma 6 may try"
log "           the camera automatically)"
log "  The IR emitter lights for ~2 s; if it fails you get the password"
log "  prompt as usual. Nothing is replaced, only added."
echo
warn "TEST IT NOW, before logging out, with a root terminal open:"
warn "  1. open a TTY: Ctrl+Alt+F3, log in there as a safety net"
warn "  2. lock the session (Super+L) and try face unlock"
warn "  3. if anything misbehaves: sudo bash $0 --revert"
echo
log "Caveats: KWallet still needs your password (it is unlocked with the"
log "login password, which face auth never supplies); full-disk"
log "encryption is unaffected - that prompt is pre-boot."
