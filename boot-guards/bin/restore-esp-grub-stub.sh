#!/bin/sh
# restore-esp-grub-stub.sh — keep the ESP grub.cfg stub pinned to a known-good copy.
#
# WHY THIS EXISTS (Fedora Asahi specific):
#   /boot/efi/EFI/fedora/grub.cfg on Asahi is a tiny 4-line *stub* that searches
#   for the /boot filesystem by UUID and chainloads the real grub.cfg from
#   /boot/grub2/grub.cfg. A stray `grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg`
#   — which plenty of guides and some packaging hooks still tell you to run —
#   overwrites that stub with a FULL generated config. On an encrypted root the
#   full config in the ESP does not know how to cryptomount, and the box drops to
#   a GRUB rescue prompt on the next boot.
#
#   This guard hashes the stub and restores it from a known-good reference if it
#   drifts. Idempotent; runs at boot and every 60s via esp-grub-stub-guard.timer.
#
# The reference copy and its hash are generated PER MACHINE by boot-guards/install.sh
# (the stub embeds your own /boot filesystem UUID, so it cannot be shipped).
#   REF  = /root/grub-esp-stub.cfg.known-good
#   HASH = /root/grub-esp-stub.sha512
#
# If you legitimately change the stub (e.g. after encrypting /boot, or after
# reinstalling GRUB), re-baseline it:
#     sudo /usr/local/sbin/esp-grub-stub-rebaseline
set -eu

ESP=${ESP_GRUB_CFG:-/boot/efi/EFI/fedora/grub.cfg}
REF=${ESP_GRUB_REF:-/root/grub-esp-stub.cfg.known-good}
HASHFILE=${ESP_GRUB_HASH:-/root/grub-esp-stub.sha512}

[ -f "$ESP" ]      || { echo "ESP grub.cfg missing: $ESP" >&2; exit 1; }
[ -f "$REF" ]      || { echo "reference file missing: $REF (run boot-guards/install.sh)" >&2; exit 1; }
[ -f "$HASHFILE" ] || { echo "hash file missing: $HASHFILE (run boot-guards/install.sh)" >&2; exit 1; }

KNOWN=$(awk '{print $1; exit}' "$HASHFILE")
[ -n "$KNOWN" ] || { echo "empty hash in $HASHFILE" >&2; exit 1; }

cur=$(sha512sum "$ESP" | awk '{print $1}')
[ "$cur" = "$KNOWN" ] && exit 0

ts=$(date +%Y%m%d-%H%M%S)
cp -a "$ESP" "${ESP}.broken.${ts}"
cp -a "$REF" "$ESP"
sync
logger -t esp-grub-stub-guard \
    "restored ESP grub.cfg from $REF (drifted copy saved as ${ESP}.broken.${ts}, was sha=$cur)"
