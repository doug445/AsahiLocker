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
# loopback-core-test.sh — exercise the encryption core against a throwaway
# file-backed loop device. No real disk is ever touched; safe to run in CI.
#
# What it proves (the exact cryptsetup/btrfs sequence luks-deploy.sh runs,
# with CI-sized argon2id parameters):
#   1. the shrink-idempotency guard (dump-super gap check) fires correctly
#   2. in-place `cryptsetup reencrypt --encrypt` with our flags succeeds
#   3. the result is LUKS2/argon2id, opens, and the inner btrfs (subvols,
#      files) survived intact
#   4. recovery-key enrollment (luksAddKey via key-files) unlocks the volume
#   5. an initialized-but-unfinished reencrypt carries the online-reencrypt
#      flag and finishes with --resume-only  (built with --init-only, so it
#      is deterministic — no race against a live reencrypt)
#   5b. a hard-killed reencrypt demands `cryptsetup repair` before it will
#      resume  (best-effort: the kill is inherently timing-dependent, so
#      unreachable states are reported and skipped, never asserted against)
#   6. btrfs resize max reclaims the container
#
# Run as root:  sudo bash tests/loopback-core-test.sh
# Requires: cryptsetup >= 2.4, btrfs-progs, util-linux (losetup).
# ============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
for c in cryptsetup btrfs losetup blockdev mkfs.btrfs; do
    command -v "$c" >/dev/null || { echo "missing tool: $c"; exit 1; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/luks-loopback-test.XXXXXX")
MAP1="lbtest1-$$"
MAP2="lbtest2-$$"
LOOP1=""; LOOP2=""; LOOP3=""
PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

cleanup() {
    set +e
    umount "$WORK/mnt" 2>/dev/null
    cryptsetup close "$MAP1" 2>/dev/null
    cryptsetup close "$MAP2" 2>/dev/null
    [ -n "$LOOP1" ] && losetup -d "$LOOP1" 2>/dev/null
    [ -n "$LOOP2" ] && losetup -d "$LOOP2" 2>/dev/null
    [ -n "$LOOP3" ] && losetup -d "$LOOP3" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# CI-sized KDF (the point here is the mechanics, not KDF strength)
KDF=(--pbkdf argon2id --pbkdf-memory 65536 --pbkdf-parallel 2 --pbkdf-force-iterations 4)
printf 'loopback-test-passphrase' > "$WORK/pass"; chmod 600 "$WORK/pass"

fs_gap() { # $1 = device; prints (device bytes - btrfs total_bytes)
    local dev_b fs_b
    dev_b=$(blockdev --getsize64 "$1")
    fs_b=$(btrfs inspect-internal dump-super "$1" | awk '/^total_bytes/{print $2; exit}')
    echo $(( dev_b - fs_b ))
}

has_reenc_flag() { # $1 = device; true when the LUKS2 header still requires reencryption
    cryptsetup luksDump "$1" 2>/dev/null | grep -q 'online-reencrypt'
}

mk_shrunk_btrfs() { # $1 = device; fresh btrfs with 32M of slack at the end
    mkfs.btrfs -q -f "$1"
    mount "$1" "$WORK/mnt"
    btrfs -q filesystem resize -32M "$WORK/mnt"
    umount "$WORK/mnt"
}

assert_unlocks() { # $1 = device, $2 = mapper name, $3 = label
    if cryptsetup open --key-file "$WORK/pass" "$1" "$2"; then
        pass "$3 unlocks"
        cryptsetup close "$2" 2>/dev/null || true
    else
        fail "$3 cannot unlock"
    fi
}

echo "== setup: 1200M image, btrfs with root/home subvols + a sentinel file =="
truncate -s 1200M "$WORK/disk1.img"
LOOP1=$(losetup --show -f "$WORK/disk1.img")
mkfs.btrfs -q -f "$LOOP1"
mkdir -p "$WORK/mnt"
mount "$LOOP1" "$WORK/mnt"
btrfs -q subvolume create "$WORK/mnt/root"
btrfs -q subvolume create "$WORK/mnt/home"
mkdir -p "$WORK/mnt/root/etc"
echo "sentinel-fstab-content" > "$WORK/mnt/root/etc/fstab"

echo "== 1. shrink-idempotency guard =="
GAP=$(fs_gap "$LOOP1")
if [ "$GAP" -lt $((32*1024*1024)) ]; then
    pass "fresh fs: gap ${GAP}B < 32M — guard would allow the shrink"
else
    fail "fresh fs already has a ${GAP}B gap (mkfs layout changed?)"
fi
btrfs -q filesystem resize -32M "$WORK/mnt"
umount "$WORK/mnt"
GAP=$(fs_gap "$LOOP1")
if [ "$GAP" -ge $((32*1024*1024)) ]; then
    pass "after shrink: gap ${GAP}B >= 32M — guard would SKIP a re-shrink"
else
    fail "gap ${GAP}B still < 32M after resize -32M"
fi

echo "== 2. in-place reencrypt with luks-deploy's flags =="
cryptsetup reencrypt --encrypt --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 \
    "${KDF[@]}" --hash sha512 \
    --reduce-device-size 32M --resilience checksum \
    --key-file "$WORK/pass" --batch-mode -q "$LOOP1"
pass "reencrypt --encrypt completed"

echo "== 3. header + content survival =="
DUMP=$(cryptsetup luksDump "$LOOP1")
echo "$DUMP" | grep -q 'Version:.*2'        && pass "LUKS2 header"        || fail "not LUKS2"
echo "$DUMP" | grep -q 'argon2id'           && pass "argon2id KDF"        || fail "argon2id missing"
echo "$DUMP" | grep -q 'aes-xts-plain64'    && pass "aes-xts-plain64"     || fail "cipher wrong"
cryptsetup open --key-file "$WORK/pass" "$LOOP1" "$MAP1"
INNER=$(blkid -s TYPE -o value "/dev/mapper/$MAP1")
[ "$INNER" = "btrfs" ] && pass "inner fs is btrfs" || fail "inner fs is '$INNER'"
mount -o subvol=root "/dev/mapper/$MAP1" "$WORK/mnt"
grep -q 'sentinel-fstab-content' "$WORK/mnt/etc/fstab" \
    && pass "subvol=root content intact through encryption" \
    || fail "sentinel file lost/corrupt"
umount "$WORK/mnt"

echo "== 6. btrfs resize max reclaims the container ==" # (while open)
mount "/dev/mapper/$MAP1" "$WORK/mnt"
btrfs -q filesystem resize max "$WORK/mnt"
umount "$WORK/mnt"
pass "resize max ok"

echo "== 4. recovery-key enrollment (luks-deploy's luksAddKey shape) =="
od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$WORK/rk"; chmod 600 "$WORK/rk"
cryptsetup luksAddKey --key-file "$WORK/pass" "$LOOP1" "$WORK/rk" "${KDF[@]}"
cryptsetup close "$MAP1"
cryptsetup open --key-file "$WORK/rk" "$LOOP1" "$MAP1" \
    && pass "recovery key unlocks the volume" \
    || fail "recovery key cannot unlock"
cryptsetup close "$MAP1"

echo "== 5. an unfinished reencrypt carries the resume flag and finishes =="
truncate -s 1200M "$WORK/disk2.img"
LOOP2=$(losetup --show -f "$WORK/disk2.img")
mk_shrunk_btrfs "$LOOP2"
ENCRYPT_ARGS=(--encrypt --type luks2 "${KDF[@]}"
              --reduce-device-size 32M --resilience checksum
              --key-file "$WORK/pass" --batch-mode -q)

# --init-only writes the header and the online-reencrypt requirement without
# moving a byte of data: exactly the on-disk state an interrupted run leaves,
# reached deterministically.  The previous version raced a kill -9 against a
# live reencrypt and then *guessed* what state it had produced — on CI it
# guessed wrong (isLuks said LUKS, `open` said otherwise) and asserted against
# a device it had never successfully built.
cryptsetup reencrypt "${ENCRYPT_ARGS[@]}" --init-only "$LOOP2"
if has_reenc_flag "$LOOP2"; then
    pass "--init-only left the online-reencrypt requirement flag"
else
    fail "--init-only left no online-reencrypt requirement flag"
fi
cryptsetup reencrypt --resume-only --key-file "$WORK/pass" --batch-mode -q "$LOOP2"
if has_reenc_flag "$LOOP2"; then
    fail "flag still present after --resume-only"
else
    pass "--resume-only finished the encryption"
fi
assert_unlocks "$LOOP2" "$MAP2" "resumed volume"

echo "== 5b. a hard-killed reencrypt demands repair before it resumes =="
truncate -s 1200M "$WORK/disk3.img"
LOOP3=$(losetup --show -f "$WORK/disk3.img")
mk_shrunk_btrfs "$LOOP3"
# The repair path is only reachable by killing the *initial* --encrypt run:
# a kill during --resume-only leaves the checksum journal clean and resumes
# without complaint. So this stage keeps the kill, and with it the timing
# dependence — but every state it can land in is now classified by a full
# header parse (luksDump), never by isLuks, and a state we did not manage to
# build is reported instead of asserted against. Test 5 above already covers
# the resume mechanics deterministically, so a skip here costs no coverage.
cryptsetup reencrypt "${ENCRYPT_ARGS[@]}" "$LOOP3" &
RPID=$!
for _ in $(seq 1 200); do
    if has_reenc_flag "$LOOP3"; then
        sleep 0.2          # let some data actually move before pulling the plug
        break
    fi
    if ! kill -0 "$RPID" 2>/dev/null; then break; fi
    sleep 0.05
done
if kill -9 "$RPID" 2>/dev/null; then wait "$RPID" 2>/dev/null || true; fi
sync

if ! cryptsetup luksDump "$LOOP3" >/dev/null 2>&1; then
    # The kill caught cryptsetup before or during the header write. Nothing to
    # assert — but print the evidence, so a failure here explains itself.
    echo "  SKIP: kill left no readable header — repair path not exercised"
    echo "        luksDump: $(cryptsetup luksDump "$LOOP3" 2>&1 | head -1)"
    echo "        isLuks:   $(cryptsetup isLuks "$LOOP3" 2>/dev/null && echo yes || echo no)"
elif has_reenc_flag "$LOOP3"; then
    pass "interrupt left the online-reencrypt requirement flag"
    # A hard kill leaves the reencryption journal dirty: --resume-only refuses
    # with "Device requires reencryption recovery. Run repair first."
    # This mirrors luks-deploy.sh's resume path: repair, then resume.
    if cryptsetup reencrypt --resume-only --key-file "$WORK/pass" --batch-mode -q "$LOOP3" 2>/dev/null; then
        echo "  NOTE: --resume-only succeeded without repair (journal was clean)"
    else
        pass "--resume-only correctly demanded repair after a hard kill"
        cryptsetup repair --key-file "$WORK/pass" --batch-mode -q "$LOOP3"
        pass "cryptsetup repair cleaned the reencryption journal"
        cryptsetup reencrypt --resume-only --key-file "$WORK/pass" --batch-mode -q "$LOOP3"
    fi
    if has_reenc_flag "$LOOP3"; then
        fail "flag still present after repair + --resume-only"
    else
        pass "repair + --resume-only finished the encryption"
    fi
    assert_unlocks "$LOOP3" "$MAP2" "repaired volume"
else
    echo "  SKIP: reencrypt finished before the kill landed — repair path not exercised"
    assert_unlocks "$LOOP3" "$MAP2" "completed volume"
fi

echo ""
echo "==================================================="
echo "  $PASS passed, $FAIL failed"
echo "==================================================="
[ "$FAIL" -eq 0 ]
