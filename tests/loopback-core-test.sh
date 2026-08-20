#!/bin/bash
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
#   5. an interrupted reencrypt carries the online-reencrypt flag and
#      finishes with --resume-only  (skipped gracefully if the reencrypt
#      completes before the interrupt lands — small devices are fast)
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
LOOP1=""; LOOP2=""
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

echo "== 5. interrupted reencrypt carries the resume flag and finishes =="
truncate -s 1200M "$WORK/disk2.img"
LOOP2=$(losetup --show -f "$WORK/disk2.img")
mkfs.btrfs -q -f "$LOOP2"
mount "$LOOP2" "$WORK/mnt"; btrfs -q filesystem resize -32M "$WORK/mnt"; umount "$WORK/mnt"
ENCRYPT_ARGS=(--encrypt --type luks2 "${KDF[@]}"
              --reduce-device-size 32M --resilience checksum
              --key-file "$WORK/pass" --batch-mode -q)
cryptsetup reencrypt "${ENCRYPT_ARGS[@]}" "$LOOP2" &
RPID=$!
# Kill once the header — and with it the online-reencrypt requirement — is on
# disk.  A blind `sleep` is a coin flip on CI: too early and cryptsetup has not
# written a header at all, too late and the whole 1200M is already encrypted.
# Both cases leave nothing to resume, and the too-early one used to reach the
# unlock check below against a device that was never a LUKS device.
for _ in $(seq 1 200); do
    if cryptsetup luksDump "$LOOP2" 2>/dev/null | grep -q 'online-reencrypt'; then
        sleep 0.2          # let some data actually move before pulling the plug
        break
    fi
    if ! kill -0 "$RPID" 2>/dev/null; then break; fi
    sleep 0.05
done
if kill -9 "$RPID" 2>/dev/null; then wait "$RPID" 2>/dev/null || true; fi
sync

if cryptsetup luksDump "$LOOP2" 2>/dev/null | grep -q 'online-reencrypt'; then
    pass "interrupt left the online-reencrypt requirement flag"
    # A hard kill leaves the reencryption journal dirty: --resume-only refuses
    # with "Device requires reencryption recovery. Run repair first."
    # This mirrors luks-deploy.sh's resume path: repair, then resume.
    if ! cryptsetup reencrypt --resume-only --key-file "$WORK/pass" --batch-mode -q "$LOOP2" 2>/dev/null; then
        pass "--resume-only correctly demanded repair after a hard kill"
        cryptsetup repair --key-file "$WORK/pass" --batch-mode -q "$LOOP2"
        pass "cryptsetup repair cleaned the reencryption journal"
        cryptsetup reencrypt --resume-only --key-file "$WORK/pass" --batch-mode -q "$LOOP2"
    fi
    if cryptsetup luksDump "$LOOP2" | grep -q 'online-reencrypt'; then
        fail "flag still present after --resume-only"
    else
        pass "--resume-only finished the encryption"
    fi
elif cryptsetup isLuks "$LOOP2" 2>/dev/null; then
    echo "  SKIP: reencrypt finished before the interrupt landed (fast disk) — resume path not exercised"
else
    echo "  SKIP: interrupt landed before the LUKS header was written — resume path not exercised"
    cryptsetup reencrypt "${ENCRYPT_ARGS[@]}" "$LOOP2"
    pass "reencrypt completed on the retry"
fi
cryptsetup open --key-file "$WORK/pass" "$LOOP2" "$MAP2" \
    && pass "volume unlocks" || fail "volume cannot unlock"
cryptsetup close "$MAP2" 2>/dev/null || true

echo ""
echo "==================================================="
echo "  $PASS passed, $FAIL failed"
echo "==================================================="
[ "$FAIL" -eq 0 ]
