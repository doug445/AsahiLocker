# extras — `luks-fetch-cache`, `kbd-backlight` and `boot-tripwire`

All three optional. [`kbd-backlight/`](#kbd-backlight--the-keyboard-lit-at-the-passphrase-prompt) and [`boot-tripwire/`](#boot-tripwire--was-boot-changed-while-the-mac-was-off) are at the end.

`luks-fetch-cache` gives an aligned, one-line-per-volume summary of every LUKS and BitLocker
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

## `kbd-backlight/` — the keyboard lit at the passphrase prompt

On a MacBook, the keyboard backlight is dark while you type the LUKS passphrase. This makes it light at 100% at the prompt, and it stays on for as long as the prompt waits.

```bash
sudo ./kbd-backlight/install.sh               # install, rebuild every initramfs, verify
sudo ./kbd-backlight/install.sh --uninstall
./kbd-backlight/install.sh --check            # status (sudo also inspects each image)
```

**Why it is dark:** the backlight is a PWM LED (`pwm-apple` + `leds-pwm`). The stock Asahi dracut configuration does not put either driver in the initramfs, so the LED does not exist until the root is unlocked.

**What it installs:** a dracut module, `/usr/lib/dracut/modules.d/90asahi-kbd-backlight/`. It adds the two drivers and one udev rule, `ATTR{brightness}="$attr{max_brightness}"`, which runs in the initramfs only. It also adds `/etc/dracut.conf.d/90-asahi-kbd-backlight.conf`, so kernel updates include the module. After unlock, `systemd-backlight` and the desktop control the backlight as usual.

**Images it rebuilds:**
- Every kernel in `/boot`.
- The `0-rescue` image. It is rebuilt with the dracut arguments recorded inside it (`usr/lib/dracut/build-parameter.txt`), so a host-only rescue stays host-only. The new image is written to `.new` and replaces the old one only after a check: the `rescue` module and the backlight module must both be present, and `/boot` must have had room. Kernel updates leave an existing rescue image alone, so re-run the installer after rebuilding it by hand.

**Limits:**
- It cannot light a GRUB `cryptomount` prompt for an encrypted `/boot`. That prompt comes before Linux loads its drivers. The root volume this repository encrypts is unlocked in the initramfs, so that prompt is covered.
- It needs a MacBook. Desktop Macs have no `kbd_backlight`, and the installer refuses to run on them.

Also published on its own: [asahi-luks-kbd-backlight](https://github.com/doug445/asahi-luks-kbd-backlight).

## `boot-tripwire/` — was /boot changed while the Mac was off?

`/boot` and the EFI partition cannot be encrypted, and nothing on this platform
verifies them (see [What this protects, and what it does not](../README.md#what-this-protects-and-what-it-does-not)).
Someone with the Mac to themselves could change the initramfs or the boot loader
there to capture the passphrase at the next boot. This does not stop that. It
tells you afterwards.

```bash
sudo ./boot-tripwire/install.sh               # install, take the first record, enable
sudo ./boot-tripwire/install.sh --uninstall
asahilocker-boot-tripwire status              # any time; no root needed
```

**How it works.** At every shutdown it records a sha256 of every file and
symlink on `/boot` and the EFI partition, in `/var/lib/asahilocker/boot-tripwire/`
on the encrypted root, where the record cannot be changed without the
passphrase. At every boot it compares. Updates made while the system runs (a
new kernel, a GRUB or m1n1 update) are recorded at the next shutdown and never
reported. Anything added, changed or removed *between* a shutdown and the next
boot is reported by path: in the journal at critical priority
(`journalctl -t asahilocker-boot-tripwire`), in a desktop notification at every
login, and in `status`, until you accept it. A check of 5,000 files takes well
under a second.

Left out of the record, because they change at every boot by design:
`/boot/grub2/grubenv` (GRUB's boot counters), `ubootefi.var` (U-Boot's
variables), the dot-folders macOS leaves on the EFI partition, and a swap file
on `/boot` if there is one.

**When it reports.** First ask whether it was you. Running the RAM rescue, a
live USB or another install on this Mac changes `/boot` while this system is
off, and so does a crash or power cut after an update but before a clean
shutdown. If so:

```bash
sudo asahilocker-boot-tripwire accept     # shows the changes, clears the alert, records anew
```

If nobody should have touched it, treat the passphrase typed at that boot as
seen. Do not type it on this Mac again until the boot files are known good:
from a live USB you trust, unlock and mount the install (`luks-mount.sh mount`),
reinstall the kernel, GRUB, shim and m1n1 packages into it (`luks-mount.sh
chroot`, then `dnf reinstall`), and change the passphrase and the recovery key
(`cryptsetup luksChangeKey`, `luksAddKey`/`luksKillSlot`).

**The check that does not trust this system.** `check` runs on the system whose
boot files it is checking. From a live USB, compare the install's `/boot` and
EFI partition with its record, or with a copy of the record you keep off the
machine (`sudo cp /var/lib/asahilocker/boot-tripwire/record` to a stick):

```bash
sudo ./bin/luks-mount.sh mount /dev/nvme0n1p6        # /mnt, with its /boot and EFI
sudo ./extras/boot-tripwire/asahilocker-boot-tripwire verify /mnt [/path/to/kept/record]
```

Exit 0 is a match, 2 lists the differences.

**What it cannot do.** Prevent anything: by the time it reports, the changed
initramfs has run and seen the passphrase. Catch someone who knows it is here:
that initramfs runs with the root unlocked and could put the files back, or
rewrite the record, before the check (a record kept off the machine and
`verify` from a live USB close the second gap, not the first). Say what was
done: only which files changed. What it catches is a change that does not cover
its tracks, which is most of them, and every change made from outside this
system.
