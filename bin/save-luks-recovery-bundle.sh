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
# Assembles a CLEARLY LABELED LUKS recovery bundle: everything needed to get
# back into this machine's data when something other than the passphrase is
# lost — a header, a partition table, a boot entry, a crypttab.
#
# What goes in, and why each item is there:
#   * a fresh luksHeaderBackup of EVERY LUKS volume on the machine, not just
#     root (a separate /home or swap volume dies just as quietly), each one
#     verified readable and its UUID cross-checked before it is kept;
#   * the public luksDump of each (cipher, KDF, keyslot count) — so you know
#     what a restored header should look like;
#   * the partition table of every disk holding a LUKS volume (`sfdisk --dump`,
#     restorable with `sfdisk`): a header backup is useless if nobody knows
#     the offset the volume starts at;
#   * crypttab, fstab, every kernel command-line carrier, the initramfs
#     generator's config, boot entries, EFI boot variables, mounts, the last
#     deploy log — the boot configuration a chroot repair has to reproduce;
#   * sha256 sums of all of it, and a README with the repair steps for THIS
#     machine's initramfs style, including the checks to make before a
#     header is ever restored.
#
# What deliberately does NOT go in: key files named in crypttab. A header
# backup holds key SLOTS (useless without a passphrase); a key file IS a key.
# They are listed so you back them up separately, on your own terms.
#
# The /boot emergency copy luks-deploy.sh left behind goes stale the moment a
# keyslot is re-costed or a passphrase changed. It is compared with the fresh
# header; when it is older and the fresh one verifies, it is refreshed (the
# old copy kept beside it) — unless --no-boot-refresh is given.
#
# Destination defaults to /root; override with LUKS_BUNDLE_DIR=/some/path.
# The bundle then lives ON the encrypted drive — fine as staging, useless as
# your only copy. Copy it to secure offline storage afterwards.
#
# Run on the booted, encrypted system:   sudo ./save-luks-recovery-bundle.sh
# (Also callable right after luks-deploy from the live USB — it auto-detects a
#  target mounted at /mnt and writes under /mnt instead.)
#
#   --dry-run          list what would be saved; write nothing
#   --no-boot-refresh  never touch /boot/luks-header-backup.img
#
# Exits non-zero when the authoritative header backup of ANY volume failed,
# so post-encryption-setup.sh and fleet automation can see it.
#
# Scripts do not expand shell aliases, and PATH is pinned below so the system
# tools are the ones that run.
# ============================================================================
set -uo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
FAILS=0
ok(){ echo -e "  ${G}✅${N} $*"; }; warn(){ echo -e "  ${Y}⚠️ ${N} $*"; }
err(){ echo -e "  ${R}❌${N} $*"; FAILS=$((FAILS+1)); }
note(){ echo "     $*"; }

DRY=0; BOOT_REFRESH=1
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-boot-refresh) BOOT_REFRESH=0 ;;
    -h|--help) sed -n '/^# Assembles a CLEARLY/,/^# =\{20,\}/p' "$0" | sed -e '$d' -e 's/^# \?//'; exit 0 ;;
    *) echo "unknown option: $a (--dry-run, --no-boot-refresh, --help)" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { err "run as root (sudo)"; exit 1; }
DRYNOTE=""; [ "$DRY" -eq 1 ] && DRYNOTE="  (dry run — nothing is written)"

SELFDIR=$(dirname "$(readlink -f "$0")")
HAVE_BOOT_LIB=0
if [ -f "$SELFDIR/lib-boot.sh" ]; then
  # shellcheck source=lib-boot.sh
  . "$SELFDIR/lib-boot.sh"; HAVE_BOOT_LIB=1
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────
strip_subvol(){ sed 's/\[.*//'; }
# luks_ancestor <dev> — the crypt mapper somewhere below <dev> (handles a
# root on LVM-on-LUKS or on a btrfs subvolume: lsblk -s walks the stack down).
luks_ancestor(){
  lsblk -sno NAME,TYPE "$1" 2>/dev/null | awk '$2=="crypt"{print $1; exit}'
}
mapper_raw(){   # crypt mapper name -> canonical backing device
  local d; d=$(cryptsetup status "$1" 2>/dev/null | awk '$1=="device:"{print $2; exit}')
  [ -n "$d" ] && readlink -f "$d" 2>/dev/null
}
run(){ if [ "$DRY" -eq 1 ]; then note "[dry-run] $*"; else "$@"; fi; }

