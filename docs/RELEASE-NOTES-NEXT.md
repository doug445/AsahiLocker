# Notes for the next release (not yet tagged)

These are the notes for the next tagged release. When it is cut, paste them into
`gh release create --notes-file` and delete this file in the same commit.
Proposed number: **3.1.0** (a new optional feature; nothing existing changes).

---

## AsahiLocker 3.1.0: the keyboard is lit at the passphrase prompt

Nothing changes in how a volume is encrypted, in the KDF, or in any volume an earlier release made. If you are already encrypted, there is nothing to redo. The new piece is optional and installs separately.

### `extras/kbd-backlight/`: see the keys while you type the passphrase
On a MacBook running Fedora Asahi Remix, the keyboard backlight was dark at the LUKS passphrase prompt. The backlight is a PWM LED (`pwm-apple` + `leds-pwm`), and the stock Asahi initramfs carries neither driver.

```bash
sudo ./extras/kbd-backlight/install.sh               # install, rebuild every initramfs, verify
sudo ./extras/kbd-backlight/install.sh --uninstall
./extras/kbd-backlight/install.sh --check
```

- A dracut module adds the two drivers and one initramfs-only udev rule that sets `kbd_backlight` to its maximum as soon as it appears. Nothing in the initramfs dims it, so it stays on for as long as the prompt waits.
- Every kernel in `/boot` is rebuilt. Future kernels include the module automatically.
- **The rescue image is rebuilt too**, with the dracut arguments recorded inside it, so a host-only rescue stays host-only. It is written to `.new` and replaces the old image only after a check: the `rescue` module and the backlight module must both be present, and `/boot` must have had room.
- After unlock, `systemd-backlight` and the desktop control the backlight as usual.
- It refuses to run on a desktop Mac (no keyboard backlight) or anywhere that is not Apple Silicon.
- It cannot light a GRUB `cryptomount` prompt for an encrypted `/boot`. That prompt runs before Linux loads its drivers. The root volume AsahiLocker encrypts is unlocked in the initramfs, so that prompt is covered.

Tested on a 14" MacBook Pro (M2 Max), Fedora Asahi Remix 45. The keys were lit at the Plymouth prompt, and the host-only rescue image kept its boot settings and `crypttab` unchanged.

The same tool is published on its own as [asahi-luks-kbd-backlight](https://github.com/doug445/asahi-luks-kbd-backlight).

### Tests
- `cli-smoke-test.sh` covers the new installer: `--help` without root, unknown options refused, a one-line "run as root" (29 checks).
- shellcheck at warning severity covers the new scripts.
