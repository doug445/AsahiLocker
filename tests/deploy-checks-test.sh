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
# deploy-checks-test.sh — three things luks-deploy.sh decides by itself,
# checked WITHOUT root and without a device:
#
#   1. kdf_default_profile: the KDF profile the menu and --defaults offer.
#      moderate on any Mac with 8 GB of RAM (under 12 GiB reported),
#      aggressive on every other Mac and when the memory cannot be read.
#   2. swap_plain_entries: which swaps the encryption would NOT cover. zram,
#      a mapper that crypttab lists and a swap file on the root filesystem
#      are covered; a swap partition, a swap file on /boot and a mapper that
#      crypttab does not list are reported. *.swap units count as well as the
#      fstab, and a commented-out line does not count.
#   3. typed_confirm: every typed gate word is lower case. The word in
#      capitals means Caps Lock is on: it is answered with a warning and the
#      question is asked again (at most five times); any other answer, Enter
#      alone or closed input is a no.
#
# The functions are the shipped code, pulled out of bin/luks-deploy.sh.
# Run as an ordinary user:  bash tests/deploy-checks-test.sh
# ============================================================================
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)/bin/luks-deploy.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC"; exit 1; }
PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/asahilocker-deploy-checks.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Read by the extracted kdf_default_profile(); assigned outside the function
# body in the script, so it is set here the same way.
eval "$(grep -m1 '^KDF_SMALL_RAM_KIB=' "$SRC")"
eval "$(sed -n '/^kdf_default_profile() {/,/^}$/p' "$SRC")"
eval "$(sed -n '/^swap_plain_entries() {/,/^}$/p' "$SRC")"
eval "$(sed -n '/^typed_confirm() {/,/^}$/p' "$SRC")"
warn() { echo "WARN: $*" >&2; }
for f in kdf_default_profile swap_plain_entries typed_confirm; do
    declare -F "$f" >/dev/null || { echo "could not extract $f() from $SRC"; exit 1; }
done

echo "== 1. the default KDF profile =="
meminfo() { printf 'MemTotal:       %s kB\nMemFree:        1000 kB\n' "$1" > "$WORK/meminfo"; }
expect_profile() {      # expect_profile <want> <what this is>
    local got
    got=$(kdf_default_profile "$WORK/meminfo")
    if [ "$got" = "$1" ]; then pass "$2: $got"; else fail "$2: got '$got', want '$1'"; fi
}
# MemTotal as an 8 GB Asahi Mac reports it (some RAM is reserved), then 16 GB.
meminfo 7863296;   expect_profile moderate   "8 GB (any chip: M1, M2, M3 base models)"
meminfo 12582911;  expect_profile moderate   "just under 12 GiB"
meminfo 12582912;  expect_profile aggressive "12 GiB"
meminfo 16039936;  expect_profile aggressive "16 GB"
meminfo 33554432;  expect_profile aggressive "32 GB"
printf 'garbage\n' > "$WORK/meminfo"; expect_profile aggressive "unreadable meminfo"
got=$(kdf_default_profile "$WORK/no-such-meminfo")
if [ "$got" = aggressive ]; then pass "no meminfo at all: aggressive"
else fail "no meminfo at all: got '$got', want aggressive"; fi

