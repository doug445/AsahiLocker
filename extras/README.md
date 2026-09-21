# extras — `luks-fetch-cache`

Optional. An aligned, one-line-per-volume summary of every LUKS and BitLocker
encrypted volume attached to the machine, for use as a fastfetch module.

```bash
sudo ./install.sh
sudo ./install.sh --uninstall
```

Example output:

```
nvme0n1p6  LUKS2 argon2id, 4 GiB, 4 threads, t=10, sha512
sdb1       LUKS2 argon2id, 1 GiB, 4 threads, t=8, sha512
sdc2       BitLocker v2 AES-256 XTS, 476.9 GiB, recovery+passphrase
```

Only **public header metadata** is read — `cryptsetup luksDump` and `bitlkDump`
report cipher, key size and KDF parameters. No key material is exposed.

## Wiring it into fastfetch

Add to `~/.config/fastfetch/config.jsonc`:

```jsonc
{ "type": "command", "key": "Disk Encryption", "text": "luks-fetch-cache 1" },
{ "type": "command", "key": " ",               "text": "luks-fetch-cache 2" },
{ "type": "command", "key": " ",               "text": "luks-fetch-cache 3" }
```

fastfetch's `command` module renders its output as a **single line**, so an
embedded newline would escape the logo column and garble every device after the
first. Instead it is called once per line number; asking for a line past the end
prints nothing and fastfetch skips that module.

The script reads that config back. It finds the `command` modules that call it
and takes its layout from them: the first module's `key` and `keyWidth` (or
`display.key.width`) and the `display.separator` give the indent for the
continuation lines, so the alignment follows whatever you name the key — no
constant to keep in step — and the number of modules is the number of lines it
will be asked for. With more encrypted volumes than modules, the last line
carries `(+N more)` rather than dropping them silently. The config is the
calling user's (`$SUDO_USER`'s through `sudo`), else the system one; without one
the defaults are the old ones, 17 columns and unlimited lines. Overrides:
`LUKS_FETCH_CONFIG`, `LUKS_FETCH_KEYPAD`, `LUKS_FETCH_SLOTS`.

`sudo` in the module text is optional. Unprivileged, the script serves the cache
the timer keeps, re-indented for the caller's layout; it never prints a
half-parsed line for a header it was not allowed to read.

## Notes

- The systemd timer refreshes a world-readable cache at `/var/cache/luks-fetch.txt`
  every 15 minutes, so opening a terminal never blocks on a header sweep. The
  sweep probes every block device, which is why the interval is loose — it avoids
  constantly waking idle USB disks.
- Concurrent per-line calls are serialised on a flock, so only the first does the
  actual scan.
- `GRUB_UUIDS` tags volumes that GRUB itself must unlock (as opposed to the
  initramfs) with `(GRUB boot)`. Empty by default:
  `GRUB_UUIDS=" <uuid> " luks-fetch-cache`. Such volumes are KDF-constrained:
  the usable argon2id memory cost is set by the **firmware's** heap and must be
  measured per platform — ~1 GiB on x86 vendor UEFI, 2 GiB measured working
  under U-Boot on an M2 Max (see
  [BOOT-ENCRYPTION-STATUS.md](../docs/BOOT-ENCRYPTION-STATUS.md)). Use 1 GiB as
  the portable default; an allocation failure there means the machine does not
  boot. **Never 4 GiB**: a 32-bit overflow in GRUB's `argon2_init` wraps the
  allocation to zero, so it proceeds rather than rejecting the parameters. GRUB
  2.12 has no argon2 support at all. None of that is a reason to drop a volume
  to pbkdf2 — upgrade GRUB, or keep the volume off GRUB's unlock path. The root
  volume encrypted by this repo is unlocked by the initramfs, so it is
  unaffected either way.
