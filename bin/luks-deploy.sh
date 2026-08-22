#!/bin/bash
#
# AsahiLocker — in-place LUKS2 encryption for Fedora Asahi Remix on Apple Silicon
# https://github.com/doug445/AsahiLocker
#
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# ============================================================================
# Fedora Asahi Btrfs LUKS2 Deployment Script (hardened)
# ============================================================================
# In-place LUKS2 encryption of a btrfs root partition.
#
# Targets: Fedora Asahi Remix on Apple Silicon (aarch64), btrfs root
# Also works on: Fedora x86_64, Manjaro, Arch (btrfs)
#
# MUST be run from a live USB / rescue environment, NOT the installed system.
#
# What this script does:
#   1. Auto-detects partitions, subvolumes, and boot configuration
#   2. Validates btrfs integrity, power state, kernel modules
#   3. Shrinks btrfs by 32MB for LUKS2 header space
#   4. In-place encrypts the partition with LUKS2 + checksum resilience
#   5. Verifies LUKS header, opens container, resizes btrfs to max
#   6. Updates fstab, crypttab, /etc/kernel/cmdline, BLS entries, GRUB
#   7. Rebuilds ALL initramfs images with crypt+dm+btrfs modules
#   8. Self-verifies every component; auto-repairs failed initramfs
#   9. Full verification gate: blocks reboot until ALL checks pass
#
# Re-entrant / resumable:
#   - Interrupted mid-encryption? Re-run the script: it detects the LUKS2
#     'online-reencrypt' requirement flag and finishes the encryption with
#     `cryptsetup reencrypt --resume-only`, then redoes the config phase.
#   - Died during the config phase? Re-run the script: it offers a
#     configuration-only mode that unlocks the container and redoes every
#     config + verification step (all idempotent) without touching the data.
# ============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Mapper name for the unlocked root. Overridable for fleets that need a
# different device-mapper name; the companion scripts (recovery bundle,
# post-encryption setup) auto-detect it from the booted system's root source.
LUKS_NAME="${LUKS_MAPPER_NAME:-fedora_crypt}"
case "$LUKS_NAME" in
    *[!A-Za-z0-9_-]*|'') echo "LUKS_MAPPER_NAME must match [A-Za-z0-9_-]+" >&2; exit 1;;
esac

# ─── CLI flags ───────────────────────────────────────────────────────────────
# --dry-run (or LUKS_DRY_RUN=1): run every read-only phase — detection, menus,
# fstab cross-checks, KDF benchmark, state backup to the deployment drive —
# print the full plan, and exit BEFORE the point of no return. Nothing on the
# TARGET is modified (config-only dry-run still asks for the passphrase to
# unlock the container read-only for discovery).
DRY_RUN="${LUKS_DRY_RUN:-0}"
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) echo "Unknown argument: $arg (only --dry-run is accepted; everything else is via LUKS_* env vars — see the header of this script)" >&2; exit 1 ;;
    esac
done

# ─── Non-interactive passphrase (fleet / automated testing) ──────────────────
# LUKS_PASSPHRASE_FILE=<path>: read the passphrase from a file instead of the
# terminal (used for reencrypt/resume/open and as the existing key when
# enrolling the recovery key). The file's exact bytes are the passphrase — no
# trailing newline. The file is NOT deleted; the caller owns its lifecycle.
CRYPT_PASS_ARGS=()      # for interactive prompts these stay empty
CRYPT_BATCH_ARGS=()
if [ -n "${LUKS_PASSPHRASE_FILE:-}" ]; then
    [ -r "$LUKS_PASSPHRASE_FILE" ] && [ -s "$LUKS_PASSPHRASE_FILE" ] \
        || { echo "LUKS_PASSPHRASE_FILE=$LUKS_PASSPHRASE_FILE is missing, unreadable, or empty" >&2; exit 1; }
    CRYPT_PASS_ARGS=(--key-file "$LUKS_PASSPHRASE_FILE")
    # --batch-mode also skips cryptsetup's own are-you-sure prompt; this
    # script's typed ENCRYPT gate remains the consent step.
    CRYPT_BATCH_ARGS=(--batch-mode)
fi

# Log to the directory this script lives in (the USB/deployment drive),
# not /tmp (which is tmpfs on live USB and gets wiped on reboot)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_LOG="$SCRIPT_DIR/luks-deploy-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$DEPLOY_LOG") 2>&1
echo "Full log: $DEPLOY_LOG"

log()  { echo -e "[$(date '+%H:%M:%S')] ${GREEN}[LUKS]${NC} $*"; }
warn() { echo -e "[$(date '+%H:%M:%S')] ${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "[$(date '+%H:%M:%S')] ${RED}[ERROR]${NC} $*" >&2; }
fatal() { err "$@"; exit 1; }

# ─── LUKS2 KDF profiles ──────────────────────────────────────────────────────
# Three presets, chosen interactively before encryption starts. The KDF is
# re-run in the INITRAMFS at every boot, so its memory cost must be allocatable
# there — and you pay its full cost as unlock latency on EVERY boot.
#
# argon2id cost is ~proportional to (memory x iterations). The script benchmarks
# THIS machine and shows a real estimated unlock time for each profile, rather
# than quoting numbers from someone else's hardware.
#
#   aggressive  4 GiB  t=12   paranoid; 4 GiB is the memory ceiling an 8 GiB
#                              Mac can hold, so the extra cost goes into
#                              iterations rather than more memory
#   moderate    2 GiB  t=6    balanced; the default
#   fast        1 GiB  t=4    comfortable even on an 8 GiB M1
#
# ALWAYS argon2id. It is memory-hard, which is what makes GPU/ASIC cracking
# expensive; never substitute pbkdf2 to save memory or time — argon2id at 1 GiB
# beats pbkdf2 at any iteration count. There is no profile that selects pbkdf2.
#
# Non-interactive use:
#   LUKS_PROFILE=fast ./luks-deploy.sh                       # pick a preset
#   LUKS_PBKDF_MEMORY=1572864 LUKS_PBKDF_ITER=6 ./luks-deploy.sh   # fully custom
# Setting any LUKS_PBKDF_* variable pins the parameters and skips the menu.
#
# Partition pinning (skips the selection menus — for fleet/scripted use):
#   LUKS_TARGET_ROOT=/dev/nvme0n1p6 LUKS_TARGET_BOOT=/dev/nvme0n1p5 \
#   LUKS_TARGET_EFI=/dev/nvme0n1p4 ./luks-deploy.sh
# Each pinned device is still fstype-checked, cross-checked against the
# target's fstab, and subject to the same typed ENCRYPT confirmation.
#
# Recovery key (2nd keyslot): prompted interactively; pin with
#   LUKS_RECOVERY_KEY=yes|no ./luks-deploy.sh
#
# More environment knobs:
#   LUKS_PASSPHRASE_FILE=<path>  read the passphrase from a file (fleet/testing);
#                                the file's exact bytes are the passphrase
#   LUKS_MAPPER_NAME=<name>      device-mapper name (default: fedora_crypt)
#   LUKS_KEEP_SPLASH=1           do NOT strip 'rhgb quiet' from the boot args
#                                (default: strip, so the passphrase prompt is
#                                visible; post-encryption-setup.sh restores them)
#   LUKS_SKIP_VERSION_CHECK=1    bypass the cryptsetup >= 2.4 floor
#   LUKS_DRY_RUN=1 (or --dry-run flag)  preview: full detection + plan, no
#                                       changes to the target, exit before
#                                       the point of no return

KDF_PROFILE_AGGRESSIVE_MEM=4194304;  KDF_PROFILE_AGGRESSIVE_ITER=12
KDF_PROFILE_MODERATE_MEM=2097152;    KDF_PROFILE_MODERATE_ITER=6
KDF_PROFILE_FAST_MEM=1048576;        KDF_PROFILE_FAST_ITER=4
KDF_DEFAULT_PARALLEL=4

# Did the caller pin anything explicitly? (checked before defaults are applied)
KDF_PINNED_BY_ENV=0
if [ -n "${LUKS_PBKDF_MEMORY:-}" ] || [ -n "${LUKS_PBKDF_ITER:-}" ] || [ -n "${LUKS_PBKDF_PARALLEL:-}" ]; then
    KDF_PINNED_BY_ENV=1
fi

# Defaults = the moderate profile; the menu (or LUKS_PROFILE) may replace them.
LUKS_PBKDF_MEMORY="${LUKS_PBKDF_MEMORY:-$KDF_PROFILE_MODERATE_MEM}"
LUKS_PBKDF_ITER="${LUKS_PBKDF_ITER:-$KDF_PROFILE_MODERATE_ITER}"
LUKS_PBKDF_PARALLEL="${LUKS_PBKDF_PARALLEL:-$KDF_DEFAULT_PARALLEL}"
KDF_PROFILE_NAME="moderate"

case "$LUKS_PBKDF_MEMORY" in ''|*[!0-9]*) echo "LUKS_PBKDF_MEMORY must be an integer (KiB)" >&2; exit 1;; esac
case "$LUKS_PBKDF_ITER" in ''|*[!0-9]*) echo "LUKS_PBKDF_ITER must be an integer" >&2; exit 1;; esac
case "$LUKS_PBKDF_PARALLEL" in ''|*[!0-9]*) echo "LUKS_PBKDF_PARALLEL must be an integer" >&2; exit 1;; esac

# Refuse accidentally-weak pinned parameters. Floor = half the 'fast' profile.
# A typo like LUKS_PBKDF_MEMORY=1048 (meant 1048576) would otherwise silently
# produce a near-worthless KDF. Set LUKS_PBKDF_ACK_WEAK=1 to proceed anyway.
if [ "$KDF_PINNED_BY_ENV" -eq 1 ] \
   && { [ "$LUKS_PBKDF_MEMORY" -lt 524288 ] || [ "$LUKS_PBKDF_ITER" -lt 4 ]; }; then
    if [ "${LUKS_PBKDF_ACK_WEAK:-0}" = "1" ]; then
        warn "Pinned KDF parameters are BELOW the safety floor (mem=${LUKS_PBKDF_MEMORY} KiB, iters=${LUKS_PBKDF_ITER}) — proceeding because LUKS_PBKDF_ACK_WEAK=1."
    else
        fatal "Pinned KDF parameters too weak: mem=${LUKS_PBKDF_MEMORY} KiB, iters=${LUKS_PBKDF_ITER} (floor: 524288 KiB / 4 iterations). If this is intentional, set LUKS_PBKDF_ACK_WEAK=1."
    fi
fi

# Apply a named profile requested via the environment.
apply_kdf_profile() {
    case "$1" in
        aggressive) LUKS_PBKDF_MEMORY=$KDF_PROFILE_AGGRESSIVE_MEM; LUKS_PBKDF_ITER=$KDF_PROFILE_AGGRESSIVE_ITER ;;
        moderate)   LUKS_PBKDF_MEMORY=$KDF_PROFILE_MODERATE_MEM;   LUKS_PBKDF_ITER=$KDF_PROFILE_MODERATE_ITER ;;
        fast)       LUKS_PBKDF_MEMORY=$KDF_PROFILE_FAST_MEM;       LUKS_PBKDF_ITER=$KDF_PROFILE_FAST_ITER ;;
        *) return 1 ;;
    esac
    LUKS_PBKDF_PARALLEL=$KDF_DEFAULT_PARALLEL
    KDF_PROFILE_NAME="$1"
}

# Estimate unlock time for (mem_kib, iters, parallel) by calibrating against
# cryptsetup's own benchmark on THIS machine. benchmark reports how many
# iterations fit in ~2000 ms and CLAMPS requested memory to what it can
# actually allocate right now (measured: ~2.3 GiB free on a 29 GiB machine
# clamped a 4 GiB request), so scale from the memory it
# actually used rather than the memory we asked for.
kdf_estimate_ms() {
    local mem_kib="$1" iters="$2" par="$3" out b_iters b_mem
    out=$(cryptsetup benchmark --pbkdf argon2id --pbkdf-memory "$mem_kib" \
              --pbkdf-parallel "$par" 2>/dev/null | grep -m1 'argon2id') || return 1
    b_iters=$(echo "$out" | awk '{print $2}')
    b_mem=$(echo "$out"   | awk '{print $4}')
    case "$b_iters" in ''|*[!0-9]*) return 1;; esac
    case "$b_mem"   in ''|*[!0-9]*) return 1;; esac
    [ "$b_iters" -gt 0 ] && [ "$b_mem" -gt 0 ] || return 1
    awk -v ti="$iters" -v tm="$mem_kib" -v bi="$b_iters" -v bm="$b_mem" \
        'BEGIN{ printf "%.0f", 2000.0 * (ti*tm) / (bi*bm) }'
}

kdf_fmt_ms() {
    local ms="$1"
    case "$ms" in ''|*[!0-9]*) echo "?"; return;; esac
    if [ "$ms" -lt 1000 ]; then echo "${ms} ms"
    else awk -v m="$ms" 'BEGIN{ printf "%.1f s", m/1000 }'; fi
}

