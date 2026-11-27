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
# cli-smoke-test.sh — the command-line surface of every script, checked
# WITHOUT root and without touching a device.
#
# What it proves:
#   1. --help works for every script: exit 0, prints its usage, needs no root,
#      and leaves nothing behind (no log file, no directory)
#   2. an option a script does not know is REFUSED with a non-zero exit. For
#      the two installers this is the point: "install.sh --help", or a mistyped
#      --uninstall, used to fall through to a full install
#   3. run without root, every script stops with a one-line message, and
#      luks-deploy.sh does it before opening a log or printing recovery advice
#
# Run as an ordinary user:  bash tests/cli-smoke-test.sh
# (As root the "needs root" checks are skipped; nothing else changes.)
# ============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# The scripts are run from a copy, so a stray file one of them writes next to
# itself shows up as a difference instead of landing in the working tree.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/asahilocker-cli-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cp -a "$REPO/bin" "$REPO/boot-guards" "$REPO/extras" "$WORK/"
before=$(cd "$WORK" && find . | sort)

# script | a string its --help must print
HELP=(
  "bin/luks-deploy.sh|--defaults"
  "bin/luks-mount.sh|chroot ROOT"
  "bin/luks-tune.sh|--dry-run"
  "bin/ram-rescue.sh|build [--arm]"
  "bin/post-encryption-setup.sh|--keep-splash-off"
  "bin/save-luks-recovery-bundle.sh|--no-boot-refresh"
  "boot-guards/install.sh|--uninstall"
  "extras/install.sh|--uninstall"
  "extras/kbd-backlight/install.sh|--uninstall"
  "extras/boot-tripwire/install.sh|--uninstall"
  "extras/boot-tripwire/asahilocker-boot-tripwire|verify DIR"
  "boot-guards/bin/uboot-efivar.py|prune-stale"
)

echo "== 1. --help: exit 0, usage printed, nothing written =="
for row in "${HELP[@]}"; do
    s="${row%%|*}"; want="${row#*|}"
    out=$("$WORK/$s" --help 2>&1 </dev/null); rc=$?
    if [ "$rc" -eq 0 ] && grep -qF -- "$want" <<< "$out"; then pass "$s --help"
    else fail "$s --help (exit $rc; wanted '$want' in the output)"; fi
done

echo "== 2. an unknown option is refused =="
for row in "${HELP[@]}"; do
    s="${row%%|*}"
    case "$s" in bin/luks-mount.sh|bin/ram-rescue.sh) sub=(mount --no-such-option) ;; *) sub=(--no-such-option) ;; esac
    case "$s" in bin/ram-rescue.sh) sub=(build --no-such-option) ;; esac
    "$WORK/$s" "${sub[@]}" >/dev/null 2>&1 </dev/null; rc=$?
    if [ "$rc" -ne 0 ]; then pass "$s ${sub[*]} refused (exit $rc)"
    else fail "$s ${sub[*]} was ACCEPTED (exit 0)"; fi
done

echo "== 3. without root: one line, no log, no recovery advice =="
if [ "$(id -u)" -eq 0 ]; then
    echo "  (skipped: running as root)"
else
    out=$("$WORK/bin/luks-deploy.sh" 2>&1 </dev/null); rc=$?
    if [ "$rc" -ne 0 ] && [ "$(wc -l <<< "$out")" -eq 1 ] && grep -q 'Must run as root' <<< "$out"; then
        pass "luks-deploy.sh without root: one line, exit $rc"
    else
        fail "luks-deploy.sh without root printed $(wc -l <<< "$out") lines (exit $rc)"
    fi
    for s in bin/luks-mount.sh bin/ram-rescue.sh; do
        out=$("$WORK/$s" status 2>&1 </dev/null); rc=$?
        if [ "$rc" -ne 0 ] && grep -qi 'sudo' <<< "$out"; then pass "$s status without root asks for sudo"
        else fail "$s status without root (exit $rc): $out"; fi
    done
    for s in bin/post-encryption-setup.sh bin/save-luks-recovery-bundle.sh boot-guards/install.sh extras/install.sh extras/kbd-backlight/install.sh extras/boot-tripwire/install.sh; do
        out=$("$WORK/$s" 2>&1 </dev/null); rc=$?
        if [ "$rc" -ne 0 ] && grep -qi 'root' <<< "$out"; then pass "$s without root asks for root"
        else fail "$s without root (exit $rc): $out"; fi
    done
fi

after=$(cd "$WORK" && find . -name __pycache__ -prune -o -print | sort)
if [ "$before" = "$after" ]; then pass "no script left a file behind"
else fail "files appeared next to the scripts:"; diff <(echo "$before") <(echo "$after") | sed 's/^/        /'; fi

echo
echo "cli-smoke-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
