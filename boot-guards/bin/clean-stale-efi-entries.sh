#!/bin/sh
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
# clean-stale-efi-entries.sh — delete EFI boot entries whose GPT partition
# GUID is not present on any currently-attached disk. U-Boot on Asahi
# auto-registers entries for every shim.efi it discovers on removable media
# (old USB installers, etc); they persist in its runtime varstore and
# produce "can't find boot XXXX" errors on the U-Boot screen after the
# device is unplugged. Running this once per boot cleans them up.
#
# Safe: only touches entries that encode a GPT,<uuid> device path. Entries
# using VenHw paths (auto NVMe/USB enumeration) or absolute file paths
# without a partition GUID are left alone.
set -eu
[ -d /sys/firmware/efi/efivars ] || exit 0

efibootmgr -v 2>/dev/null | awk '
    # \*? — inactive (un-starred) entries are just as stale when their GPT
    # partition is gone, so consider both. Header lines (BootOrder:,
    # BootCurrent:, Timeout:) cannot match the 4-hex-char class.
    /^Boot[0-9A-F]{4}\*?[[:space:]]/ {
        entry=$1; sub(/\*$/,"",entry); sub(/^Boot/,"",entry)
        for (i=1; i<=NF; i++) {
            if (match($i, /GPT,[0-9a-f-]{36}/)) {
                print entry, substr($i, RSTART+4, 36)
                next
            }
        }
    }' | while read -r entry guid; do
    if ! blkid -t PARTUUID="$guid" >/dev/null 2>&1; then
        if efibootmgr -b "$entry" -B >/dev/null 2>&1; then
            logger -t clean-stale-efi "deleted Boot$entry (partition $guid not attached)"
        fi
    fi
done
