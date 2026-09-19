#!/usr/bin/env python3
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
"""uboot-efivar.py — read and edit U-Boot's EFI variable file (ubootefi.var).

On Apple Silicon the firmware is U-Boot, and U-Boot keeps its non-volatile EFI
variables — the Boot#### entries and BootOrder among them — in ONE FILE on the
EFI System Partition: ubootefi.var (lib/efi_loader/efi_var_file.c). It reads
the file at boot and writes it back only from its own boot-time code. A write
from Linux through efivarfs — `efibootmgr -B`, `efibootmgr -c` — reaches only
U-Boot's in-memory runtime copy (efi_set_variable_runtime); nothing writes it
to the file, so the change is gone at the next boot. To delete a boot entry
persistently, edit the file. That is what this does.

File format (include/efi_variable.h, lib/efi_loader/efi_var_mem.c):
    header  u64 reserved, u64 magic "UbEfiVa\\x01" (0x0161566966456255),
            u32 length (whole file), u32 crc32 (everything after the header)
    entry   u32 data_length, u32 attr, u64 time, 16-byte vendor GUID,
            UTF-16LE name NUL-terminated, data, padded to a multiple of 8

Usage:
    uboot-efivar.py [--file PATH] list
    uboot-efivar.py [--file PATH] stale          # Boot#### whose GPT partition is not attached
    uboot-efivar.py [--file PATH] [--dry-run] remove BOOT_NUMBER...
    uboot-efivar.py [--file PATH] [--dry-run] prune-stale
    uboot-efivar.py check                        # exit 0 if the file parses and its CRC matches

--file defaults to ubootefi.var on the mounted ESP (/boot/efi, then /efi).
Every write keeps a copy of the previous file beside it (ubootefi.var.bak-<time>)
and replaces the file atomically. A file U-Boot cannot parse is not fatal to
the machine — U-Boot starts with no variables and boots the default loader on
the stub's own ESP — but this tool never writes a file it cannot read back.
"""
import os
import struct
import subprocess
import sys
import time
import zlib

MAGIC = 0x0161566966456255
HDR = struct.Struct("<QQII")          # reserved, magic, length, crc32
ENT = struct.Struct("<IIQ16s")        # data_length, attr, time, guid
GLOBAL_GUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"


def guid_str(b):
    d1, d2, d3 = struct.unpack("<IHH", b[:8])
    return "%08x-%04x-%04x-%s-%s" % (d1, d2, d3, b[8:10].hex(), b[10:16].hex())


class Var:
    def __init__(self, attr, tm, guid, name, data):
        self.attr, self.time, self.guid, self.name, self.data = attr, tm, guid, name, data

    def encode(self):
        name = self.name.encode("utf-16-le") + b"\0\0"
        body = ENT.pack(len(self.data), self.attr, self.time, self.guid) + name + self.data
        return body + b"\0" * (-len(body) % 8)


def parse(buf):
    if len(buf) < HDR.size:
        raise ValueError("file shorter than its header")
    _, magic, length, crc = HDR.unpack_from(buf, 0)
    if magic != MAGIC:
        raise ValueError("not a U-Boot variable file (bad magic)")
    if length != len(buf):
        raise ValueError("header length %d != file size %d" % (length, len(buf)))
    if zlib.crc32(buf[HDR.size:length]) & 0xFFFFFFFF != crc:
        raise ValueError("CRC32 mismatch")
    out, pos = [], HDR.size
    while pos + ENT.size <= length:
        dlen, attr, tm, guid = ENT.unpack_from(buf, pos)
        p = pos + ENT.size
        end = buf.find(b"\0\0", p)
        # a UTF-16 NUL is 2-byte aligned relative to the name start
        while end != -1 and (end - p) % 2:
            end = buf.find(b"\0\0", end + 1)
        if end == -1:
            raise ValueError("unterminated variable name at %d" % pos)
        name = buf[p:end].decode("utf-16-le")
        p = end + 2
        data = buf[p:p + dlen]
        if len(data) != dlen:
            raise ValueError("truncated data for %s" % name)
        out.append(Var(attr, tm, guid, name, data))
        pos = p + dlen
        pos += -pos % 8
    return out


def build(vars_):
    body = b"".join(v.encode() for v in vars_)
    length = HDR.size + len(body)
    return HDR.pack(0, MAGIC, length, zlib.crc32(body) & 0xFFFFFFFF) + body


