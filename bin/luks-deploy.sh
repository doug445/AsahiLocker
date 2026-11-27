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
# Targets: Fedora Asahi Remix on Apple Silicon (aarch64), btrfs root — only.
# Every other platform: LinuxLocker (https://github.com/doug445/LinuxLocker).
#
# MUST NOT be run from the system it is encrypting. Run it from the RAM-only
# rescue that ram-rescue.sh builds (docs/RAM-RESCUE.md; no USB stick needed),
# from a Fedora Asahi live USB (docs/LIVE-USB.md), or from a second, minimal
# Asahi install on the same internal disk (docs/SECOND-INSTALL.md). In every
# case the running system's own partitions are excluded from the menus and
# refused as targets.
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
# unlock the container for discovery; all discovery mounts are read-only).
# The short way (see README "Quick start"):
#   sudo ./luks-deploy.sh --list                     the installs on this Mac
#   sudo ./luks-deploy.sh /dev/nvme0n1p6 --defaults  encrypt that one
# A root partition named on the command line takes its /boot and EFI from the
# install's own /etc/fstab, matched by UUID: no partition menus. --defaults
# (-y) also takes the recommended answer wherever a question has one: run the
# btrfs check, the aggressive KDF profile (moderate on a Mac with 8 GB),
# enrol a recovery key. Every safety gate stays: the typed encrypt, the Caps
# Lock check, cryptsetup's own YES and the passphrase itself.
DRY_RUN="${LUKS_DRY_RUN:-0}"
USE_DEFAULTS=0
CLI_ROOT=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --defaults|-y) USE_DEFAULTS=1 ;;
        --list|-l)
            exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/luks-mount.sh" list ;;
        -h|--help)
            sed -n '/^# The short way/,/^# and the passphrase itself\./p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            echo "Also: --dry-run (preview, changes nothing). Everything else is a LUKS_* environment"
            echo "variable; see the header of this script."
            exit 0 ;;
        /dev/*)
            [ -z "$CLI_ROOT" ] || { echo "Give one root partition, not two ($CLI_ROOT, $arg)." >&2; exit 1; }
            CLI_ROOT="$arg" ;;
        *) echo "Unknown argument: $arg (try --help)" >&2; exit 1 ;;
    esac
done
if [ -n "$CLI_ROOT" ]; then
    if [ -n "${LUKS_TARGET_ROOT:-}" ] && [ "$LUKS_TARGET_ROOT" != "$CLI_ROOT" ]; then
        echo "LUKS_TARGET_ROOT=$LUKS_TARGET_ROOT and the command line ($CLI_ROOT) disagree." >&2; exit 1
    fi
    LUKS_TARGET_ROOT="$CLI_ROOT"
fi
if [ "$USE_DEFAULTS" = 1 ]; then
    LUKS_RECOVERY_KEY="${LUKS_RECOVERY_KEY:-default}"
fi

# ─── Root check ──────────────────────────────────────────────────────────────
# Here, before the log is opened and the cleanup trap is armed: a forgotten
# sudo gets one line, not a stray log file and a page of recovery advice.
[ "$EUID" -eq 0 ] || { echo "Must run as root: sudo $0${*:+ $*}" >&2; exit 1; }

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
    # script's typed encrypt gate remains the consent step.
    CRYPT_BATCH_ARGS=(--batch-mode)
fi

# Log to the directory this script lives in (the USB/deployment drive),
# not /tmp (which is tmpfs on live USB and gets wiped on reboot)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# /mnt and /mnt_temp are where this script mounts the install it encrypts.
# Run from a drive mounted there, step 4 would mount the target over the top
# of this directory: the state backup, the header copy and the recovery key
# could no longer be written, and the run would stop AFTER the encryption.
case "$(cd "$SCRIPT_DIR" && pwd -P)/" in
    /mnt/*|/mnt_temp/*)
        echo "AsahiLocker is running from $SCRIPT_DIR." >&2
        echo "  /mnt is where this script mounts the install it encrypts, which would" >&2
        echo "  hide this directory (log, state backup, recovery key) in mid-run." >&2
        echo "  Mount the drive somewhere else (e.g. /media), or copy AsahiLocker to" >&2
        echo "  /root, and run it from there. Nothing was changed." >&2
        exit 1 ;;
esac
DEPLOY_LOG="$SCRIPT_DIR/luks-deploy-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$DEPLOY_LOG") 2>&1
echo "Full log: $DEPLOY_LOG"

log()  { echo -e "[$(date '+%H:%M:%S')] ${GREEN}[LUKS]${NC} $*"; }
warn() { echo -e "[$(date '+%H:%M:%S')] ${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "[$(date '+%H:%M:%S')] ${RED}[ERROR]${NC} $*" >&2; }
fatal() { err "$@"; exit 1; }

# ─── Typed confirmations ─────────────────────────────────────────────────────
# Every word this script asks you to type is lower case: encrypt, configure,
# swap, battery, mismatch, force, sibling, align, uuid-changed. A word in
# capitals is what sends a hand to Caps Lock, and Caps Lock still on a moment
# later inverts the passphrase, both times it is typed, so cryptsetup's
# type-it-twice check passes and the boot prompt is where it shows (up to
# 3.1.0 every one of these words was in capitals). A word in lower case cannot
# be typed with Caps Lock on, so typing it also proves Caps Lock is off. If it
# arrives in capitals, that is said, and the question asked again.
#   typed_confirm <word> <prompt>
# 0 when the word is typed; 1 for any other answer, or when input has closed.
typed_confirm() {
    local want="$1" prompt="$2" got caps=0
    while :; do
        read -r -p "$prompt" got || { echo ""; return 1; }
        [ "$got" = "$want" ] && return 0
        if [ -n "$got" ] && [ "$got" = "${want^^}" ] && [ "$caps" -lt 5 ]; then
            caps=$((caps + 1))
            warn "  That arrived as '$got': Caps Lock is on. Turn it off and type '$want' in lower case."
            continue
        fi
        return 1
    done
}

# ─── Permissions on the deployment drive ─────────────────────────────────────
# chmod(2) SUCCEEDS and does nothing on vfat/exfat/ntfs: the mode comes from the
# mount's fmask/dmask, not from the inode. So `chmod 0400 secret` on a FAT stick
# reports success and leaves the file world-readable. The recovery key and the
# LUKS header backup both land on the deployment drive, which is very often
# exactly such a stick, so a silent no-op here is the dangerous case -- not a
# hard failure.
#
# Set the mode, read it back, and say so ONCE if it did not take. Never returns
# non-zero: a drive that cannot hold permissions is a reason to warn loudly, not
# to abort a deployment that is already under way.
MODE_WARNED=0
harden_path() {                        # harden_path <octal-mode> <path>
    local mode="$1" path="$2" got
    chmod "$mode" "$path" 2>/dev/null || true
    got="$(stat -c '%a' "$path" 2>/dev/null || true)"
    if [ "$got" = "${mode#0}" ]; then
        return 0
    fi
    if [ "$MODE_WARNED" -eq 0 ]; then
        MODE_WARNED=1
        warn "This drive cannot store Unix permissions (vfat/exfat?)."
        warn "  Wanted mode $mode on $(basename "$path"); it is ${got:-unknown}."
        warn "  The recovery key and LUKS header backup written here are readable"
        warn "  by ANYONE who picks this drive up. Move them to secure offline"
        warn "  storage as soon as deployment finishes."
    fi
    return 0
}

# ─── SELinux labels on the target ────────────────────────────────────────────
# Label paths ON THE TARGET with the target's own policy, then read the labels
# back from the files.
#
# restorecon cannot do this job here. It exits 0 without touching anything when
# it finds SELinux "not enabled", and inside this script's chroot it never
# finds it: /sys is bound without its submounts, so there is no selinuxfs to
# see. `restorecon -n -v` prints nothing for the same reason, so a relabel that
# did nothing used to be reported as "SELinux contexts OK". On a live USB with
# SELinux on, the running kernel had at least given every new file a label. In
# the RAM rescue no policy is loaded, a new file gets no label at all, and the
# first enforcing boot met unlabeled_t on everything written here. (Issue #9.)
#
# setfiles is given the target's file_contexts and writes the labels whatever
# the state of SELinux in the running kernel. The read-back uses stat, not the
# tool that did the writing, so a relabel that silently did nothing cannot pass.
#
#   target_relabel <path-as-the-target-sees-it>...
# Directories are labeled recursively, without crossing into another filesystem
# (the EFI partition under /boot has no labels to set). Missing paths are
# skipped. Returns 0 when every path is labeled, 2 when the target has no
# SELinux policy to label for, anything else when a label is missing -- and
# then prints "<label> <path>" for each such file, with what setfiles said.
target_relabel() {
    chroot /mnt /bin/bash -s -- "$@" <<'RELABEL'
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
[ -f /etc/selinux/config ] || exit 2
command -v setfiles >/dev/null 2>&1 || exit 2
st=$(sed -n 's/^[[:space:]]*SELINUXTYPE=[[:space:]]*//p' /etc/selinux/config | tail -n1 | sed 's/[[:space:]]*$//')
fc="/etc/selinux/${st:-targeted}/contexts/files/file_contexts"
[ -f "$fc" ] || exit 2
paths=()
for p in "$@"; do
    if [ -e "$p" ] || [ -L "$p" ]; then paths+=("$p"); fi
done
[ "${#paths[@]}" -gt 0 ] || exit 0
said=$(setfiles -F "$fc" "${paths[@]}" 2>&1)
left=0
for p in "${paths[@]}"; do
    # %D is the device number: a mount point inside $p belongs to another
    # filesystem and is left out. "?" is what stat prints for no label at all.
    bad=$(find "$p" -xdev -exec stat -c '%D %C %n' {} + 2>/dev/null \
        | awk 'NR == 1 { dev = $1 }
               $1 == dev && ($2 == "?" || $2 ~ /:unlabeled_t(:|$)/) { sub(/^[^ ]+ /, ""); print }')
    if [ -n "$bad" ]; then echo "$bad"; left=1; fi
done
if [ "$left" -ne 0 ] && [ -n "$said" ]; then echo "$said"; fi
exit "$left"
RELABEL
}

# ─── LUKS2 KDF profiles ──────────────────────────────────────────────────────
# Three presets, chosen interactively before encryption starts. The KDF is
# re-run in the INITRAMFS at every boot, so its memory cost must be allocatable
# there — and you pay its full cost as unlock latency on EVERY boot.
#
# argon2id cost is ~proportional to (memory x iterations). The script benchmarks
# THIS machine and shows a real estimated unlock time for each profile, rather
# than quoting numbers from someone else's hardware.
#
#   aggressive  4 GiB  t=10   the default; 4 GiB is argon2id's maximum memory
#                              cost - cryptsetup refuses anything above
#                              4194304 KiB - so cost above it buys iterations
#   moderate    2 GiB  t=8    balanced; half the memory, a faster boot. The
#                              default on a Mac with 8 GB of RAM (see
#                              kdf_default_profile below)
#   fast        1 GiB  t=9    the FLOOR, not a discount. cryptsetup's own
#                              default is argon2id at 1 GiB with iterations
#                              auto-tuned to ~2000 ms -- t=8 on an M2 Max.
#                              t=9 stays above stock on this class of
#                              machine. (<= v1.3.0 shipped t=4, which was
#                              HALF the cost of a plain luksFormat.)
#
# ALWAYS argon2id. It is memory-hard, which is what makes GPU/ASIC cracking
# expensive; never substitute pbkdf2 to save memory or time — argon2id at 1 GiB
# beats pbkdf2 at any iteration count. There is no profile that selects pbkdf2.
#
# Non-interactive use:
#   LUKS_PROFILE=fast ./luks-deploy.sh                       # pick a preset
#   LUKS_PBKDF_MEMORY=3145728 LUKS_PBKDF_ITER=8 ./luks-deploy.sh   # fully custom
# Setting any LUKS_PBKDF_* variable pins the parameters and skips the menu.
#
# Partition pinning (skips the selection menus — for fleet/scripted use):
#   LUKS_TARGET_ROOT=/dev/nvme0n1p6 LUKS_TARGET_BOOT=/dev/nvme0n1p5 \
#   LUKS_TARGET_EFI=/dev/nvme0n1p4 ./luks-deploy.sh
# Each pinned device is still fstype-checked, cross-checked against the
# target's fstab, and subject to the same typed encrypt confirmation.
#
# Recovery key (2nd keyslot): prompted interactively; pin with
#   LUKS_RECOVERY_KEY=yes|no ./luks-deploy.sh
#
# More environment knobs:
#   LUKS_PASSPHRASE_FILE=<path>  read the passphrase from a file (fleet/testing);
#                                the file's exact bytes are the passphrase
#   LUKS_MAPPER_NAME=<name>      device-mapper name (default: fedora_crypt)
#   LUKS_KEEP_SPLASH=1           do NOT strip 'rhgb quiet' from the boot args:
#                                the splash stays on. (Default: strip, so the
#                                passphrase prompt is visible. After the first
#                                boot post-encryption-setup.sh puts them back,
#                                unless it is run with --keep-splash-off. This
#                                variable is read here only, not by that script.)
#   LUKS_SECTOR_SIZE=4096        encryption sector size (default: 4096 when the
#                                btrfs sectorsize allows it, else 512); never
#                                larger than the filesystem's sectorsize
#   LUKS_ALIGN_PARTITION=yes|no  when the partition's size is not a multiple of
#                                that sector size (the last partition on a
#                                512-byte-sector GPT disk never is): move its
#                                end down by the remainder (table backed up), or
#                                keep it and use 512-byte sectors. Asked when unset
#   LUKS_SKIP_VERSION_CHECK=1    bypass the cryptsetup >= 2.4 floor
#   LUKS_DRY_RUN=1 (or --dry-run flag)  preview: full detection + plan, no
#                                       changes to the target, exit before
#                                       the point of no return

KDF_PROFILE_AGGRESSIVE_MEM=4194304;  KDF_PROFILE_AGGRESSIVE_ITER=10
KDF_PROFILE_MODERATE_MEM=2097152;    KDF_PROFILE_MODERATE_ITER=8
KDF_PROFILE_FAST_MEM=1048576;        KDF_PROFILE_FAST_ITER=9
KDF_DEFAULT_PARALLEL=4

# ─── The default profile on this Mac ─────────────────────────────────────────
# aggressive, except on a Mac with 8 GB of RAM (any chip: M1, M2 and M3 base
# models all come with 8 GB), where the default is moderate. The KDF's memory
# has to be free in the initramfs at every boot, or the volume does not open;
# aggressive's 4 GiB is half of such a machine, and the initramfs only grows as
# firmware and GPU support are added to it. moderate keeps 2 GiB of margin.
# aggressive stays on the menu, a choice made on purpose. The rule is the RAM,
# read from MemTotal, so it holds for any Mac Asahi adds. Prints the profile
# name. The meminfo file can be given, for the tests.
KDF_SMALL_RAM_KIB=12582912      # 12 GiB: an 8 GB Mac reports about 7.5 GiB
kdf_default_profile() {
    local mem_kib
    mem_kib=$(awk '$1 == "MemTotal:" { print $2; exit }' "${1:-/proc/meminfo}" 2>/dev/null) || mem_kib=""
    case "$mem_kib" in
        ''|*[!0-9]*) ;;
        *) if [ "$mem_kib" -lt "$KDF_SMALL_RAM_KIB" ]; then echo moderate; return 0; fi ;;
    esac
    echo aggressive
}
KDF_DEFAULT_PROFILE=$(kdf_default_profile)

# Did the caller pin anything explicitly? (checked before defaults are applied)
KDF_PINNED_BY_ENV=0
if [ -n "${LUKS_PBKDF_MEMORY:-}" ] || [ -n "${LUKS_PBKDF_ITER:-}" ] || [ -n "${LUKS_PBKDF_PARALLEL:-}" ]; then
    KDF_PINNED_BY_ENV=1
fi

# Defaults = this Mac's default profile; the menu (or LUKS_PROFILE) may replace
# them. When anything is pinned in the environment, what was left out falls
# back to aggressive on every machine, as it always has: pinned parameters must
# come out the same on every Mac of a fleet.
if [ "$KDF_PINNED_BY_ENV" -eq 0 ] && [ "$KDF_DEFAULT_PROFILE" = moderate ]; then
    _kdf_mem=$KDF_PROFILE_MODERATE_MEM;   _kdf_iter=$KDF_PROFILE_MODERATE_ITER;   KDF_PROFILE_NAME="moderate"
else
    _kdf_mem=$KDF_PROFILE_AGGRESSIVE_MEM; _kdf_iter=$KDF_PROFILE_AGGRESSIVE_ITER; KDF_PROFILE_NAME="aggressive"
