#!/usr/bin/env bash
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
# luks-tune.sh
# ============================================================================
# An ncurses front-end for inspecting and re-costing the argon2id KDF
# parameters of keyslots on LUKS2 volumes that ALREADY EXIST.
#
# The deploy script's KDF profiles apply at luksFormat time only. A header
# keeps whatever it was built with, so this is the tool for changing your mind
# afterwards.
#
# What it does:      cryptsetup luksConvertKey  — re-wraps ONE keyslot's key
#                    under new argon2id parameters.
# What it never does: create or destroy a keyslot, change a passphrase, touch
#                    filesystem data, or offer pbkdf2. There is no code path
#                    here that selects pbkdf2; see README, "Never use pbkdf2".
#
# The passphrase is never read, stored or passed by this script. cryptsetup
# prompts for it directly on the terminal, outside the ncurses UI.
#
# A header backup is taken before any write and its path is shown. Keep it
# until a successful boot confirms the new parameters.
#
# Usage:
#   sudo ./bin/luks-tune.sh              # interactive
#   sudo ./bin/luks-tune.sh --dry-run    # show the command, change nothing
# ============================================================================

set -euo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# ─── Safety floor (mirrors luks-deploy.sh) ───────────────────────────────────
FLOOR_MEM_KIB=524288    # 512 MiB
FLOOR_ITER=4

# ─── Profiles (mirrors luks-deploy.sh; memory in KiB) ────────────────────────
P_AGGRESSIVE_MEM=4194304; P_AGGRESSIVE_ITER=12
P_MODERATE_MEM=2097152;   P_MODERATE_ITER=6
P_FAST_MEM=1048576;       P_FAST_ITER=4
P_PARALLEL=4

CRYPTSETUP=/usr/sbin/cryptsetup
[ -x "$CRYPTSETUP" ] || CRYPTSETUP=/sbin/cryptsetup
[ -x "$CRYPTSETUP" ] || { echo "cryptsetup not found" >&2; exit 1; }

# ─── UI backend ──────────────────────────────────────────────────────────────
if command -v dialog >/dev/null 2>&1; then UI=dialog
elif command -v whiptail >/dev/null 2>&1; then UI=whiptail
else
    echo "Neither 'dialog' nor 'whiptail' is installed." >&2
    echo "  sudo dnf install dialog     # or: sudo dnf install newt" >&2
    exit 1
fi

BACKTITLE="AsahiLocker — LUKS2 KDF tuning"
ui() { "$UI" --backtitle "$BACKTITLE" "$@"; }

