#!/bin/bash
#
# AsahiLocker — read back argon2id probe results written by GRUB's save_env.
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
set -euo pipefail
# Run under sudo and $HOME is root's, so the build tree is not where this would
# otherwise look. Resolve the invoking user's home instead.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    REAL_HOME="$HOME"
fi
EDITENV="${GRUB_PREFIX:-$REAL_HOME/Projects/grub-argon2-build/install-root}/bin/grub-editenv"
[ -x "$EDITENV" ] || { echo "FATAL: no grub-editenv at $EDITENV" >&2; exit 1; }
ENVF="${1:-/boot/efi/asahilocker-probe/grubenv}"

[ -f "$ENVF" ] || { echo "no grubenv at $ENVF"; exit 1; }

echo "== raw =="
sudo "$EDITENV" "$ENVF" list
echo
echo "== interpretation =="
raw=$(sudo "$EDITENV" "$ENVF" list)

started=$(echo "$raw" | /usr/bin/sed -n 's/^probe_started=//p')
finished=$(echo "$raw" | /usr/bin/sed -n 's/^probe_finished=//p')

if [ "$started" != "yes" ]; then
    echo "The probe never ran, or save_env could not write to this filesystem."
    echo "If the screen showed results but this file is unchanged, save_env is"
    echo "the problem, not the probe -- trust the screen."
    exit 0
fi

ceiling=""
while read -r mib; do
    v=$(echo "$raw" | /usr/bin/sed -n "s/^p_${mib}M=//p")
    printf '  %5s MiB  %s\n' "$mib" "${v:-<unset>}"
    [ "$v" = "OK" ] && ceiling="$mib"
done < "$(dirname "$ENVF")/MANIFEST.txt"

echo
if [ "$finished" != "yes" ]; then
    echo "INCOMPLETE: probe_finished=no. It stopped part way -- the first size"
    echo "after the last OK is where it hung. That is a finding: the allocation"
    echo "is not failing cleanly."
elif [ -n "$ceiling" ]; then
    echo "Highest argon2id memory cost GRUB could allocate: ${ceiling} MiB"
else
    echo "Nothing succeeded -- argon2 is not usable under U-Boot at all."
    echo "Capture the on-screen error text; that distinguishes 'out of memory'"
    echo "from 'unknown KDF'."
fi
