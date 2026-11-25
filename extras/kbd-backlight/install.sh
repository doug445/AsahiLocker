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
# extras/kbd-backlight/install.sh — keyboard backlight at 100% at the LUKS prompt (Fedora Asahi)
# ============================================================================
# The MacBook keyboard backlight is a PWM LED (pwm-apple + leds-pwm). Stock
# Asahi initramfs images do not carry those two modules, so the keys stay
# dark while you type the LUKS passphrase. This adds a small dracut module
# that puts both drivers plus one udev rule in the initramfs; the rule sets
# kbd_backlight to max_brightness as soon as it appears. Nothing in the
# initramfs dims it, so it stays on for as long as the prompt waits.
#
#     sudo ./install.sh               install, rebuild every initramfs, verify
#     sudo ./install.sh --uninstall   remove, rebuild every initramfs
#     ./install.sh --check            status only (sudo to inspect images)
#
# Every kernel in /boot is rebuilt, and so is the 0-rescue image: with the
# dracut arguments it was first built with (read from the image itself), to
# .new, checked, and only then swapped in. A host-only rescue stays host-only.
# ============================================================================
set -euo pipefail

NAME="asahi-kbd-backlight"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dracut/90${NAME}"
MOD_DEST="/usr/lib/dracut/modules.d/90${NAME}"
CONF_DEST="/etc/dracut.conf.d/90-${NAME}.conf"
RULE="90-${NAME}.rules"

if [[ -t 1 ]]; then C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_N=$'\e[0m'
else C_G=""; C_Y=""; C_R=""; C_B=""; C_N=""; fi
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_N" "$*"; }
info() { printf '  %s•%s %s\n' "$C_B" "$C_N" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_N" "$*" >&2; }
die()  { printf '  %s✗%s %s\n' "$C_R" "$C_N" "$*" >&2; exit 1; }

# Strict arguments: anything unrecognised is an error, never an install.
MODE="install"
case "${1:-}" in
    "")          ;;
    --uninstall) MODE="uninstall";;
    --check)     MODE="check";;
    -h|--help)
        /usr/bin/sed -n '/^# extras\/kbd-backlight\/install.sh — /,/^# .new, checked/p' "${BASH_SOURCE[0]}" | /usr/bin/sed 's/^# \{0,1\}//'
        exit 0 ;;
    *) die "unknown option: $1 (no argument installs; --uninstall; --check; --help)";;
