#!/usr/bin/env bash
# ============================================================================
# AsahiLocker — in-place LUKS2 disk encryption for Fedora Asahi Remix on Apple Silicon
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
# ============================================================================
# tests/uboot-efivar-test.sh — uboot-efivar.py against a synthetic ubootefi.var
# built with U-Boot's own on-disk layout (include/efi_variable.h): a
# PlatformLang, two Boot#### load options whose device paths carry GPT
# partition GUIDs — one that exists on this machine, one that cannot — and a
# BootOrder naming both. No root, no real ESP.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOL="$HERE/../boot-guards/bin/uboot-efivar.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $*"; }
bad() { fail=$((fail+1)); echo "  FAIL  $*"; }

# a GPT partition GUID this machine really has (any), and one it cannot have
HAVE=$(ls /dev/disk/by-partuuid/ 2>/dev/null | head -1)
GONE=e6b2aca4-214c-4d1e-8531-162686a25ce5
[ -n "$HAVE" ] || { echo "no /dev/disk/by-partuuid entries here — using two absent GUIDs"; HAVE=11111111-2222-4333-8444-555555555555; }

python3 - "$T/v.var" "$HAVE" "$GONE" <<'PY'
import struct, sys, zlib
out, have, gone = sys.argv[1], sys.argv[2], sys.argv[3]
MAGIC = 0x0161566966456255
GG = bytes.fromhex("61dfe48bca93d211aa0d00e098032b8c")   # EFI_GLOBAL_VARIABLE_GUID, little-endian fields
def guid_bytes(s):
    p = s.split("-"); return struct.pack("<IHH", int(p[0],16), int(p[1],16), int(p[2],16)) + bytes.fromhex(p[3]) + bytes.fromhex(p[4])
def entry(name, data, attr=7):
    body = struct.pack("<IIQ16s", len(data), attr, 0, GG) + name.encode("utf-16-le") + b"\0\0" + data
    return body + b"\0" * (-len(body) % 8)
def load_option(desc, part_guid):
    hd = struct.pack("<BBHIQQ", 4, 1, 42, 1, 2048, 1228800) + guid_bytes(part_guid) + bytes([2, 2])
    fp = struct.pack("<BBH", 4, 4, 4 + 2 * (len("\\EFI\\fedora\\shimaa64.efi") + 1)) + "\\EFI\\fedora\\shimaa64.efi".encode("utf-16-le") + b"\0\0"
    end = struct.pack("<BBH", 0x7F, 0xFF, 4)
    path = hd + fp + end
    return struct.pack("<IH", 1, len(path)) + desc.encode("utf-16-le") + b"\0\0" + path
body = entry("PlatformLang", b"en-US\0") + entry("Boot0003", load_option("Fedora", have)) \
     + entry("Boot0006", load_option("Fedora", gone)) + entry("BootOrder", struct.pack("<2H", 6, 3)) + entry("SbatLevel", b"sbat,1\n", attr=3)
hdr = struct.pack("<QQII", 0, MAGIC, 24 + len(body), zlib.crc32(body) & 0xFFFFFFFF)
open(out, "wb").write(hdr + body)
PY

out=$(python3 "$TOOL" --file "$T/v.var" check 2>&1) && grep -q "5 variables" <<<"$out" && ok "synthetic file parses: $out" || bad "check: $out"
lst=$(python3 "$TOOL" --file "$T/v.var" list)
grep -q "Boot0006 .*'Fedora'.*$GONE (NOT attached)" <<<"$lst" && ok "list shows the vanished partition's entry as NOT attached" || bad "list: $lst"
grep -q "BootOrder .*0006,0003" <<<"$lst" && ok "list decodes BootOrder" || bad "BootOrder not decoded: $lst"
st=$(python3 "$TOOL" --file "$T/v.var" stale)
[ "$st" = "Boot0006" ] && ok "stale names exactly the vanished entry" || bad "stale: '$st'"
d=$(python3 "$TOOL" --file "$T/v.var" --dry-run prune-stale) && grep -q "would remove Boot0006" <<<"$d" && ok "dry run removes nothing, says what it would" || bad "dry run: $d"
python3 "$TOOL" --file "$T/v.var" check >/dev/null && ok "file untouched by the dry run" || bad "dry run changed the file"
r=$(python3 "$TOOL" --file "$T/v.var" prune-stale) && grep -q "removed Boot0006" <<<"$r" && ok "prune-stale: $r" || bad "prune: $r"
python3 "$TOOL" --file "$T/v.var" check >/dev/null && ok "rewritten file parses with a valid CRC and length" || bad "rewritten file invalid"
lst=$(python3 "$TOOL" --file "$T/v.var" list)
grep -q "Boot0006" <<<"$lst" && bad "Boot0006 still present" || ok "Boot0006 gone"
grep -q "BootOrder .* 0003$" <<<"$lst" && ok "BootOrder no longer names 0006" || bad "BootOrder: $(grep BootOrder <<<"$lst")"
grep -q "Boot0003 .*'Fedora'" <<<"$lst" && ok "the attached entry survives" || bad "Boot0003 lost"
ls "$T"/v.var.bak-* >/dev/null 2>&1 && ok "previous file kept beside the new one" || bad "no backup"
n=$(python3 "$TOOL" --file "$T/v.var" prune-stale) && [ "$n" = "nothing to remove" ] && ok "second prune is a no-op" || bad "second prune: $n"
printf 'garbage' > "$T/bad.var"; python3 "$TOOL" --file "$T/bad.var" check >/dev/null 2>&1; [ $? -eq 4 ] && ok "a file that is not U-Boot's is refused (exit 4)" || bad "garbage accepted"
# a real file from this machine, when there is one: read-only, must parse
for f in /boot/efi/ubootefi.var /efi/ubootefi.var; do
    [ -r "$f" ] || continue
    python3 "$TOOL" --file "$f" check >/dev/null && ok "this machine's $f parses" || bad "this machine's $f does not parse"
done

echo; echo "uboot-efivar-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
