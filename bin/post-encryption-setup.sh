#!/usr/bin/env bash
# ============================================================================
# post-encryption-setup.sh — finish the job after the box first boots encrypted
# ============================================================================
# Run ON THE ENCRYPTED TARGET, after it has booted encrypted at least once
# (NOT from the live USB):
#
#     sudo ./post-encryption-setup.sh
#     sudo ./post-encryption-setup.sh --config /path/to/post-encryption.conf
#
# What it does (all idempotent — safe to re-run):
#   0. Saves a labeled LUKS recovery bundle (header + boot state) to disk.
#   1. Creates the snapper snapshot subvolumes, which must be made AFTER
#      encryption so the snapshots live on the encrypted volume.
#   2. Enables the LUKS/boot-dependent systemd units (the boot guards), which
#      are unsafe to enable before the root is actually encrypted.
#   3. Enables any extra units you list in the config file.
#   4. Verifies the result and prints a summary.
#
# Written as a script on purpose: scripts do NOT source ~/.bashrc, so shell
# aliases (cp='cp -i', rm='rm -i', cat=bat, find=fd ...) cannot corrupt it.
# Every tool is still called by absolute path.
# ============================================================================
set -uo pipefail

CHMOD=/usr/bin/chmod; CHOWN=/usr/bin/chown
GREP=/usr/bin/grep; SED=/usr/bin/sed; BTRFS=/usr/bin/btrfs
SYSTEMCTL=/usr/bin/systemctl; RESTORECON=/usr/sbin/restorecon
LSBLK=/usr/bin/lsblk; WC=/usr/bin/wc; DIRNAME=/usr/bin/dirname; READLINK=/usr/bin/readlink

G='\033[0;32m'; Y='\033[1;33m'; RED='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok(){   echo -e "  ${G}[ok]${N} $*"; }
warn(){ echo -e "  ${Y}[warn]${N} $*"; }
err(){  echo -e "  ${RED}[fail]${N} $*"; }
hdr(){  echo -e "\n${B}${C}## $* ${N}"; }

[ "$(id -u)" -eq 0 ] || { err "run as root (sudo)"; exit 1; }

SELFDIR=$("$DIRNAME" "$("$READLINK" -f "$0")")
FAILS=0

# ─── Config ─────────────────────────────────────────────────────────────────
# Optional. Lets you enable your own units without editing this script.
CONFIG=""
[ "${1:-}" = "--config" ] && { CONFIG="${2:-}"; shift 2 || true; }
[ -z "$CONFIG" ] && [ -f "$SELFDIR/post-encryption.conf" ] && CONFIG="$SELFDIR/post-encryption.conf"
[ -z "$CONFIG" ] && [ -f /etc/post-encryption.conf ] && CONFIG=/etc/post-encryption.conf

# Defaults; a config file may override.
SNAPPER_SUBVOLS=("/.snapshots" "/home/.snapshots")
SNAPPER_CONFIGS="root home"
ENABLE_SNAPPER=1
BOOT_GUARD_UNITS=(clean-stale-efi-entries.service esp-grub-stub-guard.timer)
EXTRA_UNITS=()

