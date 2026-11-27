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
# boot-guards-test.sh — boot-guards/install.sh and the ESP stub guard, under a
# real systemd, against a vfat "EFI partition" on a loop device.
#
# What it proves:
#   1. installing over a 3.1.0-era guard (the 60-second timer, enabled and
#      running) removes the timer and leaves the path unit watching
#   2. an overwrite of the stub, written the way grub2-mkconfig writes it, is
#      undone within seconds, and the overwritten copy is kept
#   3. a write to another file in the stub's directory changes nothing
#   4. running install.sh again changes nothing that matters and the guard
#      still works: re-running it is how a machine set up by an older release
#      gets the new guards
#   5. --uninstall removes everything, and an overwrite then stays overwritten
#
# NOT for your Mac: it installs units and scripts into the running system
# and points the stub guard at a throwaway file. It refuses to run unless
# CI=true, as on a CI runner or in a disposable VM:
#     sudo CI=true bash tests/boot-guards-test.sh
# Requires: systemd as PID 1, util-linux (losetup, mount), dosfstools.
# ============================================================================
set -uo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
if [ "${CI:-}" != true ]; then
    echo "Refusing: this test installs the boot guards into the running system and"
    echo "points them at a throwaway file. Run it in CI or a disposable VM, with CI=true."
    exit 1
