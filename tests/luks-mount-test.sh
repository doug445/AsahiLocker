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
# luks-mount-test.sh — bin/luks-mount.sh against a throwaway partitioned loop
# image laid out like an Asahi install: EFI (vfat), /boot (ext4), root (btrfs
# with root and home subvolumes and an /etc/fstab naming the other two by
# UUID). No real disk is touched; safe to run in CI.
#
# What it proves:
#   1. list reports the install and its state
#   2. mount takes /boot and /boot/efi from the install's own fstab and mounts
#      them PARENT FIRST, in a UTF-8 locale too. (Sorted in the caller's
#      locale, "/boot/efi" came before "/boot", the EFI mount failed for want
#      of its mountpoint, and nothing said so.)
#   3. mount --ro is read-only all the way down
#   4. a directory is one place however it is spelled: mounted by a relative
#      path, unmounted by an absolute one with a trailing slash, and nothing
#      is left mounted, unlocked or on record
#   5. umount refuses a mountpoint luks-mount.sh did not mount
#   6. the same for an ENCRYPTED root: unlocked for the mount, locked again by
#      umount  (needs python3, to type the passphrase on a pty)
#
# Run as root:  sudo bash tests/luks-mount-test.sh
# Requires: util-linux, gdisk, dosfstools, e2fsprogs, btrfs-progs, cryptsetup.
# ============================================================================
set -uo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
for c in losetup sgdisk partprobe lsblk blkid findmnt mkfs.vfat mkfs.ext4 mkfs.btrfs btrfs cryptsetup; do
    command -v "$c" >/dev/null || { echo "missing tool: $c"; exit 1; }
done