fi
LUKS_PBKDF_MEMORY="${LUKS_PBKDF_MEMORY:-$_kdf_mem}"
LUKS_PBKDF_ITER="${LUKS_PBKDF_ITER:-$_kdf_iter}"
LUKS_PBKDF_PARALLEL="${LUKS_PBKDF_PARALLEL:-$KDF_DEFAULT_PARALLEL}"
unset _kdf_mem _kdf_iter

case "$LUKS_PBKDF_MEMORY" in ''|*[!0-9]*) echo "LUKS_PBKDF_MEMORY must be an integer (KiB)" >&2; exit 1;; esac
case "$LUKS_PBKDF_ITER" in ''|*[!0-9]*) echo "LUKS_PBKDF_ITER must be an integer" >&2; exit 1;; esac
case "$LUKS_PBKDF_PARALLEL" in ''|*[!0-9]*) echo "LUKS_PBKDF_PARALLEL must be an integer" >&2; exit 1;; esac

# ─── The 'fast' profile IS the floor ────────────────────────────────────────
# Nothing below it is accepted, and there is deliberately NO acknowledgement
# flag. cryptsetup's own default is argon2id at 1 GiB with iterations tuned to
# ~2000 ms, so anything cheaper than 'fast' would ship a volume weaker than a
# plain `luksFormat` with no arguments — which this tool exists to beat, not to
# offer as a setting. It also catches the classic typo (LUKS_PBKDF_MEMORY=1048
# for 1048576). If you genuinely want a cheaper KDF, run cryptsetup's
# luksConvertKey yourself; this script will not do it for you.
#
# Two conditions, because they fail differently: memory below 1 GiB loses the
# memory-hardness that is the entire point, and total work below 'fast' is
# cheaper per guess however the two factors are traded off.
KDF_FLOOR_MEM=$KDF_PROFILE_FAST_MEM
KDF_FLOOR_WORK=$((KDF_PROFILE_FAST_MEM * KDF_PROFILE_FAST_ITER))

if [ "$KDF_PINNED_BY_ENV" -eq 1 ]; then
    if [ -n "${LUKS_PBKDF_ACK_WEAK:-}" ]; then
        warn "LUKS_PBKDF_ACK_WEAK is no longer honoured — the 'fast' profile is a hard floor."
    fi
    if [ "$LUKS_PBKDF_MEMORY" -lt "$KDF_FLOOR_MEM" ] \
       || [ $((LUKS_PBKDF_MEMORY * LUKS_PBKDF_ITER)) -lt "$KDF_FLOOR_WORK" ]; then
        fatal "Pinned KDF parameters are below the 'fast' floor.
       requested : $((LUKS_PBKDF_MEMORY / 1024)) MiB x ${LUKS_PBKDF_ITER} iterations
       floor     : $((KDF_FLOOR_MEM / 1024)) MiB x ${KDF_PROFILE_FAST_ITER} iterations (the 'fast' profile)
     There is no override. cryptsetup's own default is ~1 GiB with iterations
     tuned to 2000 ms, so this would be weaker than luksFormat with no flags.
     AsahiLocker hardens; it never writes a weaker KDF. If you truly want one,
     that is a manual cryptsetup luksFormat/luksConvertKey outside this tool."
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

# Read cryptsetup's OWN default parameters for this machine: argon2id at its
# default memory with the iteration count auto-tuned to --iter-time (2000 ms).
# Sets STOCK_ITER / STOCK_MEM. Returns non-zero if the benchmark is unusable.
#
# Sampled, and the LOWEST reading wins. This benchmark is load-sensitive --
# measured at 8 iterations idle and 4 (libcryptsetup's minimum) on the same
# machine under load, for the same 1 GiB. Bias matters here because the two
# errors are not symmetric: reading stock too LOW only makes the guard a no-op,
# while reading it too HIGH inflates the iteration count permanently and you
# pay that as unlock latency at EVERY boot. The static 'fast' floor is what
# guarantees the baseline; this guard only has to catch hardware faster than
# the profiles assume.
KDF_STOCK_SAMPLES=3
kdf_stock_params() {
    local out i it mem best_it="" best_mem=""
    for i in $(seq 1 "$KDF_STOCK_SAMPLES"); do
        out=$(cryptsetup benchmark --pbkdf argon2id 2>/dev/null | grep -m1 'argon2id') || continue
        it=$(echo "$out"  | awk '{print $2}')
        mem=$(echo "$out" | awk '{print $4}')
        case "$it"  in ''|*[!0-9]*) continue;; esac
        case "$mem" in ''|*[!0-9]*) continue;; esac
        [ "$it" -gt 0 ] && [ "$mem" -gt 0 ] || continue
        if [ -z "$best_it" ] || [ $((it * mem)) -lt $((best_it * best_mem)) ]; then
            best_it=$it; best_mem=$mem
        fi
    done
    [ -n "$best_it" ] || return 1
    STOCK_ITER=$best_it
    STOCK_MEM=$best_mem
}

# Never ship a KDF weaker than what a bare `luksFormat` would have produced on
# THIS machine. The profiles are fixed numbers; stock is a fixed *time*, so on
# faster hardware stock climbs and a fixed profile can fall behind it.
#
#   named profile  -> raise the iteration count past stock, and say so
#   pinned numbers -> fatal; the operator chose exact values, so silently
#                     changing them would break the fleet reproducibility that
#                     pinning exists to provide
#
# The boost overshoots by KDF_STOCK_MARGIN_PCT rather than landing exactly on
# stock: matching it would only tie with a plain luksFormat, and the benchmark
# jitters run to run, so an exact match can read as 'weaker' on the next boot.
KDF_STOCK_MARGIN_PCT=25
kdf_enforce_stock_floor() {
    local stock_work sel_work target_work need
    if ! kdf_stock_params; then
        warn "Could not read cryptsetup's default KDF parameters — skipping the stock-strength check."
        return 0
    fi
    stock_work=$((STOCK_MEM * STOCK_ITER))
    sel_work=$((LUKS_PBKDF_MEMORY * LUKS_PBKDF_ITER))
    [ "$sel_work" -ge "$stock_work" ] && return 0

    if [ "$KDF_PINNED_BY_ENV" -eq 1 ]; then
        fatal "Pinned KDF parameters are weaker than cryptsetup's own default on this machine.
       requested : $((LUKS_PBKDF_MEMORY / 1024)) MiB x ${LUKS_PBKDF_ITER} iterations
       stock     : $((STOCK_MEM / 1024)) MiB x ${STOCK_ITER} iterations (argon2id tuned to 2000 ms)
     Raise the iteration count and re-run. There is no override: AsahiLocker
     hardens, never weakens. A weaker KDF is a manual cryptsetup operation."
    fi

    target_work=$(( stock_work * (100 + KDF_STOCK_MARGIN_PCT) / 100 ))
    need=$(( (target_work + LUKS_PBKDF_MEMORY - 1) / LUKS_PBKDF_MEMORY ))
    # ceil() can still tie when the division is exact; never come back equal.
    [ $((need * LUKS_PBKDF_MEMORY)) -gt "$stock_work" ] || need=$((need + 1))
    warn "Profile '$KDF_PROFILE_NAME' ($((LUKS_PBKDF_MEMORY / 1024)) MiB x ${LUKS_PBKDF_ITER}) is weaker than cryptsetup's"
    warn "  own default on this machine ($((STOCK_MEM / 1024)) MiB x ${STOCK_ITER}). Raising iterations ${LUKS_PBKDF_ITER} -> ${need}"
    warn "  — ${KDF_STOCK_MARGIN_PCT}% past stock, so the volume is never cheaper to attack than a"
    warn "  plain luksFormat with no arguments."
    LUKS_PBKDF_ITER=$need
    KDF_PROFILE_NAME="$KDF_PROFILE_NAME (boosted past stock)"
}

kdf_fmt_ms() {
    local ms="$1"
    case "$ms" in ''|*[!0-9]*) echo "?"; return;; esac
    if [ "$ms" -lt 1000 ]; then echo "${ms} ms"
    else awk -v m="$ms" 'BEGIN{ printf "%.1f s", m/1000 }'; fi
}

# ─── cracklib dictionary helpers ─────────────────────────────────────────────
# cryptsetup runs a passphrase typed at the terminal through libpwquality, and
# its dictionary check needs a cracklib dictionary on disk. Where the running
# environment has none (the dracut RAM rescue, docs/RAM-RESCUE.md), discovery
# lends this run the target install's own copy (under /run, plus a
# pwquality.conf.d drop-in); see "Passphrase quality dictionary" below.
# Defined up here because cleanup() removes both.

# The dictionary base path libpwquality uses under root $1 ("" = the running
# system): dictpath from pwquality.conf, else cracklib's compiled-in default.
# libpwquality reads pwquality.conf.d/*.conf first and pwquality.conf last,
# each overriding the one before, so the last dictpath in that order wins.
pwq_dict_base() {
    local root="${1:-}" d
    d=$(sed -n 's/^[[:space:]]*dictpath[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' \
            "$root"/etc/security/pwquality.conf.d/*.conf \
            "$root/etc/security/pwquality.conf" 2>/dev/null \
        | tail -n 1 || true)
    echo "${d:-/usr/share/cracklib/pw_dict}"
}

# True when cracklib can open the dictionary at base $1: the index (.pwi) and
# the word file (.pwd, or .pwd.gz where cracklib is built with zlib). The .hwm
# file is optional to cracklib.
pwq_dict_present() {
    [ -f "$1.pwi" ] && { [ -f "$1.pwd" ] || [ -f "$1.pwd.gz" ]; }
}

PWQ_BORROWED=()          # files written for this run (dictionary copy, drop-in)
PWQ_BORROWED_DIRS=()     # directories made for them, deepest first
pwq_unborrow() {
    local f
    for f in ${PWQ_BORROWED[@]+"${PWQ_BORROWED[@]}"}; do
        rm -f "$f" 2>/dev/null || true
    done
    # rmdir, never rm -r: only a directory this run made, and only if empty.
    for f in ${PWQ_BORROWED_DIRS[@]+"${PWQ_BORROWED_DIRS[@]}"}; do
        rmdir "$f" 2>/dev/null || true
    done
    PWQ_BORROWED=()
    PWQ_BORROWED_DIRS=()
}

# ─── Cleanup Trap ────────────────────────────────────────────────────────────
# MNT_OURS: set once step 4 mounts the target on /mnt. Until then whatever is
# on /mnt is the operator's (a backup drive, a hand mount), and a dry run or a
# declined prompt has no business unmounting it.
# RECOVERY_HINTS: set once the target may be in a part-way state: an existing
# LUKS header was found, or this run was told to go ahead. An exit before that
# has changed nothing on the target, and says so instead of printing recovery
# advice for an encryption that never started.
MNT_OURS=0
RECOVERY_HINTS=0
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        err "════════════════════════════════════════════════════════════"
        if [ "$RECOVERY_HINTS" = "1" ]; then
            err "  Script exited with error (code $exit_code). Cleaning up..."
        else
            err "  Stopped (code $exit_code). Nothing on the target was changed."
        fi
        err "════════════════════════════════════════════════════════════"
    fi
    # Clean up any temp mounts first (-R: the BLS check nests a boot mount
    # inside /mnt_temp, and a plain umount would fail on the child mount)
    umount -R /mnt_temp 2>/dev/null || umount /mnt_temp 2>/dev/null || true
    rmdir /mnt_temp 2>/dev/null || true
    if [ "$MNT_OURS" = "1" ]; then
        rm -f /mnt/tmp/.luks-deploy-env 2>/dev/null || true
        # Clean up chroot bind mounts (specific order matters)
        umount /mnt/sys/firmware/efi/efivars 2>/dev/null || true
        for mp in /mnt/run /mnt/sys /mnt/proc /mnt/dev/pts /mnt/dev; do
            umount "$mp" 2>/dev/null || true
        done
        umount /mnt/boot/efi 2>/dev/null || true
        umount /mnt/boot 2>/dev/null || true
        umount /mnt/home 2>/dev/null || true
        umount /mnt 2>/dev/null || true
    fi
    cryptsetup close "$LUKS_NAME" 2>/dev/null || true
    pwq_unborrow
    if [ $exit_code -ne 0 ] && [ "$RECOVERY_HINTS" != "1" ]; then
        echo "  Full log: $DEPLOY_LOG"
    elif [ $exit_code -ne 0 ]; then
        local root_dev="${TARGET_ROOT:-<ROOT_DEV>}"
        echo ""
        echo "Recovery options:"
        echo "  If btrfs was shrunk but encryption didn't start:"
        echo "    mount $root_dev /mnt && btrfs filesystem resize max /mnt && umount /mnt"
        echo "  If encryption was interrupted:"
        echo "    RE-RUN THIS SCRIPT — it detects the interrupted state and"
        echo "    resumes automatically (cryptsetup reencrypt --resume-only)."
        echo "  If encryption completed but config is wrong:"
        echo "    RE-RUN THIS SCRIPT — it offers a configuration-only mode that"
        echo "    redoes crypttab/fstab/initramfs/BLS and re-runs verification."
        echo "  LUKS header restore (if backed up):"
        echo "    cryptsetup luksHeaderRestore $root_dev --header-backup-file /boot/luks-header-backup.img"
        echo ""
        echo "  Pre-encryption backups saved to: $SCRIPT_DIR/"
        echo "  Full log: $DEPLOY_LOG"
        if [ "${STATE_VOLATILE:-0}" = "1" ]; then
            echo ""
            echo "  $SCRIPT_DIR is held in RAM. If you are not re-running the"
            echo "  script straight away, copy it somewhere persistent BEFORE you"
            echo "  reboot: it holds the log and, if one was enrolled, the only"
            echo "  copy of the recovery key."
        fi
    fi
    # Give the background tee logger a moment to drain the pipe, so the final
    # lines (including the recovery instructions above) reach the log file.
    sync
    sleep 1
}
trap cleanup EXIT

# ─── Partial Previous Run Detection ─────────────────────────────────────────
# If a previous run was interrupted, detect and warn
if [ -b "/dev/mapper/${LUKS_NAME}" ]; then
    # Not always a leftover. An install this tool encrypted is itself unlocked
    # as ${LUKS_NAME}; run from there to encrypt a second install, the name is
    # simply taken, by the root filesystem. That used to be reported as a
    # stale mapper from a previous run, offered for closing, and ended in
    # "Could not close ... (still in use?)" with no way forward on offer.
    _root_src=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*//' || true)
    if [ -n "$_root_src" ] \
       && [ "$(readlink -f "$_root_src" 2>/dev/null || true)" = "$(readlink -f "/dev/mapper/${LUKS_NAME}")" ]; then
        fatal "The system you are running is itself encrypted, and unlocked as
       /dev/mapper/${LUKS_NAME}: the name this script gives the volume it creates.
       Give the install you are about to encrypt a name of its own and run again:
           sudo LUKS_MAPPER_NAME=${LUKS_NAME}2 $0${*:+ $*}
       Each install keeps its name in its own crypttab, so the two never meet."
    fi
    unset _root_src
    warn "Found /dev/mapper/${LUKS_NAME} already open from a previous run!"
    echo "  keep  = leave it open and reuse it (saves a passphrase prompt in config-only mode)"
    echo "  close = close it and start fresh"
    read -r -p "Keep or close? (keep/close): " STALE_CHOICE
    umount -R /mnt 2>/dev/null || true
    case "$STALE_CHOICE" in
        keep)
            log "  Keeping ${LUKS_NAME} open — it will be reused."
            ;;
        close)
            cryptsetup close "${LUKS_NAME}" 2>/dev/null \
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
# Detect GRUB config tool
GRUB_MKCONFIG=""
if command -v grub2-mkconfig &>/dev/null; then
    GRUB_MKCONFIG="grub2-mkconfig"
elif command -v grub-mkconfig &>/dev/null; then
    GRUB_MKCONFIG="grub-mkconfig"
fi

# Both tools only ever run inside the target's chroot, where step 4 checks for
# them again. The check here is an early warning for live media. An initrd
# (the RAM rescue, docs/RAM-RESCUE.md; systemd marks one with
# /etc/initrd-release) carries neither, and needs neither.
if [ -f /etc/initrd-release ]; then
    INITRAMFS_TOOL="${INITRAMFS_TOOL:-chroot}"
    GRUB_MKCONFIG="${GRUB_MKCONFIG:-chroot}"
else
    [ -n "$INITRAMFS_TOOL" ] || MISSING+=("dracut/mkinitcpio/update-initramfs")
    [ -n "$GRUB_MKCONFIG" ] || MISSING+=("grub2-mkconfig/grub-mkconfig")
fi

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
# /proc/modules, not `lsmod | grep -q`: grep -q leaves at its first match, and
# under pipefail a producer cut short by SIGPIPE reads as "not loaded".
if ! grep -q '^dm_crypt ' /proc/modules 2>/dev/null; then
    warn "Cannot load dm-crypt module. cryptsetup may still work via kernel built-in."
