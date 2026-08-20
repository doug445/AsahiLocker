#!/usr/bin/env bash
# ============================================================================
# boot-guards/install.sh — install the two Asahi boot guards
# ============================================================================
# Run ON THE INSTALLED SYSTEM (encrypted or not), as root:
#     sudo ./boot-guards/install.sh
#
# Installs:
#   1. esp-grub-stub-guard   — pins /boot/efi/EFI/fedora/grub.cfg to the small
#      chainload stub, so a stray `grub2-mkconfig -o <ESP path>` cannot replace
#      it with a full config that has no idea how to cryptomount an encrypted
#      root. Baseline is generated FROM YOUR OWN CURRENT STUB at install time.
#   2. clean-stale-efi-entries — deletes EFI boot entries whose GPT partition is
#      no longer attached. U-Boot on Asahi auto-registers an entry for every
#      shim.efi it finds on removable media, and they linger after you unplug the
#      installer USB, producing "can't find boot XXXX" noise at every boot.
#
# Idempotent — safe to re-run. Uninstall with ./install.sh --uninstall
# All tools called by absolute path (immune to shell aliases like cp='cp -i').
# ============================================================================
set -uo pipefail

CP=/usr/bin/cp; RM=/usr/bin/rm; MKDIR=/usr/bin/mkdir; CHMOD=/usr/bin/chmod
SYSTEMCTL=/usr/bin/systemctl; WC=/usr/bin/wc; SHA=/usr/bin/sha512sum; AWK=/usr/bin/awk

G='\033[0;32m'; Y='\033[1;33m'; RED='\033[0;31m'; B='\033[1m'; N='\033[0m'
ok(){   echo -e "  ${G}[ok]${N} $*"; }
warn(){ echo -e "  ${Y}[warn]${N} $*"; }
err(){  echo -e "  ${RED}[fail]${N} $*"; }

[ "$(id -u)" -eq 0 ] || { err "run as root: sudo $0"; exit 1; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SBIN=/usr/local/sbin
UNITS=/etc/systemd/system
ESP=/boot/efi/EFI/fedora/grub.cfg
REF=/root/grub-esp-stub.cfg.known-good
HASHFILE=/root/grub-esp-stub.sha512

# ─── Uninstall ──────────────────────────────────────────────────────────────
if [ "${1:-}" = "--uninstall" ]; then
    echo -e "${B}Removing Asahi boot guards...${N}"
    for u in esp-grub-stub-guard.timer esp-grub-stub-guard.service clean-stale-efi-entries.service; do
        "$SYSTEMCTL" disable --now "$u" >/dev/null 2>&1
        "$RM" -f "$UNITS/$u"
    done
    "$RM" -f "$SBIN/restore-esp-grub-stub.sh" "$SBIN/clean-stale-efi-entries.sh" "$SBIN/esp-grub-stub-rebaseline"
    "$SYSTEMCTL" daemon-reload
    ok "boot guards removed (baseline files in /root left in place)"
    exit 0
fi

echo -e "${B}Installing Asahi boot guards...${N}"

# ─── Sanity: is this actually an EFI/Asahi-shaped system? ───────────────────
[ -d /sys/firmware/efi ] || warn "no /sys/firmware/efi — EFI-entry cleanup will no-op"

# ─── 1. Scripts ─────────────────────────────────────────────────────────────
"$MKDIR" -p "$SBIN"
for s in restore-esp-grub-stub.sh clean-stale-efi-entries.sh esp-grub-stub-rebaseline; do
    "$CP" -f "$HERE/bin/$s" "$SBIN/$s" && "$CHMOD" 0755 "$SBIN/$s" \
        && ok "installed $SBIN/$s" || { err "could not install $s"; exit 1; }
done

# ─── 2. Baseline the ESP stub FROM THIS MACHINE ─────────────────────────────
# The stub embeds this box's own /boot filesystem UUID, so it is generated here
# rather than shipped. Refuse to baseline a full generated config.
if [ -f "$ESP" ]; then
    lines=$("$WC" -l < "$ESP")
    if [ "$lines" -gt 40 ]; then
        err "$ESP is $lines lines — that is a FULL grub.cfg, not the chainload stub."
        err "Your ESP stub has ALREADY been overwritten. Fix it before baselining:"
        err "  restore the 4-line stub (see docs/RECOVERY.md), then re-run this installer."
        err "Skipping esp-grub-stub-guard; continuing with the EFI-entry cleaner."
        SKIP_STUB=1
    else
        "$CP" -a "$ESP" "$REF"; "$CHMOD" 0400 "$REF"
        "$SHA" "$ESP" | "$AWK" '{print $1}' > "$HASHFILE"; "$CHMOD" 0400 "$HASHFILE"
        ok "baselined ESP stub ($lines lines) -> $REF"
        ok "sha512: $(cat "$HASHFILE")"
        SKIP_STUB=0
    fi
else
    warn "$ESP not found — skipping esp-grub-stub-guard (not a Fedora EFI layout?)"
    SKIP_STUB=1
fi

# ─── 3. Units ───────────────────────────────────────────────────────────────
"$CP" -f "$HERE/systemd/clean-stale-efi-entries.service" "$UNITS/" && ok "installed clean-stale-efi-entries.service"
if [ "$SKIP_STUB" -eq 0 ]; then
    "$CP" -f "$HERE/systemd/esp-grub-stub-guard.service" "$UNITS/"
    "$CP" -f "$HERE/systemd/esp-grub-stub-guard.timer"   "$UNITS/"
    ok "installed esp-grub-stub-guard.service + .timer"
fi
"$SYSTEMCTL" daemon-reload

# ─── 4. Enable ──────────────────────────────────────────────────────────────
"$SYSTEMCTL" enable --now clean-stale-efi-entries.service >/dev/null 2>&1 \
    && ok "enabled clean-stale-efi-entries.service" \
    || warn "could not enable clean-stale-efi-entries.service"
if [ "$SKIP_STUB" -eq 0 ]; then
    "$SYSTEMCTL" enable --now esp-grub-stub-guard.timer >/dev/null 2>&1 \
        && ok "enabled esp-grub-stub-guard.timer (checks every 60s)" \
        || warn "could not enable esp-grub-stub-guard.timer"
fi

echo
echo -e "${B}Done.${N} Check with:"
echo "    systemctl status clean-stale-efi-entries.service"
echo "    systemctl list-timers esp-grub-stub-guard.timer"
echo "    journalctl -t esp-grub-stub-guard -t clean-stale-efi"
echo
echo "If you ever change the ESP stub on purpose, re-baseline it:"
echo "    sudo $SBIN/esp-grub-stub-rebaseline"