die() { ui --title "Error" --msgbox "$1" 12 70 || true; clear; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2; exit 1
fi

# ─── Discover LUKS2 volumes ──────────────────────────────────────────────────
mapfile -t CANDIDATES < <(lsblk -rpno NAME,FSTYPE | awk '$2=="crypto_LUKS"{print $1}')
[ "${#CANDIDATES[@]}" -gt 0 ] || die "No LUKS volumes found on this system."

MENU_ITEMS=()
for dev in "${CANDIDATES[@]}"; do
    "$CRYPTSETUP" isLuks --type luks2 "$dev" 2>/dev/null || continue
    size=$(lsblk -dno SIZE "$dev" 2>/dev/null | tr -d ' ')
    label=$("$CRYPTSETUP" luksDump "$dev" 2>/dev/null | awk -F': *' '/^Label:/{print $2}')
    [ -n "$label" ] && [ "$label" != "(no label)" ] || label="no label"
    MENU_ITEMS+=("$dev" "$size  $label")
done
[ "${#MENU_ITEMS[@]}" -gt 0 ] || die "Found LUKS volumes, but none are LUKS2.\n\nluksConvertKey applies to LUKS2 headers only."

DEV=$(ui --title "Select a LUKS2 volume" \
         --menu "Keyslot parameters are per-volume." 16 74 6 \
         "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3) || { clear; exit 0; }

# ─── Show current state ──────────────────────────────────────────────────────
slot_table() {   # $1 = device; emits "slot<TAB>kdf<TAB>mem_kib<TAB>iter<TAB>threads"
    "$CRYPTSETUP" luksDump "$1" | awk '
        /^[[:space:]]+[0-9]+: luks2/ { slot=$1; sub(":","",slot); k=""; m=""; i=""; t=""; next }
        slot!="" && /PBKDF:/      { k=$2 }
        slot!="" && /Time cost:/  { i=$3 }
        slot!="" && /Memory:/     { m=$2 }
        slot!="" && /Threads:/    { t=$2; printf "%s\t%s\t%s\t%s\t%s\n", slot, k, m, i, t; slot="" }
    '
}

human_mem() { awk -v k="$1" 'BEGIN{ if (k>=1048576) printf "%.0f GiB", k/1048576; else printf "%.0f MiB", k/1024 }'; }

render_slots() {
    printf '%-6s %-10s %-10s %-12s %s\n' SLOT KDF MEMORY ITERATIONS THREADS
    printf '%s\n' "------------------------------------------------------"
    while IFS=$'\t' read -r s k m i t; do
        printf '%-6s %-10s %-10s %-12s %s\n' "$s" "$k" "$(human_mem "$m")" "$i" "$t"
    done
}

mapfile -t SLOTS < <(slot_table "$DEV")
[ "${#SLOTS[@]}" -gt 0 ] || die "Could not read any keyslots from $DEV."

SUMMARY=$(printf '%s\n' "${SLOTS[@]}" | render_slots)
ui --title "$DEV — current keyslots" \
   --msgbox "$SUMMARY

Each keyslot carries its own parameters. A passphrase slot and a
keyfile slot on the same volume are commonly different." 18 74 || { clear; exit 0; }

# ─── Pick a slot ─────────────────────────────────────────────────────────────
SLOT_ITEMS=()
while IFS=$'\t' read -r s k m i t; do
    SLOT_ITEMS+=("$s" "$k  $(human_mem "$m")  t=$i  threads=$t")
done < <(printf '%s\n' "${SLOTS[@]}")

SLOT=$(ui --title "Select a keyslot to re-cost" \
          --menu "Only the chosen slot is changed." 16 74 6 \
          "${SLOT_ITEMS[@]}" 3>&1 1>&2 2>&3) || { clear; exit 0; }

CUR=$(printf '%s\n' "${SLOTS[@]}" | awk -F'\t' -v s="$SLOT" '$1==s')
CUR_KDF=$(echo "$CUR" | cut -f2); CUR_MEM=$(echo "$CUR" | cut -f3)
CUR_ITER=$(echo "$CUR" | cut -f4); CUR_PAR=$(echo "$CUR" | cut -f5)

# ─── Pick new parameters ─────────────────────────────────────────────────────
CHOICE=$(ui --title "New argon2id cost for slot $SLOT" --menu \
"Memory cost is the thing an attacker cannot buy their way around.
argon2id needs its full memory for EVERY guess, so a 24 GB GPU that
would run thousands of guesses at once against a weak KDF gets ~6
against 4 GiB. More memory is strictly stronger. Iterations raise
the price further once memory hits your hardware ceiling." 20 74 5 \
    aggressive "4 GiB x 12  strongest — ~6 guesses at once on a 24 GB GPU" \
    moderate   "2 GiB x  6  strong    — ~12 at once on that same GPU" \
    fast       "1 GiB x  4  still memory-hard — ~24 at once" \
    custom     "set memory / iterations / threads yourself" \
    3>&1 1>&2 2>&3) || { clear; exit 0; }

case "$CHOICE" in
    aggressive) NEW_MEM=$P_AGGRESSIVE_MEM; NEW_ITER=$P_AGGRESSIVE_ITER; NEW_PAR=$P_PARALLEL ;;
    moderate)   NEW_MEM=$P_MODERATE_MEM;   NEW_ITER=$P_MODERATE_ITER;   NEW_PAR=$P_PARALLEL ;;
    fast)       NEW_MEM=$P_FAST_MEM;       NEW_ITER=$P_FAST_ITER;       NEW_PAR=$P_PARALLEL ;;
    custom)
        MIB=$(ui --title "Memory cost" --inputbox \
            "Memory in MiB (cryptsetup wants KiB; this converts for you).\n\nCurrent: $(human_mem "$CUR_MEM")" \
            12 70 "$((CUR_MEM / 1024))" 3>&1 1>&2 2>&3) || { clear; exit 0; }
        NEW_ITER=$(ui --title "Iteration cost" --inputbox \
            "Iterations (argon2id 'time cost').\n\nCurrent: $CUR_ITER" \
            12 70 "$CUR_ITER" 3>&1 1>&2 2>&3) || { clear; exit 0; }
        NEW_PAR=$(ui --title "Parallelism" --inputbox \
            "Threads (lanes).\n\nCurrent: $CUR_PAR" \
            12 70 "$CUR_PAR" 3>&1 1>&2 2>&3) || { clear; exit 0; }
        case "$MIB"      in ''|*[!0-9]*) die "Memory must be a whole number of MiB." ;; esac
        case "$NEW_ITER" in ''|*[!0-9]*) die "Iterations must be a whole number." ;; esac
        case "$NEW_PAR"  in ''|*[!0-9]*) die "Threads must be a whole number." ;; esac
        NEW_MEM=$((MIB * 1024))
        ;;
