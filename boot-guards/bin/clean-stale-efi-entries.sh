#!/bin/sh
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
    /^Boot[0-9A-F]{4}\*/ {
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
