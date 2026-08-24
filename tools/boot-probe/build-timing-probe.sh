#!/bin/bash
#
# AsahiLocker — argon2id UNLOCK LATENCY probe for GRUB under U-Boot
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# The allocation probe (build-probe.sh) answered "can GRUB get the memory?" —
# 512 / 1024 / 2048 MiB all allocated AND decrypted on an M2 Max. It said
# nothing about how LONG that takes, because it deliberately used t=4: it was
# measuring memory, not strength.
#
# That gap matters. GRUB's argon2 is not the kernel's — it is unoptimised, and
# its parallelism lanes are not real threads, so a cost that unlocks in ~2 s
# from the initramfs may take far longer at the GRUB prompt. You pay it at every
# boot, before anything is on screen to explain the wait. If 1 GiB x 10 costs 40
# seconds here, that changes the design rather than the documentation.
#
# Measures the real candidate parameters for an encrypted /boot.
#
# Timed with GRUB's own `time` command, which prints millisecond-resolution
# elapsed time straight to the screen — no video, no stopwatch.
#
# v1 tried `date` and it was useless: U-Boot implements no EFI GetTime runtime
# service, so every bracket printed "can't get datetime using efi". But
# `sleep --verbose` worked in that same run, which proves grub_get_time_ms() is
# fine — and that is precisely the clock commands/time.c uses. `cryptomount` is
# an extcmd; grub_cmd_time passes the found command through to its dispatcher,
# so its options still parse.
#
# The START/END banners are kept as a fallback for a phone video, in case `time`
# ever reports nonsense on some other machine.
#
# There is deliberately NO save_env here. The allocation probe proved that
# save_env returns success on this FAT ESP and writes nothing (verified by
# grepping the raw partition). The screen is the only channel that works.
#
# Touches no real volume. The containers are throwaway files holding nothing.
set -euo pipefail
cd "$(dirname "$0")"

GRUB_PREFIX="${GRUB_PREFIX:-$HOME/Projects/grub-argon2-build/install-root}"
MKIMAGE="$GRUB_PREFIX/bin/grub-mkimage"
SCRIPTCHECK="$GRUB_PREFIX/bin/grub-script-check"
MODDIR="$GRUB_PREFIX/lib/grub/arm64-efi"
DIRNAME="asahilocker-timing"
PASS="grubtest"

# "<memory MiB> <iterations>", measured in this order. The design default for
# /boot goes FIRST, so a hang in a later case still leaves the number that
# actually decides the design on screen.
#
#   1024 x 10  the candidate /boot parameters (docs/BOOT-ENCRYPTION-DESIGN.md)
#   1024 x  4  cross-check: the same cost the allocation probe ran, so GRUB's
#              scaling in iterations can be checked rather than assumed
#   2048 x 10  the stretch option, now that 2 GiB is known to allocate here
#   2048 x 20  THE DECISION. A root keyslot at 4 GiB x 10 is 40 GiB-passes, and
#              4 GiB is unusable in GRUB, so 2 GiB x 20 is the only setting that
#              matches it. If this is tolerable, unlock Option 1 (keyfile) costs
#              nothing; if it is not, Option 1 means accepting a weaker keyslot.
#
# NEVER 4096: 1024*memory_blocks overflows u32 at exactly 4 GiB in kdf.c
# argon2_init -> xtrymalloc(0).
PAIRS=("1024 10" "1024 4" "2048 10" "2048 20")

TARGET="${1:-/boot/efi}"
[ -x "$MKIMAGE" ] || { echo "FATAL: no grub-mkimage at $MKIMAGE"; exit 1; }
[ -d "$TARGET" ]  || { echo "FATAL: target $TARGET is not a directory"; exit 1; }

ESP_DEV="$(/usr/bin/findmnt -n -o SOURCE --target "$TARGET")"
ESP_UUID="$(sudo /usr/sbin/blkid -s UUID -o value "$ESP_DEV")"
[ -n "$ESP_UUID" ] || { echo "FATAL: could not read UUID of $ESP_DEV"; exit 1; }

echo "== target: $TARGET/$DIRNAME  (dev $ESP_DEV, uuid $ESP_UUID) =="
/usr/bin/rm -rf staging-timing && /usr/bin/mkdir -p staging-timing