fi

# ─── Environment Detection ───────────────────────────────────────────────────
# Three environments can run this script safely:
#   • a Fedora Asahi live USB                       (docs/LIVE-USB.md)
#   • a second, minimal Asahi install on the same internal disk
#                                                   (docs/SECOND-INSTALL.md)
#   • a RAM-only rescue: the target install's own initramfs, stopped at a
#     dracut rd.break=pre-mount shell, with this script included in the image.
#     / is "rootfs", nothing on the disk is mounted, and everything written
#     next to the script is gone at reboot ($STATE_VOLATILE below).
# The second route exists because plenty of Apple Silicon machines never
# enumerate a USB stick in U-Boot at all, and a 20 GiB Fedora Minimal install
# alongside the real one is the reliable way out. Encrypting a partition from a
# sibling install is no different from doing it off a stick — but the sibling
# sits on the same disk as the target, which is exactly the situation where
# picking the wrong partition is easy and unrecoverable.
#
# So: map every device the running system is using, up front. The partition
# menus mark those [IN USE] and refuse to hand them out, and the self-target
# guard below turns "I selected the system I am booted from" into a hard stop
# instead of an obscure umount failure an hour later.
CURRENT_ROOT_FSTYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")
RUNNING_ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*//')
# Resolve only a real path. A RAM root reports a bare word ("rootfs", "tmpfs",
# "overlay"), and readlink -f resolves that against the current directory,
# which put "booted from /root/AsahiLocker/bin/rootfs" in the log.
case "$RUNNING_ROOT_DEV" in
    /*) RUNNING_ROOT_DEV=$(readlink -f "$RUNNING_ROOT_DEV" 2>/dev/null || echo "$RUNNING_ROOT_DEV") ;;
    '') RUNNING_ROOT_DEV="unknown" ;;
esac
# What a block device is built on, as /dev paths: the partitions under a
# dm-crypt, LVM or RAID device. Nothing for a plain partition or disk. The one
# place the /sys slaves layout is spelled out; both walks below use it.
block_slaves() {
    local s
    for s in "/sys/class/block/$(basename "$1")/slaves/"*; do
        [ -e "$s" ] && echo "/dev/$(basename "$s")"
    done
    return 0
}

# Walk down through dm-crypt/LVM so "which disk am I on?" has an answer even
# when / is a mapper device with no PKNAME of its own. First slave at each
# level: this answers "which disk", and a root striped across disks is not a
# layout this tool supports anyway.
RUNNING_ROOT_BASE="$RUNNING_ROOT_DEV"
_depth=0
while [ -b "$RUNNING_ROOT_BASE" ] \
   && [ -z "$(lsblk -dno PKNAME "$RUNNING_ROOT_BASE" 2>/dev/null | head -1)" ] \
   && [ "$_depth" -lt 8 ]; do
    _next=$(block_slaves "$RUNNING_ROOT_BASE" | head -1)
    [ -n "$_next" ] || break
    RUNNING_ROOT_BASE="$_next"
    _depth=$((_depth + 1))
done
unset _depth _next
# || true: in a RAM rescue / is "rootfs", not a block device, and lsblk exits 32,
# which set -e + pipefail would turn into a silent script exit.
RUNNING_ROOT_DISK=$(lsblk -dno PKNAME "$RUNNING_ROOT_BASE" 2>/dev/null | head -1 || true)
log "Current root filesystem: $CURRENT_ROOT_FSTYPE ($RUNNING_ROOT_DEV)"
RUNNING_ROOT_NOTE=""
if [ "$RUNNING_ROOT_BASE" != "$RUNNING_ROOT_DEV" ]; then
    RUNNING_ROOT_NOTE=" (backed by $RUNNING_ROOT_BASE)"
    log "  $RUNNING_ROOT_DEV is backed by $RUNNING_ROOT_BASE — this system is itself encrypted."
fi

# Every block device the running system has mounted or is swapping onto.
RUNNING_DEVS=()
_add_running_dev() {
    local raw="$1" d seen slave
    d=$(printf '%s' "$raw" | sed 's/\[.*//')          # btrfs: strip [/subvol]
    [ -n "$d" ] || return 0
    d=$(readlink -f "$d" 2>/dev/null || echo "$d")
    [ -b "$d" ] || return 0
    for seen in ${RUNNING_DEVS[@]+"${RUNNING_DEVS[@]}"}; do
        [ "$seen" = "$d" ] && return 0
    done
    RUNNING_DEVS+=("$d")
    # Follow device-mapper down to the real partitions. A rescue install that
    # is ITSELF encrypted mounts / from /dev/dm-0, and the crypto_LUKS
    # partition underneath it is what shows up in the ROOT menu (which accepts
    # crypto_LUKS so interrupted runs can be resumed). Without this the menu
    # would happily offer the running system's own container back.
    while IFS= read -r slave; do
        [ -n "$slave" ] && _add_running_dev "$slave"
    done < <(block_slaves "$d")
}
# Only the mounts that ARE this system. udisks on a live desktop automounts
# the target's partitions under /run/media, and a hand mount lands under /mnt;
# counting those would mark the very install the operator came to encrypt as
# IN USE, refuse it in every menu, and never reach the unmount offer further
# down (ensure_unmounted) that exists for exactly that case. A mount is the
# running system's when its mountpoint is one the OS lives at, or where live
# media keeps its own backing image.
is_system_mountpoint() {
    case "$1" in
        /|/boot|/boot/efi|/efi|/home|/usr|/var|/opt|/srv|/tmp|/nix) return 0 ;;
        /usr/*|/var/*|/run/initramfs/*|/run/rootfsbase|/run/rootfsbase/*) return 0 ;;
    esac
    return 1
}
while read -r _tgt _src; do
    [ -n "$_tgt" ] && is_system_mountpoint "$_tgt" && _add_running_dev "$_src"
done < <(findmnt -rno TARGET,SOURCE 2>/dev/null)
unset _tgt
while IFS= read -r _src; do _add_running_dev "$_src"; done \
    < <(awk 'NR > 1 { print $1 }' /proc/swaps 2>/dev/null)

is_running_dev() {
    # True if $1 backs any filesystem or swap of the system we are running on.
    local d seen
    d=$(readlink -f "$1" 2>/dev/null || echo "$1")
    for seen in ${RUNNING_DEVS[@]+"${RUNNING_DEVS[@]}"}; do
        [ "$seen" = "$d" ] && return 0
    done
    return 1
}

# M3 (t8122) behind m1n1 older than 1.9.1: U-Boot sees no USB mass storage at
# all, so the live USB the installed-system warning sends the user for never
# appears in bootflow (issue #4). Which m1n1 stage carries the fix is not yet
# pinned down, so either stage below 1.9.1 warns. m1n1 writes both versions
# into /chosen. A warning, never a stop: a second install needs no USB.
M1N1_USB_MIN="1.9.1"
m1n1_usb_check() {
    local compat stage ver old=""
    compat=$(tr '\0' ' ' 2>/dev/null < /proc/device-tree/compatible) || return 0
    case "$compat" in *apple,t8122*) ;; *) return 0 ;; esac
    for stage in 1 2; do
        ver=$(tr -d '\0' 2>/dev/null < "/proc/device-tree/chosen/asahi,m1n1-stage${stage}-version") || ver=""
        ver="${ver#v}"
        # Missing or unparsable counts as old: m1n1 has written this property
        # for years, so its absence means an old or broken boot object.
        if [ -z "$ver" ] || ! [[ "$ver" =~ ^[0-9]+\.[0-9]+ ]] \
           || [ "$(printf '%s\n' "$M1N1_USB_MIN" "$ver" | sort -V | head -n1)" != "$M1N1_USB_MIN" ]; then
            old="${old:+$old, }stage ${stage}: ${ver:+v}${ver:-unknown}"
        fi
    done
    [ -n "$old" ] || return 0
    echo ""
    warn "This is an M3 (t8122) running m1n1 ${old}."
    warn "  Below m1n1 ${M1N1_USB_MIN}, U-Boot on the M3 finds no USB storage at all: a"
    warn "  live USB will not appear in bootflow, whatever stick or port you use."
    warn "  First: sudo dnf upgrade m1n1, then reboot (stage 2; a normal update)."
    warn "  Still no USB? Stage 1 via the Asahi installer (option 'm') fixed it"
    warn "    on an M3 Air, but has left an M2 Max on macOS 27 unbootable --"
    warn "    read docs/LIVE-USB.md before trying it."
    warn "  Or skip the USB: a second install needs none (docs/SECOND-INSTALL.md)."
    warn "  Details: docs/LIVE-USB.md, 'M3: m1n1 1.9.1 or later'."
}

# Live media vs. an installed system. A Fedora Asahi live USB is a real
# installed system too (asahi-fedora-usb writes ext4/btrfs, not squashfs), so
# fstype alone is not the tell — removability is.
ENV_KIND="installed"
case "$CURRENT_ROOT_FSTYPE" in
    overlay|tmpfs|ramfs|rootfs|squashfs|iso9660|erofs) ENV_KIND="live" ;;
esac
if [ "$ENV_KIND" = "installed" ] && [ -n "$RUNNING_ROOT_DISK" ]; then
    [ "$(cat "/sys/block/$RUNNING_ROOT_DISK/removable" 2>/dev/null || echo 0)" = "1" ] \
        && ENV_KIND="live"
    # A rescue system on a Thunderbolt or USB4 NVMe enclosure reports
    # TRAN=nvme and removable=0, and would otherwise be taken for a sibling
    # install on the internal disk -- then walked through the sibling
    # confirmation and told its own drive is a rescue install to be erased.
    # HOTPLUG is the kernel's word for "this bus can go away"; it covers those
    # and plain USB alike, and Apple's internal NVMe reports 0.
    case "$(lsblk -dno TRAN "/dev/$RUNNING_ROOT_DISK" 2>/dev/null || echo)" in
        usb|thunderbolt|usb4) ENV_KIND="live" ;;
    esac
    [ "$(lsblk -dno HOTPLUG "/dev/$RUNNING_ROOT_DISK" 2>/dev/null | tr -d ' ')" = "1" ] \
        && ENV_KIND="live"
fi
log "Environment: $ENV_KIND (booted from ${RUNNING_ROOT_DEV}, disk ${RUNNING_ROOT_DISK:-unknown})"

# Is the directory this script runs from held in RAM? Everything the run leaves
# behind is written there: the deploy log, the pre-encryption state, a copy of
# the LUKS header backup and the recovery key. On a stick that is the point; in
# a RAM rescue all of it is gone at reboot, and the recovery key exists nowhere
# else. The end of the run copies the directory onto the encrypted system
# (KEEP_DIR, far below); this is the early notice.
STATE_VOLATILE=0
case "$(findmnt -n -o FSTYPE --target "$SCRIPT_DIR" 2>/dev/null || true)" in
    rootfs|tmpfs|ramfs) STATE_VOLATILE=1 ;;
esac
if [ "$STATE_VOLATILE" = "1" ]; then
    echo ""
    warn "AsahiLocker is running from $SCRIPT_DIR, which is held in RAM."
    warn "  The deploy log, the pre-encryption state backup, the LUKS header"
    warn "  backup copy and the recovery key are written there, and RAM is"
    warn "  cleared at reboot. A completed run copies them onto the encrypted"
    warn "  system before it exits. If the run stops early, copy that directory"
    warn "  somewhere persistent BEFORE you reboot."
fi

if [ "$ENV_KIND" = "installed" ]; then
    echo ""
    warn "You are not on live media — this is an installed system on"
    warn "  ${RUNNING_ROOT_DEV}${RUNNING_ROOT_NOTE}."
    warn "That is a supported way to run AsahiLocker (see docs/SECOND-INSTALL.md),"
    warn "  but ONLY to encrypt a DIFFERENT install than the one you booted."
    warn "The partitions this system is using are marked [IN USE] in the menus"
    warn "  below and cannot be chosen. If the install you want to encrypt is the"
    warn "  one you are sitting in, stop now: build the RAM rescue instead"
    warn "  (ram-rescue.sh build --arm, then reboot; docs/RAM-RESCUE.md), or"
    warn "  reboot into a live USB or a second Asahi install and run this there."
    m1n1_usb_check
fi

# ─── Power / Battery Check ──────────────────────────────────────────────────
for ps_dir in /sys/class/power_supply/*/; do
    [ -d "$ps_dir" ] || continue
    ps_type=$(cat "$ps_dir/type" 2>/dev/null || echo "")
    if [ "$ps_type" = "Battery" ]; then
        bat_capacity=$(cat "$ps_dir/capacity" 2>/dev/null || echo "100")
        # Guard the arithmetic below: a garbled sysfs read must not kill the
        # script under set -e with an inscrutable '[ -lt ]' error.
        case "$bat_capacity" in ''|*[!0-9]*) bat_capacity=100;; esac
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
            typed_confirm battery "Continue on battery? (Type 'battery' to override): " \
                || fatal "Connect AC power and try again."
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

# The running system's devices and disk were mapped during environment
# detection above ($RUNNING_DEVS / $RUNNING_ROOT_DISK / $ENV_KIND).

partition_number() {
    # The kernel's own index for a partition, /sys/class/block/<p>/partition:
    # 6 for nvme0n1p6, 3 for sda3. Absent -- so nothing printed -- for a whole
    # disk and for device-mapper devices. Trailing digits were used before, and
    # read a mapper's dm-N as partition N, which could hand the neighbour bonus
    # to an unrelated unlocked volume. Never fails: the result is captured in
    # an assignment, where a non-zero status would trip set -e.
    local base
    base=$(basename "$(readlink -f "$1" 2>/dev/null || echo "$1")")
    cat "/sys/class/block/$base/partition" 2>/dev/null || true
}

# A menu cannot be answered once stdin has closed (a pipe that ran dry, a
# terminal that went away), and read then fails at once, every time. The menu
# loops below used to go round on that for ever: no prompt was ever answered,
# and each pass wrote another line to the deploy log -- 1.5 GB in six minutes
# when it was measured. This ends the menu instead. pick_partition runs inside
# $( ), so the exit leaves that subshell and the failed assignment stops the
# script.
pick_no_input() {
    echo "" >&2
    echo "  No input: stdin is closed, so this menu cannot be answered. Stopping." >&2
    echo "  (For unattended runs pin the partitions: LUKS_TARGET_ROOT/BOOT/EFI.)" >&2
    exit 1
}

