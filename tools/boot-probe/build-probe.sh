#!/bin/bash
#
# AsahiLocker — argon2id allocation probe for GRUB under U-Boot on Apple Silicon
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# Measures how much memory argon2id can actually get INSIDE GRUB. GRUB's
# luks2.c passes the memory cost straight through with no clamp, so the ceiling
# is purely whether the EFI allocation succeeds -- and under U-Boot on Apple
# Silicon nobody has measured it.
#
# Touches no real volume. The containers are throwaway files holding nothing.
#
# ---------------------------------------------------------------------------
# v2 (2026-08-23) — restructured after the first run dropped to a bare GRUB
# 2.14 prompt with probe_started=no. Two defects, both fatal:
#
#   1. The whole probe lived in the image's EMBEDDED config. That is executed
#      by grub_load_config() BEFORE the `normal` module takes over, so it is
#      parsed by the RESCUE parser, which supports simple commands only -- no
#      `if`/`then`/`else`, which every measurement depended on.
#   2. When the embedded config fell through, `normal` loaded, found no
#      grub.cfg at $prefix, CLEARED THE SCREEN and gave a prompt -- destroying
#      any output that had made it out.
#
# Now: the embedded config only pins the ESP by UUID and sets $prefix. The real
# script is deployed as grub.cfg on the ESP and executed by `normal` with the
# full parser. It reports on screen as the primary channel (save_env to the FAT
# grubenv is secondary, since U-Boot's EFI block-write path is unproven), and
# ends with a long interruptible sleep so the screen is never wiped.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

GRUB_PREFIX="${GRUB_PREFIX:-$HOME/Projects/grub-argon2-build/install-root}"
MKIMAGE="$GRUB_PREFIX/bin/grub-mkimage"
EDITENV="$GRUB_PREFIX/bin/grub-editenv"
SCRIPTCHECK="$GRUB_PREFIX/bin/grub-script-check"
MODDIR="$GRUB_PREFIX/lib/grub/arm64-efi"
DIRNAME="asahilocker-probe"
PASS="grubtest"
ITER=4                       # low on purpose: we are measuring memory, not strength

# 1 GiB is the known GRUB ceiling (confirmed in practice on Manjaro / Linux Mint
# / Fedora x86). The open question is whether it holds under U-Boot's EFI on
# Apple Silicon. 512 is the fallback data point if 1024 fails; 2048 is ordered
# LAST so that, ceiling or not, it cannot affect the results already on screen.
#   NEVER probe 4096: 1024*memory_blocks overflows u32 at exactly 4 GiB in
#   kdf.c argon2_init -> xtrymalloc(0).
SIZES_MIB=(512 1024 2048)

TARGET="${1:-/boot/efi}"
[ -x "$MKIMAGE" ] || { echo "FATAL: no grub-mkimage at $MKIMAGE"; exit 1; }
[ -d "$TARGET" ]  || { echo "FATAL: target $TARGET is not a directory"; exit 1; }

# ── pin the target filesystem by UUID ───────────────────────────────────────
# A `search -f` by filename is ambiguous: the recovery USB's ESP carries an
# identical payload, so the probe could latch onto either device and write its
# results somewhere we would never look.
ESP_DEV="$(/usr/bin/findmnt -n -o SOURCE --target "$TARGET")"
ESP_UUID="$(sudo /usr/sbin/blkid -s UUID -o value "$ESP_DEV")"
[ -n "$ESP_UUID" ] || { echo "FATAL: could not read UUID of $ESP_DEV"; exit 1; }

echo "== target: $TARGET/$DIRNAME  (dev $ESP_DEV, uuid $ESP_UUID) =="
/usr/bin/rm -rf staging && /usr/bin/mkdir -p staging

# ── containers ──────────────────────────────────────────────────────────────
: > staging/MANIFEST.txt
for mib in "${SIZES_MIB[@]}"; do
    img="staging/argon2id-${mib}M.img"
    echo "-- container: ${mib} MiB argon2id"
    /usr/bin/truncate -s 24M "$img"
    printf '%s' "$PASS" | cryptsetup luksFormat --type luks2 \
        --pbkdf argon2id --pbkdf-memory "$((mib * 1024))" \
        --pbkdf-force-iterations "$ITER" --pbkdf-parallel 4 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
        --batch-mode "$img" -
    echo "${mib}" >> staging/MANIFEST.txt
done