# ─── Where is the target: this system, or one mounted at /mnt? ──────────────
ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null | strip_subvol)
ROOT_CRYPT=$(luks_ancestor "$ROOT_SRC")
PREFIX=""
if [ -z "$ROOT_CRYPT" ]; then
  MNT_SRC=$(findmnt -no SOURCE /mnt 2>/dev/null | strip_subvol)
  if [ -n "$MNT_SRC" ] && [ -f /mnt/etc/fstab ] && [ -n "$(luks_ancestor "$MNT_SRC")" ]; then
    PREFIX="/mnt"; ROOT_SRC="$MNT_SRC"; ROOT_CRYPT=$(luks_ancestor "$MNT_SRC")
  fi
fi
[ -n "$ROOT_CRYPT" ] || { err "neither / nor /mnt sits on a LUKS volume — is the box encrypted & mounted?"; exit 1; }
ROOT_RAW=$(mapper_raw "$ROOT_CRYPT")
[ -n "$ROOT_RAW" ] && [ -b "$ROOT_RAW" ] || { err "cannot resolve the raw device behind /dev/mapper/$ROOT_CRYPT"; exit 1; }
ROOT_LUKS_UUID=$(cryptsetup luksUUID "$ROOT_RAW" 2>/dev/null || blkid -s UUID -o value "$ROOT_RAW" 2>/dev/null || echo unknown)
FS_UUID=$(blkid -s UUID -o value "$ROOT_SRC" 2>/dev/null || echo unknown)
FS_TYPE=$(blkid -s TYPE -o value "$ROOT_SRC" 2>/dev/null || echo unknown)
if [ -n "$PREFIX" ] && [ -r "$PREFIX/etc/hostname" ]; then HOST=$(head -1 "$PREFIX/etc/hostname")
else HOST=$(hostname 2>/dev/null || echo host); fi
HOST=${HOST:-host}
STAMP=$(date +%Y%m%d-%H%M%S)
[ -n "$PREFIX" ] && note "target mounted at $PREFIX (live-USB mode)"

# ─── Which initramfs style — decides the repair commands in the README ───────
INITRAMFS=unknown; UNLOCK_ARGS=""
if [ -x "$PREFIX/usr/bin/dracut" ] || [ -x "$PREFIX/usr/sbin/dracut" ]; then
  INITRAMFS=dracut; UNLOCK_ARGS="rd.luks.uuid=$ROOT_LUKS_UUID rd.luks.name=$ROOT_LUKS_UUID=$ROOT_CRYPT"
elif [ -f "$PREFIX/etc/mkinitcpio.conf" ]; then
  INITRAMFS=mkinitcpio
  if grep -Eq '^HOOKS=.*[( ]systemd[ )]' "$PREFIX/etc/mkinitcpio.conf"; then UNLOCK_ARGS="rd.luks.name=$ROOT_LUKS_UUID=$ROOT_CRYPT"
  else UNLOCK_ARGS="cryptdevice=UUID=$ROOT_LUKS_UUID:$ROOT_CRYPT"; fi
elif [ -x "$PREFIX/usr/sbin/update-initramfs" ] || [ -d "$PREFIX/etc/initramfs-tools" ]; then
  INITRAMFS=initramfs-tools; UNLOCK_ARGS="(none — crypttab with the 'initramfs' option drives the unlock)"
fi

# ─── Every LUKS volume on the machine ───────────────────────────────────────
# "label<TAB>raw device<TAB>mapper-or-inactive<TAB>uuid"
VOLUMES=()
while read -r name fstype; do
  [ "$fstype" = "crypto_LUKS" ] || continue
  raw=$(readlink -f "/dev/$name"); [ -b "$raw" ] || continue
  uuid=$(cryptsetup luksUUID "$raw" 2>/dev/null || echo unknown)
  mapper=$(lsblk -rno NAME,TYPE "$raw" 2>/dev/null | awk '$2=="crypt"{print $1; exit}')
  if [ "$raw" = "$ROOT_RAW" ]; then label=root
  elif [ -n "$mapper" ]; then label="$mapper"
  else label="inactive-$(basename "$raw")"; fi
  VOLUMES+=("$label	$raw	${mapper:-inactive}	$uuid")