LM="$(cd "$(dirname "$0")/.." && pwd)/bin/luks-mount.sh"
[ -x "$LM" ] || { echo "cannot run $LM"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/luks-mount-test.XXXXXX")
LOOP=""; MAPTMP="lmtest-$$"
PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

cleanup() {
    set +e
    cd /
    "$LM" umount "$WORK/t" >/dev/null 2>&1
    umount -R "$WORK/t" 2>/dev/null
    umount "$WORK/m" 2>/dev/null
    cryptsetup close "$MAPTMP" 2>/dev/null
    [ -n "$LOOP" ] && cryptsetup close "am-$(basename "$LOOP")p3" 2>/dev/null
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# The locale the ordering bug needs: one whose collation skips punctuation.
UTF8_LOCALE=$(locale -a 2>/dev/null | grep -iE '^en_US\.utf-?8$' | head -1 || true)
if [ -n "$UTF8_LOCALE" ]; then
    export LC_ALL="$UTF8_LOCALE"
    echo "running in LC_ALL=$LC_ALL"
else
    echo "NOTE: no en_US.UTF-8 locale here; the mount-order check runs, but cannot fail the old way"
fi

# build_install <plain|luks>: (re)make the three partitions. The root's btrfs
# lives straight on p3, or inside a LUKS2 container on it.
PASSPHRASE='Loop-Mount-Test-71'
build_install() {
    local kind="$1" inner uuid
    wipefs -qa "${LOOP}p1" "${LOOP}p2" "${LOOP}p3" 2>/dev/null
    mkfs.vfat "${LOOP}p1" >/dev/null
    mkfs.ext4 -qF "${LOOP}p2"
    if [ "$kind" = luks ]; then
        printf '%s' "$PASSPHRASE" > "$WORK/pass"
        cryptsetup luksFormat --type luks2 --pbkdf argon2id --pbkdf-memory 65536 \
            --pbkdf-parallel 2 --pbkdf-force-iterations 4 --key-file "$WORK/pass" --batch-mode "${LOOP}p3"
        cryptsetup open --key-file "$WORK/pass" "${LOOP}p3" "$MAPTMP"
        inner="/dev/mapper/$MAPTMP"
    else
        inner="${LOOP}p3"
    fi
    mkfs.btrfs -q -f "$inner"
    mount "$inner" "$WORK/m"
    btrfs -q subvolume create "$WORK/m/root"
    btrfs -q subvolume create "$WORK/m/home"
    mkdir -p "$WORK/m/root/etc" "$WORK/m/root/boot" "$WORK/m/root/home"
    echo "home-sentinel" > "$WORK/m/home/file"
    uuid=$(blkid -s UUID -o value "$inner")
    printf 'UUID=%s / btrfs subvol=root 0 0\nUUID=%s /home btrfs subvol=home 0 0\nUUID=%s /boot ext4 defaults 0 0\nUUID=%s /boot/efi vfat umask=0077 0 0\n' \
        "$uuid" "$uuid" "$(blkid -s UUID -o value "${LOOP}p2")" "$(blkid -s UUID -o value "${LOOP}p1")" > "$WORK/m/root/etc/fstab"
    umount "$WORK/m"
    # /boot/efi's mountpoint is a directory on the /boot filesystem, as on a real install
    mount "${LOOP}p2" "$WORK/m"; mkdir -p "$WORK/m/efi"; umount "$WORK/m"
    [ "$kind" = luks ] && cryptsetup close "$MAPTMP"
    udevadm settle 2>/dev/null || true
}
mounted_from() { findmnt -rno SOURCE "$1" 2>/dev/null | sed 's/\[.*//'; }
leftovers() { # nothing mounted under t, no am- mapper, no record
    [ "$(findmnt -R "$WORK/t" 2>/dev/null | wc -l)" -eq 0 ] \
        && ! [ -b "/dev/mapper/am-$(basename "$LOOP")p3" ] \
        && ! compgen -G "/run/asahilocker-mount/*$(basename "$WORK")*" >/dev/null
}

truncate -s 900M "$WORK/disk.img"
LOOP=$(losetup --show -fP "$WORK/disk.img")
sgdisk -n1:0:+64M -t1:EF00 -c1:"EFI - FEDORA" -n2:0:+128M -t2:8300 -c2:boot -n3:0:0 -t3:8300 -c3:root "$LOOP" >/dev/null
partprobe "$LOOP"; udevadm settle 2>/dev/null || true
mkdir -p "$WORK/m" "$WORK/t"
cd "$WORK" || exit 1

echo "== 1. a plain btrfs install: list, mount order, read-only, spelling =="
build_install plain
OUT=$("$LM" list 2>&1)
grep -q "${LOOP}p3 .*btrfs .*not encrypted" <<< "$OUT" && pass "list: ${LOOP}p3 is 'not encrypted'" || fail "list did not report the plain root: $OUT"

OUT=$("$LM" mount --ro "${LOOP}p3" t 2>&1); RC=$?
[ "$RC" -eq 0 ] && pass "mount --ro by a relative path (t)" || fail "mount --ro failed (exit $RC): $OUT"
[ "$(mounted_from "$WORK/t/boot")" = "${LOOP}p2" ] && pass "/boot is the partition the install's fstab names" || fail "/boot is not mounted from ${LOOP}p2"
[ "$(mounted_from "$WORK/t/boot/efi")" = "${LOOP}p1" ] && pass "/boot/efi is mounted, inside /boot (parent first)" \
    || fail "/boot/efi is NOT mounted: $(grep -i 'efi' <<< "$OUT" | head -2 | tr '\n' ' ')"
grep -q home-sentinel "$WORK/t/home/file" 2>/dev/null && pass "/home is the home subvolume" || fail "/home subvolume not mounted"
if touch "$WORK/t/home/x" 2>/dev/null || touch "$WORK/t/boot/x" 2>/dev/null || touch "$WORK/t/x" 2>/dev/null; then
    fail "--ro: something under the mount is writable"
else
    pass "--ro: root, /home and /boot all refuse a write"
fi
# Captured, never piped into grep -q: under pipefail a producer that is still
# writing when grep -q leaves is killed by SIGPIPE and the match reads as a miss.
OUT=$("$LM" status 2>&1)
grep -q "${LOOP}p3 on $WORK/t\$" <<< "$OUT" || grep -q "${LOOP}p3 on $WORK/t " <<< "$OUT" \
    && pass "status records the canonical directory" || fail "status: $(head -1 <<< "$OUT")"

OUT=$("$LM" umount "$WORK/t/" 2>&1); RC=$?
[ "$RC" -eq 0 ] && leftovers && pass "umount by an absolute path with a trailing slash: nothing left behind" \
    || fail "umount $WORK/t/ (exit $RC) left something: $OUT"

echo "== 2. umount leaves other people's mountpoints alone =="
mount -t tmpfs tmpfs "$WORK/t"
OUT=$("$LM" umount "$WORK/t" 2>&1); RC=$?
if [ "$RC" -ne 0 ] && mountpoint -q "$WORK/t"; then pass "a mountpoint luks-mount.sh did not mount is refused, and still mounted"
else fail "umount of a foreign mountpoint: exit $RC, still mounted: $(mountpoint -q "$WORK/t" && echo yes || echo no)"; fi
umount "$WORK/t" 2>/dev/null

echo "== 3. an encrypted install: unlocked for the mount, locked again after =="
if command -v python3 >/dev/null 2>&1; then
    build_install luks
    OUT=$("$LM" list 2>&1)
    grep -q "${LOOP}p3 .*crypto_LUKS .*encrypted" <<< "$OUT" && pass "list: ${LOOP}p3 is 'encrypted'" || fail "list did not report the encrypted root: $OUT"
    # cryptsetup asks for the passphrase on the terminal: answer it on a pty.
    python3 - "$PASSPHRASE" "$LM" mount "${LOOP}p3" "$WORK/t/" > "$WORK/mount.out" 2>&1 <<'PYEOF'
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
buf, sent, deadline = b"", False, time.time() + 120
while time.time() < deadline:
    if not select.select([fd], [], [], 1)[0]:
        continue
    try:
        data = os.read(fd, 65536)
    except OSError:
        break
    if not data:
        break
    buf += data
    if not sent and b"Enter passphrase" in buf:
        time.sleep(0.3); os.write(fd, sys.argv[1].encode() + b"\n"); sent = True
else:
    os.kill(pid, 9)
sys.stdout.write(buf.decode("utf-8", "replace"))
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
PYEOF
    RC=$?
    MAPPER="/dev/mapper/am-$(basename "$LOOP")p3"
    [ "$RC" -eq 0 ] && [ "$(mounted_from "$WORK/t")" = "$MAPPER" ] && pass "mount unlocks the root as $(basename "$MAPPER")" \
        || fail "encrypted mount failed (exit $RC): $(tail -3 "$WORK/mount.out" | tr '\n' ' ')"
    [ "$(mounted_from "$WORK/t/boot/efi")" = "${LOOP}p1" ] && pass "/boot and /boot/efi mounted, parent first" || fail "/boot/efi not mounted on the encrypted install"
    OUT=$("$LM" umount "$WORK/t" 2>&1); RC=$?
    [ "$RC" -eq 0 ] && leftovers && pass "umount (spelled without the slash) unmounts and locks the volume again" \
        || fail "umount left the encrypted install mounted or unlocked (exit $RC): $OUT"
else
    echo "  SKIP: python3 not available to type the passphrase on a pty"
fi

echo ""
echo "==================================================="
echo "  $PASS passed, $FAIL failed"
echo "==================================================="
[ "$FAIL" -eq 0 ]
