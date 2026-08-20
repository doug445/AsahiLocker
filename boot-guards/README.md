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

U-Boot auto-registers an EFI boot entry for every `shim.efi` it discovers on
removable media — every Fedora installer USB you have ever booted. They persist
in the varstore after you unplug the drive and produce `can't find boot XXXX`
errors on the U-Boot screen.

This runs once per boot and deletes entries whose GPT partition GUID is not
present on any attached disk. It only touches entries encoding a `GPT,<uuid>`
device path; entries using `VenHw` paths (U-Boot's auto NVMe/USB enumeration) or
plain file paths are left alone.

```bash
journalctl -t clean-stale-efi          # what it removed
```
