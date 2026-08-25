#!/bin/bash
#
# AsahiLocker — remove the argon2id probe from the INTERNAL ESP.
#
# (An earlier, unpublished remove-probe.sh targeted the live-USB staging route;
# this is the version for the internal ESP staging that the repo documents.)
# The internal route works differently in one important way: it never edited
# grub.cfg at all. Fedora's grub.cfg already sources custom.cfg from $prefix,
# so the menu entry went in a file of its own and removal is deleting that file.
set -euo pipefail

CUSTOM=/boot/grub2/custom.cfg
PAYLOAD=/boot/efi/asahilocker-probe

echo "== menu entry =="
if sudo /usr/bin/grep -q 'BEGIN AsahiLocker argon2id probe' "$CUSTOM" 2>/dev/null; then
    # Only ours is in there; if someone later adds their own entries, strip just
    # the marked block instead of deleting the file.
    if [ "$(sudo /usr/bin/grep -c '^menuentry' "$CUSTOM")" -eq 1 ]; then
        sudo /usr/bin/rm -f "$CUSTOM"
        echo "   $CUSTOM removed"
    else
        sudo /usr/bin/sed -i '/### BEGIN AsahiLocker argon2id probe/,/### END AsahiLocker argon2id probe/d' "$CUSTOM"
        echo "   probe block stripped from $CUSTOM (other entries kept)"
    fi
else
    echo "   no probe entry found (already clean)"
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
