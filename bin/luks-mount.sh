#!/bin/bash
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
# ═══════════════════════════════════════════════════════════════════════════════
# luks-mount.sh — find, unlock, mount and chroot into the OTHER Fedora Asahi
# installs on this Mac, encrypted or not, for maintenance; and put everything
# back afterwards. Runs from a live USB, a second install or the RAM rescue.
#
#   sudo ./bin/luks-mount.sh list                  every install, and its state
#   sudo ./bin/luks-mount.sh mount  ROOT [DIR]     unlock if needed, mount on DIR
#   sudo ./bin/luks-mount.sh chroot ROOT [CMD...]  mount, run a shell (or CMD)
#                                                  inside it, put it all back
#   sudo ./bin/luks-mount.sh umount [DIR]          unmount DIR, close what mount opened
#   sudo ./bin/luks-mount.sh status
#
# ROOT is the install's root partition, e.g. /dev/nvme0n1p6. DIR defaults to
# /mnt. Root and /home come from the root's btrfs subvolumes; /boot and
# /boot/efi come from the install's OWN /etc/fstab, matched by UUID, never
# guessed from partition order. Partitions of the system you are running on
# are refused, so this cannot mount your own root a second time by accident.
# mount --ro mounts everything read-only.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

STATE_DIR=/run/asahilocker-mount
if [ -t 1 ]; then
    RED=$'\033[0;31m' YEL=$'\033[1;33m' GRN=$'\033[0;32m' BLD=$'\033[1m' NC=$'\033[0m'
else
    RED="" YEL="" GRN="" BLD="" NC=""