done < <(lsblk -rno NAME,FSTYPE 2>/dev/null)
# Detached headers (crypttab header=): the data device carries no header.
DETACHED=()
if [ -r "$PREFIX/etc/crypttab" ]; then
  while read -r ct_name _ _ ct_opts; do
    case "$ct_name" in ''|'#'*) continue ;; esac
    case ",${ct_opts:-}," in *,header=*) h=$(printf '%s' ",$ct_opts," | sed -n 's/.*,header=\([^,]*\),.*/\1/p'); [ -n "$h" ] && DETACHED+=("$ct_name	$h") ;; esac
  done < "$PREFIX/etc/crypttab"
fi

# ─── Destination ────────────────────────────────────────────────────────────
BUNDLE_BASE="${LUKS_BUNDLE_DIR:-/root}"
DEST="$PREFIX${BUNDLE_BASE}/LUKS-RECOVERY-${HOST}-${STAMP}"
NEED_KB=$(( (${#VOLUMES[@]} + ${#DETACHED[@]} + 2) * 16 * 1024 + 4096 ))
if [ "$DRY" -eq 0 ]; then
  mkdir -p "$DEST" || { err "cannot create $DEST"; exit 1; }
  chmod 0700 "$DEST"
  # chmod is a silent no-op on vfat/exfat (the mode comes from the mount's
  # fmask) — say so when the bundle lands on such a stick.
  if [ "$(stat -c %a "$DEST" 2>/dev/null)" != "700" ]; then
    warn "$DEST cannot hold Unix permissions (vfat/exfat?) — the headers here are readable by anyone holding the drive"
  fi
  AVAIL_KB=$(df -Pk "$DEST" 2>/dev/null | awk 'NR==2{print $4}')
  case "$AVAIL_KB" in ''|*[!0-9]*) ;; *) [ "$AVAIL_KB" -lt "$NEED_KB" ] && { err "only ${AVAIL_KB} KiB free under $DEST, need about ${NEED_KB} KiB"; exit 1; } ;; esac
fi
ok "bundle dir: $DEST$DRYNOTE"
echo "  root: $ROOT_SRC  via /dev/mapper/$ROOT_CRYPT  on $ROOT_RAW  luks-uuid=$ROOT_LUKS_UUID"
echo "  fs=$FS_TYPE fs-uuid=$FS_UUID  initramfs=$INITRAMFS  volumes=${#VOLUMES[@]} detached-headers=${#DETACHED[@]}"

# ─── 1. Headers — every volume, verified ────────────────────────────────────
# luksHeaderBackup creates the file itself and refuses to overwrite, so the
# mode has to be right at creation: umask 077 in a subshell.
backup_header(){   # $1 = label, $2 = source (device or detached header file), $3 = expected uuid
  local label="$1" src="$2" want="$3" got
  local out="$DEST/luks-header-${label}.img"
  if [ "$DRY" -eq 1 ]; then note "[dry-run] luksHeaderBackup $src -> $(basename "$out")"; return 0; fi
  if ! ( umask 077; cryptsetup luksHeaderBackup "$src" --header-backup-file "$out" 2>/dev/null ); then
    err "luksHeaderBackup failed for $label ($src)"; return 1
  fi
  chmod 0400 "$out"
  # A backup that luksDump cannot parse is a backup of a damaged header —
  # keep it (it may still hold what a repair needs) but never call it good.
  got=$(cryptsetup luksDump "$out" 2>/dev/null | awk '/^UUID:/{print $2; exit}')
  if [ -z "$got" ]; then
    err "$label: the header backup does not parse (on-disk header damaged?) — kept as $(basename "$out"), NOT verified"
    mv -f "$out" "$out.UNVERIFIED"; return 1
  fi
  if [ "$want" != "unknown" ] && [ "$got" != "$want" ]; then
    err "$label: backup UUID $got does not match the device's $want"; return 1
  fi
  cryptsetup luksDump "$src" > "$DEST/luksDump-${label}.txt" 2>/dev/null && chmod 0600 "$DEST/luksDump-${label}.txt"
  ok "header of $label backed up and verified (UUID $got, $(grep -cE '^[[:space:]]+[0-9]+: luks' "$DEST/luksDump-${label}.txt" 2>/dev/null || echo '?') keyslots)"
  return 0
}
ROOT_HDR_OK=0
for v in "${VOLUMES[@]}"; do
  IFS=$'\t' read -r label raw mapper uuid <<< "$v"
  if backup_header "$label" "$raw" "$uuid"; then [ "$label" = root ] && ROOT_HDR_OK=1; fi
done
for d in "${DETACHED[@]+"${DETACHED[@]}"}"; do
  IFS=$'\t' read -r ct_name hpath <<< "$d"
  hp="$PREFIX$hpath"; [ -f "$hp" ] || hp="$hpath"
  if [ -f "$hp" ]; then backup_header "detached-${ct_name}" "$hp" unknown
  else err "crypttab says $ct_name uses a detached header at $hpath, which is not present"; fi
done

# ─── 2. The /boot emergency copy: current, or stale? ────────────────────────
BOOT_COPY="$PREFIX/boot/luks-header-backup.img"
if [ -f "$BOOT_COPY" ]; then
  run cp -f "$BOOT_COPY" "$DEST/luks-header-from-boot.img"; [ "$DRY" -eq 0 ] && chmod 0400 "$DEST/luks-header-from-boot.img"
  BC_UUID=$(cryptsetup luksDump "$BOOT_COPY" 2>/dev/null | awk '/^UUID:/{print $2; exit}')
  if [ "$BC_UUID" != "$ROOT_LUKS_UUID" ]; then
    warn "/boot/luks-header-backup.img is for UUID ${BC_UUID:-?}, not this root ($ROOT_LUKS_UUID) — copied, left alone"
  elif [ "$ROOT_HDR_OK" -eq 1 ] && cmp -s "$BOOT_COPY" "$DEST/luks-header-root.img"; then
    ok "/boot/luks-header-backup.img is identical to the current header"
  elif [ "$ROOT_HDR_OK" -eq 1 ]; then
    # Older than the header on disk: a keyslot was re-costed or a passphrase
    # changed since luks-deploy wrote it. Restoring it would resurrect the old
    # keyslot parameters — and any passphrase they belonged to.
    if [ "$BOOT_REFRESH" -eq 1 ]; then
      run cp -f "$BOOT_COPY" "$BOOT_COPY.prev-$STAMP"
      run install -m 0400 "$DEST/luks-header-root.img" "$BOOT_COPY"
      ok "/boot/luks-header-backup.img was STALE — refreshed from the verified current header (old copy kept as luks-header-backup.img.prev-$STAMP)"
      note "the old copy still opens with whatever passphrase was valid when it was made: shred it once this bundle is stored offline"
    else
      warn "/boot/luks-header-backup.img is STALE (differs from the current header); --no-boot-refresh given, left as is"
    fi
  else
    warn "/boot/luks-header-backup.img differs from the on-disk header, and the fresh backup did not verify — NOT refreshing; the /boot copy may be your good one"
  fi
elif [ "$DRY" -eq 0 ] && [ "$ROOT_HDR_OK" -eq 1 ] && [ -d "$PREFIX/boot" ] && [ "$BOOT_REFRESH" -eq 1 ]; then
  install -m 0400 "$DEST/luks-header-root.img" "$BOOT_COPY" && ok "wrote the /boot emergency copy (none existed)"
fi

# ─── 3. Partition tables of every disk holding a LUKS volume ────────────────
# The header says how to decrypt; the partition table says WHERE the volume
# is. Losing the table with only a header backup in hand is a puzzle nobody
# wants to solve from dd output. `sfdisk /dev/X < file` puts it back.
DISKS=$(for v in "${VOLUMES[@]}"; do IFS=$'\t' read -r _ raw _ _ <<< "$v"; lsblk -dno PKNAME "$raw" 2>/dev/null; done | sort -u)
for dk in $DISKS; do
  [ -n "$dk" ] || continue
  if [ "$DRY" -eq 1 ]; then note "[dry-run] sfdisk --dump /dev/$dk"; continue; fi
  if sfdisk --dump "/dev/$dk" > "$DEST/partition-table-${dk}.sfdisk" 2>/dev/null; then
    chmod 0600 "$DEST/partition-table-${dk}.sfdisk"; ok "partition table of /dev/$dk saved (sfdisk --dump)"
  else warn "could not dump the partition table of /dev/$dk"; rm -f "$DEST/partition-table-${dk}.sfdisk"; fi
done

# ─── 4. Boot configuration a chroot repair has to reproduce ─────────────────
save(){   # $1 = path relative to the target root
  local f="$1" dst
  [ -f "$PREFIX/$f" ] || return 0
  dst="$DEST/$(printf '%s' "$f" | tr / _)"
  [ -e "$dst" ] && return 0                     # already saved (carrier lists overlap)
  if [ "$DRY" -eq 1 ]; then note "[dry-run] save /$f"; return 0; fi
  cp -f "$PREFIX/$f" "$dst" 2>/dev/null && chmod 0600 "$dst" && ok "saved /$f" || warn "could not save /$f"
}
for f in etc/crypttab etc/fstab etc/kernel/cmdline etc/default/grub etc/mkinitcpio.conf \
         etc/os-release etc/hostname boot/firmware/cmdline.txt boot/cmdline.txt \
         boot/firmware/config.txt boot/extlinux/extlinux.conf boot/refind_linux.conf \
         boot/luks-deploy.log var/lib/asahilocker/restore-splash; do
  save "$f"
done
for f in "$PREFIX"/etc/default/grub.d/*.cfg "$PREFIX"/etc/cmdline.d/*.conf \
         "$PREFIX"/etc/dracut.conf.d/*.conf "$PREFIX"/etc/mkinitcpio.d/*.preset \
         "$PREFIX"/etc/initramfs-tools/conf.d/* "$PREFIX"/etc/initramfs-tools/initramfs.conf \
         "$PREFIX"/boot/limine.conf "$PREFIX"/boot/limine/limine.conf "$PREFIX"/etc/default/limine; do
  [ -f "$f" ] && save "${f#"$PREFIX"/}"
done
if [ "$HAVE_BOOT_LIB" -eq 1 ]; then
  while IFS=$'\t' read -r _ cpath; do
    [ -n "$cpath" ] || continue
    case "$cpath" in */loader/entries/*) continue ;; esac   # handled below, per directory
    save "${cpath#"$PREFIX"/}"
  done < <(cl_find_carriers "$PREFIX")
fi
for d in boot efi boot/efi; do
  [ -d "$PREFIX/$d/loader/entries" ] || continue
  if [ "$DRY" -eq 1 ]; then note "[dry-run] save /$d/loader/entries/*.conf"; continue; fi
  mkdir -p "$DEST/bls-entries-$(printf '%s' "$d" | tr / _)"
  cp -f "$PREFIX/$d"/loader/entries/*.conf "$DEST/bls-entries-$(printf '%s' "$d" | tr / _)/" 2>/dev/null \
    && ok "saved /$d/loader/entries" || rmdir "$DEST/bls-entries-$(printf '%s' "$d" | tr / _)" 2>/dev/null
done
if [ "$DRY" -eq 0 ]; then
  lsblk -o NAME,FSTYPE,LABEL,PARTLABEL,PARTUUID,SIZE,UUID,MOUNTPOINTS > "$DEST/lsblk.txt" 2>/dev/null \
    || lsblk -o NAME,FSTYPE,LABEL,PARTLABEL,SIZE,UUID > "$DEST/lsblk.txt" 2>/dev/null || true
  blkid > "$DEST/blkid.txt" 2>/dev/null || true
  findmnt -R "${PREFIX:-/}" > "$DEST/findmnt.txt" 2>/dev/null || true
  [ -z "$PREFIX" ] && cp -f /proc/cmdline "$DEST/proc_cmdline.txt" 2>/dev/null
  if [ -d /sys/firmware/efi ] && command -v efibootmgr >/dev/null 2>&1; then
    efibootmgr -v > "$DEST/efibootmgr.txt" 2>/dev/null && ok "saved EFI boot entries (efibootmgr -v)"
  fi
  chmod 0600 "$DEST"/*.txt 2>/dev/null
fi

# ─── 5. Key files are NOT copied — but they are named ───────────────────────
if [ -r "$PREFIX/etc/crypttab" ]; then
  KEYED=$(awk '$1 !~ /^#/ && NF>=3 && $3 != "none" && $3 != "-" {print $1": "$3}' "$PREFIX/etc/crypttab")
  if [ -n "$KEYED" ]; then
    warn "crypttab unlocks these with a KEY FILE, which is NOT in this bundle (it is the key, not a slot):"
    echo "$KEYED" | sed 's/^/       /'
    note "back those files up separately, offline; a volume with only a keyfile slot is lost with the file"
  fi
fi

# ─── 6. Sums + README ───────────────────────────────────────────────────────
SUMS=""
if [ "$DRY" -eq 0 ]; then
  ( cd "$DEST" && sha256sum -- * 2>/dev/null | grep -v 'README-RECOVERY\|sha256sums' > sha256sums.txt )
  chmod 0600 "$DEST/sha256sums.txt" 2>/dev/null
  SUMS="  sha256sums.txt             sha256sum -c sha256sums.txt   (run it before trusting any of this)"
fi
case "$INITRAMFS" in
  dracut)          REBUILD='dracut --regenerate-all --force' ;;
  mkinitcpio)      REBUILD='mkinitcpio -P' ;;
  initramfs-tools) REBUILD='update-initramfs -u -k all' ;;
  *)               REBUILD='(initramfs generator not identified — dracut --regenerate-all --force | mkinitcpio -P | update-initramfs -u -k all)' ;;
esac
MOUNT_HINT="mount /dev/mapper/$ROOT_CRYPT /mnt"
if [ "$FS_TYPE" = "btrfs" ]; then
  SUBVOL=$(findmnt -no SOURCE "${PREFIX:-/}" 2>/dev/null | sed -n 's/.*\[\/\(.*\)\]/\1/p')
  [ -n "$SUBVOL" ] && MOUNT_HINT="mount -o subvol=$SUBVOL /dev/mapper/$ROOT_CRYPT /mnt"
elif [ "$ROOT_SRC" != "/dev/mapper/$ROOT_CRYPT" ]; then
  MOUNT_HINT="# root is $ROOT_SRC, layered on the LUKS mapper (LVM?): activate it, then
  mount $ROOT_SRC /mnt"
fi
VOL_LINES=$(for v in "${VOLUMES[@]}"; do IFS=$'\t' read -r label raw mapper uuid <<< "$v"; printf '  %-14s %-16s mapper=%-22s uuid=%s\n' "$label" "$raw" "$mapper" "$uuid"; done)
README="$DEST/README-RECOVERY.txt"
if [ "$DRY" -eq 0 ]; then
cat > "$README" <<EOF
================================================================================
  LUKS RECOVERY BUNDLE  —  $HOST  —  $STAMP
================================================================================
Headers and boot state for every LUKS volume on "$HOST", made by AsahiLocker.

  Root volume    : $ROOT_RAW  (LUKS UUID $ROOT_LUKS_UUID)  -> /dev/mapper/$ROOT_CRYPT
  Root filesystem: $FS_TYPE  UUID=$FS_UUID  mounted from $ROOT_SRC
  Initramfs      : $INITRAMFS
  Unlock args    : $UNLOCK_ARGS

  All LUKS volumes found:
$VOL_LINES

>>> ACTION REQUIRED: COPY THIS ENTIRE FOLDER TO SECURE OFFLINE STORAGE. <<<
It currently sits ON the encrypted drive it protects — good as staging, useless
as your only copy if this drive dies. Put a copy on an encrypted USB / another box.

SENSITIVITY: a header contains key SLOTS, not your key. It cannot decrypt data
without a passphrase — but it accepts every passphrase that was valid WHEN IT
WAS MADE. If you ever change a passphrase, every older bundle still opens the
volume with the old one: make a fresh bundle and shred the old ones.

--------------------------------------------------------------------------------
BEFORE RESTORING A HEADER — read this twice
--------------------------------------------------------------------------------
A header restore rewrites the keyslots and the data-offset of the volume. Done
onto the wrong device, or onto a volume that was re-encrypted or reformatted
since the backup, it destroys data with no undo. Check first:

  sha256sum -c sha256sums.txt                       # the bundle is intact
  cryptsetup luksDump luks-header-root.img | grep UUID    # what the backup is
  cryptsetup luksDump $ROOT_RAW | grep UUID          # what the device is
  # The UUIDs must match. If the on-disk header is too damaged to dump, use
  # the partition table dump to confirm the device is still the same partition
  # (same start sector, same size) before going on.
  # If the device opens fine right now, you do NOT need a restore.

  cryptsetup luksHeaderRestore $ROOT_RAW --header-backup-file luks-header-root.img

--------------------------------------------------------------------------------
LOST PARTITION TABLE
--------------------------------------------------------------------------------
  sfdisk /dev/DISK < partition-table-DISK.sfdisk    # restores GPT/MBR exactly
Then the LUKS volumes are back where they were and open normally.

--------------------------------------------------------------------------------
SYSTEM WILL NOT BOOT — repair from any live USB for this machine
--------------------------------------------------------------------------------
  cryptsetup open $ROOT_RAW $ROOT_CRYPT
  $MOUNT_HINT
  # mount /boot, EFI and/or firmware partitions under /mnt as etc_fstab lists them
  for i in dev dev/pts proc sys run; do mount --bind /\$i /mnt/\$i; done
  chroot /mnt /bin/bash
  #   compare the live files with this bundle: etc_crypttab, etc_fstab,
  #   etc_kernel_cmdline, etc_default_grub (+ etc_default_grub.d_*), bls-entries-*,
  #   boot_*cmdline.txt, extlinux, refind, limine — root= must be the mapper
  #   (root=UUID=<filesystem uuid> is also fine), and the initramfs must have
  #   its unlock arguments:  $UNLOCK_ARGS
  #   rebuild the initramfs:
  $REBUILD
  #   regenerate the bootloader config: update-grub | grub2-mkconfig -o /boot/grub2/grub.cfg
  #   BLS systems:  grubby --update-kernel=ALL --args="$UNLOCK_ARGS"
  #   a UKI has the command line INSIDE the .efi: rebuild it (mkinitcpio -P /
  #   kernel-install add ...) and re-sign it if Secure Boot is on.
  # efibootmgr.txt has the firmware boot entries that existed; recreate a lost
  # one with efibootmgr -c -d /dev/DISK -p N -L "Linux" -l '\\EFI\\...\\shim.efi'

--------------------------------------------------------------------------------
KEY FILES
--------------------------------------------------------------------------------
Never included here. Any crypttab entry whose third field is a path unlocks with
a file that IS the key; keep those backed up separately and offline.

Files in this bundle:
  luks-header-<label>.img    fresh, VERIFIED luksHeaderBackup per volume
  luks-header-*.img.UNVERIFIED  a backup that did not parse (damaged header) — kept, not trusted
  luks-header-from-boot.img  the /boot emergency copy as it was when this ran
  luksDump-<label>.txt       public header metadata (cipher, KDF, keyslots)
  partition-table-*.sfdisk   sfdisk --dump of each disk holding a LUKS volume
  etc_*, boot_*, bls-entries-*/   boot configuration as it was
  lsblk.txt blkid.txt findmnt.txt efibootmgr.txt proc_cmdline.txt
$SUMS
================================================================================
EOF
chmod 0600 "$README"
ok "wrote README-RECOVERY.txt"
fi

sync
echo
if [ "$FAILS" -eq 0 ]; then
  ok "LUKS recovery bundle complete$DRYNOTE:"
else
  err "bundle finished with $FAILS problem(s) — read the ❌ lines; a volume without a verified header here has NO good backup in this bundle"
fi
[ "$DRY" -eq 0 ] && ls -la "$DEST" | sed 's/^/    /'
echo -e "  ${Y}Remember to copy $DEST off this machine.${N}"
[ "$FAILS" -eq 0 ]