pick_partition() {
    # Usage: pick_partition <ROLE> <FSTYPE> <LABEL_HINT_REGEX> [NEAR_DEV]
    # Displays scored numbered list, returns selected device path on stdout.
    # All display/prompts go to stderr so stdout is clean for capture.
    #
    # NEAR_DEV is an already-chosen partition of the SAME install — in practice
    # the ROOT, passed when picking BOOT and EFI. An Asahi install lays its
    # three partitions down consecutively (EFI, boot, root), so on a disk
    # carrying two installs the neighbours just below the chosen root are
    # almost certainly its own boot and EFI. That only moves the default; the
    # fstab cross-check further down is what actually proves the pairing.
    local role="$1" fstype="$2" label_hint="$3" near_dev="${4:-}"
    local -a devs=() disp_labels=() sizes=() disks=() scores=() inuse=()
    local idx=0 best_idx=-1 best_score=-999999

    local near_disk="" near_num=""
    if [ -n "$near_dev" ]; then
        near_disk=$(lsblk -dno PKNAME "$near_dev" 2>/dev/null | head -1)
        near_num=$(partition_number "$near_dev")
    fi

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

        # lsblk prints a device-mapper device by its dm name, and there is no
        # /dev/<dmname> node — only /dev/mapper/<dmname>. Built naively the
        # path does not exist, so blkid, blockdev and (much worse) the
        # is_running_dev check below all quietly do nothing for it.
        local dev="/dev/$name"
        [ -b "$dev" ] || dev="/dev/mapper/$name"
        [ -b "$dev" ] || continue
        local label partlabel
        label=$(blkid -s LABEL -o value "$dev" 2>/dev/null || echo "")
        partlabel=$(blkid -s PARTLABEL -o value "$dev" 2>/dev/null || echo "")
        local disp="${label:-${partlabel:-(none)}}"

        # Score this candidate
        local score=0 busy=0
        # Strongly prefer NVMe over USB/SATA
        [[ "$dev" == *nvme* ]] && score=$((score + 100))
        # Bonus for label matching the expected role
        if [ -n "$label_hint" ]; then
            echo "$label $partlabel" | grep -Eqi "$label_hint" 2>/dev/null && score=$((score + 50))
        fi
        # On a live USB, everything on the USB's own disk is the wrong answer.
        # When running from a second install the target is on the same disk by
        # definition, so that penalty would rule out the right answer too —
        # there the running install is excluded partition by partition instead.
        if [ "$ENV_KIND" = "live" ] && [ -n "$RUNNING_ROOT_DISK" ] && [ "$disk" = "$RUNNING_ROOT_DISK" ]; then
            score=$((score - 200))
        fi
        # Partitions of the system we are running from are never candidates.
        if is_running_dev "$dev"; then
            busy=1
            score=$((score - 100000))
        fi
        # Neighbours of the already-chosen root beat a same-type partition
        # belonging to some other install further down the disk.
        if [ -n "$near_disk" ] && [ "$disk" = "$near_disk" ]; then
            score=$((score + 10))
            local num delta
            num=$(partition_number "$dev")
            if [ -n "$num" ] && [ -n "$near_num" ]; then
                delta=$((near_num - num))
                if [ "$delta" -gt 0 ] && [ "$delta" -le 3 ]; then
                    score=$((score + 60 - delta))
                fi
            fi
        fi
        # Tie-break on size: a 20 GiB rescue install and a 250 GiB daily driver
        # both answer to 'fedora', and it is the big one people mean.
        local size_b
        size_b=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        case "$size_b" in ''|*[!0-9]*) size_b=0;; esac
        score=$((score + size_b / 68719476736))     # +1 per 64 GiB

        devs+=("$dev")
        disp_labels+=("$disp")
        sizes+=("$size")
        disks+=("$disk")
        scores+=("$score")
        inuse+=("$busy")

        # An in-use partition is never the recommendation, whatever it scores.
        if [ "$busy" -eq 0 ] && [ "$score" -gt "$best_score" ]; then
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
            read -r -p "  Enter device path manually: " manual_dev || pick_no_input
            if [ ! -b "$manual_dev" ]; then
                echo "  ERROR: $manual_dev is not a block device." >&2
                continue
            fi
            if is_running_dev "$manual_dev"; then
                echo -e "  ${RED}ERROR: $manual_dev belongs to the system you are booted from.${NC}" >&2
                continue
            fi
            # The same fstype check the menu path makes: a whole disk, or the
            # ESP typed at the BOOT prompt, must not pass on [ -b ] alone --
            # BOOT_UUID would be read from the wrong device and step 4 would
            # mount it as /boot after the point of no return.
            local manual_fs
            manual_fs=$(blkid -s TYPE -o value "$manual_dev" 2>/dev/null || echo "unknown")
            if ! [[ "$manual_fs" =~ ^($fstype)$ ]]; then
                echo "  WARNING: $manual_dev has '$manual_fs', expected '$fstype'." >&2
                read -r -p "  Accept anyway? (yes/no): " accept
                [ "$accept" = "yes" ] || continue
            fi
            echo "  Selected: $manual_dev" >&2; echo "$manual_dev"; return
        done
    fi

    # Display numbered candidates with recommended / in-use markers
    for ((i=0; i<${#devs[@]}; i++)); do
        local marker=""
        [ "$i" -eq "$best_idx" ] && marker=" ${GREEN}← recommended${NC}"
        [ "${inuse[$i]}" -eq 1 ] && marker=" ${RED}← IN USE by this running system${NC}"
        printf "    %d) %-18s  %-22s  %8s  (%s)" \
            "$((i+1))" "${devs[$i]}" "${disp_labels[$i]}" "${sizes[$i]}" "${disks[$i]}" >&2
        echo -e "$marker" >&2
    done
    if [ "$best_idx" -lt 0 ]; then
        echo -e "  ${YELLOW}Every candidate belongs to the running system — nothing to recommend.${NC}" >&2
        echo -e "  ${YELLOW}You are probably booted into the very install you meant to encrypt.${NC}" >&2
    fi

    # Selection loop
    while true; do
        local default_hint=""
        [ "$best_idx" -ge 0 ] && default_hint=" [default: $((best_idx+1))]"
        read -r -p "  Select [1-${#devs[@]}] or device path${default_hint}: " choice || pick_no_input
        if [ -z "$choice" ]; then
            if [ "$best_idx" -lt 0 ]; then
                echo "  No default available — type a number or a device path." >&2
                continue
            fi
            choice=$((best_idx+1))
        fi

        # Numeric selection
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#devs[@]}" ]; then
            local sel="${devs[$((choice-1))]}"
            if [ "${inuse[$((choice-1))]}" -eq 1 ]; then
                echo -e "  ${RED}$sel is part of the system you are booted from — it cannot be${NC}" >&2
                echo -e "  ${RED}encrypted from inside itself. Pick the OTHER install.${NC}" >&2
                continue
            fi
            echo -e "  Selected: ${GREEN}${sel}${NC}" >&2
            echo "$sel"
            return
        fi

        # Direct device path
        if [ -b "$choice" ]; then
            if is_running_dev "$choice"; then
                echo -e "  ${RED}$choice is part of the system you are booted from — pick another.${NC}" >&2
                continue
            fi
            local actual_fs
            actual_fs=$(blkid -s TYPE -o value "$choice" 2>/dev/null || echo "unknown")
            if ! [[ "$actual_fs" =~ ^($fstype)$ ]]; then
                echo "  WARNING: $choice has '$actual_fs', expected '$fstype'." >&2
                read -r -p "  Accept anyway? (yes/no): " accept
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

# ─── BOOT and EFI from the target's own fstab ───────────────────────────────
# A root named on the command line (luks-deploy.sh /dev/nvme0n1pN) brings its
# own /boot and EFI: they are read from that install's /etc/fstab, mounted
# read-only, and matched by UUID. That is proof, where partition order is only
# a guess, and it skips the two menus. A root that is already encrypted cannot
# be read without its passphrase, and anything not found falls back to the
# menus; the fstab cross-check further down verifies the pairing either way.
if [ -n "$CLI_ROOT" ] && { [ -z "${LUKS_TARGET_BOOT:-}" ] || [ -z "${LUKS_TARGET_EFI:-}" ]; } \
   && [ "$(blkid -s TYPE -o value "$CLI_ROOT" 2>/dev/null || true)" = "btrfs" ]; then
    _fs_top=$(mktemp -d /tmp/luks-fstab.XXXXXX)
    if mount -o ro,subvolid=5 "$CLI_ROOT" "$_fs_top" 2>/dev/null; then
        _fs_tab=""
        for _fs_sub in root @rootfs @; do
            if [ -f "$_fs_top/$_fs_sub/etc/fstab" ]; then _fs_tab="$_fs_top/$_fs_sub/etc/fstab"; break; fi
        done
        if [ -n "$_fs_tab" ]; then
            while read -r _fs_spec _fs_mp; do
                _fs_dev=""
                case "$_fs_spec" in
                    UUID=*)     _fs_dev=$(blkid -U "${_fs_spec#UUID=}" 2>/dev/null || true) ;;
                    PARTUUID=*) _fs_dev=$(readlink -f "/dev/disk/by-partuuid/${_fs_spec#PARTUUID=}" 2>/dev/null || true) ;;
                esac
                if [ -z "$_fs_dev" ] || [ ! -b "$_fs_dev" ]; then continue; fi
                if [ "$_fs_mp" = "/boot" ] && [ -z "${LUKS_TARGET_BOOT:-}" ]; then
                    LUKS_TARGET_BOOT="$_fs_dev"; log "BOOT from the target's own fstab: $_fs_dev"
                elif [ "$_fs_mp" = "/boot/efi" ] && [ -z "${LUKS_TARGET_EFI:-}" ]; then
                    LUKS_TARGET_EFI="$_fs_dev"; log "EFI from the target's own fstab: $_fs_dev"
                fi
            done < <(awk '$1 !~ /^#/ && ($2 == "/boot" || $2 == "/boot/efi") { print $1, $2 }' "$_fs_tab")
        fi
        umount "$_fs_top" 2>/dev/null || true
    fi
    rmdir "$_fs_top" 2>/dev/null || true
    unset _fs_top _fs_tab _fs_sub _fs_spec _fs_mp _fs_dev
fi

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
    TARGET_BOOT=$(pick_partition "BOOT" "ext4" "boot" "$TARGET_ROOT")
fi
if [ -n "${LUKS_TARGET_EFI:-}" ]; then
    TARGET_EFI=$(pinned_partition "EFI" "LUKS_TARGET_EFI" "$LUKS_TARGET_EFI" "vfat")
else
    TARGET_EFI=$(pick_partition "EFI" "vfat" "efi|fedor" "$TARGET_ROOT")
fi

# ─── Self-Target Guard ───────────────────────────────────────────────────────
# There is no override here. Re-encrypting the blocks under a mounted, running
# root rewrites the filesystem the kernel is reading from, and the half-done
# state is not recoverable by re-running anything. Selecting the running
# system used to fail later and obscurely (umount / refuses); it fails here
# instead, while nothing has happened yet.
for _role_dev in "ROOT:$TARGET_ROOT" "BOOT:$TARGET_BOOT" "EFI:$TARGET_EFI"; do
    _guard_role="${_role_dev%%:*}"
    _guard_dev="${_role_dev#*:}"
    if is_running_dev "$_guard_dev"; then
        echo ""
        err "Selected $_guard_role partition $_guard_dev is in use by the system you booted."
        err "  Booted root: $RUNNING_ROOT_DEV"
        err "  Nothing can encrypt the filesystem it is itself running from."
        echo ""
        if [ -x "$SCRIPT_DIR/ram-rescue.sh" ]; then
            err "  To encrypt THIS system, the quickest way is the built-in RAM"
            err "  rescue: no USB stick, no second install (docs/RAM-RESCUE.md):"
            err "      sudo $SCRIPT_DIR/ram-rescue.sh build --arm && sudo reboot"
            err "  Or boot a Fedora Asahi live USB (docs/LIVE-USB.md) or a second"
        else
            err "  Boot the RAM rescue (docs/RAM-RESCUE.md), a Fedora Asahi live"
            err "  USB (docs/LIVE-USB.md) or a second"
        fi
        err "  minimal Asahi install (docs/SECOND-INSTALL.md), and from there"
        err "  select the partitions of the install you want encrypted."
        fatal "Refusing to operate on the running system."
    fi
done
unset _role_dev _guard_role _guard_dev

# ─── Second-Install Confirmation ─────────────────────────────────────────────
# Running from a sibling install on the same disk is supported, and the guard
# above has already proved the target is not this system. What is left is the
# one thing only the operator knows: which of the two installs is the keeper.
# Show both, side by side, and make them say it.
if [ "$ENV_KIND" = "installed" ]; then
    _run_label=$(blkid -s LABEL -o value "$RUNNING_ROOT_DEV" 2>/dev/null || echo "")
    _tgt_label=$(blkid -s LABEL -o value "$TARGET_ROOT" 2>/dev/null || echo "")
    echo ""
    log "=== Second-install mode ==="
    echo "  Running FROM  : $RUNNING_ROOT_DEV  ${_run_label:+[$_run_label]}  $(lsblk -dno SIZE "$RUNNING_ROOT_DEV" 2>/dev/null || echo '?')"
    echo "  Encrypting    : $TARGET_ROOT  ${_tgt_label:+[$_tgt_label]}  $(lsblk -dno SIZE "$TARGET_ROOT" 2>/dev/null || echo '?')"
    echo ""
    echo "  The second line is the system that will ask for a passphrase at boot."
    echo "  If those are the wrong way round, abort now."
    if [ "${LUKS_ACK_SIBLING:-0}" = "1" ]; then
        log "  LUKS_ACK_SIBLING=1 — confirmation pre-acknowledged."
    else
        typed_confirm sibling "  Confirm (Type 'sibling' to proceed): " || fatal "Aborted for safety."
    fi
    unset _run_label _tgt_label

    # Where the recovery material will land. On the live-USB route $SCRIPT_DIR
    # is the stick, which the user keeps. On this route it is very often the
    # rescue install's own root — and that install gets deleted from macOS a
    # day later, taking the header backup and recovery key with it.
    SCRIPT_DEV=$(findmnt -n -o SOURCE --target "$SCRIPT_DIR" 2>/dev/null | sed 's/\[.*//')
    SCRIPT_DEV=$(readlink -f "$SCRIPT_DEV" 2>/dev/null || echo "${SCRIPT_DEV:-}")
    if [ -n "$SCRIPT_DEV" ] && is_running_dev "$SCRIPT_DEV"; then
        echo ""
        warn "AsahiLocker is running from $SCRIPT_DIR, which lives on this"
        warn "  rescue install ($SCRIPT_DEV) — not on removable media."
        warn "The deploy log, the pre-encryption state backup, the LUKS header"
        warn "  backup and the recovery key are all written there. Deleting this"
        warn "  install afterwards destroys every one of them."
        warn "Copy that directory onto a USB stick — or onto the encrypted system"
        warn "  itself — BEFORE you reclaim this partition in macOS."
    fi
fi

# ─── Stale Mapper Cross-Check ────────────────────────────────────────────────
# If ${LUKS_NAME} is open (e.g. kept from a previous run), it MUST be backed by
# the ROOT partition just selected. Otherwise every later step that reuses the
# mapper (discovery, config, verification) would run against a DIFFERENT device
# than the one LUKS_UUID/crypttab point at — cross-wiring two systems.
if [ -b "/dev/mapper/${LUKS_NAME}" ]; then
    MAPPER_BACKING=$(cryptsetup status "${LUKS_NAME}" 2>/dev/null \
        | awk '$1 == "device:" {print $2; exit}')
    MAPPER_BACKING=$(readlink -f "$MAPPER_BACKING" 2>/dev/null || echo "${MAPPER_BACKING:-unknown}")
    TARGET_ROOT_REAL=$(readlink -f "$TARGET_ROOT")
    if [ "$MAPPER_BACKING" = "$TARGET_ROOT_REAL" ]; then
        log "Open ${LUKS_NAME} is backed by $TARGET_ROOT_REAL — OK to reuse."
    else
        err "/dev/mapper/${LUKS_NAME} is open but backed by: $MAPPER_BACKING"
        err "You selected ROOT: $TARGET_ROOT_REAL"
        err "Reusing this mapper would configure the WRONG system — closing it."
        if cryptsetup close "${LUKS_NAME}" 2>/dev/null; then
            log "  Closed mismatched ${LUKS_NAME}; the selected device will be opened when needed."
        else
            fatal "Could not close ${LUKS_NAME} (still in use?). Close it manually and re-run."
        fi
    fi
fi

# ─── Mounted-Target Guard ────────────────────────────────────────────────────
# Live desktops (udisks) automount internal partitions, and cryptsetup
# reencrypt refuses busy devices — catch that NOW, not an hour after the
# user typed encrypt and walked away.
ensure_unmounted() {
    # $1 = device; offer to unmount every mountpoint it currently has
    local dev="$1" mps mp
    # findmnt -S lists every mountpoint of a source on any util-linux; lsblk's
    # MOUNTPOINTS column only arrived in 2.37, and on older live media the
    # old lsblk call errored out and this guard silently passed.
    # sort -r: unmount nested child mounts (/mnt/home) before parents (/mnt)
    mps=$(findmnt -rno TARGET -S "$dev" 2>/dev/null | grep -v '^$' | sort -r || true)
    [ -n "$mps" ] || return 0
    warn "$dev is currently mounted at:"
    echo "$mps" | sed 's/^/    /'
    if [ "$DRY_RUN" = "1" ]; then
        warn "  [dry-run] a real run would require unmounting these first."
        return 0
    fi
    read -r -p "  Unmount it now? (yes/no): " UNMOUNT_OK
    [ "$UNMOUNT_OK" = "yes" ] || fatal "Cannot operate on a mounted device."
    while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        umount "$mp" || fatal "Could not unmount $mp — close whatever is using it and re-run."
    done <<< "$mps"
    log "  Unmounted $dev."
}
# This script's own directory on the target is the one mount that cannot be
# released: say that, rather than offer an unmount that can only fail busy.
_self_src=$(findmnt -n -o SOURCE --target "$SCRIPT_DIR" 2>/dev/null | sed 's/\[.*//' || true)
_self_src=$(readlink -f "${_self_src:-/nonexistent}" 2>/dev/null || true)
if [ "$_self_src" = "$(readlink -f "$TARGET_ROOT")" ] \
   || { [ -b "/dev/mapper/${LUKS_NAME}" ] && [ "$_self_src" = "$(readlink -f "/dev/mapper/${LUKS_NAME}")" ]; }; then
    fatal "AsahiLocker is running from $SCRIPT_DIR, which is ON the partition it is
       about to encrypt ($TARGET_ROOT). Copy the AsahiLocker folder to /root (or a
       USB stick), unmount the target, and run it from the copy."
fi
unset _self_src
ensure_unmounted "$TARGET_ROOT"
if [ -b "/dev/mapper/${LUKS_NAME}" ]; then
    ensure_unmounted "/dev/mapper/${LUKS_NAME}"
fi

# ─── Same-Disk Sanity Check ──────────────────────────────────────────────────
DISK_ROOT=$(lsblk -dno PKNAME "$TARGET_ROOT" 2>/dev/null | head -n1)
DISK_BOOT=$(lsblk -dno PKNAME "$TARGET_BOOT" 2>/dev/null | head -n1)
DISK_EFI=$(lsblk -dno PKNAME "$TARGET_EFI" 2>/dev/null | head -n1)
if [ "$DISK_ROOT" != "$DISK_BOOT" ] || [ "$DISK_ROOT" != "$DISK_EFI" ]; then
    warn "Selected partitions are on different disks!"
    echo "  ROOT: $TARGET_ROOT → $DISK_ROOT"
    echo "  BOOT: $TARGET_BOOT → $DISK_BOOT"
    echo "  EFI : $TARGET_EFI → $DISK_EFI"
    read -r -p "Proceed? (yes/no): " cross_disk
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
if [ "$(blkid -s TYPE -o value "$TARGET_ROOT" 2>/dev/null || true)" = "crypto_LUKS" ]; then
    RECOVERY_HINTS=1
    echo ""
    warn "$TARGET_ROOT already contains a LUKS header."
    # One dump, held in a variable, and the flag looked for in that. This is
    # the test that tells an INTERRUPTED encryption from a finished one, so it
    # does not ride on `luksDump | grep -q` under pipefail. grep -q exits at
    # its first match; a producer still writing is then killed by SIGPIPE, and
    # pipefail reports the pipeline as failed: "no match". That construction
    # did misreport in post-encryption-setup.sh (lsinitrd, a long listing). It
    # was not seen to fail with luksDump -- 300 runs against a 5.4 KB dump, no
    # miss -- but "interrupted volume taken for a complete one" is not an
    # outcome to leave to buffer sizes.
    if ! LUKS_DUMP=$(cryptsetup luksDump "$TARGET_ROOT" 2>/dev/null); then
        err "blkid reports crypto_LUKS but 'cryptsetup luksDump' cannot read the header."
        echo "  Try repairing it first, then re-run this script:"
        echo "    cryptsetup repair $TARGET_ROOT"
        fatal "LUKS header unreadable — see docs/RECOVERY.md."
    fi
    if grep -q 'online-reencrypt' <<< "$LUKS_DUMP"; then
        warn "The header carries the 'online-reencrypt' requirement flag:"
        warn "a previous in-place encryption was INTERRUPTED partway through."
        echo ""
        echo "  The safe fix is to let cryptsetup finish the encryption"
        echo "  (reencrypt --resume-only) and then redo the configuration"
        echo "  phase. This script can do both now."
        echo ""
        read -r -p "  Resume the interrupted encryption now? (yes/no): " RESUME_OK
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
        read -r -p "  Re-run configuration + verification on $TARGET_ROOT? (yes/no): " CONFIG_OK
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
        # One more try if the first resume after repair fails. Seen once in a
        # Fedora Asahi 45 VM (cryptsetup 2.8.8, power cut at 20 %): repair
        # succeeded, the next --resume-only unlocked keyslot 0 and then failed
        # with "wrong or missing parameters" (-1), and the very same command
        # run again straight afterwards finished the encryption. A failed
        # --resume-only changes nothing on disk, so a second attempt is safe.
        if ! cryptsetup reencrypt --resume-only --verbose "${CRYPT_PASS_ARGS[@]}" "${CRYPT_BATCH_ARGS[@]}" "$TARGET_ROOT"; then
            warn "  Resume after repair failed once — trying again (a failed attempt changes nothing on disk)..."
            cryptsetup reencrypt --resume-only --verbose "${CRYPT_PASS_ARGS[@]}" "${CRYPT_BATCH_ARGS[@]}" "$TARGET_ROOT" \
                || fatal "Resume still failing after repair. Do NOT wipe or reformat anything — see docs/RECOVERY.md."
        fi
    fi
    log "  Reencryption finished."
    DEPLOY_MODE="config-only"
fi

# In config-only mode the raw partition is a LUKS container, so discovery
# (subvolumes, fstab, UUIDs) must read through the opened mapper device.
DISCOVERY_DEV="$TARGET_ROOT"
if [ "$DEPLOY_MODE" = "config-only" ]; then
    if [ ! -b "/dev/mapper/${LUKS_NAME}" ]; then
        log "Unlocking $TARGET_ROOT (passphrase required)..."
        cryptsetup open "${CRYPT_PASS_ARGS[@]}" "$TARGET_ROOT" "${LUKS_NAME}"
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

# ─── Target tools ───────────────────────────────────────────────────────────
# Steps 6-7 rebuild the initramfs and grub.cfg INSIDE the target's chroot, so
# it is the target that must have the tools, whatever this environment has.
# Check now, while nothing has been written: after encryption a missing tool
# is only a warning and a system that will not boot.
_tgt_has() {
    local d
    for d in usr/bin usr/sbin bin sbin; do
        [ -e "/mnt_temp/${ROOT_SUBVOL}/$d/$1" ] && return 0
    done
    return 1
}
if ! { _tgt_has dracut || _tgt_has mkinitcpio || _tgt_has update-initramfs; }; then
    umount /mnt_temp; rmdir /mnt_temp
    fatal "The target install has no dracut/mkinitcpio/update-initramfs: it could not boot once encrypted."
fi
if ! { _tgt_has grub2-mkconfig || _tgt_has grub-mkconfig; }; then
    umount /mnt_temp; rmdir /mnt_temp
    fatal "The target install has no grub2-mkconfig/grub-mkconfig: it could not boot once encrypted."
fi
unset -f _tgt_has

# ─── Passphrase quality dictionary ──────────────────────────────────────────
# Without a cracklib dictionary, cryptsetup refuses EVERY typed passphrase with
# "error loading dictionary". The dracut RAM rescue carries none, but the
# install being encrypted almost always does (Fedora: cracklib-dicts), and its
# root is mounted read-only right here. Lend it to this run, so the quality
# check stays ON:
#   - the dictionary is copied to a fresh directory under /run (tmpfs). Not
#     into /usr: systemd mounts /usr read-only in an initrd, and a live
#     system's /usr is not this script's to change;
#   - a drop-in, $PWQ_DROPIN, points libpwquality's dictpath at the copy.
#     libpwquality reads the drop-ins in name order and pwquality.conf last,
#     so a dictpath set in pwquality.conf itself still wins: the result is
#     checked, and undone unless libpwquality will really use the copy.
# Only a fresh encryption sets a new passphrase, and only a typed one is
# checked (never LUKS_PASSPHRASE_FILE). Only on live media, never on an
# installed sibling; never over an existing file. cleanup() removes the copy,
# the drop-in and every directory made for them, on every exit. If nothing can
# be lent, the reencrypt step falls back to --force-password and says so.
# Verified in a Fedora Asahi 45 RAM rescue (cryptsetup 2.8.8): with the
# drop-in, luksFormat rejects "password1" as a dictionary word; without it,
# every passphrase fails with "error loading dictionary".
PWQ_DROPIN="/etc/security/pwquality.conf.d/zz-asahilocker-dict.conf"
if [ "$DEPLOY_MODE" = "encrypt" ] && [ -z "${LUKS_PASSPHRASE_FILE:-}" ]; then
    _pwq_have=$(pwq_dict_base "")
    if ! pwq_dict_present "$_pwq_have"; then
        _pwq_root="/mnt_temp/${ROOT_SUBVOL}"
        _pwq_src="${_pwq_root}$(pwq_dict_base "$_pwq_root")"
        _pwq_why=""
        if [ "$ENV_KIND" != "live" ]; then
            _pwq_why="AsahiLocker does not change an installed system's configuration"
        elif ! pwq_dict_present "$_pwq_src"; then
            _pwq_why="the target install has none either"
        # The index header opens with cracklib's magic 0x70775631, stored in
        # host byte order: proof the copy is a dictionary this machine reads.
        elif [ "$(od -An -tx4 -N4 "$_pwq_src.pwi" 2>/dev/null | tr -d ' \n')" != "70775631" ]; then
            _pwq_why="the target's index $_pwq_src.pwi is not a cracklib dictionary this machine can read"
        elif [ -e "$PWQ_DROPIN" ]; then
            _pwq_why="$PWQ_DROPIN already exists, and is left alone"
        fi
        if [ -n "$_pwq_why" ]; then
            log "  No cracklib dictionary at $_pwq_have, and $_pwq_why."
        elif [ "$DRY_RUN" = "1" ]; then
            log "  [dry-run] would lend the target's cracklib dictionary ($_pwq_src) to this run"
            log "  [dry-run]   (a copy under /run + $PWQ_DROPIN), keeping the passphrase quality check on."
        else
            _pwq_ok=0
            if _pwq_dir=$(mktemp -d /run/asahilocker-dict.XXXXXX 2>/dev/null); then
                PWQ_BORROWED_DIRS+=("$_pwq_dir")
                _pwq_ok=1
                for _pwq_ext in pwd pwd.gz pwi hwm; do
                    [ -f "$_pwq_src.$_pwq_ext" ] || continue
                    # Recorded before the copy, so a half-written file goes too.
                    PWQ_BORROWED+=("$_pwq_dir/pw_dict.$_pwq_ext")
                    cp "$_pwq_src.$_pwq_ext" "$_pwq_dir/pw_dict.$_pwq_ext" 2>/dev/null \
                        || { _pwq_ok=0; break; }
                done
            else
                _pwq_dir="/run"
            fi
            if [ "$_pwq_ok" = "1" ]; then
                # Note every directory level mkdir -p is about to create,
                # deepest first, so cleanup() can take them all away again.
                _pwq_d=$(dirname "$PWQ_DROPIN")
                while [ "$_pwq_d" != "/" ] && [ ! -e "$_pwq_d" ]; do
                    PWQ_BORROWED_DIRS+=("$_pwq_d")
                    _pwq_d=$(dirname "$_pwq_d")
                done
                PWQ_BORROWED+=("$PWQ_DROPIN")
                { mkdir -p "$(dirname "$PWQ_DROPIN")" \
                    && printf '# Written by AsahiLocker luks-deploy.sh for one run; removed at exit.\ndictpath = %s\n' \
                        "$_pwq_dir/pw_dict" > "$PWQ_DROPIN"; } 2>/dev/null || _pwq_ok=0
            fi
            if [ "$_pwq_ok" = "1" ] && [ "$(pwq_dict_base "")" = "$_pwq_dir/pw_dict" ] \
               && pwq_dict_present "$_pwq_dir/pw_dict"; then
                log "  Lent the target's cracklib dictionary ($_pwq_src) to this run,"
                log "    via $_pwq_dir and $PWQ_DROPIN:"
                log "    cryptsetup's passphrase quality check stays on. Both are removed at exit."
            else
                pwq_unborrow
                log "  Could not lend the target's cracklib dictionary to this run (tried $_pwq_dir)."
            fi
            unset _pwq_ok _pwq_ext _pwq_d _pwq_dir
        fi
        unset _pwq_root _pwq_src _pwq_why
    fi
    unset _pwq_have
fi

# Capture UUIDs before encryption. In config-only mode the raw partition
# holds the LUKS header, so the btrfs UUID must be read from the open mapper.
if [ "$DEPLOY_MODE" = "config-only" ]; then
    BTRFS_UUID=$(blkid -s UUID -o value "/dev/mapper/${LUKS_NAME}")
else
    BTRFS_UUID=$(blkid -s UUID -o value "$TARGET_ROOT")
fi
BOOT_UUID=$(blkid -s UUID -o value "$TARGET_BOOT")
EFI_UUID=$(blkid -s UUID -o value "$TARGET_EFI")

# ─── LUKS sector size ────────────────────────────────────────────────────────
# Apple NVMe has 4096-byte sectors, and btrfs writes 4096-byte blocks on every
# machine this runs on — yet cryptsetup's default encryption sector is 512, so
# each filesystem block became eight XTS blocks with eight IVs (measured: the
# author's own M2 Max volume, made by an earlier version of this script, is
# "sector: 512 [bytes]" on a 4096/4096 disk). LUKS2 encrypts in 4096-byte
# sectors when the filesystem never writes anything smaller, which btrfs with
# a 4096-byte sectorsize never does: one XTS block per fs block, and the same
# alignment the disk itself uses. Verified in-place on cryptsetup 2.8.8 for a
# 4096-byte-sector device and a 512-byte one alike (tests/loopback-core-test.sh).
# LUKS_SECTOR_SIZE=512|1024|2048|4096 pins it; it must not exceed the fs
# sectorsize, and the device size must be a multiple of it.
DEV_LSS=$(blockdev --getss "$TARGET_ROOT" 2>/dev/null || echo 512)
if [ "$DEPLOY_MODE" = "config-only" ]; then
    FS_SECTOR=$(btrfs inspect-internal dump-super "/dev/mapper/${LUKS_NAME}" 2>/dev/null | awk '/^sectorsize/{print $2; exit}')
else
    FS_SECTOR=$(btrfs inspect-internal dump-super "$TARGET_ROOT" 2>/dev/null | awk '/^sectorsize/{print $2; exit}')
fi
case "$FS_SECTOR" in ''|*[!0-9]*) FS_SECTOR=4096 ;; esac
if [ "$DEPLOY_MODE" = "config-only" ]; then
    # The header exists and its sector size is what it is: read it, so the log
    # and the closing summary state the volume's real value. (They used to
    # print the size a fresh run would have chosen: 4096 for a volume made
    # with 512-byte sectors before 1.12.0.)
    LUKS_SECTOR_SIZE=$(cryptsetup luksDump "$TARGET_ROOT" 2>/dev/null \
        | awk '/^Data segments:/{d=1; next} d && /^[[:space:]]+sector:/{print $2; exit}' || true)
    case "$LUKS_SECTOR_SIZE" in ''|*[!0-9]*) LUKS_SECTOR_SIZE="unknown" ;; esac
