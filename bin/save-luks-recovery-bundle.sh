#!/usr/bin/env bash
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
# save-luks-recovery-bundle.sh
# ============================================================================
# Assembles a CLEARLY LABELED LUKS recovery bundle on the MAIN DRIVE, so you
# don't need a 2nd USB during luks-deploy. Copy the bundle to secure OFFLINE
# storage afterwards (it currently lives ON the encrypted drive — fine as
# staging, not as your only copy).
#
# Destination defaults to /root; override with LUKS_BUNDLE_DIR=/some/path.
#
# Run on the booted, encrypted system:   sudo ./save-luks-recovery-bundle.sh
# (Also callable right after luks-deploy from the live USB — it auto-detects a
#  target mounted at /mnt and writes under /mnt instead.)
#
# Absolute paths throughout (immune to the user's cp/rm/find/… aliases).
# ============================================================================
set -uo pipefail
CRYPTSETUP=/usr/sbin/cryptsetup; [ -x "$CRYPTSETUP" ] || CRYPTSETUP=/usr/bin/cryptsetup
LSBLK=/usr/bin/lsblk; BLKID=/usr/sbin/blkid; [ -x "$BLKID" ] || BLKID=/usr/bin/blkid
CP=/usr/bin/cp; MKDIR=/usr/bin/mkdir; CHMOD=/usr/bin/chmod; GREP=/usr/bin/grep
DATE=/usr/bin/date; HOSTN=/usr/bin/hostname; SYNC=/usr/bin/sync
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
ok(){ echo -e "  ${G}✅${N} $*"; }; warn(){ echo -e "  ${Y}⚠️ ${N} $*"; }; err(){ echo -e "  ${R}❌${N} $*"; }
[ "$(id -u)" -eq 0 ] || { err "run as root (sudo)"; exit 1; }

