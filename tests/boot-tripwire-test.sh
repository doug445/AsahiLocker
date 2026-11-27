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
# boot-tripwire-test.sh — extras/boot-tripwire/asahilocker-boot-tripwire on a
# throwaway directory tree laid out like /boot with its EFI partition.
#
# What it proves:
#   1. the first check takes the record; an unchanged tree raises nothing
#   2. what changes at every boot by design (GRUB's grubenv, U-Boot's
#      ubootefi.var, macOS's dot-folders on the EFI partition, lost+found)
#      raises nothing
#   3. a changed initramfs, an added EFI binary, a removed boot entry and a
#      retargeted symlink are each reported, by path
#   4. the alert stays, across checks, until it is accepted; accept clears it
#      and records anew
#   5. verify, the live-USB check, compares an install mounted elsewhere with
#      its record: 0 when they match, 2 and the path when they do not
#
# Touches nothing outside its own temporary directory. Root only because the
# tool insists on it for record, check, accept and verify.
# Run as root:  sudo bash tests/boot-tripwire-test.sh
# ============================================================================
set -uo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
TOOL="$(cd "$(dirname "$0")/.." && pwd)/extras/boot-tripwire/asahilocker-boot-tripwire"
[ -x "$TOOL" ] || { echo "cannot run $TOOL"; exit 1; }
PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

W=$(mktemp -d "${TMPDIR:-/tmp}/asahilocker-tripwire-test.XXXXXX")
trap 'rm -rf "$W"' EXIT
B="$W/boot"
mkdir -p "$B/loader/entries" "$B/grub2" "$B/lost+found" "$B/dtb-a" "$B/dtb-b" \
         "$B/efi/EFI/fedora" "$B/efi/m1n1" "$B/efi/.fseventsd"
for f in vmlinuz-7.3 initramfs-7.3.img loader/entries/fedora-7.3.conf grub2/grub.cfg \
         grub2/grubenv lost+found/junk dtb-a/t8103-j313.dtb dtb-b/t8103-j313.dtb \
         efi/EFI/fedora/grub.cfg efi/EFI/fedora/grubaa64.efi efi/m1n1/boot.bin \
         efi/ubootefi.var efi/.fseventsd/fseventsd-uuid; do
    echo "original $f" > "$B/$f"
done
ln -s dtb-a "$B/dtb"
export TRIPWIRE_STATE="$W/state" TRIPWIRE_ROOTS="$B"
ALERT="$W/state/ALERT"

echo "== 1. first record, then an unchanged tree =="
"$TOOL" check >/dev/null 2>&1
if [ -s "$W/state/record" ]; then pass "first check took the record ($(wc -l < "$W/state/record") lines)"
else fail "no record after the first check"; fi
"$TOOL" check >/dev/null 2>&1
if [ ! -e "$ALERT" ]; then pass "unchanged tree: no alert"; else fail "unchanged tree raised: $(cat "$ALERT")"; fi

echo "== 2. what changes at every boot raises nothing =="
for f in grub2/grubenv efi/ubootefi.var efi/.fseventsd/fseventsd-uuid lost+found/junk; do
    echo "rewritten at boot" > "$B/$f"
done
echo "new" > "$B/efi/ubootefi.var.bak-20261127-070000"
"$TOOL" check >/dev/null 2>&1
if [ ! -e "$ALERT" ]; then pass "grubenv, ubootefi.var, .fseventsd, lost+found: no alert"
else fail "an excluded file raised: $(cat "$ALERT")"; fi

echo "== 3. tampering is reported, by path =="
echo "implant" >> "$B/initramfs-7.3.img"
echo "sniffer" > "$B/efi/EFI/fedora/evil.efi"
rm -f "$B/loader/entries/fedora-7.3.conf"
ln -sfn dtb-b "$B/dtb"
"$TOOL" check >/dev/null 2>&1
for want in "changed  $B/initramfs-7.3.img" "added    $B/efi/EFI/fedora/evil.efi" \
            "removed  $B/loader/entries/fedora-7.3.conf" "changed  $B/dtb"; do
    if grep -qF -- "$want" "$ALERT" 2>/dev/null; then pass "reported: ${want%% *} ${want##*/}"
    else fail "not reported: $want"; fi
done
if [ "$(grep -c '^    ' "$ALERT" 2>/dev/null)" -eq 4 ]; then pass "exactly four changes reported"
else fail "$(grep -c '^    ' "$ALERT" 2>/dev/null) changes reported, wanted 4"; fi

echo "== 4. the alert stays until accepted =="
"$TOOL" status >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then pass "status exits 1 while an alert waits"; else fail "status exit $rc with an alert"; fi
"$TOOL" check >/dev/null 2>&1
if [ "$(grep -c 'changed while this' "$ALERT")" -eq 2 ]; then pass "a second boot adds to the alert, it does not replace it"
else fail "alert after a second check: $(cat "$ALERT")"; fi
"$TOOL" accept >/dev/null 2>&1
if [ ! -e "$ALERT" ]; then pass "accept clears the alert"; else fail "alert still there after accept"; fi
"$TOOL" check >/dev/null 2>&1
if [ ! -e "$ALERT" ]; then pass "after accept the current state is the record"; else fail "alert after accept: $(cat "$ALERT")"; fi
"$TOOL" status >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "status exits 0 with no alert"; else fail "status exit $rc with no alert"; fi

echo "== 5. verify: an install mounted elsewhere =="
I="$W/inst"
mkdir -p "$I/var/lib/asahilocker/boot-tripwire"
cp -a "$B" "$I/boot"
# The record as the install itself would have taken it: paths from its own /.
TRIPWIRE_STATE="$W/inst-state" TRIPWIRE_ROOTS="$I/boot" "$TOOL" record
sed "s|	$I/|	/|" "$W/inst-state/record" > "$I/var/lib/asahilocker/boot-tripwire/record"
out=$(TRIPWIRE_ROOTS="$I/boot" "$TOOL" verify "$I" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q '^MATCH' <<< "$out"; then pass "verify: untouched install matches (exit 0)"
else fail "verify on an untouched install: exit $rc: $out"; fi
echo "implant" >> "$I/boot/vmlinuz-7.3"
out=$(TRIPWIRE_ROOTS="$I/boot" "$TOOL" verify "$I" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grep -qF "changed  /boot/vmlinuz-7.3" <<< "$out"; then pass "verify: changed kernel reported by its own path (exit 2)"
else fail "verify after a change: exit $rc: $out"; fi
cp "$I/var/lib/asahilocker/boot-tripwire/record" "$W/kept-off-the-machine"
: > "$I/var/lib/asahilocker/boot-tripwire/record"
out=$(TRIPWIRE_ROOTS="$I/boot" "$TOOL" verify "$I" "$W/kept-off-the-machine" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "verify against a copy kept off the machine"
else fail "verify against a kept copy: exit $rc: $out"; fi

echo
echo "boot-tripwire-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