if [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG" && ok "loaded config: $CONFIG"
else
    warn "no config file — using built-in defaults (see post-encryption.conf.example)"
fi

# ============================================================================
hdr "0. LUKS recovery bundle"
# ============================================================================
if [ -x "$SELFDIR/save-luks-recovery-bundle.sh" ]; then
    "$SELFDIR/save-luks-recovery-bundle.sh" || warn "recovery-bundle step reported an issue (see above)"
else
    warn "save-luks-recovery-bundle.sh not found next to this script — skipping bundle"
fi

# ============================================================================
hdr "1. Snapper subvolumes on the encrypted volume"
# ============================================================================
if [ "$ENABLE_SNAPPER" != 1 ]; then
    warn "ENABLE_SNAPPER=0 — skipping snapper setup"
elif ! command -v snapper >/dev/null 2>&1; then
    warn "snapper not installed — skipping (dnf install snapper if you want it)"
else
    # Register the configs with snapper itself FIRST. `snapper create-config`
    # writes /etc/snapper/configs/<name>, adds it to SNAPPER_CONFIGS, and
    # creates the .snapshots subvolume itself (and refuses if one already
    # exists) — so configs come before any manual subvolume creation.
    for cfg in $SNAPPER_CONFIGS; do
        subject="/"; [ "$cfg" != "root" ] && subject="/$cfg"
        if [ -f "/etc/snapper/configs/$cfg" ]; then
            ok "snapper config exists: $cfg"
        elif cc_out=$(/usr/bin/snapper -c "$cfg" create-config "$subject" 2>&1); then
            ok "created snapper config: $cfg → $subject"
        else
            err "snapper create-config failed for $cfg ($subject): $cc_out"
            FAILS=$((FAILS+1))
        fi
    done
    # Ensure the snapshot subvolumes exist (covers pre-existing configs whose
    # .snapshots subvolume was lost, e.g. not carried over by a restore).
    for sv in "${SNAPPER_SUBVOLS[@]}"; do
        if "$BTRFS" subvolume show "$sv" >/dev/null 2>&1; then
            ok "subvolume exists: $sv"
        elif "$BTRFS" subvolume create "$sv" >/dev/null 2>&1; then
            ok "created subvolume: $sv"
        else
            err "could not create subvolume: $sv"; FAILS=$((FAILS+1)); continue
        fi
        "$CHMOD" 0750 "$sv" 2>/dev/null; "$CHOWN" root:root "$sv" 2>/dev/null
        "$RESTORECON" -RF "$sv" 2>/dev/null || true
    done
    if [ -f /etc/sysconfig/snapper ]; then
        "$GREP" -q "SNAPPER_CONFIGS=\"$SNAPPER_CONFIGS\"" /etc/sysconfig/snapper \
            || "$SED" -i "s/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS=\"$SNAPPER_CONFIGS\"/" /etc/sysconfig/snapper
    else
        echo "SNAPPER_CONFIGS=\"$SNAPPER_CONFIGS\"" > /etc/sysconfig/snapper
    fi
    "$SYSTEMCTL" restart snapperd 2>/dev/null || "$SYSTEMCTL" start snapperd 2>/dev/null || true
    /usr/bin/sleep 1
    missing=0
    for cfg in $SNAPPER_CONFIGS; do
        /usr/bin/snapper list-configs 2>/dev/null | "$GREP" -q "\b$cfg\b" || missing=1
    done
    if [ "$missing" -eq 0 ]; then
        ok "snapper configs registered ($SNAPPER_CONFIGS)"
        "$SYSTEMCTL" enable --now snapper-timeline.timer snapper-cleanup.timer >/dev/null 2>&1 \
            && ok "snapper timers enabled" || warn "could not enable snapper timers"
    else
        err "snapper configs NOT registered ($SNAPPER_CONFIGS)"; FAILS=$((FAILS+1))
    fi
fi

# ============================================================================
hdr "2. LUKS/boot-dependent units (safe now that root is encrypted)"
# ============================================================================
enable_units() {
    local label="$1"; shift
    [ "$#" -eq 0 ] && { warn "$label: none configured"; return; }
    for u in "$@"; do
        if [ ! -e "/etc/systemd/system/$u" ] && [ ! -e "/usr/lib/systemd/system/$u" ]; then
            warn "absent: $u"; continue
        fi
        if "$SYSTEMCTL" is-enabled "$u" >/dev/null 2>&1; then ok "already enabled: $u"; continue; fi
        "$SYSTEMCTL" enable --now "$u" >/dev/null 2>&1 \
            && ok "enabled: $u" || warn "enable failed (check: systemctl status $u): $u"
    done
}
enable_units "boot guards" "${BOOT_GUARD_UNITS[@]}"

# ============================================================================
hdr "3. Extra units from config"
# ============================================================================
enable_units "extra units" "${EXTRA_UNITS[@]}"

# ============================================================================
hdr "3b. Restore boot splash (rhgb quiet) if luks-deploy stripped it"
# ============================================================================
# luks-deploy.sh strips 'rhgb quiet' so the first LUKS passphrase prompt is
# visible instead of hiding behind the splash, and leaves this marker so the
# tokens come back once the encrypted system is up. Idempotent.
SPLASH_MARKER=/var/lib/asahilocker/restore-splash
# Before the AsahiLocker rename (<= v1.2.0) the marker lived under the old
# project name; honour it so a mixed-version deploy still gets its splash back.
LEGACY_SPLASH_MARKER=/var/lib/asahi-luks2-encrypter/restore-splash
if [ ! -f "$SPLASH_MARKER" ] && [ -f "$LEGACY_SPLASH_MARKER" ]; then
    SPLASH_MARKER=$LEGACY_SPLASH_MARKER
fi
GRUBBY=/usr/sbin/grubby; [ -x "$GRUBBY" ] || GRUBBY=/usr/bin/grubby
if [ -f "$SPLASH_MARKER" ]; then
    TOKENS=$(/usr/bin/cat "$SPLASH_MARKER" 2>/dev/null)
    TOKENS=${TOKENS:-rhgb quiet}
    if "$GRUBBY" --update-kernel=ALL --args="$TOKENS" >/dev/null 2>&1; then
        ok "BLS entries: restored '$TOKENS' (grubby)"
    else
        err "grubby could not restore '$TOKENS' to the BLS entries"; FAILS=$((FAILS+1))
    fi
    if [ -f /etc/kernel/cmdline ] && ! "$GREP" -qw rhgb /etc/kernel/cmdline; then
        "$SED" -i "1s/[[:space:]]*\$/ $TOKENS/" /etc/kernel/cmdline \
            && ok "/etc/kernel/cmdline: appended '$TOKENS'"
    fi
    if [ -f /etc/default/grub ] && ! "$GREP" -qw rhgb /etc/default/grub; then
        "$SED" -i -E "s/^(GRUB_CMDLINE_LINUX=\".*)\"[[:space:]]*\$/\1 $TOKENS\"/" /etc/default/grub \
            && ok "/etc/default/grub: appended '$TOKENS' to GRUB_CMDLINE_LINUX"
    fi
    /usr/bin/rm -f "$SPLASH_MARKER" && ok "splash restored; marker removed"
else
    ok "no splash-restore marker — nothing to do"
fi

# ============================================================================
hdr "4. Verification"
# ============================================================================
echo "  --- is root actually LUKS-encrypted? ---"
ROOT_SRC=$(/usr/bin/findmnt -no SOURCE / 2>/dev/null)
if "$LSBLK" -o TYPE 2>/dev/null | "$GREP" -q crypt && "$GREP" -q . /etc/crypttab 2>/dev/null; then
    ok "root is on a LUKS mapper: $ROOT_SRC"
    /usr/bin/cryptsetup status "$(/usr/bin/basename "$ROOT_SRC")" 2>/dev/null \
        | "$GREP" -E 'cipher|keysize|device' | "$SED" 's/^/    /' || true
else
    err "no active LUKS mapper found — is this box actually encrypted?"; FAILS=$((FAILS+1))
fi

echo "  --- initramfs carries the crypt module? ---"
KVER=$(/usr/bin/uname -r)
if /usr/bin/lsinitrd "/boot/initramfs-${KVER}.img" 2>/dev/null | "$GREP" -q 'cryptsetup\|crypt'; then
    ok "initramfs-${KVER}.img contains crypt support"
else
    warn "could not confirm crypt module in initramfs-${KVER}.img (lsinitrd unavailable?)"
fi

echo "  --- failed units ---"
FAILED=$("$SYSTEMCTL" --failed --no-legend 2>/dev/null | "$WC" -l)
if [ "$FAILED" -eq 0 ]; then ok "0 failed units"
else "$SYSTEMCTL" --failed --no-legend | "$SED" 's/^/    /'; FAILS=$((FAILS+1)); fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo -e "${G}${B}Post-encryption setup complete.${N}"
    echo -e "${C}Now copy the LUKS recovery bundle off this machine, and take a fresh backup${N}"
    echo -e "${C}so the encrypted box has its own first snapshot with the new crypttab/fstab.${N}"
else
    echo -e "${Y}${B}Completed with $FAILS issue(s) — review the [warn]/[fail] lines above.${N}"
fi
# Nonzero on failure so fleet automation can detect problems.
[ "$FAILS" -eq 0 ]
exit $?