esac
[[ $# -le 1 ]] || die "unexpected argument: $2"

[[ $MODE == check || $EUID -eq 0 ]] || die "run as root: sudo $0${1:+ $1}"

# ── preflight ────────────────────────────────────────────────────────────────
[[ $(uname -m) == aarch64 ]] || die "not aarch64 — this is for Asahi Linux on Apple Silicon."
/usr/bin/tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null | /usr/bin/grep -q '^apple,' \
    || die "device tree is not Apple Silicon."
command -v dracut >/dev/null || die "dracut not found."

# Kernels that boot: one per /boot/vmlinuz-*. 0-rescue is rebuild_rescue()'s.
kernels() {
    local v k
    for v in /boot/vmlinuz-*; do
        [[ -e $v ]] || continue
        k=${v#/boot/vmlinuz-}
        [[ $k == 0-rescue-* ]] && continue
        [[ -d /lib/modules/$k ]] && echo "$k"
    done
    return 0
}

has_light() {   # $1 = initramfs image path
    local img="$1" list
    [[ -r $img ]] || return 1
    list=$(lsinitrd "$img" 2>/dev/null) || return 1
    /usr/bin/grep -q "etc/udev/rules.d/$RULE" <<<"$list" &&
    /usr/bin/grep -q 'pwm-apple\.ko' <<<"$list" &&
    /usr/bin/grep -q 'leds-pwm\.ko' <<<"$list"
}

# Rescue image: rebuilt with the arguments it was built with (dracut keeps
# them in usr/lib/dracut/build-parameter.txt), to .new, checked, swapped in.
rebuild_rescue() {
    local img old_args kver new need avail i mods
    local -a args=() keep=()
    for img in /boot/initramfs-0-rescue-*.img; do
        [[ -e $img ]] || continue
        kver=$(lsinitrd "$img" 2>/dev/null | /usr/bin/grep -oE 'usr/lib/modules/[^/]+/' | /usr/bin/head -1 | /usr/bin/cut -d/ -f4 || true)
        if [[ -z $kver || ! -d /lib/modules/$kver ]]; then
            warn "rescue: modules for '${kver:-unknown}' not installed — ${img##*/} left alone"; continue
        fi
        old_args=$(lsinitrd -f usr/lib/dracut/build-parameter.txt "$img" 2>/dev/null || true)
        old_args=${old_args#Arguments: }
        if [[ -n $old_args ]]; then
            readarray -t args < <(/usr/bin/xargs printf '%s\n' <<<"$old_args")
        else
            args=(--no-hostonly --no-uefi -a rescue)   # stock 51-dracut-rescue recipe
        fi
        keep=()                                        # drop --kver/--force; set below
        for ((i = 0; i < ${#args[@]}; i++)); do
            case ${args[i]} in
                --kver) i=$((i + 1)) ;;
                --kver=*|-f|--force) ;;
                *) keep+=("${args[i]}") ;;
            esac
        done

        need=$(( $(/usr/bin/stat -c %s "$img") / 1024 + 20480 ))
        avail=$(/usr/bin/df --output=avail -k /boot | /usr/bin/tail -1)
        if (( avail < need )); then
            warn "rescue: /boot has ${avail} KiB free, need ${need} — ${img##*/} left alone"; return 1
        fi

        new="$img.new"
        info "rebuilding rescue initramfs ($kver): dracut ${keep[*]}"
        if ! dracut --force "${keep[@]}" --kver "$kver" "$new" >/dev/null; then
            /usr/bin/rm -f -- "$new"; warn "rescue: dracut failed — old image left in place"; return 1
        fi
        # Captured first: `lsinitrd | grep -q` under pipefail reads as "no match"
        # when grep exits before lsinitrd has finished writing (SIGPIPE).
        mods=$(lsinitrd -f usr/lib/dracut/modules.txt "$new" 2>/dev/null || true)
        if ! /usr/bin/grep -qx rescue <<<"$mods"; then
            /usr/bin/rm -f -- "$new"; warn "rescue: new image lacks the rescue module — old image left in place"; return 1
        fi
        if [[ -d $MOD_DEST ]] && ! has_light "$new"; then
            /usr/bin/rm -f -- "$new"; warn "rescue: new image lacks the backlight module — old image left in place"; return 1
        fi
        /usr/bin/chmod 600 -- "$new"
        /usr/bin/mv -f -- "$new" "$img"
        ok "${img##*/}"
    done
    return 0
}

rebuild() {
    local k fail=0
    for k in $(kernels); do
        info "rebuilding initramfs for $k"
        if dracut -f --kver "$k" >/dev/null; then ok "initramfs-$k.img"
        else warn "dracut failed for $k (old image left in place)"; fail=1; fi
    done
    rebuild_rescue || fail=1
    return $fail
}

status() {
    local k img
    if [[ -d $MOD_DEST ]]; then ok "dracut module: $MOD_DEST"; else info "dracut module: not installed"; fi
    if [[ -f $CONF_DEST ]]; then ok "dracut conf:   $CONF_DEST"; else info "dracut conf:   not installed"; fi
    for k in $(kernels); do
        if [[ $EUID -ne 0 ]]; then info "initramfs-$k: run with sudo to inspect"; continue; fi
        if has_light "/boot/initramfs-$k.img"; then ok "initramfs-$k: lit at LUKS prompt"
        else info "initramfs-$k: not included"; fi
    done
    for img in /boot/initramfs-0-rescue-*.img; do
        [[ -e $img && $EUID -eq 0 ]] || continue
        if has_light "$img"; then ok "${img##*/}: lit at LUKS prompt"; else info "${img##*/}: not included"; fi
    done
    if [[ -e /sys/class/leds/kbd_backlight ]]; then
        info "kbd_backlight now: $(< /sys/class/leds/kbd_backlight/brightness)/$(< /sys/class/leds/kbd_backlight/max_brightness)"
    fi
}

case $MODE in
check)
    status
    ;;
install)
    [[ -e /sys/class/leds/kbd_backlight ]] \
        || die "no /sys/class/leds/kbd_backlight — this Mac has no keyboard backlight Linux can drive (desktop Mac?)."
    for m in pwm-apple leds-pwm; do
        modinfo -k "$(uname -r)" "$m" >/dev/null 2>&1 || die "kernel module $m missing for $(uname -r)."
    done
    [[ -f $SRC/module-setup.sh && -f $SRC/$RULE ]] || die "source files missing under $SRC"

    /usr/bin/install -D -m 755 "$SRC/module-setup.sh" "$MOD_DEST/module-setup.sh"
    /usr/bin/install -D -m 644 "$SRC/$RULE"           "$MOD_DEST/$RULE"
    ok "installed $MOD_DEST"
    printf '# %s: keyboard backlight at 100%% at the LUKS prompt\nadd_dracutmodules+=" %s "\n' \
        "$NAME" "$NAME" > "$CONF_DEST"
    /usr/bin/chmod 644 "$CONF_DEST"
    ok "installed $CONF_DEST"

    rebuild || die "one or more initramfs rebuilds failed — see above."
    k=$(uname -r)
    if [[ -e /boot/vmlinuz-$k ]]; then
        if has_light "/boot/initramfs-$k.img"; then ok "verified: initramfs-$k.img has both drivers and the rule"
        else die "verification failed: initramfs-$k.img is missing the module or rule."; fi
    fi
    ok "done — the keyboard lights at 100% at the next LUKS prompt. Future kernels pick it up automatically."
    ;;
uninstall)
    /usr/bin/rm -rf -- "$MOD_DEST"
    /usr/bin/rm -f  -- "$CONF_DEST"
    ok "removed $MOD_DEST and $CONF_DEST"
    rebuild || die "one or more initramfs rebuilds failed — see above."
    ok "uninstalled."
    ;;
esac
