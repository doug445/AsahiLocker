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
# multi-install-selection-test.sh — partition-menu behaviour on a disk that
# carries TWO Asahi installs, which is what you get when you encrypt from a
# second minimal install instead of a live USB (docs/SECOND-INSTALL.md).
#
# It builds a sparse, file-backed GPT disk laid out exactly like the real
# thing — two consecutive (EFI, boot, root) triplets, a 200 GiB daily driver
# and a 20 GiB rescue install, both labelled 'fedora' — then drives
# pick_partition() out of bin/luks-deploy.sh against it.
#
# What it proves:
#   1. partitions of the running system are marked IN USE, are never the
#      recommendation, and are refused when typed in by hand
#   2. with both installs idle (the live-USB case) the bigger root wins the
#      'fedora' vs 'fedora' tie
#   3. BOOT and EFI default to the neighbours of the chosen ROOT, so the
#      rescue install's boot partitions are not offered up for the daily
#      driver's root — which would write kernels into the wrong system
#   4. a device-mapper candidate is matched through /dev/mapper/<name>, so an
#      already-encrypted rescue root is recognised as in-use rather than
#      quietly offered back as a target
#
# No real disk is touched; the image is sparse, so the 230 GiB layout costs a
# few MiB. Safe to run in CI.
#
# Run as root:  sudo bash tests/multi-install-selection-test.sh
# Requires: util-linux (losetup, lsblk, blkid, blockdev), gdisk, dosfstools,
#           e2fsprogs, btrfs-progs.
# ============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
for c in losetup sgdisk partprobe lsblk blkid blockdev mkfs.vfat mkfs.ext4 mkfs.btrfs; do
    command -v "$c" >/dev/null || { echo "missing tool: $c"; exit 1; }
done

SRC="$(cd "$(dirname "$0")/.." && pwd)/bin/luks-deploy.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/luks-multi-install-test.XXXXXX")
IMG="$WORK/disk.img"
LOOP=""
PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