# ── pre-allocated env block for the results ─────────────────────────────────
# save_env writes by blocklist into an EXISTING file; it cannot create one.
"$EDITENV" staging/grubenv create
for mib in "${SIZES_MIB[@]}"; do "$EDITENV" staging/grubenv set "p_${mib}M=nottried"; done
"$EDITENV" staging/grubenv set probe_started=no probe_finished=no

VARS=""
for mib in "${SIZES_MIB[@]}"; do VARS="$VARS p_${mib}M"; done
VARS="probe_started probe_finished$VARS"

# ── embedded config: rescue-parser safe, simple commands ONLY ───────────────
# No control flow here. This runs before `normal` is up.
{
  echo "search --no-floppy --fs-uuid --set=root $ESP_UUID"
  echo "set prefix=(\$root)/$DIRNAME"
} > staging/embedded.cfg

# ── the real probe, executed by `normal` from $prefix/grub.cfg ──────────────
{
  echo "set timeout=0"
  echo 'echo "=============================================="'
  echo 'echo " AsahiLocker argon2id allocation probe"'
  echo 'echo "=============================================="'
  echo 'echo "GRUB $grub_version"'
  echo 'echo "root=$root  prefix=$prefix"'
  echo 'echo ""'
  echo "set envf=(\$root)/$DIRNAME/grubenv"
  echo "set probe_started=yes"
  # Whether GRUB can write the FAT grubenv under U-Boot's EFI block layer is
  # itself unknown, so record the answer instead of depending on it.
  echo "if save_env -f \$envf $VARS ; then set envwrite=OK ; else set envwrite=FAILED ; fi"
  echo 'echo "grubenv writable: $envwrite"'
  echo 'echo ""'
  i=0
  for mib in "${SIZES_MIB[@]}"; do
      i=$((i+1))
      echo "echo -n \"  ${mib} MiB argon2id ... \""
      echo "if loopback lo$i (\$root)/$DIRNAME/argon2id-${mib}M.img ; then"
      echo "  if cryptomount -p $PASS (lo$i) ; then set p_${mib}M=OK ; else set p_${mib}M=FAIL ; fi"
      echo "else"
      echo "  set p_${mib}M=NOLOOP"
      echo "fi"
      echo "echo \"\$p_${mib}M\""
      # saved after EVERY step, so a hang still leaves the results so far on disk
      echo "save_env -f \$envf $VARS"
  done
  echo "set probe_finished=yes"
  echo "save_env -f \$envf $VARS"
  echo 'echo ""'
  echo 'echo "=============================================="'
  RESULTLINE=""
  for mib in "${SIZES_MIB[@]}"; do RESULTLINE="$RESULTLINE ${mib}M=\$p_${mib}M"; done
  echo "echo \"RESULTS:$RESULTLINE  envwrite=\$envwrite\""
  echo 'echo "=============================================="'
  echo 'echo ""'
  echo 'echo ">>> PHOTOGRAPH THIS SCREEN NOW <<<"'
  echo 'echo ">>> then type:  reboot"'
  echo 'echo ""'
  # `normal` clears the screen the moment this script returns. Hold it.
  echo 'sleep --verbose --interruptible 900'
} > staging/grub.cfg

"$SCRIPTCHECK" staging/embedded.cfg || { echo "FATAL: bad embedded config"; exit 1; }
"$SCRIPTCHECK" staging/grub.cfg     || { echo "FATAL: bad grub.cfg"; exit 1; }

"$MKIMAGE" --directory "$MODDIR" --prefix "/$DIRNAME" \
    --output staging/grub-argon2-probe.efi --format arm64-efi \
    --config staging/embedded.cfg \
    part_gpt part_msdos fat ext2 loopback cryptodisk luks luks2 argon2 pbkdf2 \
    gcry_rijndael gcry_sha256 gcry_sha512 gcry_crc afsplitter json loadenv \
    search search_fs_file search_fs_uuid normal echo test sleep minicmd \
    terminal configfile halt reboot ls cat help chain

# ── deploy ──────────────────────────────────────────────────────────────────
sudo /usr/bin/rm -rf "${TARGET:?}/$DIRNAME"
sudo /usr/bin/mkdir -p "$TARGET/$DIRNAME"
sudo /usr/bin/cp staging/argon2id-*.img staging/MANIFEST.txt staging/grub.cfg \
                 staging/grubenv staging/grub-argon2-probe.efi "$TARGET/$DIRNAME/"
sync
echo
echo "== deployed =="
sudo ls -la "$TARGET/$DIRNAME/"
/usr/bin/df -h "$TARGET" | /usr/bin/tail -1