# ── containers ──────────────────────────────────────────────────────────────
for pair in "${PAIRS[@]}"; do
    read -r mib iter <<< "$pair"
    img="staging-timing/argon2id-${mib}M-t${iter}.img"
    echo "-- container: ${mib} MiB argon2id, t=${iter}"
    /usr/bin/truncate -s 24M "$img"
    printf '%s' "$PASS" | cryptsetup luksFormat --type luks2 \
        --pbkdf argon2id --pbkdf-memory "$((mib * 1024))" \
        --pbkdf-force-iterations "$iter" --pbkdf-parallel 4 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
        --batch-mode "$img" -
done

# ── embedded config: rescue-parser safe, simple commands ONLY ───────────────
# grub_load_config() runs this BEFORE `normal`, so the rescue parser handles it
# and it must not contain any control flow. The real script is grub.cfg below.
{
  echo "search --no-floppy --fs-uuid --set=root $ESP_UUID"
  echo "set prefix=(\$root)/$DIRNAME"
} > staging-timing/embedded.cfg

# ── the real probe, executed by `normal` from $prefix/grub.cfg ──────────────
{
  echo "set timeout=0"
  echo 'echo "=============================================="'
  echo 'echo " AsahiLocker argon2id UNLOCK LATENCY probe"'
  echo 'echo "=============================================="'
  echo 'echo "GRUB $grub_version"'
  echo 'echo ""'
  echo 'echo "Each case prints its own Elapsed time, from the GRUB millisecond"'
  echo 'echo "timer. No video needed -- but photograph the final screen."'
  echo 'echo ""'
  echo 'echo "Starting in..."'
  echo 'sleep --verbose 5'

  i=0
  for pair in "${PAIRS[@]}"; do
      read -r mib iter <<< "$pair"
      i=$((i+1))
      lbl="${mib} MiB t=${iter}"
      echo 'echo ""'
      echo "echo \"=============================================\""
      echo "echo \">>> START  $lbl\""
      echo "loopback lo$i (\$root)/$DIRNAME/argon2id-${mib}M-t${iter}.img"
      # `time` prints "Elapsed time: N.mmm seconds" using grub_get_time_ms()
      echo "if time cryptomount -p $PASS (lo$i) ; then set r$i=OK ; else set r$i=FAIL ; fi"
      echo "echo \">>> RESULT $lbl = \$r$i   (elapsed printed above)\""
      # a visible pause so the video has an unambiguous boundary between cases
      echo 'sleep --verbose 3'
  done

  echo 'echo ""'
  echo 'echo "=============================================="'
  LINE=""
  i=0
  for pair in "${PAIRS[@]}"; do
      read -r mib iter <<< "$pair"
      i=$((i+1))
      LINE="$LINE ${mib}M/t${iter}=\$r$i"
  done
  echo "echo \"RESULTS:$LINE\""
  echo 'echo "(each Elapsed time line above is the unlock latency for that case)"'
  echo 'echo "=============================================="'
  echo 'echo ""'
  echo 'echo ">>> PHOTOGRAPH THIS SCREEN, then type:  reboot"'
  echo 'echo ""'
  # `normal` clears the screen the instant this script returns. Hold it.
  echo 'sleep --verbose --interruptible 900'
} > staging-timing/grub.cfg

"$SCRIPTCHECK" staging-timing/embedded.cfg || { echo "FATAL: bad embedded config"; exit 1; }
"$SCRIPTCHECK" staging-timing/grub.cfg     || { echo "FATAL: bad grub.cfg"; exit 1; }

"$MKIMAGE" --directory "$MODDIR" --prefix "/$DIRNAME" \
    --output staging-timing/grub-argon2-timing.efi --format arm64-efi \
    --config staging-timing/embedded.cfg \
    part_gpt part_msdos fat ext2 loopback cryptodisk luks luks2 argon2 pbkdf2 \
    gcry_rijndael gcry_sha256 gcry_sha512 gcry_crc afsplitter json loadenv \
    search search_fs_file search_fs_uuid normal echo test sleep minicmd \
    terminal configfile halt reboot ls cat help chain time

# ── deploy ──────────────────────────────────────────────────────────────────
sudo /usr/bin/rm -rf "${TARGET:?}/$DIRNAME"
sudo /usr/bin/mkdir -p "$TARGET/$DIRNAME"
sudo /usr/bin/cp staging-timing/argon2id-*.img staging-timing/grub.cfg \
                 staging-timing/grub-argon2-timing.efi "$TARGET/$DIRNAME/"
sync
echo
echo "== deployed =="
sudo ls -la "$TARGET/$DIRNAME/"
/usr/bin/df -h "$TARGET" | /usr/bin/tail -1
