# U-Boot `bootflow` — booting the live USB on Apple Silicon

The boot chain is **iBoot → m1n1 s1 → m1n1 s2 → U-Boot → bootflow → GRUB → Linux**.
`bootflow` (U-Boot's *bootstd* subsystem) is where you manually choose what to boot —
e.g. the Fedora Asahi live USB you need in order to run `luks-deploy.sh`, or a specific kernel when GRUB/BLS
is misbehaving.

## Get to the U-Boot prompt

Interrupt the autoboot countdown: spam a key (any key / `Esc` / `Ctrl-C`) at the
**"Hit any key to stop autoboot"** line. You land at the `=>` prompt.

## Core sequence

```text
bootflow scan -l        # scan every bootdev; list entries as they're found
bootflow list           # re-show the table afterwards (add -e to include errors)
bootflow select 3       # pick by NUMBER — or by NAME: bootflow select usb0.bootdev
bootflow info           # confirm what's selected  (add -d to dump full details)
bootflow boot           # boot the selected entry
```

## `bootflow scan` flags

| flag | meaning |
|------|---------|
| `-l` | **l**ist bootflows as they are scanned |
| `-e` | show **e**rrors for entries that failed to load |
| `-a` | collect **a**ll bootflows, including ones that error |
| `-b` | **b**oot each valid bootflow as it is found |
| `-G` | skip **G**lobal bootmeths |

Handy combos:
```text
bootflow scan -lb       # scan, list, and boot the FIRST valid entry (just-boot-something)
bootflow scan -ale      # DIAGNOSTIC: list everything incl. failures + why they failed
bootflow scan usb0      # scope the scan to a single bootdev (see 'bootdev list')
```

## When the entry you want isn't listed

```text
bootdev list            # which boot devices U-Boot sees (nvme0, usb0, mmc…)
bootmeth list           # active boot methods (extlinux, efi, script, …)
bootflow scan -ale      # show why a device's bootflow failed (missing bootmeth, no ESP, …)
```

## Persist the boot order

```text
env print boot_targets              # current order
env set boot_targets "usb nvme"     # try USB before internal NVMe
env save                            # persist to U-Boot env
```

## The flow for this repo (boot the live USB to encrypt)

```text
=> bootflow scan -l
   # find the entry on the usb0 bootdev (NOT nvme0 = the internal disk)
=> bootflow select <N>       # the usb0 entry
=> bootflow info             # sanity check: it's the USB, not the NVMe
=> bootflow boot
   # → boots Fedora Asahi live → sudo /root/asahi-luks-tooling/bin/luks-deploy.sh
```

## Notes / gotchas

- **`usb start` first** if USB devices don't appear: some builds need
  `usb start` (or `usb reset`) before `bootflow scan` sees `usb0`.
- Selecting by **name** is more stable than by number across reboots — the
  numeric index can shift if a device appears/disappears.
- This is separate from GRUB. U-Boot is the UEFI firmware layer; once bootflow
  hands off to shim/GRUB, use GRUB's own menu and editor. Fedora Asahi normally
  drives GRUB from BLS entries in `/boot/loader/entries/` — which is why
  `luks-deploy.sh` updates those with `grubby` rather than relying on
  `grub2-mkconfig` alone.
- `bootflow boot` on a failed/partial entry returns to the `=>` prompt with an
  error rather than hanging — re-scan with `-ale` to see the reason.

## If the USB never shows up

Some U-Boot builds do not enumerate USB until told to, and some ports are simply
not usable for boot. In order:

1. `usb start` (or `usb reset`), then `bootflow scan -l` again.
2. `bootdev list` — if `usb0` is absent entirely, U-Boot cannot see the drive.
3. Try a different physical port, and a different USB stick. Some controllers
   (notably certain Phison-based drives) enumerate under Linux but stay invisible
   to U-Boot's `bootdev list`. That is a firmware/controller issue, not a problem
   with your install.
4. `bootflow scan -ale` shows *why* a device's bootflow failed.

*Kept alongside the LUKS scripts so it is available on the live USB when you need it.*