elif [ -n "${LUKS_SECTOR_SIZE:-}" ]; then
    case "$LUKS_SECTOR_SIZE" in 512|1024|2048|4096) ;; *) fatal "LUKS_SECTOR_SIZE must be 512, 1024, 2048 or 4096 (got '$LUKS_SECTOR_SIZE')" ;; esac
    [ "$LUKS_SECTOR_SIZE" -le "$FS_SECTOR" ] || fatal "LUKS_SECTOR_SIZE=$LUKS_SECTOR_SIZE is larger than the btrfs sectorsize ($FS_SECTOR) — the filesystem would write partial encryption sectors"
elif [ "$FS_SECTOR" -ge 4096 ]; then
    LUKS_SECTOR_SIZE=4096
else
    LUKS_SECTOR_SIZE=512
fi
# cryptsetup refuses a sector size the DEVICE size is not a multiple of
# ("Device size is not aligned to requested sector size"), and on a 512-byte-
# sector GPT disk the last partition is always 33 sectors short of one: the
# table reserves 33 sectors at the end of the disk, so an installer's "rest of
# the disk" root partition ends on an odd sector. Apple's 4096-byte-sector
# NVMe never has this problem; nearly every x86 disk does. The only in-place
# fix is to move the partition's END down by those few bytes — a partition-
# table edit, so it is a typed choice (or LUKS_ALIGN_PARTITION=yes|no), never
# a default; the table is backed up first, and the filesystem, already 32 MiB
# smaller, loses nothing. Declined, the volume gets 512-byte sectors — as
# every release before 1.12.0 did.
SECTOR_ALIGN=0; SECTOR_SHORT=0
if [ "$DEPLOY_MODE" != "config-only" ] && [ "$LUKS_SECTOR_SIZE" -gt 512 ]; then
    _dev_b=$(blockdev --getsize64 "$TARGET_ROOT" 2>/dev/null || echo 0)
    SECTOR_SHORT=$(( _dev_b % LUKS_SECTOR_SIZE ))
    if [ "$SECTOR_SHORT" -ne 0 ]; then
        _disk=$(lsblk -dno PKNAME "$TARGET_ROOT" 2>/dev/null | head -n1)
        # || true: a root that is not a partition has no parent disk, and a
        # failed test inside $( ) would end the script under set -e, silently,
        # one line short of the warning written for exactly that case.
        _pt=$( { [ -n "$_disk" ] && lsblk -dno PTTYPE "/dev/$_disk" 2>/dev/null | tr -d ' '; } || true )
        if [ -z "$_disk" ] || [ "$_pt" != gpt ] || ! command -v sgdisk >/dev/null 2>&1; then
            warn "  $TARGET_ROOT is $SECTOR_SHORT bytes past a ${LUKS_SECTOR_SIZE}-byte boundary and its end cannot be moved here (not a GPT partition, or no sgdisk) — 512-byte LUKS sectors"
            LUKS_SECTOR_SIZE=512
        else
            echo ""
            warn "  $TARGET_ROOT is $SECTOR_SHORT bytes past a ${LUKS_SECTOR_SIZE}-byte boundary."
            echo "     GPT reserves 33 sectors at the end of a disk, so on a 512-byte-sector disk the"
            echo "     last partition is normally this many bytes short of a 4096-byte multiple — and"
            echo "     cryptsetup can only encrypt in ${LUKS_SECTOR_SIZE}-byte sectors a device whose size is one."
            echo "     Two choices:"
            echo "       align  move the end of $TARGET_ROOT down by $SECTOR_SHORT bytes: a partition-table"
            echo "              edit (backed up first to the deployment drive; type, name, GUID and"
            echo "              attributes kept; the filesystem, already 32 MiB smaller, is untouched),"
            echo "              then encrypt in ${LUKS_SECTOR_SIZE}-byte sectors — one XTS block per filesystem block."
            echo "       Enter  keep the partition as it is and encrypt in 512-byte sectors — eight XTS"
            echo "              blocks per filesystem block, as every release before 1.12.0 did."
            case "${LUKS_ALIGN_PARTITION:-}" in
                yes|YES) SECTOR_ALIGN=1; log "  LUKS_ALIGN_PARTITION=yes: the partition end will be moved down $SECTOR_SHORT bytes (before encryption)" ;;
                no|NO)   LUKS_SECTOR_SIZE=512; log "  LUKS_ALIGN_PARTITION=no: 512-byte LUKS sectors" ;;
                "")
                    if [ "$DRY_RUN" = "1" ]; then
                        log "  [dry-run] a real run asks here; LUKS_ALIGN_PARTITION=yes|no answers it. Showing the align plan."
                        SECTOR_ALIGN=1
                    else
                        if typed_confirm align "  Type 'align' to move the partition end, or press Enter for 512-byte sectors: "; then
                            SECTOR_ALIGN=1
                        else
                            LUKS_SECTOR_SIZE=512; log "  Keeping the partition as it is: 512-byte LUKS sectors"
                        fi
                    fi ;;
                *) fatal "LUKS_ALIGN_PARTITION must be yes or no (got '$LUKS_ALIGN_PARTITION')" ;;
            esac
        fi
    fi
