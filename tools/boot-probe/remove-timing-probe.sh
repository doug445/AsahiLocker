#!/bin/bash
#
# AsahiLocker — remove the argon2id TIMING probe from the internal ESP.
# Counterpart to remove-probe-internal.sh; strips only the timing block, so the
# allocation probe entry (if still staged) is left alone.
set -euo pipefail

CUSTOM=/boot/grub2/custom.cfg
PAYLOAD=/boot/efi/asahilocker-timing

echo "== menu entry =="
if sudo /usr/bin/grep -q 'BEGIN AsahiLocker argon2id timing probe' "$CUSTOM" 2>/dev/null; then
    if [ "$(sudo /usr/bin/grep -c '^menuentry' "$CUSTOM")" -eq 1 ]; then
        sudo /usr/bin/rm -f "$CUSTOM"
        echo "   $CUSTOM removed (it held only the timing entry)"
    else
        sudo /usr/bin/sed -i '/### BEGIN AsahiLocker argon2id timing probe/,/### END AsahiLocker argon2id timing probe/d' "$CUSTOM"
        echo "   timing block stripped from $CUSTOM (other entries kept)"
    fi
else
    echo "   no timing entry found (already clean)"
fi

echo "== payload =="
if [ -d "$PAYLOAD" ]; then
    sudo /usr/bin/rm -rf "$PAYLOAD"
    sync
    echo "   $PAYLOAD removed"
else
    echo "   no payload found (already clean)"
fi

echo
echo "grub.cfg was never modified, so there is nothing to restore."
/usr/bin/df -h /boot/efi | /usr/bin/tail -1