esac

# ─── Refuse accidentally-weak parameters ─────────────────────────────────────
if [ "$NEW_MEM" -lt "$FLOOR_MEM_KIB" ] || [ "$NEW_ITER" -lt "$FLOOR_ITER" ]; then
    ui --title "Below the safety floor" --yesno \
"$(human_mem "$NEW_MEM") / $NEW_ITER iterations is below this tool's floor of
$(human_mem "$FLOOR_MEM_KIB") / $FLOOR_ITER iterations.

A slip like 1048 where you meant 1048576 lands here, and would
leave the keyslot far cheaper to attack than it looks.

Proceed anyway?" 16 70 || { clear; exit 0; }
fi

# ─── Confirm ─────────────────────────────────────────────────────────────────
UUID=$("$CRYPTSETUP" luksUUID "$DEV")
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/root/luks-header-${UUID}-${STAMP}.bin"

# Estimate what the new cost means as unlock latency on THIS machine, by
# calibrating against cryptsetup's own benchmark. It reports how many
# iterations fit in ~2000 ms, and CLAMPS the memory it will benchmark to what
# it can allocate right now — so above that clamp this is scaled from a
# smaller measurement, not measured outright.
kdf_estimate() {   # $1 = mem KiB, $2 = iterations, $3 = threads
    local out bi bm
    out=$("$CRYPTSETUP" benchmark --pbkdf argon2id --pbkdf-memory "$1" \
              --pbkdf-parallel "$3" 2>/dev/null | grep -m1 argon2id) || return 1
    bi=$(echo "$out" | awk '{print $2}'); bm=$(echo "$out" | awk '{print $4}')
    case "$bi" in ''|*[!0-9]*) return 1;; esac
    case "$bm" in ''|*[!0-9]*) return 1;; esac
    [ "$bi" -gt 0 ] && [ "$bm" -gt 0 ] || return 1
    awk -v ti="$2" -v tm="$1" -v bi="$bi" -v bm="$bm" \
        'BEGIN{ printf "%.1f s", 2.0 * (ti*tm) / (bi*bm) }'
}

EST_CUR=$(kdf_estimate "$CUR_MEM" "$CUR_ITER" "$CUR_PAR" || echo "?")
EST_NEW=$(kdf_estimate "$NEW_MEM" "$NEW_ITER" "$NEW_PAR" || echo "?")

# What the cost is actually FOR. Attacker model, stated in the UI so the
# figure can be checked rather than taken on faith: 1000 top-end GPUs, each
# with 24 GiB of VRAM, each running as many concurrent guesses as this memory
# cost leaves room for, each guess costing the same work measured above.
# The KDF sets the price per guess; the passphrase sets how many guesses.
crack_years() {   # $1 = mem KiB, $2 = seconds per guess, $3 = passphrase bits
    awk -v mem="$1" -v t="$2" -v bits="$3" 'BEGIN{
        if (t <= 0 || mem <= 0) { print "?"; exit }
        vram = 24 * 1024 * 1024                       # KiB of VRAM per GPU
        lanes = int(vram / mem); if (lanes < 1) lanes = 1
        rate  = 1000 * lanes / t                      # guesses per second, whole fleet
        yrs   = (2 ^ (bits - 1)) / rate / 31557600    # half the keyspace, in years
        e = log(yrs) / log(10)
        printf "%d", int(e + 0.5)
    }'
}

# Anchor an exponent to something a person can picture. Keyed off the computed
# exponent, not the profile, so it stays true whatever parameters are chosen.
# The universe is ~1.4e10 years old; the later marks follow the standard
# stelliferous / degenerate / black-hole era sequence.
cosmic() {   # $1 = base-10 exponent of the crack time in years
    if   [ "$1" -lt 10 ]; then echo "less than the age of the universe"
    elif [ "$1" -lt 14 ]; then echo "long past the age of the universe"
    elif [ "$1" -lt 18 ]; then echo "every star has burned out"
    elif [ "$1" -lt 22 ]; then echo "galaxies have evaporated"
    elif [ "$1" -lt 31 ]; then echo "protons may have decayed"
    else                       echo "only black holes remain"
    fi
}

