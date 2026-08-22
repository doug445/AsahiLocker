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
# extras/install.sh — disk-encryption status readout for fastfetch (optional)
# ============================================================================
# Installs luks-fetch-cache: prints an aligned one-line-per-volume summary of
# every LUKS and BitLocker volume attached to the box (KDF, cipher, key size,
# protector types). No key material is ever exposed — only public header
# metadata from `cryptsetup luksDump` / `bitlkDump`.
#
#     sudo ./extras/install.sh              # install + enable the refresh timer
#     sudo ./extras/install.sh --uninstall
#
# After installing, add this to ~/.config/fastfetch/config.jsonc:
#
#   { "type": "command", "key": "Disk Encryption", "text": "luks-fetch-cache 1" },
#   { "type": "command", "key": " ",               "text": "luks-fetch-cache 2" },
#   { "type": "command", "key": " ",               "text": "luks-fetch-cache 3" }
#
# fastfetch's `command` module renders output as a SINGLE line, so an embedded
# newline would escape the logo column. Hence one module per line number; a line
# number past the end prints nothing and fastfetch skips that module.
# ============================================================================
set -uo pipefail

CP=/usr/bin/cp; RM=/usr/bin/rm; CHMOD=/usr/bin/chmod; MKDIR=/usr/bin/mkdir
SYSTEMCTL=/usr/bin/systemctl
G='\033[0;32m'; Y='\033[1;33m'; RED='\033[0;31m'; B='\033[1m'; N='\033[0m'
ok(){ echo -e "  ${G}[ok]${N} $*"; }; warn(){ echo -e "  ${Y}[warn]${N} $*"; }; err(){ echo -e "  ${RED}[fail]${N} $*"; }

[ "$(id -u)" -eq 0 ] || { err "run as root: sudo $0"; exit 1; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN=/usr/local/bin
UNITS=/etc/systemd/system

if [ "${1:-}" = "--uninstall" ]; then
    "$SYSTEMCTL" disable --now luks-fetch-cache.timer luks-fetch-cache.service >/dev/null 2>&1
    "$RM" -f "$UNITS/luks-fetch-cache.timer" "$UNITS/luks-fetch-cache.service"
    "$RM" -f "$BIN/luks-fetch-cache" /var/cache/luks-fetch.txt
    "$SYSTEMCTL" daemon-reload
    ok "luks-fetch-cache removed"
    exit 0
fi

echo -e "${B}Installing luks-fetch-cache...${N}"
"$MKDIR" -p "$BIN"
"$CP" -f "$HERE/bin/luks-fetch-cache" "$BIN/luks-fetch-cache" && "$CHMOD" 0755 "$BIN/luks-fetch-cache" \
    && ok "installed $BIN/luks-fetch-cache" || { err "install failed"; exit 1; }
"$CP" -f "$HERE/systemd/luks-fetch-cache.service" "$UNITS/"
"$CP" -f "$HERE/systemd/luks-fetch-cache.timer"   "$UNITS/"
"$SYSTEMCTL" daemon-reload
"$SYSTEMCTL" enable --now luks-fetch-cache.timer >/dev/null 2>&1 \
    && ok "enabled luks-fetch-cache.timer (refreshes every 15 min)" \
    || warn "could not enable luks-fetch-cache.timer"

echo
echo -e "${B}Current readout:${N}"
"$BIN/luks-fetch-cache" | /usr/bin/sed 's/^/    /'