fi
if [ "$DEPLOY_MODE" = "config-only" ]; then
    log "  LUKS sector size: $LUKS_SECTOR_SIZE bytes (existing header — unchanged)"
else
    log "  LUKS sector size: $LUKS_SECTOR_SIZE bytes (disk logical sector $DEV_LSS, btrfs sectorsize $FS_SECTOR)$( [ "$SECTOR_ALIGN" = 1 ] && echo " — after moving the partition end down $SECTOR_SHORT bytes")"
fi

# --- align_partition_end ---
# Move the end of $TARGET_ROOT down so its size is a multiple of
# $LUKS_SECTOR_SIZE. Runs after the btrfs shrink (the filesystem must already
# fit). One sgdisk call recreates the partition with the same number, start,
# type code, name, unique GUID and attribute flags; the whole table is backed
# up first and the restore command is logged. Sector arithmetic is done in
# bytes and converted with the DISK's logical sector size — sgdisk counts in
# those, /sys counts in 512-byte units, and on a 4096-byte-sector disk the two
# differ by eight.
align_partition_end() {
    local part disk num lss start512 size_b new_b start_u end_u type guid name attrs bak fs_b i
    part=$(basename "$(readlink -f "$TARGET_ROOT")")
    disk="/dev/$(lsblk -dno PKNAME "$TARGET_ROOT" | head -n1)"
    num=$(cat "/sys/class/block/$part/partition" 2>/dev/null); [ -n "$num" ] || fatal "cannot read the partition number of $TARGET_ROOT"
    lss=$(blockdev --getss "$disk"); start512=$(cat "/sys/class/block/$part/start")
    size_b=$(blockdev --getsize64 "$TARGET_ROOT"); new_b=$(( size_b - size_b % LUKS_SECTOR_SIZE ))
    fs_b=$(btrfs inspect-internal dump-super "$TARGET_ROOT" 2>/dev/null | awk '/^total_bytes/{print $2; exit}')
    [ -n "$fs_b" ] && [ "$fs_b" -le "$new_b" ] || fatal "the filesystem (${fs_b:-?} bytes) would not fit the aligned partition ($new_b bytes) — not moving the end"
    start_u=$(( start512 * 512 / lss )); end_u=$(( start_u + new_b / lss - 1 ))
    type=$(sgdisk -i "$num" "$disk" | awk '/^Partition GUID code:/{print $4}')
    guid=$(sgdisk -i "$num" "$disk" | awk '/^Partition unique GUID:/{print $4}')
    name=$(sgdisk -i "$num" "$disk" | sed -n "s/^Partition name: '\(.*\)'\$/\1/p")
    attrs=$(sgdisk -i "$num" "$disk" | awk '/^Attribute flags:/{print $3}')
    [ -n "$type" ] && [ -n "$guid" ] || fatal "cannot read partition $num of $disk with sgdisk"
    bak="$STATE_DIR/gpt-backup-$(basename "$disk").bin"
    sgdisk --backup="$bak" "$disk" >/dev/null || fatal "could not back up the partition table of $disk"
    harden_path 0600 "$bak"
    log "  Partition table backed up: $bak  (restore: sgdisk --load-backup=$bak $disk)"
    log "  Moving the end of $TARGET_ROOT: $size_b -> $new_b bytes (sectors $start_u..$end_u of $disk, ${lss}-byte units)"
    sgdisk -d "$num" -n "$num:$start_u:$end_u" -t "$num:$type" -c "$num:$name" -u "$num:$guid" "$disk" >/dev/null \
        || fatal "sgdisk failed — the table backup is $bak"
    if [ -n "$attrs" ] && [ "$attrs" != "0000000000000000" ]; then
        for i in $(seq 0 63); do
            [ $(( 0x$attrs >> i & 1 )) -eq 1 ] && sgdisk -A "$num:set:$i" "$disk" >/dev/null
        done
    fi
    partprobe "$disk" 2>/dev/null || partx -u "$disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    [ "$(blockdev --getsize64 "$TARGET_ROOT")" = "$new_b" ] \
        || fatal "the kernel still sees $TARGET_ROOT at $(blockdev --getsize64 "$TARGET_ROOT") bytes (wanted $new_b) — table backup: $bak"
    log "  $TARGET_ROOT is now $new_b bytes, a multiple of $LUKS_SECTOR_SIZE (unique GUID, type and name unchanged)"
}
# --- end align_partition_end ---

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
    typed_confirm mismatch "  Use $3 anyway? (Type 'mismatch' to override): " \
        || fatal "Fix the partition selection and re-run."
}
log "Cross-checking selected BOOT/EFI partitions against the target's fstab..."
cross_check_part "BOOT" "/boot"     "$TARGET_BOOT" "$BOOT_UUID"
cross_check_part "EFI"  "/boot/efi" "$TARGET_EFI"  "$EFI_UUID"

