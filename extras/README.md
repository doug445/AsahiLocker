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
prints nothing and fastfetch skips that module. Add as many as the maximum number
of encrypted volumes you expect.

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
  **1 GiB of argon2id memory is a hard ceiling for them — never exceed it.**
  GRUB is memory-constrained and an allocation failure there means the machine
  does not boot; at exactly 4 GiB a 32-bit overflow in GRUB's `argon2_init`
  wraps the allocation to zero, so it proceeds rather than rejecting the
  parameters. GRUB 2.12 has no argon2 support at all. None of that is a reason
  to drop a volume to pbkdf2 — upgrade GRUB, or keep the volume off GRUB's
  unlock path. The root volume encrypted by this repo is unlocked by the
  initramfs, so it is unaffected either way.
