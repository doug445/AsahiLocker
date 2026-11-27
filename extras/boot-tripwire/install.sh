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
# See extras/README.md, "boot-tripwire", for what it can and cannot catch.
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
STATE=/var/lib/asahilocker/boot-tripwire

if [ "${1:-}" = "--uninstall" ]; then
    # disable --now runs the unit's ExecStop (a record) one last time; it is
    # removed with the rest. An unaccepted alert is shown before it goes.
    "$SYSTEMCTL" disable --now asahilocker-boot-tripwire.service >/dev/null 2>&1
    if [ -s "$STATE/ALERT" ]; then
        warn "removing an alert that was never accepted:"
        /usr/bin/sed 's/^/      /' "$STATE/ALERT"
    fi
    "$RM" -f "$UNIT" "$TOOL" "$AUTOSTART"
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
"$SYSTEMCTL" daemon-reload
# restart: on a first install this only starts it, and the check takes the
# first record. Over an earlier install the stop records the current state
# (this system is running, so its own changes are its own) and the start
# compares with it. An alert that is waiting stays until it is accepted.
if "$SYSTEMCTL" enable asahilocker-boot-tripwire.service >/dev/null 2>&1 \
   && "$SYSTEMCTL" restart asahilocker-boot-tripwire.service; then
    ok "enabled asahilocker-boot-tripwire.service (records at shutdown, checks at boot)"
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