fi
log()   { echo "${GRN}>>>${NC} $*"; }
warn()  { echo "${YEL}[WARN]${NC} $*" >&2; }
fatal() { echo "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
    sed -n '/^#   sudo \.\/bin\/luks-mount\.sh list/,/^# mount --ro mounts/p' "$(readlink -f "$0")" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

need_root() { [ "$(id -u)" -eq 0 ] || fatal "Run with sudo."; }

# ─── The running system ──────────────────────────────────────────────────────
# Every block device this system has mounted where an OS lives, or swaps onto,
# followed down through device-mapper to the partitions underneath. Same rule
# as luks-deploy.sh: a mount under /mnt or /run/media is NOT the system.
RUNNING_DEVS=()
add_running() {
    local d s seen
    d=$(printf '%s' "$1" | sed 's/\[.*//')
    [ -n "$d" ] || return 0
    d=$(readlink -f "$d" 2>/dev/null || echo "$d")
    [ -b "$d" ] || return 0
    for seen in ${RUNNING_DEVS[@]+"${RUNNING_DEVS[@]}"}; do [ "$seen" = "$d" ] && return 0; done
    RUNNING_DEVS+=("$d")
    for s in "/sys/class/block/$(basename "$d")/slaves/"*; do
        [ -e "$s" ] && add_running "/dev/$(basename "$s")"
    done
    return 0
}
collect_running() {
    local tgt src
    while read -r tgt src; do
        case "$tgt" in
            /|/boot|/boot/efi|/efi|/home|/usr|/var|/opt|/srv|/tmp|/nix|/usr/*|/var/*|/run/initramfs/*|/run/rootfsbase|/run/rootfsbase/*)
                add_running "$src" ;;
        esac
    done < <(findmnt -rno TARGET,SOURCE 2>/dev/null)
    while read -r src; do add_running "$src"; done < <(awk 'NR > 1 { print $1 }' /proc/swaps 2>/dev/null)
}
is_running() {
    local d seen
    d=$(readlink -f "$1" 2>/dev/null || echo "$1")
    for seen in ${RUNNING_DEVS[@]+"${RUNNING_DEVS[@]}"}; do [ "$seen" = "$d" ] && return 0; done
    return 1
}

# The open mapper backed by $1, if any (prints /dev/mapper/NAME).
mapper_of() {
    local dev m
    dev=$(readlink -f "$1")
    for m in /dev/mapper/*; do
        [ -b "$m" ] || continue
        [ "$(cryptsetup status "$(basename "$m")" 2>/dev/null | awk '$1=="device:"{print $2}')" = "$dev" ] \
            && { echo "$m"; return 0; }
    done
    return 1
}

# True when the LUKS2 header on $1 still requires reencryption: an in-place
# encryption that was interrupted. The dump goes into a variable first, as in
# luks-deploy.sh: piped straight into grep -q under pipefail, a producer cut
# short by SIGPIPE reads as "no flag".
reencrypt_pending() {
    local dump
    dump=$(cryptsetup luksDump "$1" 2>/dev/null) || return 1
    grep -q 'online-reencrypt' <<< "$dump"
}

# ─── list ────────────────────────────────────────────────────────────────────
cmd_list() {
    need_root
    collect_running
    local NAME FSTYPE SIZE LABEL line dev state where m n=0
    printf '%s%-18s %-12s %7s  %-10s %s%s\n' "$BLD" "PARTITION" "TYPE" "SIZE" "LABEL" "STATE" "$NC"
    while IFS= read -r line; do
        NAME=""; FSTYPE=""; SIZE=""; LABEL=""
        eval "$line"    # lsblk -P hex-escapes anything unsafe
        case "$FSTYPE" in btrfs|crypto_LUKS) ;; *) continue ;; esac
        dev="/dev/$NAME"
        [ -b "$dev" ] || continue
        [ "$(lsblk -dno TYPE "$dev" 2>/dev/null)" = part ] || continue
        if is_running "$dev"; then
            state="this system, running (to encrypt it: ram-rescue.sh, or a live USB)"
        elif [ "$FSTYPE" = crypto_LUKS ]; then
            if reencrypt_pending "$dev"; then
                state="encryption INTERRUPTED — run luks-deploy.sh on it to resume"
            else
                state="encrypted"
            fi
            m=$(mapper_of "$dev" || true)
            [ -n "$m" ] && state="$state, unlocked as $m"
        else
            state="not encrypted"
        fi
        where=$(findmnt -rno TARGET -S "$dev" 2>/dev/null | head -1 || true)
        [ -z "$where" ] && [ -n "${m:-}" ] && where=$(findmnt -rno TARGET -S "$m" 2>/dev/null | head -1 || true)
        [ -n "$where" ] && ! is_running "$dev" && state="$state, mounted on $where"
        printf '%-18s %-12s %7s  %-10s %s\n' "$dev" "$FSTYPE" "$SIZE" "${LABEL:--}" "$state"
        n=$((n + 1)); m=""
    done < <(lsblk -Ppo NAME,FSTYPE,SIZE,LABEL 2>/dev/null | sed 's/NAME="\/dev\//NAME="/')
    [ "$n" -gt 0 ] || echo "(no btrfs or LUKS partitions found)"
}

# ─── mount ───────────────────────────────────────────────────────────────────
# One spelling per directory: "/mnt/", "/mnt" and "mnt" typed in / are the same
# place, and must find the same record. (They did not: mount /dev/X /mnt/ then
# umount /mnt left the volume unlocked and a stale record behind.)
canon_dir() { readlink -m "$1" 2>/dev/null || echo "$1"; }
state_file() { echo "$STATE_DIR/$(printf '%s' "$1" | tr '/' '_')"; }

# The fstab of the install mounted at $1: prints "MOUNTPOINT SPEC OPTIONS" for
# /home, /boot and /boot/efi.
fstab_entries() {
    awk '$1 !~ /^#/ && NF >= 3 && ($2 == "/home" || $2 == "/boot" || $2 == "/boot/efi") { print $2, $1, $4 }' \
        "$1/etc/fstab" 2>/dev/null
}
spec_to_dev() {
    case "$1" in
        UUID=*)     blkid -U "${1#UUID=}" 2>/dev/null ;;
        PARTUUID=*) readlink -f "/dev/disk/by-partuuid/${1#PARTUUID=}" 2>/dev/null ;;
        LABEL=*)    blkid -L "${1#LABEL=}" 2>/dev/null ;;
        /dev/*)     readlink -f "$1" ;;
    esac
}

do_mount() {
    # $1 = root partition, $2 = target dir, $3 = 1 for read-only
    local root dir ro="$3" fstype dev opened="" sub cand top mp spec opts bdev mo
    dir=$(canon_dir "$2")
    root=$(readlink -f "$1")
    [ -b "$root" ] || fatal "$1 is not a block device."
    [ "$(lsblk -dno TYPE "$root")" = part ] || fatal "$root is not a partition. Give the root partition, e.g. /dev/nvme0n1p6 (see: list)."
    collect_running
    is_running "$root" && fatal "$root belongs to the system you are running. Mount another install, not this one."
    mkdir -p "$dir" "$STATE_DIR"
    mountpoint -q "$dir" && fatal "$dir is already a mountpoint. Unmount it first (umount $dir)."
    [ -e "$(state_file "$dir")" ] && fatal "$dir has a stale record in $STATE_DIR; run: umount $dir"
    mo="rw"; [ "$ro" = 1 ] && mo="ro"

    fstype=$(blkid -s TYPE -o value "$root" 2>/dev/null || true)
    case "$fstype" in
        crypto_LUKS)
            if reencrypt_pending "$root"; then
                fatal "$root is in the middle of an interrupted encryption. Resume it with luks-deploy.sh first."
            fi
            if dev=$(mapper_of "$root"); then
                log "Already unlocked as $dev"
            else
                local name
                name="am-$(basename "$root")"
                log "Unlocking $root as /dev/mapper/$name"
                if [ "$ro" = 1 ]; then cryptsetup open --readonly "$root" "$name"; else cryptsetup open "$root" "$name"; fi
                dev="/dev/mapper/$name"; opened="$name"
            fi ;;
        btrfs) dev="$root" ;;
        *) fatal "$root is '$fstype', not btrfs or crypto_LUKS. Is it a Fedora Asahi root partition? (see: list)" ;;
    esac
    [ "$(blkid -s TYPE -o value "$dev" 2>/dev/null)" = btrfs ] \
        || { [ -n "$opened" ] && cryptsetup close "$opened"; fatal "$dev does not hold btrfs."; }

    # Record before mounting anything, so umount can undo a half-finished mount.
    printf 'root=%s\nmapper=%s\ndir=%s\n' "$root" "$opened" "$dir" > "$(state_file "$dir")"

    # Which subvolume is the system: the one holding etc/fstab.
    top=$(mktemp -d /run/asahilocker-top.XXXXXX)
    mount -o "ro,subvolid=5" "$dev" "$top"
    sub=""
    for cand in root @rootfs @; do
        [ -f "$top/$cand/etc/fstab" ] && { sub="$cand"; break; }
    done
    umount "$top"; rmdir "$top"
    [ -n "$sub" ] || { do_umount "$dir" quiet; fatal "No root subvolume with an /etc/fstab on $root."; }

    log "Mounting $root (subvol=$sub) on $dir$([ "$ro" = 1 ] && echo ' read-only' || true)"
    mount -o "$mo,subvol=$sub" "$dev" "$dir"
    while read -r mp spec opts; do
        case "$mp" in
            /home)
                local hsub
                hsub=$(printf '%s' "$opts" | tr ',' '\n' | sed -n 's/^subvol=\/\{0,1\}//p' | head -1)
                [ -n "$hsub" ] || continue
                if mount -o "$mo,subvol=$hsub" "$dev" "$dir/home"; then log "  /home (subvol=$hsub)"
                else warn "  /home (subvol=$hsub) could not be mounted"; fi ;;
            /boot|/boot/efi)
                bdev=$(spec_to_dev "$spec" || true)
                if [ -z "$bdev" ] || [ ! -b "$bdev" ]; then
                    warn "  $mp: $spec from the install's fstab is not on this machine; not mounted"; continue
                fi
                if is_running "$bdev"; then
                    warn "  $mp: $bdev is the running system's own $mp; not mounted"; continue
                fi
                if mount -o "$mo" "$bdev" "$dir$mp"; then log "  $mp ($bdev, from the install's fstab)"
                else warn "  $mp ($bdev) could not be mounted"; fi ;;
        esac
    # LC_ALL=C, on the mountpoint alone: parents before children. In a UTF-8
    # locale sort ignores punctuation at first, which put "/boot/efi UUID=.."
    # BEFORE "/boot UUID=..": the EFI mount then failed for want of its
    # mountpoint, nothing said so, and the chroot had no ESP.
    done < <(fstab_entries "$dir" | LC_ALL=C sort -k1,1)
}

cmd_mount() {
    local ro=0 args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --ro|--read-only) ro=1 ;;
            -h|--help) usage 0 ;;
            -*) fatal "Unknown option: $1 (mount takes --ro)" ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    [ ${#args[@]} -ge 1 ] || fatal "Which install? Give its root partition (see: list)."
    [ ${#args[@]} -le 2 ] || fatal "Too many arguments: mount ROOT [DIR]"
    need_root
    local dir
    dir=$(canon_dir "${args[1]:-/mnt}")
    do_mount "${args[0]}" "$dir" "$ro"
    log "${BLD}Done.${NC} Mounted on $dir. Undo with: $0 umount $dir"
}

# ─── chroot ──────────────────────────────────────────────────────────────────
cmd_chroot() {
    need_root
    [ $# -ge 1 ] || fatal "Which install? Give its root partition (see: list)."
    local root="$1" dir rc=0 p
    shift
    dir=$(mktemp -d /run/asahilocker-chroot.XXXXXX)
    # shellcheck disable=SC2064  # expand $dir now
    trap "do_umount '$dir' quiet; rmdir '$dir' 2>/dev/null || true" EXIT
    trap 'exit 130' INT TERM
    do_mount "$root" "$dir" 0
    for p in /dev /dev/pts /proc /sys /run; do mount --bind "$p" "$dir$p"; done
    [ -d /sys/firmware/efi/efivars ] && mount --bind /sys/firmware/efi/efivars "$dir/sys/firmware/efi/efivars" 2>/dev/null || true
    log "Entering the install on $root. Leave with 'exit'; everything is unmounted and locked again."
    log "  Changed files by hand in there? 'touch /.autorelabel' before you leave, so SELinux relabels on its next boot."
    if [ $# -gt 0 ]; then
        chroot "$dir" "$@" || rc=$?
    else
        chroot "$dir" /bin/bash -l || rc=$?
    fi
    exit "$rc"
}

# ─── umount ──────────────────────────────────────────────────────────────────
do_umount() {
    local dir="$1" quiet="${2:-}" sf mapper
    sf=$(state_file "$dir")
    if mountpoint -q "$dir"; then
        umount -R "$dir" || {
            warn "Could not unmount $dir; something is still using it:"
            fuser -vm "$dir" 2>&1 | head -10 >&2 || true
            return 1
        }
        [ -n "$quiet" ] || log "Unmounted $dir"
    fi
    if [ -f "$sf" ]; then
        mapper=$(sed -n 's/^mapper=//p' "$sf")
        if [ -n "$mapper" ] && [ -b "/dev/mapper/$mapper" ]; then
            # Keep the record if the volume will not lock: without it a later
            # umount would have nothing to close.
            cryptsetup close "$mapper" || {
                warn "Could not lock /dev/mapper/$mapper again; it is still open. Retry: $0 umount $dir"
                return 1
            }
            [ -n "$quiet" ] || log "Locked /dev/mapper/$mapper again"
        fi
        rm -f "$sf"
    fi
    return 0
}
cmd_umount() {
    need_root
    local dir
    dir=$(canon_dir "${1:-/mnt}")
    # Only what mount recorded. Without a record this is somebody else's
    # mountpoint, and "umount -R" on it (on "/", say) is not ours to run.
    [ -f "$(state_file "$dir")" ] \
        || fatal "Nothing mounted by luks-mount.sh on $dir (see: status). For any other mount, use umount itself."
    do_umount "$dir" && log "${BLD}Done.${NC}"
}

# ─── status ──────────────────────────────────────────────────────────────────
cmd_status() {
    need_root
    local sf dir root mapper any=0
    for sf in "$STATE_DIR"/*; do
        [ -f "$sf" ] || continue
        any=1
        dir=$(sed -n 's/^dir=//p' "$sf")
        root=$(sed -n 's/^root=//p' "$sf"); mapper=$(sed -n 's/^mapper=//p' "$sf")
        echo "$root on $dir${mapper:+ (unlocked as /dev/mapper/$mapper)}"
        findmnt -R -no TARGET,SOURCE "$dir" 2>/dev/null | sed 's/^/    /'
    done
    [ "$any" -eq 1 ] || echo "Nothing mounted by luks-mount.sh."
}

case "${1:-}" in
    list)    shift; cmd_list "$@" ;;
    mount)   shift; cmd_mount "$@" ;;
    chroot)  shift; cmd_chroot "$@" ;;
    umount|unmount) shift; cmd_umount "$@" ;;
    status)  shift; cmd_status ;;
    -h|--help|help) usage 0 ;;
    *) usage 1 ;;
esac