def load_option(data):
    """EFI_LOAD_OPTION → (description, [gpt partition guids])"""
    if len(data) < 6:
        return "", []
    attrs, fpl = struct.unpack_from("<IH", data, 0)
    p = 6
    end = data.find(b"\0\0", p)
    while end != -1 and (end - p) % 2:
        end = data.find(b"\0\0", end + 1)
    desc = data[p:end].decode("utf-16-le", "replace") if end != -1 else ""
    p = end + 2 if end != -1 else p
    guids, q, stop = [], p, p + fpl
    while q + 4 <= stop and q + 4 <= len(data):
        t, st, ln = struct.unpack_from("<BBH", data, q)
        if ln < 4:
            break
        if t == 4 and st == 1 and ln >= 42:          # media / hard drive node
            sig, fmt, sigtype = data[q + 24:q + 40], data[q + 40], data[q + 41]
            if fmt == 2 and sigtype == 2:             # GPT, signature is the partition GUID
                guids.append(guid_str(sig))
        if t == 0x7F and st == 0xFF:
            break
        q += ln
    return desc, guids


def is_boot(v):
    return v.name.startswith("Boot") and len(v.name) == 8 and all(c in "0123456789ABCDEFabcdef" for c in v.name[4:]) \
        and guid_str(v.guid) == GLOBAL_GUID


def partition_attached(guid):
    return os.path.exists("/dev/disk/by-partuuid/" + guid.lower())


def find_file():
    for esp in ("/boot/efi", "/efi", "/boot"):
        f = os.path.join(esp, "ubootefi.var")
        if os.path.isfile(f):
            return f
    return None


def main(argv):
    path, dry, args = None, False, []
    i = 0
    while i < len(argv):
        if argv[i] == "--file":
            path = argv[i + 1]; i += 2
        elif argv[i] == "--dry-run":
            dry = True; i += 1
        else:
            args.append(argv[i]); i += 1
    if not args:
        sys.stderr.write(__doc__); return 2
    cmd = args[0]
    path = path or find_file()
    if not path:
        sys.stderr.write("no ubootefi.var on a mounted ESP (not a U-Boot host?)\n"); return 3
    with open(path, "rb") as fh:
        buf = fh.read()
    try:
        vars_ = parse(buf)
    except ValueError as e:
        sys.stderr.write("%s: %s\n" % (path, e)); return 4
    if cmd == "check":
        print("%s: %d variables, %d bytes, CRC ok" % (path, len(vars_), len(buf))); return 0
    if cmd == "list":
        for v in vars_:
            line = "%-14s attr=0x%x %5d bytes" % (v.name, v.attr, len(v.data))
            if is_boot(v):
                desc, guids = load_option(v.data)
                line += "  %r%s" % (desc, "".join("  GPT " + g + (" (attached)" if partition_attached(g) else " (NOT attached)") for g in guids))
            elif v.name == "BootOrder":
                line += "  " + ",".join("%04X" % n for n in struct.unpack("<%dH" % (len(v.data) // 2), v.data[:len(v.data) // 2 * 2]))
            print(line)
        return 0
    stale = []
    for v in vars_:
        if is_boot(v):
            _, guids = load_option(v.data)
            if guids and not any(partition_attached(g) for g in guids):
                stale.append(v.name)
    if cmd == "stale":
        for n in stale:
            print(n)
        return 0
    if cmd == "prune-stale":
        targets = stale
    elif cmd == "remove":
        targets = ["Boot%04X" % int(a, 16) for a in args[1:]]
    else:
        sys.stderr.write("unknown command %s\n" % cmd); return 2
    if not targets:
        print("nothing to remove"); return 0
    names = set(targets)
    kept = [v for v in vars_ if not (is_boot(v) and v.name in names)]
    removed = [v.name for v in vars_ if is_boot(v) and v.name in names]
    if not removed:
        print("no such entries: %s" % " ".join(sorted(names))); return 0
    for v in kept:
        if v.name == "BootOrder" and guid_str(v.guid) == GLOBAL_GUID:
            nums = list(struct.unpack("<%dH" % (len(v.data) // 2), v.data[:len(v.data) // 2 * 2]))
            nums = [n for n in nums if "Boot%04X" % n not in names]
            v.data = struct.pack("<%dH" % len(nums), *nums)
    new = build(kept)
    parse(new)                                   # never write what cannot be read back
    if dry:
        print("would remove %s from %s (%d -> %d bytes)" % (" ".join(removed), path, len(buf), len(new))); return 0
    bak = "%s.bak-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
    with open(bak, "wb") as fh:
        fh.write(buf)
    tmp = path + ".new"
    with open(tmp, "wb") as fh:
        fh.write(new); fh.flush(); os.fsync(fh.fileno())
    os.replace(tmp, path)
    dfd = os.open(os.path.dirname(path) or ".", os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
    print("removed %s from %s (previous file kept as %s)" % (" ".join(removed), path, os.path.basename(bak)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