# ─── Cleanup Trap ────────────────────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        err "════════════════════════════════════════════════════════════"
        err "  Script exited with error (code $exit_code). Cleaning up..."
        err "════════════════════════════════════════════════════════════"
    fi
    # Clean up any temp mounts first (-R: the BLS check nests a boot mount
    # inside /mnt_temp, and a plain umount would fail on the child mount)
    umount -R /mnt_temp 2>/dev/null || umount /mnt_temp 2>/dev/null || true
    rmdir /mnt_temp 2>/dev/null || true
    # Clean up chroot bind mounts (specific order matters)
    umount /mnt/sys/firmware/efi/efivars 2>/dev/null || true
    for mp in /mnt/run /mnt/sys /mnt/proc /mnt/dev/pts /mnt/dev; do
        umount "$mp" 2>/dev/null || true
    done
    umount /mnt/boot/efi 2>/dev/null || true
    umount /mnt/boot 2>/dev/null || true
    umount /mnt/home 2>/dev/null || true
    umount /mnt 2>/dev/null || true
    cryptsetup close ${LUKS_NAME} 2>/dev/null || true
    rm -f /mnt/tmp/.luks-deploy-env 2>/dev/null || true
    if [ $exit_code -ne 0 ]; then
        echo ""
        echo "Recovery options:"
        echo "  If btrfs was shrunk but encryption didn't start:"
        echo "    mount <ROOT_DEV> /mnt && btrfs filesystem resize max /mnt && umount /mnt"
        echo "  If encryption was interrupted:"
        echo "    RE-RUN THIS SCRIPT — it detects the interrupted state and"
        echo "    resumes automatically (cryptsetup reencrypt --resume-only)."
        echo "  If encryption completed but config is wrong:"
        echo "    RE-RUN THIS SCRIPT — it offers a configuration-only mode that"
        echo "    redoes crypttab/fstab/initramfs/BLS and re-runs verification."
        echo "  LUKS header restore (if backed up):"
        echo "    cryptsetup luksHeaderRestore <ROOT_DEV> --header-backup-file /boot/luks-header-backup.img"
        echo ""
        echo "  Pre-encryption backups saved to: $SCRIPT_DIR/"
        echo "  Full log: $DEPLOY_LOG"
    fi
    # Give the background tee logger a moment to drain the pipe, so the final
    # lines (including the recovery instructions above) reach the log file.
    sync
    sleep 1
}
trap cleanup EXIT

# ─── Root Check ──────────────────────────────────────────────────────────────
[ "$EUID" -eq 0 ] || fatal "Must run as root: sudo $0"

# ─── Partial Previous Run Detection ─────────────────────────────────────────
# If a previous run was interrupted, detect and warn
if [ -b /dev/mapper/${LUKS_NAME} ] 2>/dev/null; then
    warn "Found /dev/mapper/${LUKS_NAME} already open from a previous run!"
    echo "  keep  = leave it open and reuse it (saves a passphrase prompt in config-only mode)"
    echo "  close = close it and start fresh"
    read -p "Keep or close? (keep/close): " STALE_CHOICE
    umount -R /mnt 2>/dev/null || true
    case "$STALE_CHOICE" in
        keep)
            log "  Keeping ${LUKS_NAME} open — it will be reused."
            ;;
        close)
            cryptsetup close ${LUKS_NAME} 2>/dev/null \
                || fatal "Could not close ${LUKS_NAME} (still in use?). Close it manually and re-run."
            log "  Closed stale ${LUKS_NAME}."
            ;;
        *)
            fatal "Answer 'keep' or 'close'. Nothing was changed."
            ;;
    esac
fi

# ─── Dependency Check ────────────────────────────────────────────────────────
log "Checking required tools..."
MISSING=()
for cmd in cryptsetup btrfs blkid lsblk mktemp findmnt; do
    command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done

# Detect initramfs tool (on live USB; verified again inside chroot)
INITRAMFS_TOOL=""
if command -v dracut &>/dev/null; then
    INITRAMFS_TOOL="dracut"
elif command -v mkinitcpio &>/dev/null; then
    INITRAMFS_TOOL="mkinitcpio"
elif command -v update-initramfs &>/dev/null; then
    INITRAMFS_TOOL="update-initramfs"
fi
[ -n "$INITRAMFS_TOOL" ] || MISSING+=("dracut/mkinitcpio/update-initramfs")

# Detect GRUB config tool
GRUB_MKCONFIG=""
if command -v grub2-mkconfig &>/dev/null; then
    GRUB_MKCONFIG="grub2-mkconfig"
elif command -v grub-mkconfig &>/dev/null; then
    GRUB_MKCONFIG="grub-mkconfig"
fi
[ -n "$GRUB_MKCONFIG" ] || MISSING+=("grub2-mkconfig/grub-mkconfig")