# ─── Swap the encryption would not cover ────────────────────────────────────
# Swap holds whatever the kernel pages out of memory: keys, passwords, open
# documents. Fedora Asahi Remix swaps to zram, which is RAM and never reaches
# the disk. A swap partition or swap file set up by hand is another matter: a
# partition is not the root partition and stays plain, and so does a swap file
# on any filesystem but the root's. Encrypting the root alone would leave a
# plain-text copy of whatever was swapped out, on the same disk.
#
#   swap_plain_entries <fstab> <crypttab> <root-btrfs-uuid> [<systemd-unit-dir>]
# Prints "<swap>  <why>" for each swap, from the fstab and from any *.swap
# unit, that the encryption will NOT cover. Prints nothing when every swap is
# zram, a mapper that crypttab lists, or a file on the root filesystem. Reads
# only the files it is given, so tests/swap-check-test.sh can drive it.
swap_plain_entries() {
    local fstab="$1" crypttab="$2" root_uuid="$3" unitdir="${4:-}" spec src mp best len u
    _in_crypttab() { awk -v n="$1" '$1 !~ /^#/ && $1 == n { f = 1 } END { exit !f }' "$crypttab" 2>/dev/null; }
    {
        awk '$1 !~ /^#/ && $3 == "swap" { print $1 }' "$fstab" 2>/dev/null
        if [ -n "$unitdir" ]; then
            for u in "$unitdir"/*.swap; do
                [ -f "$u" ] && sed -n 's/^[[:space:]]*What=[[:space:]]*//p' "$u"
            done
        fi
    } | while IFS= read -r spec; do
        case "$spec" in
            /dev/zram*) ;;
            /dev/mapper/*)
                _in_crypttab "${spec#/dev/mapper/}" \
                    || echo "$spec  a device-mapper device that crypttab does not list: not known to be encrypted" ;;
            UUID=*|PARTUUID=*|LABEL=*|PARTLABEL=*|/dev/*)
                echo "$spec  a swap partition: it stays plain, outside the encrypted root" ;;
            /*)
                # A swap file is on whichever fstab filesystem has the longest
                # mount point that is a prefix of its path. The trailing slash
                # comes off first, in a variable of its own: "${mp%/}"/* as a
                # case pattern does not match anything when mp is "/" (bash
                # 5.3), which put every swap file on the root down as plain.
                best=""; len=-1
                while read -r src mp; do
                    mp=${mp%/}
                    case "$spec" in
                        "$mp"/*) if [ "${#mp}" -gt "$len" ]; then best=$src; len=${#mp}; fi ;;
                    esac
                done < <(awk '$1 !~ /^#/ && $2 ~ /^\// && $3 != "swap" { print $1, $2 }' "$fstab" 2>/dev/null)
                case "$best" in
                    "UUID=$root_uuid") ;;
                    /dev/mapper/*)
                        _in_crypttab "${best#/dev/mapper/}" \
                            || echo "$spec  a swap file on $best, which crypttab does not list: not known to be encrypted" ;;
                    *) echo "$spec  a swap file on ${best:-a filesystem the fstab does not name}: it stays plain" ;;
                esac ;;
            *) echo "$spec  a kind of swap this check does not know: taken as plain" ;;
        esac
    done
    return 0
}
SWAP_PLAIN=$(swap_plain_entries "$TARGET_FSTAB" "/mnt_temp/${ROOT_SUBVOL}/etc/crypttab" \
                 "$BTRFS_UUID" "/mnt_temp/${ROOT_SUBVOL}/etc/systemd/system")
if [ -z "$SWAP_PLAIN" ]; then
    log "Swap: nothing on the disk outside the encryption (zram, or none)."
else
    echo ""
    warn "This install swaps to the disk OUTSIDE the encryption:"
    while IFS= read -r _sw; do warn "    $_sw"; done <<< "$SWAP_PLAIN"
    unset _sw
    warn "  Whatever the kernel swaps out (keys, passwords, open documents) would"
    warn "  reach the disk in plain text, encrypted root or not. Fedora's own"
    warn "  default, zram, swaps to RAM and never touches the disk. How to switch"
    warn "  to it, or to encrypt the swap instead: docs/FAQ.md, 'Can swap leak"
    warn "  what the encryption protects?'"
    # Only a fresh encryption stops here. A resume has to finish whatever the
    # swap, and a config-only run comes after the encryption: the warning is
    # what they need.
    if [ "$DEPLOY_MODE" = "encrypt" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log "[dry-run] A real run stops here until you type swap."
        else
            typed_confirm swap "  Encrypt anyway, and fix the swap afterwards? (Type 'swap' to continue): " \
                || fatal "Stopped at the swap check. Fix the swap first (see above), or run again and type swap."
        fi
    fi
fi

# ─── Pre-Encryption State Backup (next to this script) ──────────────────────
log "  Saving pre-encryption state next to this script..."
STATE_DIR="$SCRIPT_DIR/pre-luks-state-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$STATE_DIR"
# Lock the directory before the recovery key or the header backup land in it.
# This is also the first harden_path call, so an unsuitable deployment drive
# is reported here -- before encryption starts and while aborting is free.
harden_path 0700 "$STATE_DIR"
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
    read -r -p "  Continue anyway? (yes/no): " subvol_override
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
elif [ "$USE_DEFAULTS" = 1 ]; then
    DO_CHECK="Y"
    log "--defaults: running the btrfs integrity check."
else
    read -r -p "Run btrfs integrity check first? (Recommended, takes 5-30 min) [Y/n]: " DO_CHECK
fi
if [ "$DO_CHECK" != "n" ] && [ "$DO_CHECK" != "N" ]; then
    log "  Running btrfs check --readonly (this may take a while)..."
    if btrfs check --readonly "$CHECK_DEV" 2>&1 | tail -3; then
        log "  Btrfs check: PASSED"
    else
        err "  Btrfs check found errors!"
        typed_confirm force "  Continue despite btrfs errors? (Type 'force' to override): " \
            || fatal "Fix btrfs errors before encrypting."
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
elif [ -n "${LUKS_PROFILE:-}" ] || [ "$USE_DEFAULTS" = 1 ]; then
    if [ -n "${LUKS_PROFILE:-}" ]; then
        _kdf_why="LUKS_PROFILE"
    elif [ "$KDF_DEFAULT_PROFILE" = moderate ]; then
        _kdf_why="--defaults: the default on a Mac with 8 GB of RAM"
    else
        _kdf_why="--defaults"
    fi
    LUKS_PROFILE="${LUKS_PROFILE:-$KDF_DEFAULT_PROFILE}"
    apply_kdf_profile "$LUKS_PROFILE" \
        || fatal "Unknown LUKS_PROFILE '$LUKS_PROFILE' (expected: aggressive, moderate, or fast)"
    log "KDF profile: $KDF_PROFILE_NAME ($_kdf_why)"
    unset _kdf_why
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
    # The menu as it reads on every Mac but one with 8 GB, where moderate
    # is the default and the closing paragraph says why.
    if [ "$KDF_DEFAULT_PROFILE" = moderate ]; then
        KDF_DEFAULT_CHOICE=2; _mark1="";              _mark2="   [default]"
    else
        KDF_DEFAULT_CHOICE=1; _mark1="   [default]";  _mark2=""
    fi
    printf "   1) aggressive    4 GiB, 10 iterations    unlock ~%s%s\n" "$(kdf_fmt_ms "${EST_AGG:-}")" "$_mark1"
    echo   "      Strongest. A 24 GB GPU fits only ~6 guesses at once"
    echo   "      against this. 4 GiB is argon2id's maximum memory cost,"
    echo   "      so anything beyond it has to buy iterations instead."
    echo ""
    printf "   2) moderate      2 GiB,  8 iterations    unlock ~%s%s\n" "$(kdf_fmt_ms "${EST_MOD:-}")" "$_mark2"
    echo   "      Strong. ~12 concurrent guesses on that same GPU."
    echo ""
    printf "   3) fast          1 GiB,  9 iterations    unlock ~%s\n" "$(kdf_fmt_ms "${EST_FAST:-}")"
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
    if [ "$KDF_DEFAULT_PROFILE" = moderate ]; then
        echo "   This Mac has 8 GB of RAM, so moderate is"
        echo "   the default here: the KDF's memory must be free in the"
        echo "   initramfs at every boot, and 4 GiB is half of this"
        echo "   machine. aggressive is still yours to choose: type 1."
    else
        echo "   You wait this long at EVERY boot. All three fit in the"
        echo "   initramfs, which has the machine to itself — so any of"
        echo "   them is safe on any Asahi-supported Mac."
    fi
    echo ""
    unset _mark1 _mark2
    # Re-prompt on a typo: by this point the user may have sat through a
    # 5-30 minute btrfs check, so a mistyped digit must not abort the run.
    while true; do
        read -r -p "  Select KDF profile [1-3, default ${KDF_DEFAULT_CHOICE}=${KDF_DEFAULT_PROFILE}]: " KDF_CHOICE
        case "${KDF_CHOICE:-$KDF_DEFAULT_CHOICE}" in
            1) apply_kdf_profile aggressive; break ;;
            2) apply_kdf_profile moderate;   break ;;
            3) apply_kdf_profile fast;       break ;;
            *) echo "  Invalid selection '$KDF_CHOICE' — enter 1, 2 or 3." ;;
        esac
    done
    log "  Selected: $KDF_PROFILE_NAME ($((LUKS_PBKDF_MEMORY / 1024)) MiB, ${LUKS_PBKDF_ITER} iterations)"
fi

# Applies to EVERY path that formats a new header — the menu, LUKS_PROFILE, and
# pinned LUKS_PBKDF_* alike. config-only is exempt: that header already exists
# and its KDF cannot be changed from here (use luks-tune.sh).
if [ "$DEPLOY_MODE" != "config-only" ]; then
    kdf_enforce_stock_floor
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
if [ "$DEPLOY_MODE" = "config-only" ]; then
    echo "  Sector  : (existing LUKS header — unchanged)"
else
    echo "  Sector  : ${LUKS_SECTOR_SIZE}-byte LUKS sectors (disk logical ${DEV_LSS}, btrfs sectorsize ${FS_SECTOR})$( [ "$SECTOR_ALIGN" = 1 ] && echo "; partition end moved down $SECTOR_SHORT bytes first" )"
fi
echo "  Mode    : $DEPLOY_MODE"
if [ "$DEPLOY_MODE" = "config-only" ]; then
    echo "  KDF     : (existing LUKS header — unchanged)"
else
    echo "  KDF     : argon2id $KDF_PROFILE_NAME — $((LUKS_PBKDF_MEMORY / 1024)) MiB, ${LUKS_PBKDF_ITER} iterations, ${LUKS_PBKDF_PARALLEL} threads"
    # State the strength claim as a number measured on THIS machine, at the
    # moment of decision — not as a promise from the README.
    if [ -n "${STOCK_ITER:-}" ] && [ -n "${STOCK_MEM:-}" ]; then
        printf "            = %s the work of cryptsetup's own default here (%s MiB x %s)\n" \
            "$(awk -v a="$((LUKS_PBKDF_MEMORY * LUKS_PBKDF_ITER))" \
                   -v b="$((STOCK_MEM * STOCK_ITER))" 'BEGIN{printf "%.4gx", a/b}')" \
            "$((STOCK_MEM / 1024))" "$STOCK_ITER"
    fi
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
        [ "$SECTOR_ALIGN" = 1 ] && echo "     then move the end of $TARGET_ROOT down $SECTOR_SHORT bytes (sgdisk; GPT backed up to the state dir) so its size is a multiple of $LUKS_SECTOR_SIZE"
        echo "  2. cryptsetup reencrypt --encrypt --type luks2 \\"
        echo "         --cipher aes-xts-plain64 --key-size 512 \\"
        echo "         --pbkdf argon2id --pbkdf-memory $LUKS_PBKDF_MEMORY \\"
        echo "         --pbkdf-parallel $LUKS_PBKDF_PARALLEL --pbkdf-force-iterations $LUKS_PBKDF_ITER \\"
        echo "         --hash sha512 --sector-size $LUKS_SECTOR_SIZE \\"
        echo "         --reduce-device-size 32M --resilience checksum $TARGET_ROOT"
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
        echo "     (LUKS_KEEP_SPLASH=1 here leaves the splash on instead. After the first"
        echo "     boot post-encryption-setup.sh puts the tokens back, unless it is run"
        echo "     with --keep-splash-off)"
    fi
    echo "  7. in chroot: rebuild ALL initramfs images, update ALL BLS entries (grubby),"
    echo "     regenerate /boot/grub2/grub.cfg (never the ESP stub); then label"
    echo "     everything written with the target's SELinux policy (setfiles)"
    echo "  8. run the verification gate; refuse the reboot message on any error"
    echo ""
    log "[dry-run] No changes were made to the target. Backups/plan artifacts: $STATE_DIR/"
    exit 0
fi

if [ "$DEPLOY_MODE" = "config-only" ]; then
    typed_confirm configure "Type 'configure' to redo the configuration phase: " || fatal "Aborted."
else
    typed_confirm encrypt "Type 'encrypt' to begin — there is no going back: " || fatal "Aborted."
fi
RECOVERY_HINTS=1

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
    if [ "$SECTOR_ALIGN" = 1 ]; then
        log "  Aligning the partition end for ${LUKS_SECTOR_SIZE}-byte LUKS sectors..."
        align_partition_end
    fi
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
    log "  Sector: ${LUKS_SECTOR_SIZE} bytes per encryption sector (disk ${DEV_LSS}, btrfs ${FS_SECTOR})"
    log "  You will be prompted to set a passphrase (type it twice)."
    log "  If interrupted, just re-run this script — it resumes automatically."
    echo ""

    # ── Caps Lock gate ──────────────────────────────────────────────────────
    # cryptsetup's next two prompts are, in this order:
    #     Are you sure? (Type 'yes' in capital letters):
    #     Enter passphrase for /dev/...:
    # Reaching for Caps Lock to type that YES is the natural thing to do, and it
    # stays on for the passphrase one prompt later. cryptsetup asks for the
    # passphrase twice, but both entries are inverted the same way, so its
    # type-it-twice check passes and the mistake only surfaces at the boot
    # prompt — Caps Lock off, nothing works, and the volume holds the only copy
    # of the data.
    #
    # So the last thing typed before cryptsetup runs is a LOWER CASE word. It
    # cannot be entered with Caps Lock on, which makes accepting it the proof:
    # no keyboard LED reading, which is unreliable over Bluetooth anyway, and
    # no warning issued minutes before the keystroke it is about.
    caps_lock_gate() {
        local caps_ok caps_tries=0
        [ -z "${LUKS_PASSPHRASE_FILE:-}" ] || return 0
        warn "  cryptsetup will now ask you to type YES in capital letters, and"
        warn "  then for the passphrase this machine will boot with."
        warn "  Hold SHIFT for that YES — do NOT use Caps Lock. Left on, it"
        warn "  inverts the passphrase both times, so the type-it-twice check"
        warn "  still passes and the boot prompt is where you would find out."
        while :; do
            if ! read -r -p "  Type 'yes' in lower case to confirm Caps Lock is off: " caps_ok; then
                echo ""
                fatal "Aborted (no input)."
            fi
            [ "$caps_ok" = "yes" ] && break
            caps_tries=$((caps_tries + 1))
            if [ "$caps_tries" -ge 5 ]; then
                fatal "Aborted."
            fi
            if [ "$caps_ok" = "YES" ]; then
                warn "  That arrived as 'YES' — Caps Lock is ON. Turn it off and"
                warn "  type yes again in lower case."
            else
                warn "  Type yes (lower case) to continue, or Ctrl-C to abort."
            fi
        done
        echo ""
    }

    # cryptsetup runs a typed passphrase through libpwquality, whose dictionary
    # check needs the cracklib dictionary on disk; without one EVERY passphrase
    # is refused with "error loading dictionary". Discovery has already
    # borrowed the target's own dictionary where this environment had none
    # ("Passphrase quality dictionary"). --force-password is the fallback for
    # when that was not possible: it skips the quality check, so it is passed
    # only when the dictionary really is still absent, and wherever it is
    # present a weak passphrase is still rejected. A passphrase read from
    # LUKS_PASSPHRASE_FILE is never quality-checked, so that route needs nothing.
    CRYPT_PWQ_ARGS=()
    if [ -z "${LUKS_PASSPHRASE_FILE:-}" ]; then
        PWQ_DICT=$(pwq_dict_base "")
        if ! pwq_dict_present "$PWQ_DICT"; then
            CRYPT_PWQ_ARGS=(--force-password)
            warn "  No cracklib dictionary here (${PWQ_DICT}.pwi/.pwd), and none could be"
            warn "  borrowed from the target: cryptsetup's passphrase quality check is"
            warn "  OFF for this run, and a weak passphrase will be accepted without"
            warn "  complaint. Choose a strong one."
            echo ""
        fi
        unset PWQ_DICT
    fi

    # LUKS2 KDF pinned for fleet consistency — do NOT fall back to cryptsetup's
    # auto-benchmark defaults (they pick sha256 + variable, time-benchmarked memory).
    # --pbkdf-force-iterations REPLACES time benchmarking, so no --iter-time here.
    # Unlock at boot re-runs this KDF inside the initramfs, so LUKS_PBKDF_MEMORY KiB
    # must be allocatable there — fine for every profile: the initramfs has the
    # machine to itself; on an 8 GB Mac moderate is the default (above).
    #
    # In a loop, for one reason: cryptsetup takes the passphrase BEFORE it
    # writes anything, and ends there if the two entries differ, if the quality
    # check refuses it, or if its YES arrives in lower case. Measured on
    # cryptsetup 2.8.8: exit 2 (exit 1 for the YES), no LUKS header, the btrfs
    # superblock still in place, no temporary file left behind. That used to
    # end the whole run, after every prompt and a btrfs check of up to half an
    # hour, over one mistyped character. Now it asks again, and only when the
    # device proves nothing was written: still no LUKS header, still btrfs. Any
    # other failure stops here as before, and a re-run resumes it.
    ENC_ATTEMPT=1
    while :; do
        caps_lock_gate
        ENC_RC=0
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
            --sector-size "$LUKS_SECTOR_SIZE" \
            --reduce-device-size 32M \
            --resilience checksum \
            --verbose \
            ${CRYPT_PWQ_ARGS[@]+"${CRYPT_PWQ_ARGS[@]}"} \
            "${CRYPT_PASS_ARGS[@]}" "${CRYPT_BATCH_ARGS[@]}" \
            "$TARGET_ROOT" || ENC_RC=$?
        [ "$ENC_RC" -eq 0 ] && break

        if [ -n "${LUKS_PASSPHRASE_FILE:-}" ] || [ "$ENC_ATTEMPT" -ge 3 ] \
           || { [ "$ENC_RC" -ne 1 ] && [ "$ENC_RC" -ne 2 ]; } \
           || cryptsetup isLuks "$TARGET_ROOT" 2>/dev/null \
           || [ "$(blkid -p -s TYPE -o value "$TARGET_ROOT" 2>/dev/null || true)" != "btrfs" ]; then
            fatal "cryptsetup reencrypt failed (exit $ENC_RC). Re-run this script: it reads the
       state of $TARGET_ROOT and resumes or starts again as needed."
        fi
        ENC_ATTEMPT=$((ENC_ATTEMPT + 1))
        echo ""
        warn "  cryptsetup stopped at its prompts (exit $ENC_RC; its reason is just above),"
        warn "  before writing anything. Checked: $TARGET_ROOT has no LUKS header and"
        warn "  is still plain btrfs. Nothing is lost, and nothing needs undoing."
        if ! read -r -p "  Try again? [Y/n]: " ENC_RETRY; then
            echo ""
            fatal "Aborted (no input). $TARGET_ROOT is untouched."
        fi
        case "$ENC_RETRY" in
            [Nn]|[Nn][Oo]) fatal "Aborted. $TARGET_ROOT is untouched; re-run when ready." ;;
        esac
        echo ""
    done
    unset ENC_ATTEMPT ENC_RC ENC_RETRY

    log "  Encryption complete."
    [ -n "${LUKS_PASSPHRASE_FILE:-}" ] \
        || log "  Next, cryptsetup asks for your passphrase once more, to open the new volume."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Open & Verify LUKS Container
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
log "[3/8] Verifying LUKS header and opening container..."

# Verify LUKS header integrity ('Key Slot N:' is LUKS1 syntax; LUKS2 keyslot
# parameters live on Cipher:/PBKDF:/Time cost:/Memory:/Threads: lines)
log "  LUKS header dump:"
cryptsetup luksDump "$TARGET_ROOT" 2>&1 \
    | grep -E '(^Version|Cipher:|PBKDF:|Time cost:|Memory:|Threads:)' | head -12 || true
echo ""

LUKS_UUID=$(blkid -s UUID -o value "$TARGET_ROOT")
[ -n "$LUKS_UUID" ] || fatal "Cannot read LUKS UUID — header may be corrupt! Check: cryptsetup luksDump $TARGET_ROOT"
log "  LUKS UUID: $LUKS_UUID"

# Open the LUKS container (already open if we came in via config-only mode)
if [ -b "/dev/mapper/${LUKS_NAME}" ]; then
    log "  Container already open: /dev/mapper/${LUKS_NAME}"
else
    cryptsetup open "${CRYPT_PASS_ARGS[@]}" "$TARGET_ROOT" "${LUKS_NAME}"
fi

# Verify mapper device exists
[ -b "/dev/mapper/${LUKS_NAME}" ] || fatal "/dev/mapper/${LUKS_NAME} does not exist after open!"
log "  Mapper device: /dev/mapper/${LUKS_NAME} OK"

# Verify the btrfs filesystem is intact inside LUKS
INNER_FSTYPE=$(blkid -s TYPE -o value "/dev/mapper/${LUKS_NAME}" 2>/dev/null || echo "")
INNER_UUID=$(blkid -s UUID -o value "/dev/mapper/${LUKS_NAME}" 2>/dev/null || echo "")
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
    typed_confirm uuid-changed "  Continue with UUID $INNER_UUID anyway? (Type 'uuid-changed' to override): " \
        || fatal "Aborted — investigate before configuring anything."
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
mount "/dev/mapper/${LUKS_NAME}" /mnt_temp
btrfs filesystem resize max /mnt_temp 2>/dev/null || true
umount /mnt_temp
rmdir /mnt_temp
log "  Btrfs resize max complete."

# Mount with correct subvolumes for chroot
log "  Mounting filesystems for chroot..."
# A minimal environment (the RAM rescue's initramfs) has no /mnt at all.
mkdir -p /mnt
MNT_OURS=1
mount -o "subvol=$ROOT_SUBVOL" "/dev/mapper/${LUKS_NAME}" /mnt

# Verify we got the right subvolume
if [ ! -f /mnt/etc/fstab ]; then
    err "  /mnt/etc/fstab not found after mounting subvol=$ROOT_SUBVOL!"
    err "  Trying subvolid=5 (top-level) as fallback..."
    umount /mnt
    mount -o subvolid=5 "/dev/mapper/${LUKS_NAME}" /mnt
    if [ -f "/mnt/${ROOT_SUBVOL}/etc/fstab" ]; then
        log "  Found fstab at /mnt/${ROOT_SUBVOL}/etc/fstab — remounting correctly..."
        umount /mnt
        mount -o "subvol=${ROOT_SUBVOL}" "/dev/mapper/${LUKS_NAME}" /mnt
    else
        fatal "Cannot find /etc/fstab in any mount configuration."
    fi
fi

# Mount home subvolume (if separate from root)
if [ "$HOME_SUBVOL" != "$ROOT_SUBVOL" ]; then
    mkdir -p /mnt/home
    mount -o "subvol=$HOME_SUBVOL" "/dev/mapper/${LUKS_NAME}" /mnt/home
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

# Default to NO when the header already has a second keyslot. Each acceptance
# enrols another one, so someone who re-runs the config phase a few times and
# keeps hitting Enter would end up with a header full of recovery keys they
# cannot tell apart. Otherwise yes: a fresh encrypt, and also a config-only run
# after an interrupted one, has no recovery key yet, and no way back if the
# passphrase is lost.
RK_DEFAULT="yes"
[ "$DEPLOY_MODE" = "config-only" ] && [ "${SLOTS_IN_USE:-0}" -gt 1 ] && RK_DEFAULT="no"
if [ "$RK_CHOICE" = "default" ]; then
    RK_CHOICE="$RK_DEFAULT"
    log "  --defaults: recovery key: $RK_CHOICE"
fi

if [ -z "$RK_CHOICE" ]; then
    echo ""
    echo "  A recovery key is a random 64-hex-character key in a second LUKS"
    echo "  keyslot. It unlocks the volume if the passphrase is ever forgotten."
    echo "  It will be written to $STATE_DIR/ — move it to secure offline"
    echo "  storage (NOT this machine) once deployment is done."
    if [ "${SLOTS_IN_USE:-0}" -gt 1 ]; then
        warn "  Note: $SLOTS_IN_USE keyslots are already in use — a recovery key may already be enrolled."
    fi
    if [ "$RK_DEFAULT" = "no" ]; then
        warn "  The header already has $SLOTS_IN_USE keyslots: saying yes adds ANOTHER"
        warn "  one on top of what is already there. Defaulting to no."
        read -r -p "  Generate and enroll a recovery key now? [y/N]: " RK_CHOICE
    else
        read -r -p "  Generate and enroll a recovery key now? [Y/n]: " RK_CHOICE
    fi
    # A bare Enter takes the default rather than falling through to "enrol".
    RK_CHOICE="${RK_CHOICE:-$RK_DEFAULT}"
fi
case "$RK_CHOICE" in
    [Nn]|[Nn][Oo])
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
            harden_path 0600 "$RK_FILE"
            # The slot gets the CURRENT LUKS_PBKDF_* parameters. In config-only
            # mode these are the aggressive defaults (or env), not necessarily
            # what the header's other slots use — cryptographically irrelevant
            # for a random 256-bit key, but say so rather than surprise a
            # later luksDump audit.
            log "  Enrolling recovery key (enter the volume passphrase when asked)..."
            log "  Recovery keyslot KDF: argon2id $((LUKS_PBKDF_MEMORY / 1024)) MiB x ${LUKS_PBKDF_ITER} (current profile — other slots may differ)"
            # --hash sha512: a new keyslot gets its own AF hash, and without an
            # explicit value cryptsetup stamps its compiled-in sha256 — the
            # same silent downgrade luks-tune.sh had, verified on cryptsetup 2.8.
            # No --force-password: the new key comes from a file, and cryptsetup
            # quality-checks only a passphrase typed at a terminal.
            if cryptsetup luksAddKey "${CRYPT_PASS_ARGS[@]}" "$TARGET_ROOT" "$RK_FILE" \
                   --hash sha512 \
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
                harden_path 0600 "$STATE_DIR/recovery-key-README.txt"
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
# umask 077 in a subshell: luksHeaderBackup creates the file itself and refuses
# to overwrite, so the mode must be right at creation rather than fixed after.
( umask 077; cryptsetup luksHeaderBackup "$TARGET_ROOT" \
    --header-backup-file /mnt/boot/luks-header-backup.img )
harden_path 0400 /mnt/boot/luks-header-backup.img
# Also save to the deployment drive. install(1) rather than cp(1): cp creates
# the destination at 0666 & ~umask -- 0644 by default -- so the header would sit
# world-readable for the length of the copy and stay that way if the chmod that
# follows is a no-op. install sets the mode as it creates the file.
install -m 0400 /mnt/boot/luks-header-backup.img "$STATE_DIR/luks-header-backup.img"
harden_path 0400 "$STATE_DIR/luks-header-backup.img"
log "  Header backup: /boot/luks-header-backup.img"
log "  Header backup: $STATE_DIR/luks-header-backup.img (copy next to this script)"

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
mkdir -p /mnt/etc/default
if [ -f /mnt/etc/default/grub ]; then
    cp /mnt/etc/default/grub /mnt/etc/default/grub.pre-luks
else
    warn "  /etc/default/grub does not exist — creating it."
    : > /mnt/etc/default/grub
fi

# GRUB_ENABLE_CRYPTODISK=y (allows GRUB to access encrypted partitions if needed)
if ! grep -q "^GRUB_ENABLE_CRYPTODISK=y" /mnt/etc/default/grub; then
    echo "GRUB_ENABLE_CRYPTODISK=y" >> /mnt/etc/default/grub
    log "    Added GRUB_ENABLE_CRYPTODISK=y"
fi

# Add rd.luks.uuid AND rd.luks.name to the kernel command line.
#
# WHICH variable holds it is distro-dependent, so never assume one is present:
#   * plain Fedora ships  GRUB_CMDLINE_LINUX
#   * Fedora Asahi Remix ships GRUB_CMDLINE_LINUX_DEFAULT and NO
#     GRUB_CMDLINE_LINUX line at all
# Update every one that exists; if the file defines neither, create
# GRUB_CMDLINE_LINUX.  (This used to be a bare `grep ^GRUB_CMDLINE_LINUX=` in a
# command substitution — under `set -o pipefail` a missing line made grep
# return 1, which aborted stage 6 with no message at all.  See issue #2.)
LUKS_BOOT_ARGS="rd.luks.uuid=$LUKS_UUID rd.luks.name=${LUKS_UUID}=$LUKS_NAME"

# Rewrite every definition of $1 to the literal value $2.  awk via ENVIRON so
# the value is never re-interpreted (a stray & or | would corrupt a sed RHS).
grub_cmdline_set() {
    local _gv="$1" _nv="$2" _tmp="/mnt/etc/default/.grub.$$"
    GV="$_gv" NV="$_nv" awk '
        BEGIN { v = ENVIRON["GV"]; nv = ENVIRON["NV"] }
        $0 ~ "^[[:space:]]*" v "=" { print v "=\"" nv "\""; next }
        { print }
    ' /mnt/etc/default/grub > "$_tmp" || { rm -f "$_tmp"; return 1; }
    # cat, not mv: keeps the inode, mode, owner and SELinux label intact.
    cat "$_tmp" > /mnt/etc/default/grub
    rm -f "$_tmp"
}

GRUB_CMDLINE_VARS_FOUND=0
for gvar in GRUB_CMDLINE_LINUX GRUB_CMDLINE_LINUX_DEFAULT; do
    grep -qE "^[[:space:]]*${gvar}=" /mnt/etc/default/grub || continue
    GRUB_CMDLINE_VARS_FOUND=1
    if grep -E "^[[:space:]]*${gvar}=" /mnt/etc/default/grub \
         | grep -q "rd.luks.uuid=$LUKS_UUID"; then
        log "    $gvar already carries rd.luks.uuid — keeping."
        continue
    fi
    # Last definition wins in shell, so that is the one whose value we keep.
    CURRENT_CMDLINE=$(sed -n -E "s|^[[:space:]]*${gvar}=(.*)\$|\1|p" \
        /mnt/etc/default/grub | tail -n1)
    case "$CURRENT_CMDLINE" in
        \"*\") CURRENT_CMDLINE=${CURRENT_CMDLINE#\"}; CURRENT_CMDLINE=${CURRENT_CMDLINE%\"} ;;
        \'*\') CURRENT_CMDLINE=${CURRENT_CMDLINE#\'}; CURRENT_CMDLINE=${CURRENT_CMDLINE%\'} ;;
    esac
    grub_cmdline_set "$gvar" "$LUKS_BOOT_ARGS${CURRENT_CMDLINE:+ $CURRENT_CMDLINE}" \
        || fatal "  Could not rewrite $gvar in /etc/default/grub."
    log "    Added $LUKS_BOOT_ARGS to $gvar"
done

if [ "$GRUB_CMDLINE_VARS_FOUND" -eq 0 ]; then
    warn "  No GRUB_CMDLINE_LINUX[_DEFAULT] line in /etc/default/grub — adding one."
    echo "GRUB_CMDLINE_LINUX=\"$LUKS_BOOT_ARGS\"" >> /mnt/etc/default/grub
fi

# Do not leave this stage without the unlock arguments actually on disk.
if ! grep -q "rd.luks.uuid=$LUKS_UUID" /mnt/etc/default/grub; then
    fatal "  /etc/default/grub still has no rd.luks.uuid=$LUKS_UUID after update!"
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
    mkdir -p /mnt/etc/kernel
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
            else
                # Un-parseable name (e.g. initrd.img-<ver>) — cannot pick a kernel
                # version to rebuild for, and a silent pass here would let an
                # image without cryptsetup through the gate.
                echo "[CHROOT]       Cannot parse a kernel version from $(basename "$initrd") — auto-repair impossible!"
                ERRORS=$((ERRORS + 1))
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
# boot (it leaves them off when run with --keep-splash-off).
# LUKS_KEEP_SPLASH=1 skips the strip: the splash stays on throughout.
echo ""
if [ "${LUKS_KEEP_SPLASH:-0}" = "1" ]; then
    echo "[CHROOT] LUKS_KEEP_SPLASH=1 — leaving 'rhgb quiet' in place."
else
    echo "[CHROOT] Stripping 'rhgb quiet' from boot args (post-encryption-setup.sh restores them, or leaves them off with --keep-splash-off)..."
    strip_splash_tokens() {
        # $1 = file, $2 = sed address ('' = whole line applies)
        # Three boundary cases, each swept twice because adjacent tokens
        # ('rhgb quiet') need a second pass (sed resumes after the match):
        #   1. token preceded by whitespace (mid/end of line): the token and its
        #      leading space are dropped, boundary \2 (space, quote, EOL) kept
        #   2. token at the very start of the line (bare cmdline files)
        #   3. token right after an opening quote (GRUB_CMDLINE_LINUX="quiet ...")
        sed -i -E "
            $2 s/[[:space:]]+(rhgb|quiet)([[:space:]]+|\"|\$)/\\2/g
            $2 s/[[:space:]]+(rhgb|quiet)([[:space:]]+|\"|\$)/\\2/g
            $2 s/^(rhgb|quiet)([[:space:]]+|\$)//
            $2 s/^(rhgb|quiet)([[:space:]]+|\$)//
            $2 s/(=\")(rhgb|quiet)[[:space:]]+/\\1/
            $2 s/(=\")(rhgb|quiet)[[:space:]]+/\\1/
            $2 s/(=\")(rhgb|quiet)(\")/\\1\\3/
            $2 s/[[:space:]]+\$//
        " "$1"
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
GRUB_CFG_FOUND=false
if [ -n "$grub_tool" ]; then
    for grub_cfg in /boot/grub2/grub.cfg /boot/grub/grub.cfg; do
        [ -f "$grub_cfg" ] || continue
        GRUB_CFG_FOUND=true
        echo "[CHROOT] $grub_tool -o $grub_cfg"
        if $grub_tool -o "$grub_cfg" 2>&1; then
            GRUB_REBUILT=true
        else
            echo "[CHROOT] WARN: $grub_tool exited non-zero on $grub_cfg."
        fi
        break
    done
    if ! $GRUB_CFG_FOUND; then
        # No existing real config — create one at the tool's native location
        # (still never on the ESP).
        case "$grub_tool" in
            grub2-mkconfig) $grub_tool -o /boot/grub2/grub.cfg 2>&1 && GRUB_REBUILT=true ;;
            grub-mkconfig)  $grub_tool -o /boot/grub/grub.cfg  2>&1 && GRUB_REBUILT=true ;;
        esac
    fi
fi
if $GRUB_REBUILT; then
    echo "[CHROOT] GRUB config rebuilt."
elif [ ! -d /boot/loader/entries ]; then
    # No BLS entries: grub.cfg IS the boot configuration, and it still
    # carries the pre-encryption command line without the unlock args.
    echo "[CHROOT] FAIL: Could not rebuild GRUB config, and grub.cfg is what boots this machine."
    ERRORS=$((ERRORS + 1))
else
    echo "[CHROOT] WARN: Could not rebuild GRUB config."
fi

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

# ─── 7e: SELinux — label every file this deployment wrote ───────────────────
# A wrong or missing label on /etc/crypttab, /etc/fstab or a dracut conf is
# denied in enforcing mode on the first boot. /boot is done whole: the rebuilt
# initramfs images, the BLS entries, grub.cfg and the header backup are in it.
echo ""
log "  Labeling the files this deployment wrote (SELinux, the target's own policy)..."
RELABEL_RC=0
RELABEL_LEFT=$(target_relabel \
    /etc/crypttab /etc/fstab /etc/fstab.pre-luks \
    /etc/default/grub /etc/default/grub.pre-luks \
    /etc/kernel/cmdline /etc/kernel/cmdline.pre-luks \
    /etc/dracut.conf.d/99-luks.conf \
    /var/lib/asahilocker /boot 2>&1) || RELABEL_RC=$?
case "$RELABEL_RC" in
    0)  log "  SELinux labels set and read back: OK." ;;
    2)  log "  No SELinux policy on the target (no /etc/selinux/config, setfiles or file_contexts) — nothing to label." ;;
    *)  warn "  SELinux: these files could not be labeled:"
        # A here-string, not `echo | head`: with a long list head exits first,
        # echo dies of SIGPIPE, and under pipefail + set -e that would end the
        # deployment right here, before the verification gate.
        sed -n '1,20s/^/      /p' <<< "$RELABEL_LEFT"
        warn "  The system boots and unlocks all the same. post-encryption-setup.sh,"
        warn "  which you run after the first boot, labels them. If that boot fails"
        warn "  with SELinux denials instead, add 'enforcing=0' to the kernel command"
        warn "  line for one boot, then run:"
        warn "      sudo restorecon -RFv /etc /boot && sudo setenforce 1" ;;
esac

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
    log "  V8 OK: LUKS header backup exists in $STATE_DIR/"
else
    warn "  V8 WARN: LUKS header backup missing from $STATE_DIR/"
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
if [ -b "/dev/mapper/${LUKS_NAME}" ]; then
    log "  V10 OK: /dev/mapper/${LUKS_NAME} is active"
    _ss=$(cryptsetup status "${LUKS_NAME}" 2>/dev/null | awk '/sector size:/{print $3; exit}')
    if [ "$DEPLOY_MODE" = "config-only" ]; then
        log "  V10 OK: encryption sector size ${_ss:-?} bytes (existing header)"
    elif [ "${_ss:-}" = "$LUKS_SECTOR_SIZE" ]; then
        log "  V10 OK: encryption sector size $_ss bytes, as planned"
    else
        err "  V10 FAIL: encryption sector size is ${_ss:-unknown}, planned $LUKS_SECTOR_SIZE!"
        ERRORS=$((ERRORS + 1))
    fi
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
echo "  LUKS sector : ${LUKS_SECTOR_SIZE} bytes"
echo "  BLS entries : ALL updated with LUKS parameters"
echo "  initramfs   : ALL kernels rebuilt with crypt+dm+btrfs modules"
echo "  header bkup : /boot/luks-header-backup.img + $STATE_DIR/"
if [ -f "$STATE_DIR/recovery-key.txt" ]; then
    echo "  recovery key: $STATE_DIR/recovery-key.txt  ← MOVE TO SECURE OFFLINE STORAGE"
fi
echo ""

# Save log to target system's /boot (survives if USB is removed)
cp "$DEPLOY_LOG" /mnt/boot/luks-deploy.log 2>/dev/null || true
target_relabel /boot/luks-deploy.log >/dev/null 2>&1 || true
log "Log also saved to target: /boot/luks-deploy.log"
echo ""
if [ "$STATE_VOLATILE" = "1" ]; then
    echo "Full log: $DEPLOY_LOG (in RAM -- gone at reboot)"
else
    echo "Full log: $DEPLOY_LOG (on deployment drive)"
fi
echo "          /boot/luks-deploy.log (on target system)"
echo ""
echo "Pre-encryption backups: $STATE_DIR/"
echo ""

# Two routes leave the recovery material somewhere that is about to disappear:
# the second-install route ends with the operator deleting the install this
# script ran from, and a RAM rescue loses it at reboot. Say so here, where they
# are actually looking.
KEEP_WHY=""
if [ "$STATE_VOLATILE" = "1" ]; then
    KEEP_WHY="ram"
elif [ "$ENV_KIND" = "installed" ] && [ -n "${SCRIPT_DEV:-}" ] && is_running_dev "$SCRIPT_DEV"; then
    KEEP_WHY="sibling"
fi
if [ -n "$KEEP_WHY" ]; then
    # The EXIT trap unmounts /mnt and closes the mapper the moment this script
    # returns, so any "copy it now" instruction is already wrong when it is
    # read. Do the copy here, while the target is still mounted, into its own
    # /root: readable only once the volume is unlocked, so nothing is exposed,
    # and it outlives the rescue install being erased from macOS, or the reboot
    # out of a RAM rescue.
    KEEP_DIR="/mnt/root/asahilocker-$(basename "$STATE_DIR")"
    if mountpoint -q /mnt && cp -a "$STATE_DIR" "$KEEP_DIR" 2>/dev/null; then
        chmod 0700 "$KEEP_DIR" 2>/dev/null || true
        target_relabel "/root/$(basename "$KEEP_DIR")" >/dev/null 2>&1 || true
        KEEP_NOTE="Copied onto the encrypted system: /root/$(basename "$KEEP_DIR")/"
    else
        KEEP_NOTE="Could NOT copy it onto the encrypted system -- do that by hand, now"
    fi
fi
if [ "$KEEP_WHY" = "ram" ]; then
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  BEFORE you reboot:                                       ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo "  $STATE_DIR/"
    echo "  is held in RAM and holds the LUKS header backup, the pre-encryption"
    echo "  fstab/grub/BLS state and (if enrolled) the recovery key."
    echo "  $KEEP_NOTE"
    echo ""
    if [ -f "$STATE_DIR/recovery-key.txt" ]; then
        echo "  That copy sits INSIDE the volume it unlocks, which makes the recovery"
        echo "  key in it useless for the one case it exists for: a forgotten"
        echo "  passphrase. Either write the key down now, before you reboot:"
        echo "      cat $STATE_DIR/recovery-key.txt"
        echo "  or, after the first boot, move the directory from /root to offline"
        echo "  storage. (The header backup is also at /boot/luks-header-backup.img.)"
    else
        echo "  After the first boot, move the directory from /root to offline"
        echo "  storage. (The header backup is also at /boot/luks-header-backup.img.)"
    fi
    echo ""
elif [ "$KEEP_WHY" = "sibling" ]; then
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  BEFORE you delete this rescue install from macOS:        ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo "  $STATE_DIR/"
    echo "  is on the rescue install and holds the LUKS header backup, the"
    echo "  pre-encryption fstab/grub/BLS state and (if enrolled) the recovery key."
    echo "  $KEEP_NOTE"
    echo ""
    echo "  That copy sits INSIDE the volume it unlocks, which makes the recovery"
    echo "  key in it useless for the one case it exists for: a forgotten"
    echo "  passphrase. Before you erase this install, put the directory on a"
    echo "  USB stick as well. (The header backup is also at /boot/luks-header-backup.img.)"
    echo ""
    echo "  Then set System Settings → General → Startup Disk back to the"
    echo "  encrypted install before removing this one. See docs/SECOND-INSTALL.md."
    echo ""
fi
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