fi
[ -d /run/systemd/system ] || { echo "needs systemd as PID 1"; exit 1; }
command -v mkfs.vfat >/dev/null || { echo "missing tool: mkfs.vfat (dosfstools)"; exit 1; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
UNITS=/etc/systemd/system
PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/asahilocker-guards-test.XXXXXX")
ESPDIR="$WORK/esp"
STUB="$ESPDIR/EFI/fedora/grub.cfg"
cleanup() {
    set +e
    bash "$REPO/boot-guards/install.sh" --uninstall >/dev/null 2>&1
    umount "$ESPDIR" 2>/dev/null
    rm -rf "$WORK" /root/grub-esp-stub.cfg.known-good /root/grub-esp-stub.sha512
}
trap cleanup EXIT

# ─── A vfat EFI partition laid out like Asahi's ─────────────────────────────
truncate -s 64M "$WORK/esp.img"
mkfs.vfat -F 32 "$WORK/esp.img" >/dev/null
mkdir -p "$ESPDIR"
mount -o loop,umask=0077,shortname=winnt "$WORK/esp.img" "$ESPDIR"
mkdir -p "$ESPDIR/EFI/fedora"
cat > "$STUB" <<'EOF'
search --no-floppy --root-dev-only --fs-uuid --set=dev 725fee20-48b3-48c2-ba73-5c165384aa8c
set prefix=($dev)/grub2
export $prefix
configfile $prefix/grub.cfg
EOF
GOOD=$(sha512sum "$STUB" | cut -d' ' -f1)
export ESP_GRUB_CFG="$STUB"

# Overwrite the stub as grub2-mkconfig does (truncate, write, close), then
# wait up to 5 s for the guard to put the known-good one back.
overwrite_and_wait() {
    { cat "$STUB"; echo "### a full generated grub.cfg would follow ###"; } > "$WORK/full.cfg"
    cat "$WORK/full.cfg" > "$STUB"
    for _ in $(seq 1 50); do
        [ "$(sha512sum "$STUB" | cut -d' ' -f1)" = "$GOOD" ] && return 0
        sleep 0.1
    done
    return 1
}
broken_count() { find "$ESPDIR/EFI/fedora" -name 'grub.cfg.broken.*' | wc -l; }

echo "== 1. installing over a 3.1.0-era guard =="
# The two units 3.1.0 installed, as it installed them.
cat > "$UNITS/esp-grub-stub-guard.service" <<'EOF'
[Unit]
Description=Restore ESP grub.cfg stub if altered
ConditionPathExists=/boot/efi/EFI/fedora/grub.cfg

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/restore-esp-grub-stub.sh
EOF
cat > "$UNITS/esp-grub-stub-guard.timer" <<'EOF'
[Unit]
Description=Periodically check ESP grub.cfg integrity (guards against stray grub2-mkconfig)

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=esp-grub-stub-guard.service

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now esp-grub-stub-guard.timer >/dev/null 2>&1
if systemctl is-active -q esp-grub-stub-guard.timer; then pass "3.1.0 timer active before the upgrade"
else fail "could not start the 3.1.0 timer"; fi

out=$(bash "$REPO/boot-guards/install.sh" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "install.sh exit 0"; else fail "install.sh exit $rc: $out"; fi
if [ ! -e "$UNITS/esp-grub-stub-guard.timer" ] && ! systemctl is-active -q esp-grub-stub-guard.timer; then
    pass "the timer is gone"
else
    fail "the timer survived the upgrade"
fi
if systemctl is-active -q esp-grub-stub-guard.path; then pass "path unit active"
else fail "path unit not active"; fi
if systemctl is-enabled -q esp-grub-stub-guard.path && systemctl is-enabled -q esp-grub-stub-guard.service; then
    pass "path unit and boot-time service enabled"
else
    fail "path unit or service not enabled"
fi
if grep -qx "PathChanged=${STUB%/*}" "$UNITS/esp-grub-stub-guard.path.d/esp-path.conf" 2>/dev/null; then
    pass "path unit watches the stub's directory"
else
    fail "path drop-in: $(cat "$UNITS/esp-grub-stub-guard.path.d/esp-path.conf" 2>&1)"
fi
if [ "$(cut -d' ' -f1 /root/grub-esp-stub.sha512 2>/dev/null)" = "$GOOD" ]; then pass "baseline = the stub"
else fail "baseline does not match the stub"; fi

echo "== 2. an overwrite is undone =="
if overwrite_and_wait; then pass "stub restored after an overwrite"; else fail "stub NOT restored within 5 s"; fi
if [ "$(broken_count)" -eq 1 ]; then pass "overwritten copy kept as grub.cfg.broken.*"
else fail "$(broken_count) .broken copies, wanted 1"; fi

echo "== 3. another file in the directory =="
before=$(broken_count)
head -c 4096 /dev/urandom > "$ESPDIR/EFI/fedora/shimaa64.efi"
sleep 1
if [ "$(sha512sum "$STUB" | cut -d' ' -f1)" = "$GOOD" ] && [ "$(broken_count)" -eq "$before" ]; then
    pass "a write to shimaa64.efi changed nothing"
else
    fail "a write to another file disturbed the stub or its copies"
fi
if [ "$(systemctl show -p Result --value esp-grub-stub-guard.service)" = success ]; then
    pass "guard service result: success"
else
    fail "guard service result: $(systemctl show -p Result --value esp-grub-stub-guard.service)"
fi

echo "== 4. running install.sh again =="
out=$(bash "$REPO/boot-guards/install.sh" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "second install.sh exit 0"; else fail "second install.sh exit $rc: $out"; fi
if systemctl is-active -q esp-grub-stub-guard.path && [ ! -e "$UNITS/esp-grub-stub-guard.timer" ]; then
    pass "same state after the re-run"
else
    fail "state changed after the re-run"
fi
sleep 1
if overwrite_and_wait; then pass "guard still restores after the re-run"; else fail "guard dead after the re-run"; fi

echo "== 5. --uninstall =="
out=$(bash "$REPO/boot-guards/install.sh" --uninstall 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "--uninstall exit 0"; else fail "--uninstall exit $rc: $out"; fi
left=$(ls -d "$UNITS"/esp-grub-stub-guard* "$UNITS"/clean-stale-efi-entries.service \
          /usr/local/sbin/restore-esp-grub-stub.sh /usr/local/sbin/uboot-efivar.py 2>/dev/null)
if [ -z "$left" ]; then pass "nothing left installed"; else fail "left behind: $left"; fi
cat "$WORK/full.cfg" > "$STUB"
sleep 2
if [ "$(sha512sum "$STUB" | cut -d' ' -f1)" != "$GOOD" ]; then pass "after --uninstall, nothing restores the stub"
else fail "something still restored the stub after --uninstall"; fi

echo
echo "boot-guards-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