if [ ${#MISSING[@]} -gt 0 ]; then
    fatal "Missing required tools: ${MISSING[*]}"
fi

CRYPTSETUP_VER=$(cryptsetup --version | awk '{print $2}')
# LUKS2 online/in-place reencryption needs cryptsetup >= 2.4.
if [ "${LUKS_SKIP_VERSION_CHECK:-0}" != "1" ]; then
    if [ "$(printf '%s\n2.4.0\n' "$CRYPTSETUP_VER" | sort -V | head -1)" != "2.4.0" ]; then
        fatal "cryptsetup $CRYPTSETUP_VER is too old — LUKS2 in-place reencryption needs >= 2.4 (LUKS_SKIP_VERSION_CHECK=1 to override)."
    fi
fi
log "Tools OK. cryptsetup=$CRYPTSETUP_VER initramfs=$INITRAMFS_TOOL grub=$GRUB_MKCONFIG arch=$(uname -m)"

# ─── Kernel Module Preload ───────────────────────────────────────────────────
log "Loading required kernel modules..."
modprobe dm-crypt 2>/dev/null || true
modprobe dm_mod 2>/dev/null || true
if ! lsmod | grep -q dm_crypt; then
    warn "Cannot load dm-crypt module. cryptsetup may still work via kernel built-in."
fi

# ─── Live Environment Check ──────────────────────────────────────────────────
CURRENT_ROOT_FSTYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")
log "Current root filesystem: $CURRENT_ROOT_FSTYPE ($(findmnt -n -o SOURCE / 2>/dev/null || echo 'unknown'))"

if [ "$CURRENT_ROOT_FSTYPE" = "btrfs" ]; then
    echo ""
    err "Your current root filesystem is Btrfs."
    err "This script MUST be run from a LIVE USB / rescue environment."
    err "Running on the installed system WILL destroy your data."
    echo ""
    read -p "Are you certain you are in a live/rescue environment? (Type 'LIVE' to override): " LIVE_OVERRIDE
    [ "$LIVE_OVERRIDE" = "LIVE" ] || fatal "Aborted for safety."
fi

# ─── Power / Battery Check ──────────────────────────────────────────────────
for ps_dir in /sys/class/power_supply/*/; do
    [ -d "$ps_dir" ] || continue
    ps_type=$(cat "$ps_dir/type" 2>/dev/null || echo "")
    if [ "$ps_type" = "Battery" ]; then
        bat_capacity=$(cat "$ps_dir/capacity" 2>/dev/null || echo "100")
        bat_status=$(cat "$ps_dir/status" 2>/dev/null || echo "Unknown")
        log "Battery: ${bat_capacity}%, Status: ${bat_status}"
        if [ "$bat_capacity" -lt 50 ] && [ "$bat_status" != "Charging" ] && [ "$bat_status" != "Full" ]; then
            echo ""
            err "╔══════════════════════════════════════════════════════╗"
            err "║  DANGER: Battery at ${bat_capacity}% and NOT charging!       ║"
            err "║  If power dies mid-encryption, ALL DATA IS LOST.    ║"
            err "║  Connect AC power before proceeding.                ║"
            err "╚══════════════════════════════════════════════════════╝"
            echo ""
            read -p "Continue on battery? (Type 'BATTERY' to override): " BAT_OVERRIDE
            [ "$BAT_OVERRIDE" = "BATTERY" ] || fatal "Connect AC power and try again."
        fi
        break
    fi
done

# ─── Block Device Display ────────────────────────────────────────────────────
echo ""
log "=== Block Devices ==="
lsblk -o NAME,FSTYPE,LABEL,PARTLABEL,SIZE,MOUNTPOINT | grep -v "loop"
echo ""

# ─── Smart Partition Detection & Selection ──────────────────────────────────
# Prefers NVMe over USB/sd*, uses LABEL/PARTLABEL for scoring, excludes live
# USB disk from defaults, and presents a numbered menu for each partition type.

# Identify the live USB's disk so we can deprioritize its partitions
LIVE_ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*//')
LIVE_ROOT_DISK=$(lsblk -no PKNAME "$LIVE_ROOT_DEV" 2>/dev/null | head -1)
log "Live environment disk: ${LIVE_ROOT_DISK:-(unknown)}"

pick_partition() {
    # Usage: pick_partition <ROLE> <FSTYPE> <LABEL_HINT_REGEX>
    # Displays scored numbered list, returns selected device path on stdout.
    # All display/prompts go to stderr so stdout is clean for capture.
    local role="$1" fstype="$2" label_hint="$3"
    local -a devs=() disp_labels=() sizes=() disks=() scores=()
    local idx=0 best_idx=0 best_score=-999

    # Collect all partitions matching fstype (skip loop devices).
    # lsblk -P (KEY="value" pairs) instead of positional columns: columnar
    # output collapses empty fields (e.g. missing FSTYPE) and shifts columns.
    local NAME FSTYPE SIZE PKNAME lsblk_line
    while IFS= read -r lsblk_line; do
        NAME=""; FSTYPE=""; SIZE=""; PKNAME=""
        eval "$lsblk_line"    # safe: lsblk -P hex-escapes unsafe characters
        local name="$NAME" fs="$FSTYPE" size="$SIZE" disk="$PKNAME"
        [ -n "$name" ] || continue
        [[ "$fs" =~ ^($fstype)$ ]] || continue
        echo "$name" | grep -q "^loop" && continue

        local dev="/dev/$name"
        local label partlabel
        label=$(blkid -s LABEL -o value "$dev" 2>/dev/null || echo "")
        partlabel=$(blkid -s PARTLABEL -o value "$dev" 2>/dev/null || echo "")
        local disp="${label:-${partlabel:-(none)}}"

        # Score this candidate
        local score=0
        # Strongly prefer NVMe over USB/SATA
        [[ "$dev" == *nvme* ]] && score=$((score + 100))
        # Bonus for label matching the expected role
        if [ -n "$label_hint" ]; then
            echo "$label $partlabel" | grep -Eqi "$label_hint" 2>/dev/null && score=$((score + 50))
        fi
        # Heavily penalize anything on the live USB disk
        [ -n "$LIVE_ROOT_DISK" ] && [ "$disk" = "$LIVE_ROOT_DISK" ] && score=$((score - 200))

        devs+=("$dev")
        disp_labels+=("$disp")
        sizes+=("$size")
        disks+=("$disk")
        scores+=("$score")

        if [ "$score" -gt "$best_score" ]; then
            best_score=$score
            best_idx=$idx
        fi
        idx=$((idx + 1))
    done < <(lsblk -P -o NAME,FSTYPE,SIZE,PKNAME 2>/dev/null)

    echo "" >&2
    echo -e "  ${CYAN}Select ${role} partition (${fstype}):${NC}" >&2

    # No candidates at all — ask for manual entry
    if [ ${#devs[@]} -eq 0 ]; then
        echo "  No $fstype partitions found!" >&2
        while true; do
            read -p "  Enter device path manually: " manual_dev
            [ -b "$manual_dev" ] && { echo "  Selected: $manual_dev" >&2; echo "$manual_dev"; return; }
            echo "  ERROR: $manual_dev is not a block device." >&2
        done
    fi

    # Display numbered candidates with recommended marker
    for ((i=0; i<${#devs[@]}; i++)); do
        local marker=""
        [ "$i" -eq "$best_idx" ] && marker=" ${GREEN}← recommended${NC}"
        printf "    %d) %-18s  %-22s  %8s  (%s)" \
            "$((i+1))" "${devs[$i]}" "${disp_labels[$i]}" "${sizes[$i]}" "${disks[$i]}" >&2
        echo -e "$marker" >&2
    done

    # Selection loop
    while true; do
        read -p "  Select [1-${#devs[@]}] or device path [default: $((best_idx+1))]: " choice
        choice="${choice:-$((best_idx+1))}"

        # Numeric selection
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#devs[@]}" ]; then
            local sel="${devs[$((choice-1))]}"
            echo -e "  Selected: ${GREEN}${sel}${NC}" >&2
            echo "$sel"
            return
        fi

        # Direct device path
        if [ -b "$choice" ]; then
            local actual_fs
            actual_fs=$(blkid -s TYPE -o value "$choice" 2>/dev/null || echo "unknown")
            if ! [[ "$actual_fs" =~ ^($fstype)$ ]]; then
                echo "  WARNING: $choice has '$actual_fs', expected '$fstype'." >&2
                read -p "  Accept anyway? (yes/no): " accept
                [ "$accept" != "yes" ] && continue
            fi
            echo -e "  Selected: ${GREEN}${choice}${NC}" >&2
            echo "$choice"
            return
        fi

        echo "  Invalid selection. Enter a number or device path." >&2
    done
}

# Non-interactive pinning: LUKS_TARGET_ROOT / LUKS_TARGET_BOOT / LUKS_TARGET_EFI
# skip the menu but still enforce the fstype (all display goes to stderr —
# stdout is captured by the caller).
pinned_partition() {
    # $1 = role, $2 = env var name, $3 = pinned device, $4 = fstype regex
    local role="$1" var="$2" dev="$3" fstype="$4" actual
    [ -b "$dev" ] || fatal "\$$var=$dev is not a block device."
    actual=$(blkid -s TYPE -o value "$dev" 2>/dev/null || echo "unknown")
    [[ "$actual" =~ ^($fstype)$ ]] \
        || fatal "\$$var=$dev has fstype '$actual', expected '$fstype'."
    log "  $role pinned via \$$var: $dev ($actual)" >&2
    echo "$dev"
}

# ROOT also accepts crypto_LUKS so an interrupted/half-configured previous
# run can be re-selected and resumed (see mode detection below).
if [ -n "${LUKS_TARGET_ROOT:-}" ]; then
    TARGET_ROOT=$(pinned_partition "ROOT" "LUKS_TARGET_ROOT" "$LUKS_TARGET_ROOT" "btrfs|crypto_LUKS")
else
    TARGET_ROOT=$(pick_partition "ROOT" "btrfs|crypto_LUKS" "fedora|root")
fi
if [ -n "${LUKS_TARGET_BOOT:-}" ]; then
    TARGET_BOOT=$(pinned_partition "BOOT" "LUKS_TARGET_BOOT" "$LUKS_TARGET_BOOT" "ext4")
else
    TARGET_BOOT=$(pick_partition "BOOT" "ext4" "boot")
fi
if [ -n "${LUKS_TARGET_EFI:-}" ]; then
    TARGET_EFI=$(pinned_partition "EFI" "LUKS_TARGET_EFI" "$LUKS_TARGET_EFI" "vfat")
else
    TARGET_EFI=$(pick_partition "EFI" "vfat" "efi|fedor")
fi

# ─── Stale Mapper Cross-Check ────────────────────────────────────────────────
# If ${LUKS_NAME} is open (e.g. kept from a previous run), it MUST be backed by
# the ROOT partition just selected. Otherwise every later step that reuses the
# mapper (discovery, config, verification) would run against a DIFFERENT device
# than the one LUKS_UUID/crypttab point at — cross-wiring two systems.
if [ -b /dev/mapper/${LUKS_NAME} ]; then
    MAPPER_BACKING=$(cryptsetup status ${LUKS_NAME} 2>/dev/null \
        | awk '$1 == "device:" {print $2; exit}')
    MAPPER_BACKING=$(readlink -f "$MAPPER_BACKING" 2>/dev/null || echo "${MAPPER_BACKING:-unknown}")
    TARGET_ROOT_REAL=$(readlink -f "$TARGET_ROOT")
    if [ "$MAPPER_BACKING" = "$TARGET_ROOT_REAL" ]; then
        log "Open ${LUKS_NAME} is backed by $TARGET_ROOT_REAL — OK to reuse."
    else
        err "/dev/mapper/${LUKS_NAME} is open but backed by: $MAPPER_BACKING"
        err "You selected ROOT: $TARGET_ROOT_REAL"
        err "Reusing this mapper would configure the WRONG system — closing it."
        if cryptsetup close ${LUKS_NAME} 2>/dev/null; then
            log "  Closed mismatched ${LUKS_NAME}; the selected device will be opened when needed."
        else
            fatal "Could not close ${LUKS_NAME} (still in use?). Close it manually and re-run."
        fi
    fi
fi

# ─── Mounted-Target Guard ────────────────────────────────────────────────────
# Live desktops (udisks) automount internal partitions, and cryptsetup
# reencrypt refuses busy devices — catch that NOW, not an hour after the
# user typed ENCRYPT and walked away.
ensure_unmounted() {
    # $1 = device; offer to unmount every mountpoint it currently has
    local dev="$1" mps mp
    # sort -r: unmount nested child mounts (/mnt/home) before parents (/mnt)
    mps=$(lsblk -no MOUNTPOINTS "$dev" 2>/dev/null | grep -v '^$' | sort -r || true)
    [ -n "$mps" ] || return 0
    warn "$dev is currently mounted at:"
    echo "$mps" | sed 's/^/    /'
    if [ "$DRY_RUN" = "1" ]; then
        warn "  [dry-run] a real run would require unmounting these first."
        return 0
    fi
    read -p "  Unmount it now? (yes/no): " UNMOUNT_OK
    [ "$UNMOUNT_OK" = "yes" ] || fatal "Cannot operate on a mounted device."
    while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        umount "$mp" || fatal "Could not unmount $mp — close whatever is using it and re-run."
    done <<< "$mps"
    log "  Unmounted $dev."
}
ensure_unmounted "$TARGET_ROOT"
if [ -b /dev/mapper/${LUKS_NAME} ]; then
    ensure_unmounted /dev/mapper/${LUKS_NAME}
fi

# ─── Same-Disk Sanity Check ──────────────────────────────────────────────────
DISK_ROOT=$(lsblk -no PKNAME "$TARGET_ROOT" 2>/dev/null | head -n1)
DISK_BOOT=$(lsblk -no PKNAME "$TARGET_BOOT" 2>/dev/null | head -n1)
DISK_EFI=$(lsblk -no PKNAME "$TARGET_EFI" 2>/dev/null | head -n1)
if [ "$DISK_ROOT" != "$DISK_BOOT" ] || [ "$DISK_ROOT" != "$DISK_EFI" ]; then
    warn "Selected partitions are on different disks!"
    echo "  ROOT: $TARGET_ROOT → $DISK_ROOT"
    echo "  BOOT: $TARGET_BOOT → $DISK_BOOT"
    echo "  EFI : $TARGET_EFI → $DISK_EFI"
    read -p "Proceed? (yes/no): " cross_disk
    [ "$cross_disk" = "yes" ] || fatal "Aborted."
fi

# ─── Already Encrypted / Resume Detection ────────────────────────────────────
# A previous run can be interrupted in two distinct places, and both are
# recoverable by re-running this script rather than aborting:
#   1. MID-ENCRYPTION: the LUKS2 header exists and carries the
#      'online-reencrypt' requirement flag. cryptsetup can finish the job
#      with `reencrypt --resume-only`; afterwards the config phase runs
#      exactly as in a fresh deployment.
#   2. AFTER ENCRYPTION, DURING CONFIG: the header is complete but
#      crypttab/fstab/initramfs/BLS work never finished. All config steps
#      are idempotent, so they can simply be re-driven against the
#      unlocked container ("config-only" mode).
DEPLOY_MODE="encrypt"          # encrypt | resume | config-only
if blkid "$TARGET_ROOT" | grep -q 'TYPE="crypto_LUKS"'; then
    echo ""
    warn "$TARGET_ROOT already contains a LUKS header."
    if ! cryptsetup luksDump "$TARGET_ROOT" >/dev/null 2>&1; then
        err "blkid reports crypto_LUKS but 'cryptsetup luksDump' cannot read the header."
        echo "  Try repairing it first, then re-run this script:"
        echo "    cryptsetup repair $TARGET_ROOT"
        fatal "LUKS header unreadable — see docs/RECOVERY.md."
    fi
    if cryptsetup luksDump "$TARGET_ROOT" 2>/dev/null | grep -q 'online-reencrypt'; then
        warn "The header carries the 'online-reencrypt' requirement flag:"
        warn "a previous in-place encryption was INTERRUPTED partway through."
        echo ""
        echo "  The safe fix is to let cryptsetup finish the encryption"
        echo "  (reencrypt --resume-only) and then redo the configuration"
        echo "  phase. This script can do both now."
        echo ""
        read -p "  Resume the interrupted encryption now? (yes/no): " RESUME_OK
        [ "$RESUME_OK" = "yes" ] \
            || fatal "Aborted. Resume manually with: cryptsetup reencrypt --resume-only $TARGET_ROOT"
        DEPLOY_MODE="resume"
    else
        warn "The header is complete — the encryption itself FINISHED."
        echo ""
        echo "  If a previous run died during the configuration phase (crypttab,"
        echo "  fstab, initramfs, BLS entries), re-running just that phase fixes"
        echo "  it: this script will unlock the container, redo every config"
        echo "  step (all idempotent) and re-run the verification gate."
        echo ""
        echo "  If this partition is an encrypted system that already boots"
        echo "  fine, answer no."
        echo ""
        read -p "  Re-run configuration + verification on $TARGET_ROOT? (yes/no): " CONFIG_OK
        [ "$CONFIG_OK" = "yes" ] || fatal "Aborted — partition is already LUKS."
        DEPLOY_MODE="config-only"
    fi
fi

# Resume the interrupted encryption immediately — a half-encrypted disk is the
# most fragile state there is, so finish it before anything else. Afterwards
# the remaining work is identical to the config-only path.
if [ "$DEPLOY_MODE" = "resume" ]; then
    echo ""
    log "Resuming interrupted LUKS encryption (you will be asked for the passphrase)..."
    if ! cryptsetup reencrypt --resume-only --verbose "${CRYPT_PASS_ARGS[@]}" "${CRYPT_BATCH_ARGS[@]}" "$TARGET_ROOT"; then
        # A HARD interruption (power loss, kill -9) leaves the reencryption
        # journal dirty and --resume-only refuses with "Device requires
        # reencryption recovery. Run repair first." — verified in
        # tests/loopback-core-test.sh. cryptsetup repair fixes the journal,
        # then resume proceeds normally.
        warn "  Resume refused — running 'cryptsetup repair' (dirty reencryption journal after a hard interrupt), then retrying..."
        cryptsetup repair "${CRYPT_PASS_ARGS[@]}" "${CRYPT_BATCH_ARGS[@]}" "$TARGET_ROOT" \
            || fatal "cryptsetup repair failed. Do NOT wipe or reformat anything — see docs/RECOVERY.md."
        cryptsetup reencrypt --resume-only --verbose "${CRYPT_PASS_ARGS[@]}" "${CRYPT_BATCH_ARGS[@]}" "$TARGET_ROOT" \
            || fatal "Resume still failing after repair. Do NOT wipe or reformat anything — see docs/RECOVERY.md."
    fi
    log "  Reencryption finished."
    DEPLOY_MODE="config-only"
fi

# In config-only mode the raw partition is a LUKS container, so discovery
# (subvolumes, fstab, UUIDs) must read through the opened mapper device.
DISCOVERY_DEV="$TARGET_ROOT"
if [ "$DEPLOY_MODE" = "config-only" ]; then
    if [ ! -b /dev/mapper/${LUKS_NAME} ]; then
        log "Unlocking $TARGET_ROOT (passphrase required)..."
        cryptsetup open "${CRYPT_PASS_ARGS[@]}" "$TARGET_ROOT" ${LUKS_NAME}
    fi
    DISCOVERY_DEV="/dev/mapper/${LUKS_NAME}"
fi

# ─── Btrfs Subvolume Auto-Discovery ─────────────────────────────────────────
echo ""
log "Auto-discovering btrfs subvolumes and system configuration..."

mkdir -p /mnt_temp

# Mount top-level subvolume (ID 5) to see all subvolume directories
# (through the opened mapper in config-only mode, raw partition otherwise)
mount -o subvolid=5,ro "$DISCOVERY_DEV" /mnt_temp

# Auto-detect which subvolume contains the system
ROOT_SUBVOL=""
for try_sub in root @rootfs @; do
    if [ -f "/mnt_temp/${try_sub}/etc/fstab" ]; then
        ROOT_SUBVOL="$try_sub"
        break
    fi
done

if [ -z "$ROOT_SUBVOL" ]; then
    err "Cannot auto-detect root subvolume. Available subvolumes:"
    btrfs subvolume list /mnt_temp 2>/dev/null || true
    umount /mnt_temp
    rmdir /mnt_temp
    fatal "Please check btrfs subvolume layout."
fi

# Parse home subvolume name from fstab
HOME_SUBVOL=$(sed -n 's|^[^#]*[[:space:]]/home[[:space:]]\+btrfs[[:space:]]\+.*subvol=\([^,[:space:]]*\).*|\1|p' \
    "/mnt_temp/${ROOT_SUBVOL}/etc/fstab" | head -1)
[ -n "$HOME_SUBVOL" ] || HOME_SUBVOL="home"

log "  Discovered subvolumes: root='$ROOT_SUBVOL', home='$HOME_SUBVOL'"

# Verify the subvolumes actually exist
[ -d "/mnt_temp/${ROOT_SUBVOL}" ] || fatal "Root subvolume '$ROOT_SUBVOL' directory not found!"
if [ "$HOME_SUBVOL" != "$ROOT_SUBVOL" ]; then
    [ -d "/mnt_temp/${HOME_SUBVOL}" ] || warn "Home subvolume '$HOME_SUBVOL' directory not found — may be nested."
fi

# Capture UUIDs before encryption. In config-only mode the raw partition
# holds the LUKS header, so the btrfs UUID must be read from the open mapper.
if [ "$DEPLOY_MODE" = "config-only" ]; then
    BTRFS_UUID=$(blkid -s UUID -o value /dev/mapper/${LUKS_NAME})
else
    BTRFS_UUID=$(blkid -s UUID -o value "$TARGET_ROOT")
fi
BOOT_UUID=$(blkid -s UUID -o value "$TARGET_BOOT")
EFI_UUID=$(blkid -s UUID -o value "$TARGET_EFI")

# ─── fstab Cross-Validation ─────────────────────────────────────────────────
# Verify the BOOT/EFI partitions picked in the menu are the SAME ones the
# target's own fstab expects. On a disk with several installs side by side it
# is easy to pick a boot partition that belongs to a *different* install —
# and this script would then write kernels, BLS entries and GRUB config into
# the wrong system, breaking both.
TARGET_FSTAB="/mnt_temp/${ROOT_SUBVOL}/etc/fstab"
fstab_uuid_for() {
    # $1 = mountpoint; prints the UUID= value of its non-comment fstab line, if any
    awk -v mp="$1" '$1 !~ /^#/ && $2 == mp { print $1; exit }' "$TARGET_FSTAB" 2>/dev/null \
        | sed -n 's/^UUID=//p'
}
cross_check_part() {
    # $1 = role, $2 = mountpoint, $3 = selected device, $4 = selected device's UUID
    local want
    want=$(fstab_uuid_for "$2" || true)   # unreadable fstab ⇒ empty ⇒ skip, not die
    if [ -z "$want" ]; then
        warn "  fstab cross-check: target fstab has no UUID= entry for $2 — skipping $1 check."
        return 0
    fi
    if [ "$want" = "$4" ]; then
        log "  fstab cross-check OK: $2 → $3 (UUID matches target fstab)"
        return 0
    fi
    echo ""
    err "  fstab cross-check MISMATCH for $1:"
    err "    You selected      : $3 (UUID=$4)"
    err "    Target fstab wants: UUID=$want for $2"
    err "  The selected $1 partition likely belongs to a DIFFERENT install on"
    err "  this machine. Writing boot config there would break BOTH systems."
    read -p "  Use $3 anyway? (Type 'MISMATCH' to override): " XCHK
    [ "$XCHK" = "MISMATCH" ] || fatal "Fix the partition selection and re-run."
}
log "Cross-checking selected BOOT/EFI partitions against the target's fstab..."
cross_check_part "BOOT" "/boot"     "$TARGET_BOOT" "$BOOT_UUID"
cross_check_part "EFI"  "/boot/efi" "$TARGET_EFI"  "$EFI_UUID"

# ─── Pre-Encryption State Backup (to USB drive) ─────────────────────────────
log "  Saving pre-encryption state to USB drive..."
STATE_DIR="$SCRIPT_DIR/pre-luks-state-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$STATE_DIR"
cp "/mnt_temp/${ROOT_SUBVOL}/etc/fstab" "$STATE_DIR/fstab" 2>/dev/null || true
cp "/mnt_temp/${ROOT_SUBVOL}/etc/default/grub" "$STATE_DIR/grub-defaults" 2>/dev/null || true
cp "/mnt_temp/${ROOT_SUBVOL}/etc/kernel/cmdline" "$STATE_DIR/kernel-cmdline" 2>/dev/null || true
[ -f "/mnt_temp/${ROOT_SUBVOL}/etc/crypttab" ] && \
    cp "/mnt_temp/${ROOT_SUBVOL}/etc/crypttab" "$STATE_DIR/crypttab"
lsblk -o NAME,FSTYPE,LABEL,PARTLABEL,SIZE,UUID > "$STATE_DIR/lsblk.txt" 2>/dev/null || true
blkid > "$STATE_DIR/blkid.txt" 2>/dev/null || true
btrfs subvolume list /mnt_temp > "$STATE_DIR/btrfs-subvols.txt" 2>/dev/null || true
log "  Pre-encryption state saved to: $STATE_DIR/"

# ─── Check BLS entries for consistency ───────────────────────────────────────
BLS_ROOT_SUBVOL=""
if mount -o ro "$TARGET_BOOT" /mnt_temp/"${ROOT_SUBVOL}"/boot 2>/dev/null; then
    # Intentionally mount boot inside our temp tree to read BLS
    for bls_entry in /mnt_temp/"${ROOT_SUBVOL}"/boot/loader/entries/*.conf; do
        [ -f "$bls_entry" ] || continue
        echo "$bls_entry" | grep -q 'rescue' && continue
        bls_subvol=$(sed -n 's/.*rootflags=subvol=\([^[:space:]]*\).*/\1/p' "$bls_entry")
        if [ -n "$bls_subvol" ]; then
            BLS_ROOT_SUBVOL="$bls_subvol"
            break
        fi
    done
    cp /mnt_temp/"${ROOT_SUBVOL}"/boot/loader/entries/*.conf "$STATE_DIR/" 2>/dev/null || true
    umount /mnt_temp/"${ROOT_SUBVOL}"/boot 2>/dev/null || true
fi

if [ -n "$BLS_ROOT_SUBVOL" ] && [ "$BLS_ROOT_SUBVOL" != "$ROOT_SUBVOL" ]; then
    warn "BLS boot entry uses subvol='$BLS_ROOT_SUBVOL'"
    warn "  but fstab uses subvol='$ROOT_SUBVOL'"
    warn "  The script will mount and modify the fstab subvolume ('$ROOT_SUBVOL')."
    warn "  If the system boots from a DIFFERENT subvolume, config changes"
    warn "  may not take effect. Consider fixing this inconsistency first."
    read -p "  Continue anyway? (yes/no): " subvol_override
    [ "$subvol_override" = "yes" ] || fatal "Fix subvolume inconsistency first."
fi

# ─── Btrfs Free Space Check ─────────────────────────────────────────────────
FS_AVAIL_MB=$(df --block-size=1M /mnt_temp | tail -1 | awk '{print $4}')
log "  Free space: ${FS_AVAIL_MB} MiB"
# Only the 32M shrink needs headroom; config-only mode never resizes.
if [ "$DEPLOY_MODE" = "encrypt" ] && [ "$FS_AVAIL_MB" -lt 64 ]; then
    umount /mnt_temp
    rmdir /mnt_temp
    fatal "Less than 64 MiB free. Need at least 64 MiB. Free up space first."
fi

umount /mnt_temp
rmdir /mnt_temp

# ─── Optional Btrfs Integrity Check ─────────────────────────────────────────
echo ""
CHECK_DEV="$TARGET_ROOT"
[ "$DEPLOY_MODE" = "config-only" ] && CHECK_DEV="/dev/mapper/${LUKS_NAME}"
if [ "$DRY_RUN" = "1" ]; then
    DO_CHECK="n"
    log "[dry-run] Skipping the btrfs integrity check (a real run offers it here)."
else
    read -p "Run btrfs integrity check first? (Recommended, takes 5-30 min) [Y/n]: " DO_CHECK
fi
if [ "$DO_CHECK" != "n" ] && [ "$DO_CHECK" != "N" ]; then
    log "  Running btrfs check --readonly (this may take a while)..."
    if btrfs check --readonly "$CHECK_DEV" 2>&1 | tail -3; then
        log "  Btrfs check: PASSED"
    else
        err "  Btrfs check found errors!"
        read -p "  Continue despite btrfs errors? (Type 'FORCE' to override): " btrfs_override
        [ "$btrfs_override" = "FORCE" ] || fatal "Fix btrfs errors before encrypting."
    fi
else
    warn "  Skipping btrfs check."
fi

# ─── KDF Profile Selection ──────────────────────────────────────────────────
# Done here, just before the point of no return, so the estimates reflect the
# machine as it will actually be. Skipped when parameters are pinned by env.
if [ "$DEPLOY_MODE" = "config-only" ]; then
    KDF_PROFILE_NAME="(existing header — unchanged)"
    log "Config-only mode: the KDF is already fixed in the LUKS header; skipping profile menu."
elif [ "$KDF_PINNED_BY_ENV" -eq 1 ]; then
    KDF_PROFILE_NAME="custom (pinned by environment)"
    log "KDF pinned via environment: mem=$((LUKS_PBKDF_MEMORY / 1024)) MiB iters=$LUKS_PBKDF_ITER parallel=$LUKS_PBKDF_PARALLEL"
elif [ -n "${LUKS_PROFILE:-}" ]; then
    apply_kdf_profile "$LUKS_PROFILE" \
        || fatal "Unknown LUKS_PROFILE '$LUKS_PROFILE' (expected: aggressive, moderate, or fast)"
    log "KDF profile from environment: $KDF_PROFILE_NAME"
else
    echo ""
    log "Benchmarking argon2id on this machine to estimate unlock times..."
    EST_AGG=$(kdf_estimate_ms "$KDF_PROFILE_AGGRESSIVE_MEM" "$KDF_PROFILE_AGGRESSIVE_ITER" "$KDF_DEFAULT_PARALLEL" || echo "")
    EST_MOD=$(kdf_estimate_ms "$KDF_PROFILE_MODERATE_MEM"   "$KDF_PROFILE_MODERATE_ITER"   "$KDF_DEFAULT_PARALLEL" || echo "")
    EST_FAST=$(kdf_estimate_ms "$KDF_PROFILE_FAST_MEM"      "$KDF_PROFILE_FAST_ITER"       "$KDF_DEFAULT_PARALLEL" || echo "")
    [ -n "$EST_AGG$EST_MOD$EST_FAST" ] || warn "  Benchmark unavailable — showing profiles without time estimates."

    echo ""
    echo "  ════════════════════════════════════════════════════════════"
    echo "   LUKS2 KDF PROFILE"
    echo "   All three are argon2id. None uses pbkdf2."
    echo "  ════════════════════════════════════════════════════════════"
    echo ""
    printf "   1) aggressive    4 GiB, 12 iterations    unlock ~%s\n" "$(kdf_fmt_ms "${EST_AGG:-}")"
    echo   "      Strongest. A 24 GB GPU fits only ~6 guesses at once"
    echo   "      against this. 4 GiB is the ceiling an 8 GiB Mac can"
    echo   "      hold, so the extra cost goes into iterations."
    echo ""
    printf "   2) moderate      2 GiB,  6 iterations    unlock ~%s   [default]\n" "$(kdf_fmt_ms "${EST_MOD:-}")"
    echo   "      Strong. ~12 concurrent guesses on that same GPU."
    echo ""
    printf "   3) fast          1 GiB,  4 iterations    unlock ~%s\n" "$(kdf_fmt_ms "${EST_FAST:-}")"
    echo   "      Still memory-hard: ~24 at once. Comfortable on an M1."
    echo ""
    echo "  ════════════════════════════════════════════════════════════"
    echo "   argon2id needs its full memory for EVERY guess. That is"
    echo "   what caps an attacker's guess rate: they cannot trade"
    echo "   memory for speed. With a real passphrase (8+ diceware"
    echo "   words) an offline attack runs past 10^20 years. A short"
    echo "   or reused passphrase collapses that, whichever profile"
    echo "   you pick."
    echo ""
    echo "   Estimates come from cryptsetup benchmark on THIS machine;"
    echo "   approximate, and they shift with system load. cryptsetup"
    echo "   clamps the benchmark to what it can allocate right now, so"
    echo "   a profile above that clamp is extrapolated, not measured."
    echo "   You wait this long at EVERY boot. All three fit in the"
    echo "   initramfs, which has the machine to itself — so any of"
    echo "   them is safe on any Asahi-supported Mac."
    echo ""
    read -p "  Select KDF profile [1-3, default 2=moderate]: " KDF_CHOICE
    case "${KDF_CHOICE:-2}" in
        1) apply_kdf_profile aggressive ;;
        2) apply_kdf_profile moderate ;;
        3) apply_kdf_profile fast ;;
        *) fatal "Invalid selection '$KDF_CHOICE' — expected 1, 2 or 3." ;;
    esac
    log "  Selected: $KDF_PROFILE_NAME ($((LUKS_PBKDF_MEMORY / 1024)) MiB, ${LUKS_PBKDF_ITER} iterations)"
fi

# ─── Pre-Flight Summary ─────────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    PRE-FLIGHT SUMMARY                     ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "  ROOT    : $TARGET_ROOT  (UUID=$BTRFS_UUID, btrfs)"
echo "  BOOT    : $TARGET_BOOT  (UUID=$BOOT_UUID)"
echo "  EFI     : $TARGET_EFI   (UUID=$EFI_UUID)"
echo "  Subvols : root=$ROOT_SUBVOL, home=$HOME_SUBVOL"
echo "  Free    : ${FS_AVAIL_MB} MiB"
echo "  Arch    : $(uname -m)"
echo "  Crypto  : cryptsetup $CRYPTSETUP_VER"
echo "  Mode    : $DEPLOY_MODE"
if [ "$DEPLOY_MODE" = "config-only" ]; then
    echo "  KDF     : (existing LUKS header — unchanged)"
else
    echo "  KDF     : argon2id $KDF_PROFILE_NAME — $((LUKS_PBKDF_MEMORY / 1024)) MiB, ${LUKS_PBKDF_ITER} iterations, ${LUKS_PBKDF_PARALLEL} threads"
fi
[ -n "$BLS_ROOT_SUBVOL" ] && echo "  BLS boot: subvol=$BLS_ROOT_SUBVOL"
echo ""
if [ "$DEPLOY_MODE" = "config-only" ]; then
    echo -e "  ${YELLOW}${BOLD}Configuration-only mode: no data will be (re-)encrypted.${NC}"
    echo -e "  ${YELLOW}Boot configuration will be rewritten and re-verified.${NC}"
else
    echo -e "  ${RED}${BOLD}WARNING: This will perform IRREVERSIBLE in-place encryption.${NC}"
    echo -e "  ${RED}Ensure AC power is connected. Ensure you have a backup.${NC}"
fi
echo "  Pre-encryption state saved to: $STATE_DIR/"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
# ─── Dry-run: print the plan and stop here ──────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
    echo ""
    log "[dry-run] Detection, cross-checks and state backup are done. A real run would now:"
    if [ "$DEPLOY_MODE" = "encrypt" ]; then
        echo "  1. mount $TARGET_ROOT and: btrfs filesystem resize -32M  (skipped if already shrunk)"
        echo "  2. cryptsetup reencrypt --encrypt --type luks2 \\"
        echo "         --cipher aes-xts-plain64 --key-size 512 \\"
        echo "         --pbkdf argon2id --pbkdf-memory $LUKS_PBKDF_MEMORY \\"
        echo "         --pbkdf-parallel $LUKS_PBKDF_PARALLEL --pbkdf-force-iterations $LUKS_PBKDF_ITER \\"
        echo "         --hash sha512 --reduce-device-size 32M --resilience checksum $TARGET_ROOT"
    else
        echo "  1-2. (config-only: no shrink, no encryption)"
    fi
    echo "  3. open the container as /dev/mapper/${LUKS_NAME}; verify inner btrfs UUID"
    echo "  4. btrfs resize max; mount subvol=$ROOT_SUBVOL (+$HOME_SUBVOL, boot=$TARGET_BOOT, efi=$TARGET_EFI) and bind-mount for chroot"
    echo "  5. offer a recovery keyslot; back up the LUKS header to /boot + $STATE_DIR/"
    echo "  6. edit on the target: /etc/crypttab, /etc/fstab, /etc/default/grub,"
    echo "     /etc/kernel/cmdline, /etc/dracut.conf.d/99-luks.conf   (originals saved as *.pre-luks)"
    if [ "${LUKS_KEEP_SPLASH:-0}" != "1" ]; then
        echo "     and strip 'rhgb quiet' so the passphrase prompt is visible"
        echo "     (post-encryption-setup.sh restores them; LUKS_KEEP_SPLASH=1 to skip)"
    fi
    echo "  7. in chroot: rebuild ALL initramfs images, update ALL BLS entries (grubby),"
    echo "     regenerate /boot/grub2/grub.cfg (never the ESP stub), restorecon"
    echo "  8. run the verification gate; refuse the reboot message on any error"
    echo ""
    log "[dry-run] No changes were made to the target. Backups/plan artifacts: $STATE_DIR/"
    exit 0
fi

if [ "$DEPLOY_MODE" = "config-only" ]; then
    read -p "Type 'CONFIGURE' to redo the configuration phase: " CONFIRM
    [ "$CONFIRM" = "CONFIGURE" ] || fatal "Aborted."
else
    read -p "Type 'ENCRYPT' to begin — there is no going back: " CONFIRM
    [ "$CONFIRM" = "ENCRYPT" ] || fatal "Aborted."

    # ── Caps Lock trap ──────────────────────────────────────────────────────
    # 'ENCRYPT' is all caps, so it is natural to switch Caps Lock on to type it
    # and leave it on for the new passphrase a few seconds later. cryptsetup
    # asks for that passphrase twice, but both entries would be inverted the
    # same way, so its verification passes. The mistake surfaces at the boot
    # prompt — Caps Lock off, nothing works, and the volume holds the only copy
    # of the data. Ask the kernel's keyboard LED state and say so plainly.
    if [ -z "${LUKS_PASSPHRASE_FILE:-}" ]; then
        CAPS_STATE="unknown"
        for _led in /sys/class/leds/*::capslock/brightness; do
            [ -r "$_led" ] || continue
            if [ "$(cat "$_led" 2>/dev/null || echo 0)" != "0" ]; then
                CAPS_STATE="on"; break
            fi
            CAPS_STATE="off"
        done
        echo ""
        case "$CAPS_STATE" in
            on)
                warn "CAPS LOCK IS ON — turn it off before the passphrase prompt."
                warn "  You are about to set the passphrase this machine boots with."
                warn "  cryptsetup asks for it twice, but both entries would be"
                warn "  capitalised the same way, so it cannot catch this."
                read -p "  Press Enter once Caps Lock is OFF (or leave it on deliberately): " _
                ;;
            *)
                log "  If you switched Caps Lock on to type ENCRYPT, switch it off now —"
                log "  cryptsetup's type-it-twice check cannot catch a passphrase that is"
                log "  inverted both times, and the boot prompt is where you would find out."
                ;;
        esac
    fi
fi

log "Starting LUKS deployment. Pre-encryption btrfs UUID: $BTRFS_UUID"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: Shrink Btrfs
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
if [ "$DEPLOY_MODE" = "config-only" ]; then
    log "[1/8] Skipped (config-only mode) — btrfs shrink not needed."
else
    log "[1/8] Shrinking btrfs filesystem by 32M for LUKS2 header..."

    # Idempotency: if a previous interrupted run already shrank the fs, don't
    # shrink again (each retry would silently eat another 32M until resize max).
    # dump-super reads the fs size straight off the unmounted device.
    DEV_BYTES=$(blockdev --getsize64 "$TARGET_ROOT" 2>/dev/null || echo 0)
    FS_BYTES=$(btrfs inspect-internal dump-super "$TARGET_ROOT" 2>/dev/null \
        | awk '/^total_bytes/{print $2; exit}')
    if [ -n "$FS_BYTES" ] && [ "$DEV_BYTES" -gt 0 ] \
       && [ $(( DEV_BYTES - FS_BYTES )) -ge $(( 32 * 1024 * 1024 )) ]; then
        log "  Btrfs is already >= 32M smaller than the partition (fs=$FS_BYTES, dev=$DEV_BYTES) — skipping shrink."
        SKIP_SHRINK=1
    else
        SKIP_SHRINK=0
    fi

    mkdir -p /mnt_temp
    mount "$TARGET_ROOT" /mnt_temp

    # Verify btrfs is healthy enough to resize
    if ! btrfs filesystem df /mnt_temp >/dev/null 2>&1; then
        umount /mnt_temp
        rmdir /mnt_temp
        fatal "Cannot read btrfs filesystem. Partition may be damaged."
    fi

    if [ "$SKIP_SHRINK" != "1" ]; then
        btrfs filesystem resize -32M /mnt_temp
        sync
    fi
    # Verify the resize took effect
    NEW_SIZE=$(btrfs filesystem usage -b /mnt_temp 2>/dev/null | grep "Device size:" | awk '{print $3}' || echo "unknown")
    log "  Btrfs resized. Device size: $NEW_SIZE"
    umount /mnt_temp
    rmdir /mnt_temp
    log "  Btrfs shrink complete."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: In-Place LUKS2 Encryption
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
if [ "$DEPLOY_MODE" = "config-only" ]; then
    log "[2/8] Skipped (config-only mode) — partition is already encrypted."
else
    log "[2/8] Encrypting partition with LUKS2..."
    log "  KDF pinned: argon2id  mem=$(( LUKS_PBKDF_MEMORY / 1024 )) MiB (${LUKS_PBKDF_MEMORY} KiB)  time-cost(iters)=${LUKS_PBKDF_ITER}  parallel=${LUKS_PBKDF_PARALLEL}"
    log "  Hash: sha512  (AF splitter + LUKS2 volume-key digest; --hash sets both)"
    log "  Cipher: aes-xts-plain64  key-size=512 (AES-256-XTS)"
    log "  You will be prompted to set a passphrase (type it twice)."
    log "  Check Caps Lock first — both entries would be inverted, so it verifies."
    log "  If interrupted, just re-run this script — it resumes automatically."
    echo ""

    # LUKS2 KDF pinned for fleet consistency — do NOT fall back to cryptsetup's
    # auto-benchmark defaults (they pick sha256 + variable, time-benchmarked memory).
    # --pbkdf-force-iterations REPLACES time benchmarking, so no --iter-time here.
    # Unlock at boot re-runs this KDF inside the initramfs, so LUKS_PBKDF_MEMORY KiB
    # must be allocatable there — fine for every profile: the initramfs has the
    # machine to itself, so even 4 GiB (aggressive) fits on an 8 GiB M1.
    cryptsetup reencrypt \
        --encrypt \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --pbkdf argon2id \
        --pbkdf-memory "$LUKS_PBKDF_MEMORY" \
        --pbkdf-parallel "$LUKS_PBKDF_PARALLEL" \
        --pbkdf-force-iterations "$LUKS_PBKDF_ITER" \
        --hash sha512 \
        --reduce-device-size 32M \
        --resilience checksum \
        --verbose \
        "${CRYPT_PASS_ARGS[@]}" "${CRYPT_BATCH_ARGS[@]}" \
        "$TARGET_ROOT"

    log "  Encryption complete."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Open & Verify LUKS Container
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
log "[3/8] Verifying LUKS header and opening container..."

# Verify LUKS header integrity
log "  LUKS header dump:"
cryptsetup luksDump "$TARGET_ROOT" 2>&1 | grep -E '(Version|Cipher|Hash|Key Slot [0-9])' | head -10 || true
echo ""

LUKS_UUID=$(blkid -s UUID -o value "$TARGET_ROOT")
[ -n "$LUKS_UUID" ] || fatal "Cannot read LUKS UUID — header may be corrupt! Check: cryptsetup luksDump $TARGET_ROOT"
log "  LUKS UUID: $LUKS_UUID"

# Open the LUKS container (already open if we came in via config-only mode)
if [ -b /dev/mapper/${LUKS_NAME} ]; then
    log "  Container already open: /dev/mapper/${LUKS_NAME}"
else
    cryptsetup open "${CRYPT_PASS_ARGS[@]}" "$TARGET_ROOT" ${LUKS_NAME}
fi

# Verify mapper device exists
[ -b /dev/mapper/${LUKS_NAME} ] || fatal "/dev/mapper/${LUKS_NAME} does not exist after open!"
log "  Mapper device: /dev/mapper/${LUKS_NAME} OK"

# Verify the btrfs filesystem is intact inside LUKS
INNER_FSTYPE=$(blkid -s TYPE -o value /dev/mapper/${LUKS_NAME} 2>/dev/null || echo "")
INNER_UUID=$(blkid -s UUID -o value /dev/mapper/${LUKS_NAME} 2>/dev/null || echo "")
log "  Inner filesystem: type=$INNER_FSTYPE UUID=$INNER_UUID"

if [ "$INNER_FSTYPE" != "btrfs" ]; then
    fatal "Inner filesystem is '$INNER_FSTYPE', expected 'btrfs'! Encryption may have corrupted data."
fi
if [ "$INNER_UUID" != "$BTRFS_UUID" ]; then
    err "Inner btrfs UUID changed! Was: $BTRFS_UUID, Now: $INNER_UUID"
    err "  This should NEVER happen — in-place encryption preserves the inner"
    err "  filesystem. It usually means the open mapper is backed by a DIFFERENT"
    err "  device than expected, or the filesystem was damaged. Continuing"
    err "  would write boot configuration for the wrong system."
    read -p "  Continue with UUID $INNER_UUID anyway? (Type 'UUID-CHANGED' to override): " UUID_OVERRIDE
    [ "$UUID_OVERRIDE" = "UUID-CHANGED" ] || fatal "Aborted — investigate before configuring anything."
    warn "  Override accepted — updating BTRFS_UUID to $INNER_UUID."
    BTRFS_UUID="$INNER_UUID"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: Resize Btrfs + Mount for Chroot
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
log "[4/8] Resizing btrfs to fill LUKS container and mounting..."

# Resize btrfs to reclaim any space
mkdir -p /mnt_temp
mount /dev/mapper/${LUKS_NAME} /mnt_temp
btrfs filesystem resize max /mnt_temp 2>/dev/null || true
umount /mnt_temp
rmdir /mnt_temp
log "  Btrfs resize max complete."

# Mount with correct subvolumes for chroot
log "  Mounting filesystems for chroot..."
mount -o "subvol=$ROOT_SUBVOL" /dev/mapper/${LUKS_NAME} /mnt

# Verify we got the right subvolume
if [ ! -f /mnt/etc/fstab ]; then
    err "  /mnt/etc/fstab not found after mounting subvol=$ROOT_SUBVOL!"
    err "  Trying subvolid=5 (top-level) as fallback..."
    umount /mnt
    mount -o subvolid=5 /dev/mapper/${LUKS_NAME} /mnt
    if [ -f "/mnt/${ROOT_SUBVOL}/etc/fstab" ]; then
        log "  Found fstab at /mnt/${ROOT_SUBVOL}/etc/fstab — remounting correctly..."
        umount /mnt
        mount -o "subvol=${ROOT_SUBVOL}" /dev/mapper/${LUKS_NAME} /mnt
    else
        fatal "Cannot find /etc/fstab in any mount configuration."
    fi
fi

# Mount home subvolume (if separate from root)
if [ "$HOME_SUBVOL" != "$ROOT_SUBVOL" ]; then
    mkdir -p /mnt/home
    mount -o "subvol=$HOME_SUBVOL" /dev/mapper/${LUKS_NAME} /mnt/home
fi

# Mount boot and EFI
mount "$TARGET_BOOT" /mnt/boot
mount "$TARGET_EFI" /mnt/boot/efi

# Bind-mount virtual filesystems for chroot
for i in /dev /dev/pts /proc /sys /run; do
    mount --bind "$i" "/mnt$i"
done
if [ -d /sys/firmware/efi/efivars ]; then
    mount --bind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars 2>/dev/null || true
fi
log "  All mounts complete."

# ─── Verify chroot environment has required tools ────────────────────────────
log "  Verifying chroot tools..."
for tool in dracut grub2-mkconfig; do
    if chroot /mnt command -v "$tool" &>/dev/null; then
        log "    $tool: found"
    else
        # Try alternatives
        case "$tool" in
            grub2-mkconfig)
                if chroot /mnt command -v grub-mkconfig &>/dev/null; then
                    log "    grub-mkconfig: found (alternative)"
                else
                    warn "    $tool: NOT FOUND"
                fi
                ;;
            *)
                warn "    $tool: NOT FOUND"
                ;;
        esac
    fi
done
if chroot /mnt command -v grubby &>/dev/null; then
    log "    grubby: found (for BLS entries)"
else
    warn "    grubby: NOT FOUND — BLS entries must be updated manually!"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: LUKS Header Backup
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
log "[5/8] Recovery key + LUKS header backup..."

# ─── 5a: Optional recovery key (second keyslot) ─────────────────────────────
# A random 256-bit key in its own keyslot: if the passphrase is ever forgotten,
# this key still unlocks the volume. Enrolled BEFORE the header backup below so
# the backup contains the new slot. Saved to the deployment drive — the user
# must move it to secure OFFLINE storage afterwards.
# Non-interactive: LUKS_RECOVERY_KEY=yes|no
SLOTS_IN_USE=$(cryptsetup luksDump "$TARGET_ROOT" 2>/dev/null | grep -cE '^[[:space:]]+[0-9]+: luks2' || true)
RK_CHOICE="${LUKS_RECOVERY_KEY:-}"
if [ -z "$RK_CHOICE" ]; then
    echo ""
    echo "  A recovery key is a random 64-hex-character key in a second LUKS"
    echo "  keyslot. It unlocks the volume if the passphrase is ever forgotten."
    echo "  It will be written to $STATE_DIR/ — move it to secure offline"
    echo "  storage (NOT this machine) once deployment is done."
    if [ "${SLOTS_IN_USE:-0}" -gt 1 ]; then
        warn "  Note: $SLOTS_IN_USE keyslots are already in use — a recovery key may already be enrolled."
    fi
    read -p "  Generate and enroll a recovery key now? [Y/n]: " RK_CHOICE
fi
case "$RK_CHOICE" in
    n|N|no|NO)
        warn "  Skipping recovery key (passphrase will be the only way in)."
        ;;
    *)
        RK_FILE="$STATE_DIR/recovery-key.txt"
        # 32 random bytes as 64 hex chars: unambiguous to read back and type.
        RECOVERY_KEY=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
        if [ "${#RECOVERY_KEY}" -ne 64 ]; then
            warn "  Could not generate a recovery key (urandom read failed?) — skipping."
        else
            # No trailing newline: the file must byte-match what a human would
            # later TYPE at a passphrase prompt.
            install -m 600 /dev/null "$RK_FILE"
            printf '%s' "$RECOVERY_KEY" > "$RK_FILE"
            log "  Enrolling recovery key (enter the volume passphrase when asked)..."
            if cryptsetup luksAddKey "${CRYPT_PASS_ARGS[@]}" "$TARGET_ROOT" "$RK_FILE" \
                   --pbkdf argon2id \
                   --pbkdf-memory "$LUKS_PBKDF_MEMORY" \
                   --pbkdf-parallel "$LUKS_PBKDF_PARALLEL" \
                   --pbkdf-force-iterations "$LUKS_PBKDF_ITER"; then
                # Keep the keyfile PURE (usable as-is with --key-file); the
                # instructions live in a sibling README instead.
                cat > "$STATE_DIR/recovery-key-README.txt" <<RK_EOF
LUKS recovery key for $TARGET_ROOT (UUID=$LUKS_UUID), enrolled $(date '+%Y-%m-%d %H:%M').

The key is the 64 hex characters in recovery-key.txt (exactly, no trailing
newline). Two ways to use it if the passphrase is ever lost:
  - Type/paste it at the boot passphrase prompt, or
  - From a live USB:
      cryptsetup open $TARGET_ROOT ${LUKS_NAME} --key-file recovery-key.txt

MOVE BOTH FILES TO SECURE OFFLINE STORAGE — anyone holding the key can
unlock the disk.
RK_EOF
                chmod 600 "$STATE_DIR/recovery-key-README.txt"
                log "  Recovery key enrolled. Saved to: $RK_FILE"
            else
                rm -f "$RK_FILE"
                warn "  Recovery key enrollment FAILED (wrong passphrase?) — continuing without it."
                warn "  You can enroll one later: cryptsetup luksAddKey $TARGET_ROOT"
            fi
        fi
        ;;
esac

# ─── 5b: LUKS header backup ─────────────────────────────────────────────────
# luksHeaderBackup refuses to overwrite; drop any stale copy from a previous
# run first (the current header is always the authoritative one to keep).
rm -f /mnt/boot/luks-header-backup.img
cryptsetup luksHeaderBackup "$TARGET_ROOT" \
    --header-backup-file /mnt/boot/luks-header-backup.img
chmod 400 /mnt/boot/luks-header-backup.img
# Also save to USB drive
cp /mnt/boot/luks-header-backup.img "$STATE_DIR/luks-header-backup.img"
log "  Header backup: /boot/luks-header-backup.img"
log "  Header backup: $STATE_DIR/luks-header-backup.img (USB copy)"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6: Update System Configuration
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
log "[6/8] Updating system configuration..."

# ─── 6a: crypttab ────────────────────────────────────────────────────────────
if [ ! -f /mnt/etc/crypttab ]; then
    echo "# /etc/crypttab — LUKS encrypted devices" > /mnt/etc/crypttab
    log "  Created /etc/crypttab"
fi
if grep -q "$LUKS_NAME" /mnt/etc/crypttab 2>/dev/null; then
    warn "  $LUKS_NAME already in crypttab — updating."
    sed -i "/^${LUKS_NAME}[[:space:]]/d" /mnt/etc/crypttab
fi
echo "$LUKS_NAME UUID=$LUKS_UUID none luks,discard" >> /mnt/etc/crypttab
log "  crypttab: added $LUKS_NAME UUID=$LUKS_UUID"
echo "  --- /etc/crypttab ---"
cat /mnt/etc/crypttab

# ─── 6b: fstab ───────────────────────────────────────────────────────────────
cp /mnt/etc/fstab /mnt/etc/fstab.pre-luks
log "  fstab backed up to fstab.pre-luks"

if grep -q "UUID=$BTRFS_UUID" /mnt/etc/fstab; then
    sed -i "s|UUID=$BTRFS_UUID|/dev/mapper/$LUKS_NAME|g" /mnt/etc/fstab
    log "  fstab: UUID=$BTRFS_UUID → /dev/mapper/$LUKS_NAME"
elif grep -q "/dev/mapper/$LUKS_NAME" /mnt/etc/fstab; then
    log "  fstab already references /dev/mapper/$LUKS_NAME (previous run) — keeping."
else
    warn "  UUID=$BTRFS_UUID not found in fstab!"
    echo "  Current btrfs entries:"
    grep -E "^[^#].*btrfs" /mnt/etc/fstab || echo "  (none)"
    fatal "  fstab update failed — cannot find original btrfs UUID."
fi

# Verify fstab was updated correctly
if ! grep -q "$LUKS_NAME" /mnt/etc/fstab; then
    fatal "  fstab does not reference $LUKS_NAME after update!"
fi
if grep -q "UUID=$BTRFS_UUID" /mnt/etc/fstab; then
    fatal "  fstab still contains old UUID=$BTRFS_UUID after replacement!"
fi
echo "  --- /etc/fstab ---"
cat /mnt/etc/fstab

# ─── 6c: /etc/default/grub ───────────────────────────────────────────────────
log "  Updating /etc/default/grub..."
cp /mnt/etc/default/grub /mnt/etc/default/grub.pre-luks

# GRUB_ENABLE_CRYPTODISK=y (allows GRUB to access encrypted partitions if needed)
if ! grep -q "^GRUB_ENABLE_CRYPTODISK=y" /mnt/etc/default/grub; then
    echo "GRUB_ENABLE_CRYPTODISK=y" >> /mnt/etc/default/grub
    log "    Added GRUB_ENABLE_CRYPTODISK=y"
fi

# Add rd.luks.uuid AND rd.luks.name to GRUB_CMDLINE_LINUX
LUKS_BOOT_ARGS="rd.luks.uuid=$LUKS_UUID rd.luks.name=${LUKS_UUID}=$LUKS_NAME"
CURRENT_CMDLINE=$(grep "^GRUB_CMDLINE_LINUX=" /mnt/etc/default/grub | sed 's/^GRUB_CMDLINE_LINUX="//' | sed 's/"$//')
if ! echo "$CURRENT_CMDLINE" | grep -q "rd.luks.uuid=$LUKS_UUID"; then
    NEW_CMDLINE="$LUKS_BOOT_ARGS $CURRENT_CMDLINE"
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$NEW_CMDLINE\"|" /mnt/etc/default/grub
    log "    Added $LUKS_BOOT_ARGS to GRUB_CMDLINE_LINUX"
fi
echo "  --- /etc/default/grub ---"
cat /mnt/etc/default/grub

# ─── 6d: /etc/kernel/cmdline (BLS source of truth for kernel-install) ────────
log "  Updating /etc/kernel/cmdline..."
if [ -f /mnt/etc/kernel/cmdline ]; then
    cp /mnt/etc/kernel/cmdline /mnt/etc/kernel/cmdline.pre-luks
    KERN_CMDLINE=$(cat /mnt/etc/kernel/cmdline | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    if ! echo "$KERN_CMDLINE" | grep -q "rd.luks.uuid=$LUKS_UUID"; then
        echo "$KERN_CMDLINE $LUKS_BOOT_ARGS" > /mnt/etc/kernel/cmdline
        log "    Added LUKS params to /etc/kernel/cmdline"
    fi
else
    warn "  /etc/kernel/cmdline not found — creating it."
    echo "root=UUID=$BTRFS_UUID ro rootflags=subvol=$ROOT_SUBVOL $LUKS_BOOT_ARGS rhgb quiet" \
        > /mnt/etc/kernel/cmdline
fi
echo "  --- /etc/kernel/cmdline ---"
cat /mnt/etc/kernel/cmdline

# ─── 6e: dracut LUKS module config ───────────────────────────────────────────
log "  Configuring dracut LUKS modules..."
mkdir -p /mnt/etc/dracut.conf.d
cat > /mnt/etc/dracut.conf.d/99-luks.conf <<'DRACUT_CONF'
# Added by luks-deploy.sh — ensure initramfs includes LUKS unlock support
add_dracutmodules+=" crypt dm btrfs "
# Belt-and-suspenders for the kernel-side crypto stack: the crypt dracut
# module's dependency graph usually pulls these, but a missing dm-crypt.ko in
# the initramfs = an unopenable root at boot, so force it explicitly.
# (add_drivers only warns if a name is builtin/absent — safe everywhere.)
add_drivers+=" dm-crypt "
DRACUT_CONF
log "    Created /etc/dracut.conf.d/99-luks.conf (crypt+dm+btrfs modules, dm-crypt driver pinned)"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 7: Rebuild Initramfs + Update BLS + Rebuild GRUB (in chroot)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
log "[7/8] Rebuilding initramfs, BLS entries, and GRUB config..."

# Pass required variables into the chroot via a sourced env file
cat > /mnt/tmp/.luks-deploy-env <<EOF
LUKS_UUID="$LUKS_UUID"
LUKS_NAME="$LUKS_NAME"
BTRFS_UUID="$BTRFS_UUID"
LUKS_BOOT_ARGS="$LUKS_BOOT_ARGS"
LUKS_KEEP_SPLASH="${LUKS_KEEP_SPLASH:-0}"
EOF

CHROOT_RC=0
chroot /mnt /bin/bash <<'CHROOT_SCRIPT' || CHROOT_RC=$?
# ── Inside chroot ──────────────────────────────────────────────────────────
source /tmp/.luks-deploy-env
rm -f /tmp/.luks-deploy-env
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

ERRORS=0
echo ""
echo "[CHROOT] ═══════════════════════════════════════════════"
echo "[CHROOT] Architecture : $(uname -m)"
echo "[CHROOT] LUKS UUID    : $LUKS_UUID"
echo "[CHROOT] Mapper name  : $LUKS_NAME"
echo "[CHROOT] ═══════════════════════════════════════════════"
echo ""

# ── 7a: Rebuild initramfs for ALL kernels ──────────────────────────────────
# NOTE: We do NOT delete existing initramfs first.
# dracut --force overwrites in place. This way, if dracut fails for one
# kernel, the other kernels still have working initramfs images.
echo "[CHROOT] Rebuilding initramfs for all installed kernels..."

if command -v dracut &>/dev/null; then
    DRACUT_VER=$(dracut --version 2>/dev/null || echo "unknown")
    echo "[CHROOT] dracut version: $DRACUT_VER"

    if dracut --help 2>&1 | grep -q -- '--regenerate-all'; then
        echo "[CHROOT] Using dracut --regenerate-all --force..."
        if ! dracut --regenerate-all --force 2>&1; then
            echo "[CHROOT] WARN: --regenerate-all failed, trying per-kernel..."
            for kernel in /boot/vmlinuz-*; do
                [ -f "$kernel" ] || continue
                kver=$(basename "$kernel" | sed 's/vmlinuz-//')
                echo "[CHROOT] Building initramfs for $kver ..."
                if ! dracut --force "/boot/initramfs-${kver}.img" "$kver" 2>&1; then
                    echo "[CHROOT] WARN: dracut failed for $kver, retrying with explicit modules..."
                    if ! dracut --force --add "crypt dm btrfs" "/boot/initramfs-${kver}.img" "$kver" 2>&1; then
                        echo "[CHROOT] FAIL: dracut failed for $kver even with explicit modules"
                        ERRORS=$((ERRORS + 1))
                    fi
                fi
            done
        fi
    else
        for kernel in /boot/vmlinuz-*; do
            [ -f "$kernel" ] || continue
            kver=$(basename "$kernel" | sed 's/vmlinuz-//')
            echo "[CHROOT] Building initramfs for $kver ..."
            if ! dracut --force "/boot/initramfs-${kver}.img" "$kver" 2>&1; then
                echo "[CHROOT] FAIL: dracut failed for $kver"
                ERRORS=$((ERRORS + 1))
            fi
        done
    fi
elif command -v mkinitcpio &>/dev/null; then
    echo "[CHROOT] Using mkinitcpio -P..."
    mkinitcpio -P 2>&1 || ERRORS=$((ERRORS + 1))
elif command -v update-initramfs &>/dev/null; then
    echo "[CHROOT] Using update-initramfs..."
    for kernel in /boot/vmlinuz-*; do
        [ -f "$kernel" ] || continue
        kver=$(basename "$kernel" | sed 's/vmlinuz-//')
        update-initramfs -c -k "$kver" 2>&1 || ERRORS=$((ERRORS + 1))
    done
fi

# ── 7b: Verify initramfs images contain cryptsetup ─────────────────────────
echo ""
echo "[CHROOT] Verifying initramfs images..."
INITRD_FOUND=0
for initrd in /boot/initramfs-*.img /boot/initrd.img-*; do
    [ -f "$initrd" ] || continue
    # Skip rescue/fallback images (they may be legitimately different)
    basename "$initrd" | grep -qE '(fallback|rescue)' && continue

    INITRD_FOUND=$((INITRD_FOUND + 1))
    size=$(stat -c%s "$initrd" 2>/dev/null || echo 0)

    if [ "$size" -lt 5000000 ]; then
        echo "[CHROOT]   FAIL: $initrd too small (${size} bytes) — likely corrupt"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    echo "[CHROOT]   OK: $(basename "$initrd") ($((size / 1024 / 1024))MB)"

    # Check for cryptsetup inside the initramfs
    if command -v lsinitrd &>/dev/null; then
        if lsinitrd "$initrd" 2>/dev/null | grep -q 'cryptsetup'; then
            echo "[CHROOT]       Contains cryptsetup: YES"
        else
            echo "[CHROOT]       Contains cryptsetup: NO — attempting auto-repair..."
            kver=$(basename "$initrd" | sed -n 's/initramfs-\(.*\)\.img/\1/p')
            if [ -n "$kver" ]; then
                # Auto-repair: force rebuild with explicit crypt module
                if dracut --force --add "crypt dm" "$initrd" "$kver" 2>&1; then
                    # Re-check
                    if lsinitrd "$initrd" 2>/dev/null | grep -q 'cryptsetup'; then
                        echo "[CHROOT]       Auto-repair: SUCCESS — cryptsetup now included"
                    else
                        echo "[CHROOT]       Auto-repair: FAILED — cryptsetup still missing!"
                        # Last resort: try with install flag
                        echo "[CHROOT]       Trying --install /usr/sbin/cryptsetup..."
                        dracut --force --add "crypt dm" --install "/usr/sbin/cryptsetup" \
                            "$initrd" "$kver" 2>&1 || true
                        if lsinitrd "$initrd" 2>/dev/null | grep -q 'cryptsetup'; then
                            echo "[CHROOT]       Last-resort repair: SUCCESS"
                        else
                            echo "[CHROOT]       CRITICAL: Cannot include cryptsetup in initramfs!"
                            ERRORS=$((ERRORS + 1))
                        fi
                    fi
                else
                    echo "[CHROOT]       Auto-repair: dracut rebuild failed!"
                    ERRORS=$((ERRORS + 1))
                fi
            fi
        fi
    elif command -v lsinitramfs &>/dev/null; then
        if lsinitramfs "$initrd" 2>/dev/null | grep -q 'cryptsetup'; then
            echo "[CHROOT]       Contains cryptsetup: YES"
        else
            echo "[CHROOT]       Contains cryptsetup: NO"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "[CHROOT]       Cannot verify contents (no lsinitrd/lsinitramfs)"
    fi
done

if [ "$INITRD_FOUND" -eq 0 ]; then
    echo "[CHROOT] FAIL: No non-rescue initramfs images found!"
    ERRORS=$((ERRORS + 1))
else
    echo "[CHROOT] Found $INITRD_FOUND non-rescue initramfs image(s)."
fi

# ── 7c: Update BLS boot entries with grubby ────────────────────────────────
echo ""
echo "[CHROOT] Updating BLS boot entries..."
if command -v grubby &>/dev/null; then
    echo "[CHROOT] Using grubby to add: $LUKS_BOOT_ARGS"

    if grubby --update-kernel=ALL --args="$LUKS_BOOT_ARGS" 2>&1; then
        echo "[CHROOT] grubby: updated ALL kernel entries."
    else
        echo "[CHROOT] WARN: grubby --update-kernel=ALL failed. Trying individually..."
        for entry in /boot/loader/entries/*.conf; do
            [ -f "$entry" ] || continue
            kpath=$(grep "^linux " "$entry" | awk '{print $2}')
            [ -n "$kpath" ] || continue
            grubby --update-kernel="$kpath" --args="$LUKS_BOOT_ARGS" 2>&1 || true
        done
    fi

    # Verify BLS entries
    echo "[CHROOT] Verifying BLS entries..."
    BLS_ERRORS=0
    for entry in /boot/loader/entries/*.conf; do
        [ -f "$entry" ] || continue
        ename=$(basename "$entry")
        if grep -q "rd.luks.uuid=$LUKS_UUID" "$entry"; then
            echo "[CHROOT]   OK: $ename"
        else
            echo "[CHROOT]   FAIL: $ename — missing rd.luks.uuid!"
            echo "[CHROOT]   Attempting manual fix..."
            # Auto-repair: directly append to options line
            if grep -q "^options " "$entry"; then
                sed -i "s|^options |options $LUKS_BOOT_ARGS |" "$entry"
                if grep -q "rd.luks.uuid=$LUKS_UUID" "$entry"; then
                    echo "[CHROOT]   Auto-repair: SUCCESS"
                else
                    echo "[CHROOT]   Auto-repair: FAILED"
                    BLS_ERRORS=$((BLS_ERRORS + 1))
                fi
            else
                echo "[CHROOT]   No 'options' line found in BLS entry!"
                BLS_ERRORS=$((BLS_ERRORS + 1))
            fi
        fi
    done
    if [ "$BLS_ERRORS" -gt 0 ]; then
        ERRORS=$((ERRORS + BLS_ERRORS))
    fi
else
    echo "[CHROOT] WARN: grubby not found!"
    echo "[CHROOT] Attempting direct BLS entry modification..."
    PATCHED=0
    for entry in /boot/loader/entries/*.conf; do
        [ -f "$entry" ] || continue
        if ! grep -q "rd.luks.uuid=$LUKS_UUID" "$entry"; then
            if grep -q "^options " "$entry"; then
                sed -i "s|^options |options $LUKS_BOOT_ARGS |" "$entry"
                PATCHED=$((PATCHED + 1))
            fi
        fi
    done
    echo "[CHROOT] Patched $PATCHED BLS entries directly."
    if [ "$PATCHED" -eq 0 ]; then
        echo "[CHROOT] FAIL: No BLS entries were updated!"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ── 7b½: Kernel-module presence checks (dm-crypt hard, keyboard soft) ─────
# A missing dm-crypt.ko in an initramfs is an unopenable root at boot.
# A missing keyboard driver is worse in a subtler way: every other check can
# pass and the user still cannot TYPE the passphrase. The input check only
# warns (many kernels build HID support in), but it warns loudly.
echo ""
echo "[CHROOT] Checking initramfs kernel modules..."
if command -v lsinitrd &>/dev/null; then
    for initrd in /boot/initramfs-*.img; do
        [ -f "$initrd" ] || continue
        basename "$initrd" | grep -qE '(fallback|rescue)' && continue
        kver=$(basename "$initrd" | sed -n 's/initramfs-\(.*\)\.img/\1/p')
        [ -n "$kver" ] || continue
        ilist=$(lsinitrd "$initrd" 2>/dev/null || true)

        # dm-crypt: module in the image, or built into the kernel — else repair.
        if echo "$ilist" | grep -q 'dm-crypt.ko'; then
            echo "[CHROOT]   OK: $(basename "$initrd") carries dm-crypt.ko"
        elif modinfo -k "$kver" -F filename dm-crypt 2>/dev/null | grep -q 'builtin'; then
            echo "[CHROOT]   OK: dm-crypt is built into kernel $kver"
        else
            echo "[CHROOT]   FAIL: $(basename "$initrd") lacks dm-crypt — rebuilding with --add-drivers..."
            if dracut --force --add-drivers "dm-crypt" "$initrd" "$kver" 2>&1 \
               && lsinitrd "$initrd" 2>/dev/null | grep -q 'dm-crypt.ko'; then
                echo "[CHROOT]   Repair: SUCCESS — dm-crypt now included"
                ilist=$(lsinitrd "$initrd" 2>/dev/null || true)
            else
                echo "[CHROOT]   CRITICAL: cannot get dm-crypt into $initrd — the root will NOT unlock at boot!"
                ERRORS=$((ERRORS + 1))
            fi
        fi

        # Keyboard/input: dockchannel-hid (Apple internal, M2+), hid-apple,
        # usbhid/hid-generic (external), atkbd... At least one should be in the
        # image or builtin, or the passphrase prompt is a brick wall.
        if echo "$ilist" | grep -qE '(dockchannel|hid[-_]apple|apple[-_]hid|applespi|spi[-_]hid|usbhid|hid[-_]generic|atkbd)'; then
            echo "[CHROOT]   OK: $(basename "$initrd") carries keyboard/input driver(s)"
        elif modinfo -k "$kver" -F filename hid_generic 2>/dev/null | grep -q 'builtin' \
             || modinfo -k "$kver" -F filename usbhid 2>/dev/null | grep -q 'builtin'; then
            echo "[CHROOT]   OK: generic HID input is built into kernel $kver"
        else
            echo "[CHROOT]   ╔══════════════════════════════════════════════════════════╗"
            echo "[CHROOT]   ║ WARN: no keyboard/input driver found in $(basename "$initrd")"
            echo "[CHROOT]   ║ If the boot console cannot take keystrokes, you CANNOT"
            echo "[CHROOT]   ║ type the LUKS passphrase — verify before rebooting, e.g.:"
            echo "[CHROOT]   ║   lsinitrd $initrd | grep -iE 'hid|input'"
            echo "[CHROOT]   ╚══════════════════════════════════════════════════════════╝"
        fi
    done
else
    echo "[CHROOT] WARN: lsinitrd unavailable — skipping module presence checks."
fi

# ── 7c½: Strip 'rhgb quiet' so the passphrase prompt is visible ────────────
# With the splash active, the first-boot LUKS prompt hides behind boot
# graphics/text and looks like a hang. Strip both tokens now; a marker file
# tells post-encryption-setup.sh to restore them after the first encrypted
# boot. Opt out with LUKS_KEEP_SPLASH=1.
echo ""
if [ "${LUKS_KEEP_SPLASH:-0}" = "1" ]; then
    echo "[CHROOT] LUKS_KEEP_SPLASH=1 — leaving 'rhgb quiet' in place."
else
    echo "[CHROOT] Stripping 'rhgb quiet' from boot args (post-encryption-setup.sh restores them)..."
    strip_splash_tokens() {
        # $1 = file, $2 = sed address ('' = whole line applies)
        # Boundary \2 (space, closing quote, or EOL) is preserved; the token and
        # its leading space are dropped. Two passes: adjacent tokens
        # ('rhgb quiet') need a second sweep because sed resumes after \2.
        sed -i -E "$2 s/[[:space:]]+(rhgb|quiet)([[:space:]]+|\"|\$)/\\2/g; $2 s/[[:space:]]+(rhgb|quiet)([[:space:]]+|\"|\$)/\\2/g; $2 s/[[:space:]]+\$//" "$1"
    }
    if command -v grubby &>/dev/null; then
        grubby --update-kernel=ALL --remove-args="rhgb quiet" 2>&1 \
            || echo "[CHROOT] WARN: grubby --remove-args failed (BLS entries keep the splash)."
    else
        for entry in /boot/loader/entries/*.conf; do
            [ -f "$entry" ] || continue
            strip_splash_tokens "$entry" '/^options /'
        done
    fi
    [ -f /etc/kernel/cmdline ]  && strip_splash_tokens /etc/kernel/cmdline ''
    [ -f /etc/default/grub ]    && strip_splash_tokens /etc/default/grub '/^GRUB_CMDLINE_LINUX/'
    mkdir -p /var/lib/asahilocker
    echo "rhgb quiet" > /var/lib/asahilocker/restore-splash
    echo "[CHROOT] Splash stripped; marker written for post-encryption-setup.sh."
fi

# ── 7d: Rebuild GRUB config ───────────────────────────────────────────────
# NEVER regenerate onto /boot/efi/EFI/*/grub.cfg. On Fedora (Asahi included)
# that file is a tiny STUB that searches for /boot by UUID and chainloads the
# real config from /boot/grub2/grub.cfg. Overwriting the stub with a full
# generated config is exactly the failure the boot-guards esp-grub-stub-guard
# exists to undo — it can drop the next boot at a GRUB rescue prompt.
# Only the real config locations are regenerated here.
echo ""
echo "[CHROOT] Rebuilding GRUB config..."
GRUB_REBUILT=false
grub_tool=""
if command -v grub2-mkconfig &>/dev/null; then
    grub_tool="grub2-mkconfig"
elif command -v grub-mkconfig &>/dev/null; then
    grub_tool="grub-mkconfig"
fi
if [ -n "$grub_tool" ]; then
    for grub_cfg in /boot/grub2/grub.cfg /boot/grub/grub.cfg; do
        [ -f "$grub_cfg" ] || continue
        echo "[CHROOT] $grub_tool -o $grub_cfg"
        $grub_tool -o "$grub_cfg" 2>&1
        GRUB_REBUILT=true
        break
    done
    if ! $GRUB_REBUILT; then
        # No existing real config — create one at the tool's native location
        # (still never on the ESP).
        case "$grub_tool" in
            grub2-mkconfig) $grub_tool -o /boot/grub2/grub.cfg 2>&1 && GRUB_REBUILT=true ;;
            grub-mkconfig)  $grub_tool -o /boot/grub/grub.cfg  2>&1 && GRUB_REBUILT=true ;;
        esac
    fi
fi
$GRUB_REBUILT && echo "[CHROOT] GRUB config rebuilt." || echo "[CHROOT] WARN: Could not rebuild GRUB config."

# Detect an ESP grub.cfg that has ALREADY been clobbered with a full config
# (by a previous run of this script, or by a guide-following mishap).
for esp_cfg in /boot/efi/EFI/*/grub.cfg; do
    [ -f "$esp_cfg" ] || continue
    if grep -q '### BEGIN /etc/grub.d' "$esp_cfg"; then
        echo "[CHROOT] WARN: $esp_cfg is a FULL generated config, not the Fedora stub."
        echo "[CHROOT]       Something previously ran grub2-mkconfig against the ESP."
        echo "[CHROOT]       Restore the stub after first boot — see boot-guards/README.md"
        echo "[CHROOT]       (restore-esp-grub-stub.sh / esp-grub-stub-rebaseline)."
    fi
done

# ── 7e: SELinux — relabel every file this deployment wrote ─────────────────
# Files created from the live environment get labeled by the LIVE system's
# policy (or not labeled at all, if its SELinux is off). A mislabeled
# /etc/crypttab or dracut conf can fail the first boot in enforcing mode.
# restorecon runs here IN the chroot, against the target's own policy.
echo ""
if command -v restorecon &>/dev/null && [ -f /etc/selinux/config ]; then
    echo "[CHROOT] Restoring SELinux contexts on files written by this deployment..."
    restorecon -F \
        /etc/crypttab /etc/fstab /etc/fstab.pre-luks \
        /etc/default/grub /etc/default/grub.pre-luks \
        /etc/kernel/cmdline /etc/kernel/cmdline.pre-luks \
        /etc/dracut.conf.d/99-luks.conf \
        /boot/luks-header-backup.img 2>/dev/null || true
    restorecon -RF /boot/loader/entries 2>/dev/null || true
    # The freshly rebuilt initramfs images (and anything else dracut/grubby
    # wrote) were created from a chroot with no SELinux policy loaded — sweep
    # all of /boot and the marker dir so nothing is left unlabeled.
    restorecon -RF /boot 2>/dev/null || true
    restorecon -RF /var/lib/asahilocker 2>/dev/null || true
    # -n -v lists anything STILL mislabeled; empty output means all clean
    RELABEL_LEFT=$(restorecon -n -v /etc/crypttab /etc/fstab /etc/default/grub \
        /etc/kernel/cmdline /etc/dracut.conf.d/99-luks.conf 2>/dev/null || true)
    if [ -n "$RELABEL_LEFT" ]; then
        echo "[CHROOT] WARN: some files could not be relabeled:"
        echo "$RELABEL_LEFT"
        echo "[CHROOT] If the first boot fails with SELinux denials, add 'enforcing=0'"
        echo "[CHROOT] to the kernel command line for one boot, then run:"
        echo "[CHROOT]     sudo restorecon -RFv /etc /boot && sudo setenforce 1"
    else
        echo "[CHROOT] SELinux contexts OK."
    fi
else
    echo "[CHROOT] SELinux not present on target (no /etc/selinux/config or restorecon) — skipping relabel."
fi

echo ""
echo "[CHROOT] ═══════════════════════════════════════════════"
echo "[CHROOT] Chroot work complete. Errors: $ERRORS"
echo "[CHROOT] ═══════════════════════════════════════════════"
exit $ERRORS
CHROOT_SCRIPT

rm -f /mnt/tmp/.luks-deploy-env 2>/dev/null || true

if [ "$CHROOT_RC" -ne 0 ]; then
    err "Chroot reported $CHROOT_RC error(s)!"
    warn "Continuing to verification to show full status..."
fi

# Sync all writes to disk
log "  Syncing all writes to disk..."
sync

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 8: Comprehensive Verification
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
log "[8/8] Running comprehensive verification..."
ERRORS=0

# ─── V1: crypttab ────────────────────────────────────────────────────────────
if grep -q "$LUKS_NAME" /mnt/etc/crypttab && grep -q "UUID=$LUKS_UUID" /mnt/etc/crypttab; then
    log "  V1 OK: crypttab has $LUKS_NAME with correct UUID"
else
    err "  V1 FAIL: crypttab missing or incorrect!"
    cat /mnt/etc/crypttab
    ERRORS=$((ERRORS + 1))
fi

# ─── V2: fstab ───────────────────────────────────────────────────────────────
if grep -q "/dev/mapper/$LUKS_NAME" /mnt/etc/fstab; then
    log "  V2 OK: fstab references /dev/mapper/$LUKS_NAME"
else
    err "  V2 FAIL: fstab does not reference /dev/mapper/$LUKS_NAME!"
    ERRORS=$((ERRORS + 1))
fi
if grep -q "UUID=$BTRFS_UUID" /mnt/etc/fstab; then
    err "  V2 FAIL: fstab still contains old UUID=$BTRFS_UUID!"
    ERRORS=$((ERRORS + 1))
fi

# ─── V3: /etc/default/grub ───────────────────────────────────────────────────
if grep -q "GRUB_ENABLE_CRYPTODISK=y" /mnt/etc/default/grub; then
    log "  V3 OK: GRUB_ENABLE_CRYPTODISK=y set"
else
    # Not boot-critical on this layout (/boot is unencrypted, so GRUB never
    # opens the LUKS volume itself) — but the script sets it, so its absence
    # means something interfered.
    warn "  V3 WARN: GRUB_ENABLE_CRYPTODISK=y missing (not fatal: /boot is unencrypted)"
fi
if grep -q "rd.luks.uuid=$LUKS_UUID" /mnt/etc/default/grub; then
    log "  V3 OK: rd.luks.uuid in GRUB_CMDLINE_LINUX"
else
    err "  V3 FAIL: rd.luks.uuid not in GRUB_CMDLINE_LINUX!"
    ERRORS=$((ERRORS + 1))
fi
if grep -q "rd.luks.name=${LUKS_UUID}=$LUKS_NAME" /mnt/etc/default/grub; then
    log "  V3 OK: rd.luks.name in GRUB_CMDLINE_LINUX"
else
    err "  V3 FAIL: rd.luks.name not in GRUB_CMDLINE_LINUX!"
    ERRORS=$((ERRORS + 1))
fi

# ─── V4: /etc/kernel/cmdline ─────────────────────────────────────────────────
if [ -f /mnt/etc/kernel/cmdline ]; then
    if grep -q "rd.luks.uuid=$LUKS_UUID" /mnt/etc/kernel/cmdline; then
        log "  V4 OK: /etc/kernel/cmdline has rd.luks.uuid"
    else
        err "  V4 FAIL: /etc/kernel/cmdline missing rd.luks.uuid!"
        ERRORS=$((ERRORS + 1))
    fi
    if grep -q "rd.luks.name=${LUKS_UUID}=$LUKS_NAME" /mnt/etc/kernel/cmdline; then
        log "  V4 OK: /etc/kernel/cmdline has rd.luks.name"
    else
        err "  V4 FAIL: /etc/kernel/cmdline missing rd.luks.name!"
        ERRORS=$((ERRORS + 1))
    fi
else
    err "  V4 FAIL: /etc/kernel/cmdline does not exist!"
    ERRORS=$((ERRORS + 1))
fi

# ─── V5: BLS entries ─────────────────────────────────────────────────────────
BLS_TOTAL=0
BLS_OK=0
for entry in /mnt/boot/loader/entries/*.conf; do
    [ -f "$entry" ] || continue
    BLS_TOTAL=$((BLS_TOTAL + 1))
    if grep -q "rd.luks.uuid=$LUKS_UUID" "$entry"; then
        BLS_OK=$((BLS_OK + 1))
    else
        err "  V5 FAIL: $(basename "$entry") missing rd.luks.uuid!"
        ERRORS=$((ERRORS + 1))
    fi
done
if [ "$BLS_TOTAL" -gt 0 ]; then
    log "  V5 OK: $BLS_OK/$BLS_TOTAL BLS entries have rd.luks.uuid"
else
    warn "  V5 SKIP: No BLS entries found (may not use BLS)"
fi

# ─── V6: GRUB config ─────────────────────────────────────────────────────────
# Real config locations first; the ESP copy is normally just the chainload stub.
GRUB_CFG=""
for f in /mnt/boot/grub2/grub.cfg /mnt/boot/grub/grub.cfg /mnt/boot/efi/EFI/fedora/grub.cfg; do
    [ -f "$f" ] && GRUB_CFG="$f" && break
done
# The ESP grub.cfg must still be the Fedora stub, not a full generated config.
for esp_cfg in /mnt/boot/efi/EFI/*/grub.cfg; do
    [ -f "$esp_cfg" ] || continue
    if grep -q '### BEGIN /etc/grub.d' "$esp_cfg"; then
        warn "  V6 WARN: ${esp_cfg#/mnt} is a FULL generated config, not the chainload stub."
        warn "           Restore the stub after first boot (boot-guards/restore-esp-grub-stub.sh)."
    fi
done
if [ -n "$GRUB_CFG" ]; then
    log "  V6 OK: GRUB config found at $GRUB_CFG"
    # On BLS systems, grub.cfg just has blscfg command; LUKS params are in BLS entries
    if grep -q "blscfg" "$GRUB_CFG"; then
        log "  V6 OK: GRUB config uses BLS (blscfg) — LUKS params come from BLS entries"
    elif grep -q "rd.luks.uuid=$LUKS_UUID" "$GRUB_CFG"; then
        log "  V6 OK: GRUB config contains rd.luks.uuid"
    else
        warn "  V6 WARN: GRUB config has neither blscfg nor rd.luks.uuid"
    fi
else
    err "  V6 FAIL: No grub.cfg found!"
    ERRORS=$((ERRORS + 1))
fi

# ─── V7: Initramfs images ────────────────────────────────────────────────────
INITRD_COUNT=0
for f in /mnt/boot/initramfs-*.img /mnt/boot/initrd.img-*; do
    [ -f "$f" ] || continue
    basename "$f" | grep -qE '(fallback|rescue)' && continue
    INITRD_COUNT=$((INITRD_COUNT + 1))
done
if [ "$INITRD_COUNT" -gt 0 ]; then
    log "  V7 OK: $INITRD_COUNT non-rescue initramfs image(s) found"
else
    err "  V7 FAIL: No initramfs images!"
    ERRORS=$((ERRORS + 1))
fi

# ─── V8: LUKS header backup ──────────────────────────────────────────────────
if [ -f /mnt/boot/luks-header-backup.img ]; then
    log "  V8 OK: LUKS header backup exists on target"
else
    warn "  V8 WARN: LUKS header backup missing from /boot"
fi
if [ -f "$STATE_DIR/luks-header-backup.img" ]; then
    log "  V8 OK: LUKS header backup exists on USB"
else
    warn "  V8 WARN: LUKS header backup missing from USB"
fi

# ─── V9: dracut config ───────────────────────────────────────────────────────
if [ -f /mnt/etc/dracut.conf.d/99-luks.conf ]; then
    if grep -q 'crypt' /mnt/etc/dracut.conf.d/99-luks.conf; then
        log "  V9 OK: dracut LUKS module config present"
    else
        err "  V9 FAIL: dracut config exists but missing crypt module!"
        ERRORS=$((ERRORS + 1))
    fi
else
    err "  V9 FAIL: /etc/dracut.conf.d/99-luks.conf not found!"
    ERRORS=$((ERRORS + 1))
fi

# ─── V10: LUKS device integrity ──────────────────────────────────────────────
if [ -b /dev/mapper/${LUKS_NAME} ]; then
    log "  V10 OK: /dev/mapper/${LUKS_NAME} is active"
else
    err "  V10 FAIL: /dev/mapper/${LUKS_NAME} not found!"
    ERRORS=$((ERRORS + 1))
fi

# Add chroot errors to total
ERRORS=$((ERRORS + CHROOT_RC))

# ─── Verification Result ─────────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
if [ "$ERRORS" -eq 0 ]; then
    echo -e "║  ${GREEN}${BOLD}ALL CHECKS PASSED (12-point gate) — deployment verified.${NC} ║"
else
    echo -e "║  ${RED}${BOLD}$ERRORS ERROR(S) DETECTED — DO NOT REBOOT until fixed!${NC}      ║"
fi
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

if [ "$ERRORS" -gt 0 ]; then
    fatal "Verification failed with $ERRORS error(s). See log: $DEPLOY_LOG"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Summary & Recovery Instructions
# ═══════════════════════════════════════════════════════════════════════════════
echo "Summary of changes:"
echo "  crypttab    : $LUKS_NAME UUID=$LUKS_UUID none luks,discard"
echo "  fstab       : /dev/mapper/$LUKS_NAME (was UUID=$BTRFS_UUID)"
echo "  grub default: GRUB_ENABLE_CRYPTODISK=y + rd.luks.uuid + rd.luks.name"
echo "  kernel cmd  : rd.luks.uuid=$LUKS_UUID rd.luks.name=${LUKS_UUID}=$LUKS_NAME"
echo "  BLS entries : ALL updated with LUKS parameters"
echo "  initramfs   : ALL kernels rebuilt with crypt+dm+btrfs modules"
echo "  header bkup : /boot/luks-header-backup.img + $STATE_DIR/"
if [ -f "$STATE_DIR/recovery-key.txt" ]; then
    echo "  recovery key: $STATE_DIR/recovery-key.txt  ← MOVE TO SECURE OFFLINE STORAGE"
fi
echo ""

# Save log to target system's /boot (survives if USB is removed)
cp "$DEPLOY_LOG" /mnt/boot/luks-deploy.log 2>/dev/null || true
chroot /mnt /usr/sbin/restorecon -F /boot/luks-deploy.log 2>/dev/null || true
log "Log also saved to target: /boot/luks-deploy.log"
echo ""
echo "Full log: $DEPLOY_LOG (on deployment drive)"
echo "          /boot/luks-deploy.log (on target system)"
echo ""
echo "Pre-encryption backups: $STATE_DIR/"
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  You can now reboot. You will be prompted for your        ║"
echo "║  LUKS passphrase at boot.                                 ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  NOTE: The password prompt may appear behind boot text.   ║"
echo "║  If the system appears hung, just type your passphrase.   ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  If the system fails to boot:                             ║"
echo "║  1. Boot from live USB                                    ║"
echo "║  2. cryptsetup open $TARGET_ROOT ${LUKS_NAME}"
echo "║  3. mount -o subvol=$ROOT_SUBVOL /dev/mapper/${LUKS_NAME} /mnt"
echo "║  4. Mount /boot, bind-mount /dev /proc /sys /run          ║"
echo "║  5. chroot /mnt and fix configuration                     ║"
echo "║  6. Header restore if needed:                             ║"
echo "║     cryptsetup luksHeaderRestore $TARGET_ROOT \\"
echo "║       --header-backup-file /boot/luks-header-backup.img   ║"
echo "╚════════════════════════════════════════════════════════════╝"