cleanup() {
    set +e
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# ─── The disk: main install on p1..p3, rescue install on p4..p6 ─────────────
truncate -s 230G "$IMG"                    # sparse — costs almost nothing
LOOP=$(losetup --show -fP "$IMG")
sgdisk -n1:0:+32M  -c1:"EFI - FEDORA" -t1:EF00 \
       -n2:0:+64M  -c2:"boot"         -t2:8300 \
       -n3:0:+200G -c3:"root"         -t3:8300 \
       -n4:0:+32M  -c4:"EFI - FEDORA" -t4:EF00 \
       -n5:0:+64M  -c5:"boot"         -t5:8300 \
       -n6:0:+20G  -c6:"root"         -t6:8300 \
       "$LOOP" >/dev/null
partprobe "$LOOP"; udevadm settle
mkfs.vfat  -n "EFI-MAIN"        "${LOOP}p1" >/dev/null
mkfs.ext4  -qF -L "fedora_boot" "${LOOP}p2"
mkfs.btrfs -qf -L "fedora"      "${LOOP}p3"
mkfs.vfat  -n "EFI-RESC"        "${LOOP}p4" >/dev/null
mkfs.ext4  -qF -L "fedora_boot" "${LOOP}p5"
mkfs.btrfs -qf -L "fedora"      "${LOOP}p6"
udevadm settle

# ─── Harness: the real functions, a stubbed environment ─────────────────────
# These are read by the pick_partition() source pulled in below, not by
# anything shellcheck can see from here.
# shellcheck disable=SC2034
RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
log() { :; }; warn() { :; }; err() { echo "[ERROR] $*" >&2; }
fatal() { err "$@"; exit 1; }

# pick_partition() skips loop devices by design — a live USB's own loopback
# mounts are never targets. The simulated disk IS a loop device, so that one
# line is dropped here; everything else is the shipped code, verbatim.
eval "$(sed -n '/^partition_number() {/,/^}$/p' "$SRC")"
eval "$(sed -n '/^pick_partition() {/,/^}$/p' "$SRC" | grep -v 'grep -q "\^loop" && continue')"

# ...and keep the host's own disks out of the menus, so the assertions below
# describe the simulated layout and nothing else.
lsblk() {
    if [ "${1:-}" = "-P" ]; then command lsblk "$@" | grep "${LOOP#/dev/}"
    else command lsblk "$@"; fi
}

# ENV_KIND and RUNNING_ROOT_DISK are read by the sourced pick_partition(), so
# no assignment to them looks "used" from here. One setter keeps that fact --
# and the directive stating it -- in a single place, instead of one directive
# per case that the next case added would quietly go without.
# shellcheck disable=SC2034
set_env() { ENV_KIND="$1"; RUNNING_ROOT_DISK="$2"; }

# The one function pick_partition() takes from the outer script. The real one
# walks /proc/mounts and dm slaves; here the answer is dictated per case.
is_running_dev() {
    # The real one stores already-resolved paths; normalise both sides here so
    # a case can list a device by any of its names.
    local d seen
    d=$(readlink -f "$1" 2>/dev/null || echo "$1")
    for seen in ${RUNNING_DEVS[@]+"${RUNNING_DEVS[@]}"}; do
        [ "$(readlink -f "$seen" 2>/dev/null || echo "$seen")" = "$d" ] && return 0
    done
    return 1
}

pick()  { printf '%s\n' "${2:-}" | pick_partition $1 2>/dev/null; }
# Captured, not piped: `set -o pipefail` plus a `grep -q` that exits on the
# first match would report the producer's SIGPIPE as a pipeline failure.
# The order matters and is deliberate: stderr (the menu) goes to the caller,
# stdout (the chosen device) is discarded.
# shellcheck disable=SC2069,SC2086
menu()  { printf '\n' | pick_partition $1 2>&1 >/dev/null; }
menu_has() { grep -q "$2" <<<"$1"; }

ROOT_ARGS='ROOT btrfs|crypto_LUKS fedora|root'

echo "=== 1. booted from the rescue install (p4/p5/p6) ==="
RUNNING_DEVS=("${LOOP}p4" "${LOOP}p5" "${LOOP}p6")
set_env installed "${LOOP#/dev/}"

R=$(pick "$ROOT_ARGS")
[ "$R" = "${LOOP}p3" ] && pass "ROOT defaults to the other install ($R)" \
                       || fail "ROOT defaulted to $R, wanted ${LOOP}p3"
M=$(menu "$ROOT_ARGS")
menu_has "$M" "${LOOP}p6.*IN USE" \
    && pass "the running root is marked IN USE" || fail "running root not marked IN USE"
menu_has "$M" "${LOOP}p6.*recommended" \
    && fail "the running root was recommended" || pass "the running root is never recommended"

B=$(pick "BOOT ext4 boot $R")
[ "$B" = "${LOOP}p2" ] && pass "BOOT defaults to the chosen root's neighbour ($B)" \
                       || fail "BOOT defaulted to $B, wanted ${LOOP}p2"
E=$(pick "EFI vfat efi|fedor $R")
[ "$E" = "${LOOP}p1" ] && pass "EFI defaults to the chosen root's neighbour ($E)" \
                       || fail "EFI defaulted to $E, wanted ${LOOP}p1"

# Typing the in-use device by hand must be refused, not accepted.
OUT=$(printf '%s\n%s\n' "${LOOP}p6" "${LOOP}p3" | pick_partition $ROOT_ARGS 2>&1 >/dev/null || true)
SEL=$(printf '%s\n%s\n' "${LOOP}p6" "${LOOP}p3" | pick_partition $ROOT_ARGS 2>/dev/null || true)
grep -q "part of the system you are booted from" <<<"$OUT" \
    && [ "$SEL" = "${LOOP}p3" ] \
    && pass "a hand-typed in-use device is refused and re-prompted" \
    || fail "hand-typed in-use device was not refused (got '$SEL')"

echo ""
echo "=== 2. booted from a live USB, both installs idle ==="
RUNNING_DEVS=(); set_env live sdz
R2=$(pick "$ROOT_ARGS")
[ "$R2" = "${LOOP}p3" ] && pass "the bigger root wins the 'fedora' vs 'fedora' tie ($R2)" \
                        || fail "ROOT defaulted to $R2, wanted the 200G ${LOOP}p3"
E2=$(pick "EFI vfat efi|fedor $R2")
[ "$E2" = "${LOOP}p1" ] && pass "EFI follows the chosen root, not the other install ($E2)" \
                        || fail "EFI defaulted to $E2, wanted ${LOOP}p1"

echo ""
echo "=== 3. booted from the main install, rescue idle (the reverse) ==="
RUNNING_DEVS=("${LOOP}p1" "${LOOP}p2" "${LOOP}p3")
set_env installed "${LOOP#/dev/}"
R3=$(pick "$ROOT_ARGS")
[ "$R3" = "${LOOP}p6" ] && pass "ROOT defaults to the rescue install ($R3)" \
                        || fail "ROOT defaulted to $R3, wanted ${LOOP}p6"
E3=$(pick "EFI vfat efi|fedor $R3")
[ "$E3" = "${LOOP}p4" ] && pass "EFI follows it ($E3)" \
                        || fail "EFI defaulted to $E3, wanted ${LOOP}p4"

echo ""
echo "=== 4. a device-mapper candidate resolves through /dev/mapper ==="
# lsblk names a dm device by its dm name and there is no /dev/<dmname> node,
# so a naive /dev/$NAME never matches the in-use list. Stand up a linear
# mapping over p6 and check the menu matches it by its real path.
if command -v dmsetup >/dev/null; then
    DM="luks-multi-install-test-$$"
    SECTORS=$(blockdev --getsz "${LOOP}p6")
    if dmsetup create "$DM" --table "0 $SECTORS linear ${LOOP}p6 0" 2>/dev/null; then
        udevadm settle
        lsblk() {   # the dm device has no loop name; let it through too
            if [ "${1:-}" = "-P" ]; then command lsblk "$@" | grep -E "${LOOP#/dev/}|$DM"
            else command lsblk "$@"; fi
        }
        RUNNING_DEVS=("/dev/mapper/$DM")
        MDM=$(menu "$ROOT_ARGS")
        menu_has "$MDM" "/dev/mapper/$DM.*IN USE" \
            && pass "the mapper device is matched through /dev/mapper and marked IN USE" \
            || fail "the mapper device was not recognised as in-use"
        dmsetup remove "$DM" 2>/dev/null || true
    else
        echo "  SKIP: cannot create a device-mapper device here"
    fi
else
    echo "  SKIP: dmsetup not available"
fi

echo ""
echo "==================================================="
echo "  $PASS passed, $FAIL failed"
echo "==================================================="
[ "$FAIL" -eq 0 ]