# --- Determine the mapper name + where the target root lives ----------------
# Default fedora_crypt; LUKS_MAPPER_NAME overrides; if neither exists, fall
# back to whatever /dev/mapper/* device backs "/" (covers custom names set
# via LUKS_MAPPER_NAME at deploy time).
MAPPER_NAME="${LUKS_MAPPER_NAME:-fedora_crypt}"
if [ ! -e "/dev/mapper/$MAPPER_NAME" ]; then
  ROOT_SRC=$(/usr/bin/findmnt -no SOURCE / 2>/dev/null | /usr/bin/sed 's/\[.*//')
  case "$ROOT_SRC" in
    /dev/mapper/*) MAPPER_NAME=${ROOT_SRC#/dev/mapper/} ;;
  esac
fi
PREFIX=""
MAPPER=""
if [ -e "/dev/mapper/$MAPPER_NAME" ] && /usr/bin/findmnt -no SOURCE / 2>/dev/null | "$GREP" -q "$MAPPER_NAME"; then
  PREFIX=""; MAPPER="/dev/mapper/$MAPPER_NAME"        # booted encrypted system
elif [ -e "/dev/mapper/$MAPPER_NAME" ] && /usr/bin/findmnt -no SOURCE /mnt 2>/dev/null | "$GREP" -q "$MAPPER_NAME"; then
  PREFIX="/mnt"; MAPPER="/dev/mapper/$MAPPER_NAME"    # live USB, target mounted at /mnt
else
  err "no active /dev/mapper/$MAPPER_NAME found — is the box encrypted & mounted?"; exit 1
fi

# --- Resolve the RAW backing device + LUKS UUID -----------------------------
RAW=$("$CRYPTSETUP" status "$MAPPER_NAME" 2>/dev/null | "$GREP" -oE '/dev/[a-z0-9]+' | "$GREP" -vi mapper | /usr/bin/head -1)
if [ -z "$RAW" ]; then
  # Fallback: resolve the crypttab UUID to a real device path (a bare
  # "UUID=xxxx" string is NOT usable as a device argument to cryptsetup/blkid)
  CT_UUID=$("$GREP" -E '^\s*'"$MAPPER_NAME"'' "$PREFIX/etc/crypttab" 2>/dev/null \
      | "$GREP" -oE 'UUID=[0-9a-fA-F-]+' | /usr/bin/head -1 | /usr/bin/sed 's/^UUID=//')
  [ -n "$CT_UUID" ] && RAW=$(/usr/bin/readlink -f "/dev/disk/by-uuid/$CT_UUID" 2>/dev/null || true)
fi
[ -n "$RAW" ] && [ -b "$RAW" ] || { err "cannot determine the raw LUKS backing device"; exit 1; }
LUKS_UUID=$("$CRYPTSETUP" luksUUID "$RAW" 2>/dev/null || true)
[ -n "$LUKS_UUID" ] || LUKS_UUID=$("$BLKID" -s UUID -o value "$RAW" 2>/dev/null || echo unknown)
BTRFS_UUID=$("$BLKID" -s UUID -o value "$MAPPER" 2>/dev/null || echo unknown)
HOST=$("$HOSTN" 2>/dev/null || echo host)
STAMP=$("$DATE" +%Y%m%d-%H%M%S)

# --- Create the labeled bundle dir on the MAIN drive ------------------------
BUNDLE_BASE="${LUKS_BUNDLE_DIR:-/root}"
DEST="$PREFIX${BUNDLE_BASE}/LUKS-RECOVERY-${HOST}-${STAMP}"
"$MKDIR" -p "$DEST"; "$CHMOD" 0700 "$DEST"
ok "bundle dir: $DEST"
echo "  device=$RAW  luks-uuid=$LUKS_UUID  btrfs-uuid=$BTRFS_UUID"

# --- 1. The LUKS header (fresh authoritative backup) ------------------------
if "$CRYPTSETUP" luksHeaderBackup "$RAW" --header-backup-file "$DEST/luks-header-${HOST}.img" 2>/dev/null; then
  "$CHMOD" 0400 "$DEST/luks-header-${HOST}.img"; ok "LUKS header backed up (fresh luksHeaderBackup)"
else
  err "luksHeaderBackup failed on $RAW"
fi
# emergency copy that luks-deploy wrote to /boot (unencrypted p5)
if [ -f "$PREFIX/boot/luks-header-backup.img" ]; then
  "$CP" -f "$PREFIX/boot/luks-header-backup.img" "$DEST/luks-header-from-boot.img"
  "$CHMOD" 0400 "$DEST/luks-header-from-boot.img"; ok "copied /boot emergency header"
fi

# --- 2. System state needed for recovery ------------------------------------
for f in etc/crypttab etc/fstab etc/kernel/cmdline etc/default/grub; do
  [ -f "$PREFIX/$f" ] && "$CP" -f "$PREFIX/$f" "$DEST/$(echo "$f" | /usr/bin/tr / _)" 2>/dev/null && ok "saved /$f" || true
done
"$LSBLK" -o NAME,FSTYPE,LABEL,PARTLABEL,SIZE,UUID > "$DEST/lsblk.txt" 2>/dev/null || true
"$BLKID" > "$DEST/blkid.txt" 2>/dev/null || true
"$MKDIR" -p "$DEST/bls-entries"
"$CP" -f "$PREFIX"/boot/loader/entries/*.conf "$DEST/bls-entries/" 2>/dev/null && ok "saved BLS entries" || true

# --- 3. LABEL / README so it's unmistakable ---------------------------------
cat > "$DEST/README-RECOVERY.txt" <<EOF
================================================================================
  LUKS RECOVERY BUNDLE  —  $HOST  —  $STAMP
================================================================================
This is the LUKS header + system state for the encrypted root of "$HOST".

  Backing device : $RAW
  LUKS UUID      : $LUKS_UUID
  btrfs UUID     : $BTRFS_UUID   (inside the LUKS container)
  Root mapper    : $MAPPER

>>> ACTION REQUIRED: COPY THIS ENTIRE FOLDER TO SECURE OFFLINE STORAGE. <<<
It currently sits ON the encrypted drive it protects — good as staging, useless
as your only copy if this drive dies. Put a copy on an encrypted USB / another box.

SENSITIVITY: the header contains key SLOTS, not your key. It cannot decrypt data
without your passphrase, but still store it somewhere private.

--------------------------------------------------------------------------------
RECOVERY — if the system won't boot (from a Fedora Asahi live USB):
--------------------------------------------------------------------------------
  # If the header on-disk is corrupt, restore it:
  cryptsetup luksHeaderRestore $RAW --header-backup-file luks-header-${HOST}.img

  # Unlock + mount + chroot to repair boot config:
  cryptsetup open $RAW $MAPPER_NAME
  mount -o subvol=root /dev/mapper/$MAPPER_NAME /mnt
  mount ${RAW%p*}p5 /mnt/boot            # /boot (ext4) — adjust if layout differs
  mount ${RAW%p*}p4 /mnt/boot/efi        # EFI (vfat)
  for i in dev dev/pts proc sys run; do mount --bind /\$i /mnt/\$i; done
  chroot /mnt /bin/bash
  #   verify: crypttab/_fstab/_kernel_cmdline in this bundle vs live
  #   dracut --regenerate-all --force
  #   grubby --update-kernel=ALL --args="rd.luks.uuid=$LUKS_UUID rd.luks.name=$LUKS_UUID=$MAPPER_NAME"

Files in this bundle:
  luks-header-${HOST}.img    authoritative header (fresh luksHeaderBackup)
  luks-header-from-boot.img  copy luks-deploy left on /boot (should be identical)
  etc_crypttab, etc_fstab, etc_kernel_cmdline, etc_default_grub
  lsblk.txt, blkid.txt, bls-entries/*.conf
================================================================================
EOF
"$CHMOD" 0600 "$DEST/README-RECOVERY.txt"
ok "wrote README-RECOVERY.txt"

"$SYNC"
echo
ok "LUKS recovery bundle complete:"
"$LSBLK" >/dev/null 2>&1
/usr/bin/ls -la "$DEST" | /usr/bin/sed 's/^/    /'
echo -e "  ${Y}Remember to copy $DEST off this machine.${N}"
