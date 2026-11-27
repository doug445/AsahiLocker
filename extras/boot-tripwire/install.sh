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
# extras/boot-tripwire/install.sh — report changes made to /boot and the EFI partition while the Mac was off (optional)
# ============================================================================
# Records a sha256 of every file on /boot and the EFI partition at every
# shutdown, on the encrypted root, and compares at every boot. A difference
# goes to the journal and to an alert that stays until you accept it, and a
# desktop notification at every login says so. It detects; it cannot prevent.
# Updates are recorded as they happen, so they are never reported: a
# kernel-install plugin, a dnf hook when dnf's actions plugin is installed, and
# a check inside offline-update boots. See extras/README.md, "boot-tripwire".
#
#     sudo ./install.sh               install, take the first record, enable
#     sudo ./install.sh --uninstall   remove it, record and alert included
#     ./install.sh --help
#
# Idempotent: run it again to update the tool; the record and any alert stay.
# ============================================================================
set -uo pipefail

CP=/usr/bin/cp; RM=/usr/bin/rm; CHMOD=/usr/bin/chmod; MKDIR=/usr/bin/mkdir
SYSTEMCTL=/usr/bin/systemctl
G='\033[0;32m'; Y='\033[1;33m'; RED='\033[0;31m'; B='\033[1m'; N='\033[0m'
ok(){ echo -e "  ${G}[ok]${N} $*"; }; warn(){ echo -e "  ${Y}[warn]${N} $*"; }; err(){ echo -e "  ${RED}[fail]${N} $*"; }

case "${1:-}" in
    ""|--uninstall) ;;
    -h|--help)
        /usr/bin/sed -n '/^# extras\/boot-tripwire\/install.sh —/,/^# Idempotent:/p' "${BASH_SOURCE[0]}" | /usr/bin/sed 's/^# \{0,1\}//'
        exit 0 ;;
    *) err "unknown option: $1 (no argument installs; --uninstall removes; --help)"; exit 2 ;;
esac
[ "$#" -le 1 ] || { err "unexpected argument: $2"; exit 2; }
[ "$(id -u)" -eq 0 ] || { err "run as root: sudo $0"; exit 1; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOL=/usr/local/sbin/asahilocker-boot-tripwire
UNIT=/etc/systemd/system/asahilocker-boot-tripwire.service
AUTOSTART=/etc/xdg/autostart/asahilocker-boot-tripwire.desktop
KHOOK=/etc/kernel/install.d/999-asahilocker-boot-tripwire.install
DNFDIR=/etc/dnf/libdnf5-plugins/actions.d
DNFHOOK=$DNFDIR/asahilocker-boot-tripwire.actions
STATE=/var/lib/asahilocker/boot-tripwire

if [ "${1:-}" = "--uninstall" ]; then
    # disable --now runs the unit's ExecStop (a record) one last time; it is
    # removed with the rest. An unaccepted alert is shown before it goes.
    "$SYSTEMCTL" disable --now asahilocker-boot-tripwire.service >/dev/null 2>&1
    if [ -s "$STATE/ALERT" ]; then
        warn "removing an alert that was never accepted:"
        /usr/bin/sed 's/^/      /' "$STATE/ALERT"
    fi
    "$RM" -f "$UNIT" "$TOOL" "$AUTOSTART" "$KHOOK" "$DNFHOOK" /run/asahilocker/boot-tripwire.verified
    "$RM" -rf "$STATE"
    "$SYSTEMCTL" daemon-reload
    ok "boot tripwire removed"
    exit 0
fi

echo -e "${B}Installing the AsahiLocker boot tripwire...${N}"
mountpoint -q /boot || { err "/boot is not a mounted filesystem here; there is nothing to watch."; exit 1; }
"$CP" -f "$HERE/asahilocker-boot-tripwire" "$TOOL" && "$CHMOD" 0755 "$TOOL" \
    && ok "installed $TOOL" || { err "could not install $TOOL"; exit 1; }
"$CP" -f "$HERE/asahilocker-boot-tripwire.service" "$UNIT" && ok "installed $UNIT"
"$MKDIR" -p "${AUTOSTART%/*}"
"$CP" -f "$HERE/asahilocker-boot-tripwire.desktop" "$AUTOSTART" && "$CHMOD" 0644 "$AUTOSTART" \
    && ok "installed $AUTOSTART (a notification at login, if there is an alert)"
"$MKDIR" -p "${KHOOK%/*}"
"$CP" -f "$HERE/999-asahilocker-boot-tripwire.install" "$KHOOK" && "$CHMOD" 0755 "$KHOOK" \
    && ok "installed $KHOOK (records after every kernel or m1n1 update)"
if [ -d "$DNFDIR" ]; then
    "$CP" -f "$HERE/asahilocker-boot-tripwire.actions" "$DNFHOOK" && "$CHMOD" 0644 "$DNFHOOK" \
        && ok "installed $DNFHOOK (records after every dnf transaction)"
else
    warn "dnf's actions plugin is not installed, so there is no dnf hook. Kernel and m1n1"
    warn "  updates are still recorded, and everything at shutdown; only a crash right after"
    warn "  a GRUB or shim update would be reported. To close that: sudo dnf install"
    warn "  libdnf5-plugin-actions, then run this installer again."
fi
"$SYSTEMCTL" daemon-reload
# Over an earlier install, with no alert waiting, record now: this system is
# running and its own updates since the last check are its own (the earlier
# release did not mark checked boots, so without this the restart below could
# report them). With an alert waiting, nothing is recorded: it stays until it
# is accepted. reenable, not enable: the unit now also starts in offline-update
# boots, and the symlink for that is new.
if "$SYSTEMCTL" is-active -q asahilocker-boot-tripwire.service && [ ! -s "$STATE/ALERT" ]; then
    "$TOOL" record && ok "recorded /boot and the EFI partition as they are now (an upgrade)"
fi
if "$SYSTEMCTL" reenable asahilocker-boot-tripwire.service >/dev/null 2>&1 \
   && "$SYSTEMCTL" restart asahilocker-boot-tripwire.service; then
    ok "enabled asahilocker-boot-tripwire.service (checks at boot, offline-update boots too; records at shutdown)"
else
    err "could not start asahilocker-boot-tripwire.service: systemctl status asahilocker-boot-tripwire.service"
    exit 1
fi
echo
"$TOOL" status | /usr/bin/sed 's/^/    /'
echo
echo "Check any time with:  $TOOL status"
echo "From a live USB, the check that does not trust this system (extras/README.md):"
echo "    sudo $HERE/asahilocker-boot-tripwire verify /mnt"