EST_NEW_S=$(printf '%s' "$EST_NEW" | tr -dc '0-9.')
[ -n "$EST_NEW_S" ] || EST_NEW_S=0
strength_row() {   # $1 = label, $2 = passphrase bits
    local e; e=$(crack_years "$NEW_MEM" "$EST_NEW_S" "$2")
    case "$e" in ''|*[!0-9-]*) printf '  %-22s %s\n' "$1" "(not estimated)"; return;; esac
    printf '  %-22s 10^%-4s %s\n' "$1" "$e" "$(cosmic "$e")"
}
STRENGTH=$(
  strength_row "6 words   (77 bit)"  77
  strength_row "8 words  (103 bit)"  103
  strength_row "10 words (129 bit)"  129
)

CONFIRM="$(printf 'Device : %s\nUUID   : %s\nSlot   : %s' "$DEV" "$UUID" "$SLOT")

$(
  printf '  %-12s %-14s %s\n' '' 'now' 'after'
  printf '  %-12s %-14s %s\n' 'KDF'        "$CUR_KDF"                 'argon2id'
  printf '  %-12s %-14s %s\n' 'memory'     "$(human_mem "$CUR_MEM")"  "$(human_mem "$NEW_MEM")"
  printf '  %-12s %-14s %s\n' 'iterations' "$CUR_ITER"                "$NEW_ITER"
  printf '  %-12s %-14s %s\n' 'threads'    "$CUR_PAR"                 "$NEW_PAR"
  printf '  %-12s %-14s %s\n' 'unlock'     "~$EST_CUR"                "~$EST_NEW"
)

What that buys, against 1000 GPUs with 24 GiB each, all guessing
(years to search half the keyspace, and what has happened by then):

$STRENGTH

The universe is about 10^10 years old. Those numbers come from the
memory cost and your passphrase together — the KDF sets the price
of one guess, the passphrase sets how many guesses are needed. A
short or reused passphrase collapses the whole table; no KDF cost
can rescue it.

Unlock times are estimated on THIS machine and shift with load. At
boot the machine is idle, so real unlocks land at the fast end.

The header is backed up first to:
  $BACKUP

cryptsetup will prompt for the passphrase of slot $SLOT on the
terminal. This script never sees it.

Only this keyslot changes. Your passphrase does not change and no
filesystem data is touched."

if [ "$DRY_RUN" -eq 1 ]; then
    ui --title "Dry run — nothing will be changed" --msgbox \
"$CONFIRM

Command that would run:

  cryptsetup luksConvertKey -S $SLOT --pbkdf argon2id \\
    --pbkdf-memory $NEW_MEM --pbkdf-force-iterations $NEW_ITER \\
    --pbkdf-parallel $NEW_PAR $DEV" 30 76 || true
    clear; exit 0
fi

ui --title "Confirm" --yesno "$CONFIRM" 28 76 || { clear; exit 0; }

# ─── Back up the header, then convert ────────────────────────────────────────
clear
umask 077
if ! "$CRYPTSETUP" luksHeaderBackup "$DEV" --header-backup-file "$BACKUP"; then
    echo "Header backup FAILED — refusing to modify the keyslot." >&2
    exit 1
fi
echo "Header backed up to $BACKUP"
echo ""
echo "Re-costing slot $SLOT on $DEV to $(human_mem "$NEW_MEM") / $NEW_ITER iterations."
echo "cryptsetup will now ask for the passphrase that opens slot $SLOT."
echo ""

if "$CRYPTSETUP" luksConvertKey -S "$SLOT" --pbkdf argon2id \
        --pbkdf-memory "$NEW_MEM" --pbkdf-force-iterations "$NEW_ITER" \
        --pbkdf-parallel "$NEW_PAR" "$DEV"; then
    RESULT=$(slot_table "$DEV" | render_slots)
    ui --title "Done — $DEV" --msgbox \
"$RESULT

Header backup kept at:
  $BACKUP

Keep it until a successful boot confirms the new parameters, then
delete it — it wraps your key under the OLD, cheaper cost." 20 76 || true
    clear
else
    echo ""
    echo "luksConvertKey FAILED. The keyslot is unchanged."
    echo "Header backup: $BACKUP"
    exit 1
fi
