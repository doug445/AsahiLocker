# Boot guards

Two small guards that keep an encrypted Fedora Asahi box booting. Install on the
running system (encrypted or not):

```bash
sudo ./install.sh
sudo ./install.sh --uninstall
```

## esp-grub-stub-guard

`/boot/efi/EFI/fedora/grub.cfg` on Asahi is a four-line **stub** that finds
`/boot` by UUID and chainloads the real `grub.cfg` from there:

```
search --no-floppy --root-dev-only --fs-uuid --set=dev <BOOT_UUID>
set prefix=($dev)/grub2
export $prefix
configfile $prefix/grub.cfg
```

Plenty of guides — and the muscle memory of anyone who has used GRUB on a PC —
say to run `grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg`. On Asahi that
replaces the stub with a **full generated config**, which on an encrypted root
does not know how to reach `/boot`, and you land at a `rescue>` prompt.

The guard hashes the stub at boot and every 60 seconds. If it drifts, the current
copy is preserved as `grub.cfg.broken.<timestamp>`, the known-good stub is
restored, and the event is logged to the journal (`journalctl -t esp-grub-stub-guard`).

The baseline is generated **from your own machine** at install time — the stub
embeds your `/boot` filesystem UUID, so it cannot be shipped. It lives at
`/root/grub-esp-stub.cfg.known-good` with its hash in `/root/grub-esp-stub.sha512`.

Changed the stub deliberately? Re-baseline:

```bash
sudo /usr/local/sbin/esp-grub-stub-rebaseline
```

It refuses to baseline a file longer than 40 lines, since that is a full config
rather than a stub — the exact broken state you would not want pinned.

## clean-stale-efi-entries

U-Boot registers an EFI boot entry for every `shim.efi` it discovers on
removable media — every Fedora installer USB you have ever booted. They
persist after you unplug the drive and produce `can't find boot XXXX` errors
on the U-Boot screen at every boot.

**Where they persist is the whole point.** U-Boot is the firmware here, and it
keeps its non-volatile EFI variables — `Boot####`, `BootOrder` — in one file on
the EFI System Partition: `ubootefi.var` (`lib/efi_loader/efi_var_file.c`). It
reads the file at boot and writes it only from its own boot-time code. What
Linux sees through efivarfs is U-Boot's in-memory runtime copy, and a write to
it — `efibootmgr -B`, `efibootmgr -c` — stops there (`efi_set_variable_runtime`;
the Kconfig help for `EFI_RT_VOLATILE_STORE` says it plainly: *"The OS will be
responsible for syncing the RAM contents to the file, otherwise any changes made
during runtime won't persist reboots"*). Earlier releases of this guard ran
`efibootmgr -B` once per boot, logged *deleted*, and the entries were back the
next boot.

Now the guard edits the file. `uboot-efivar.py` parses it with U-Boot's own
layout (`include/efi_variable.h`: a header with magic, length and CRC32; then
entries of data length, attributes, time, vendor GUID, UTF-16 name, data),
decodes each `Boot####` load option's device path, drops every entry whose GPT
partition GUID is on no attached disk, takes the number out of `BootOrder`,
recomputes the CRC, writes the file atomically and keeps the previous one
beside it (`ubootefi.var.bak-<time>`). Then `efibootmgr -B` runs on the
runtime copy too, so the running system agrees with the file. On real UEFI
firmware (no `ubootefi.var`) efibootmgr is the persistent store and is all
that runs. Only entries that encode a `GPT,<uuid>` device path are considered;
`VenHw` entries (U-Boot's auto NVMe/USB enumeration) and file paths without a
partition GUID are left alone.

```bash
journalctl -t clean-stale-efi                       # what it removed
sudo /usr/local/sbin/uboot-efivar.py list           # every variable in the file, entries decoded
sudo /usr/local/sbin/uboot-efivar.py stale          # what the next run would remove
sudo /usr/local/sbin/uboot-efivar.py --dry-run prune-stale
sudo /usr/local/sbin/uboot-efivar.py remove 0006    # one entry, by number
```

A file U-Boot cannot parse is not a brick: it starts with no variables and
boots the default loader on the stub's own ESP (`EFI/BOOT/BOOTAA64.EFI`), and
shim's fallback re-registers the entry at that boot. The tool never writes a
file it cannot read back, and `tests/uboot-efivar-test.sh` builds one in
U-Boot's layout and takes it through the whole sequence.