echo "== 2. swap the encryption would not cover =="
ROOT_UUID=89cb3d63-1111-4222-8333-444455556666
BOOT_UUID=725fee20-48b3-48c2-ba73-5c165384aa8c
UNITS="$WORK/units"; mkdir -p "$UNITS"
# The fstab of a stock Fedora Asahi Remix install, plus whatever a case adds.
fstab() {
    {
        echo "UUID=$ROOT_UUID / btrfs subvol=root,compress=zstd:1 0 0"
        echo "UUID=$BOOT_UUID /boot ext4 defaults 0 0"
        echo "UUID=2FA7-65AB /boot/efi vfat defaults,umask=0077,shortname=winnt 0 0"
        echo "UUID=$ROOT_UUID /home btrfs subvol=home,compress=zstd:1 0 0"
        printf '%s\n' "$@"
    } > "$WORK/fstab"
}
crypttab() { printf '%s\n' "$@" > "$WORK/crypttab"; }
check_swap() {          # check_swap clean|<text the report must contain> <what>
    local out
    out=$(swap_plain_entries "$WORK/fstab" "$WORK/crypttab" "$ROOT_UUID" "$UNITS")
    if [ "$1" = clean ]; then
        if [ -z "$out" ]; then pass "$2: nothing reported"; else fail "$2: reported '$out'"; fi
    elif grep -qF -- "$1" <<< "$out"; then
        pass "$2: reported"
    else
        fail "$2: wanted '$1' in the report, got '${out:-nothing}'"
    fi
}
crypttab "# no entries"
fstab;                                                          check_swap clean "stock install, no swap line"
fstab "/dev/zram0 none swap defaults 0 0";                      check_swap clean "zram in the fstab"
fstab "#UUID=0ff1ce00-aaaa-4bbb-8ccc-ddddeeeeffff none swap defaults 0 0"
check_swap clean "a commented-out swap partition"
fstab "UUID=0ff1ce00-aaaa-4bbb-8ccc-ddddeeeeffff none swap defaults 0 0"
check_swap "a swap partition" "swap partition by UUID"
fstab "PARTUUID=0ff1ce00-aaaa-4bbb-8ccc-ddddeeeeffff none swap sw 0 0"
check_swap "a swap partition" "swap partition by PARTUUID"
fstab "/dev/nvme0n1p7 none swap defaults 0 0";                  check_swap "a swap partition" "swap partition by device name"
fstab "/var/swap/swapfile none swap defaults 0 0";              check_swap clean "swap file on the root filesystem"
fstab "/home/swapfile none swap defaults 0 0";                  check_swap clean "swap file in /home (same btrfs)"
fstab "/boot/swapfile none swap defaults 0 0";                  check_swap "on UUID=$BOOT_UUID" "swap file on /boot (plain ext4)"
fstab "/bootx/swapfile none swap defaults 0 0";                 check_swap clean "swap file in /bootx is on root, not /boot"
fstab "/dev/mapper/cryptswap none swap defaults 0 0"
check_swap "crypttab does not list" "mapper that crypttab does not list"
crypttab "cryptswap PARTUUID=0ff1ce00-aaaa-4bbb-8ccc-ddddeeeeffff /dev/urandom swap,cipher=aes-xts-plain64,size=512"
check_swap clean "random-key encrypted swap listed in crypttab"
# A config-only re-run: the fstab already names the mapper for root.
crypttab "fedora_crypt UUID=11111111-2222-4333-8444-555566667777 none luks,discard"
printf '%s\n' "/dev/mapper/fedora_crypt / btrfs subvol=root 0 0" "/swapfile none swap defaults 0 0" > "$WORK/fstab"
check_swap clean "swap file on an already-encrypted root"
crypttab "# no entries"
fstab
printf '[Swap]\nWhat=/dev/disk/by-partuuid/0ff1ce00-aaaa-4bbb-8ccc-ddddeeeeffff\n' > "$UNITS/dev-disk-by\\x2dpartuuid-0ff1ce00.swap"
check_swap "a swap partition" "swap partition in a systemd .swap unit"
rm -f "$UNITS"/*.swap
got=$(swap_plain_entries "$WORK/no-such-fstab" "$WORK/no-such-crypttab" "$ROOT_UUID")
if [ -z "$got" ]; then pass "no fstab at all: nothing reported, no error"
else fail "no fstab at all: reported '$got'"; fi

echo "== 3. typed confirmations are lower case =="
confirm() {             # confirm <want: 0|1> <what> <input, printf-style>
    local rc warned
    warned=$(printf "$3" | typed_confirm encrypt "" 2>&1 >/dev/null); rc=$?
    if [ "$rc" -eq "$1" ]; then pass "$2 (exit $rc)"; else fail "$2: exit $rc, wanted $1"; fi
    LAST_WARNING=$warned
}
confirm 0 "encrypt"                                   'encrypt\n'
confirm 0 "ENCRYPT, then encrypt: asked again"        'ENCRYPT\nencrypt\n'
if grep -q "Caps Lock is on" <<< "$LAST_WARNING"; then pass "capitals are answered with the Caps Lock warning"
else fail "no Caps Lock warning for capitals: '$LAST_WARNING'"; fi
confirm 1 "ENCRYPT, then the input ends"              'ENCRYPT\n'
confirm 1 "a different word"                          'yes\n'
confirm 1 "Enter alone"                               '\n'
confirm 1 "input already closed"                      ''
confirm 1 "capitals for ever stop after five"         'ENCRYPT\nENCRYPT\nENCRYPT\nENCRYPT\nENCRYPT\nENCRYPT\nencrypt\n'

echo
echo "deploy-checks-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
