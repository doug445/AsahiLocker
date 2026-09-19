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
# registers an entry for every shim.efi it discovers on removable media
# (old USB installers, etc); they linger after the device is unplugged and
# produce "can't find boot XXXX" errors on the U-Boot screen at every boot.
#
# WHERE THE ENTRIES LIVE (this is the part everyone gets wrong on a Mac):
# U-Boot keeps its non-volatile EFI variables in ONE FILE on the EFI System
# Partition, ubootefi.var (lib/efi_loader/efi_var_file.c), read at boot and
# written back only by U-Boot's own boot-time code. A delete from Linux —
# `efibootmgr -B` through efivarfs — reaches U-Boot's in-memory runtime copy
# only (lib/efi_loader/efi_variable.c, efi_set_variable_runtime; Kconfig
# EFI_RT_VOLATILE_STORE: "The OS will be responsible for syncing the RAM
# contents to the file, otherwise any changes made during runtime won't
# persist reboots"). So the old efibootmgr-only version of this guard
# "deleted" the same entries at every boot and they came back at every boot.
#
# On a U-Boot host the file is edited directly (uboot-efivar.py: parse,
# drop the entry, fix BootOrder, recompute the CRC, replace atomically, keep
# the previous file beside it) — that is what persists. efibootmgr is still
# run afterwards so the running system's view agrees. On real UEFI firmware
# (no ubootefi.var) efibootmgr is the persistent store and is all that runs.
#
# Safe: only entries that encode a GPT,<uuid> device path are considered.
# Entries using VenHw paths (auto NVMe/USB enumeration) or file paths without
# a partition GUID are left alone.
set -eu
[ -d /sys/firmware/efi/efivars ] || exit 0

VARTOOL=${UBOOT_EFIVAR:-/usr/local/sbin/uboot-efivar.py}
VARFILE=""
for esp in /boot/efi /efi /boot; do
    [ -f "$esp/ubootefi.var" ] && { VARFILE="$esp/ubootefi.var"; break; }
done

if [ -n "$VARFILE" ] && [ -x "$VARTOOL" ]; then
    # U-Boot host: the file is the store. Report what is stale, then prune it.
    stale=$("$VARTOOL" --file "$VARFILE" stale 2>/dev/null || true)
    if [ -n "$stale" ]; then
        if out=$("$VARTOOL" --file "$VARFILE" prune-stale 2>&1); then
            logger -t clean-stale-efi "ubootefi.var: $out"
        else
            logger -t clean-stale-efi "ubootefi.var: could not prune ($out) — entries left as they are"
        fi
    fi
elif [ -n "$VARFILE" ]; then
    logger -t clean-stale-efi "U-Boot variable file $VARFILE present but $VARTOOL is missing — a runtime efibootmgr delete does not persist here"
fi

# The running system's copy (real UEFI: the only store; U-Boot: the in-memory
# copy, so efibootmgr agrees with the file until the next boot).
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
            logger -t clean-stale-efi "deleted Boot$entry (partition $guid not attached)${VARFILE:+ — from the running copy; the file was handled above}"
        fi
    fi
done
