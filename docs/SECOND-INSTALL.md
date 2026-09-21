# Encrypting from a second Asahi install

The live USB is the recommended way to run `luks-deploy.sh`. This is the other
way: install a second, minimal Fedora Asahi alongside your real one, boot
that, encrypt from there, then delete it and give the space back to macOS.

It exists because the live USB route has a hard dependency on something Apple
Silicon is not reliable about — U-Boot enumerating a USB mass storage device.
When a stick never lights up at the U-Boot prompt, no amount of `bootflow`
juggling helps, and a 20 GiB sibling install on the internal NVMe is the
dependable way through.

> **Before you commit to this: try `usb start`.**
> By far the most common reason a stick looks dead at the `=>` prompt is that
> U-Boot has not enumerated (or powered) the port yet. It does not do so until
> something asks it to, so a drive with no activity LED and no entry in
> `bootflow scan -l` is the expected state *before* `usb start`, not evidence
> that the machine cannot boot USB.
> ```text
> => usb start          # power + enumerate; prints the devices it finds
> => usb tree           # confirm the stick is actually there
> => bootflow scan -l   # now re-scan
> ```
> Only if `usb start` reports no storage devices — after trying another port
> and another stick — is this document the right answer. See
> [LIVE-USB.md](LIVE-USB.md#if-the-usb-will-not-boot).

---

## What you are building

Your disk starts out looking roughly like this, and gains a third install in
the middle:

```text
  macOS container            ~246 GB      ← shrink this by 20 GB
  AsahiRecovery  EFI/boot/root  20 GB     ← the new minimal install
  Fedora         EFI/boot/root ~256 GB    ← the system you want encrypted
```

The minimal install is disposable. It never holds your data, it gets deleted
at the end, and macOS reclaims its space.

---

## Step 1 — Install the second Asahi

Run the standard Asahi installer **from macOS**, exactly as you did the first
time:

```bash
curl https://alx.sh | sh
```

At the prompts:

- **Resize the macOS container** down by 20 GB. (The installer offers to do
  this; do not resize the Fedora container.)
- Choose **Fedora Asahi Remix … Minimal** into that free space.
- Name it something unmistakable — `AsahiRecovery` — so you can tell the two
  installs apart later, both in the boot picker and in the partition menus.

20 GB is comfortable; the minimal image itself needs far less, and the
installer will refuse a size it considers too small.

The newly installed system becomes the **default boot target**. To boot
anything else from now on, hold the **power button** through startup until
"Loading startup options…" appears, then pick the one you want. That is also
how you get back into macOS at the end.

## Step 2 — Bring the minimal install up

It drops you at a text console with a first-boot setup. A root password is
enough; you do not need a user account.

Then get networking and `git`:

```bash
nmcli device                                          # is the wifi radio there?
nmcli device wifi connect <SSID> password '<secret>'  # or: nmtui
dnf install -y git
git clone https://github.com/doug445/AsahiLocker.git
```

## Step 3 — Encrypt the *other* install

```bash
sudo ./AsahiLocker/bin/luks-deploy.sh
```

This is the part that needs your attention, because for the first time both
the tool and the target live on the same disk. The script knows it:

- It reports `Environment: installed` and names the partition you booted from.
- Every partition this minimal install is using — its root, its `/boot`, its
  ESP, its swap — is listed as **`IN USE by this running system`**, is never
  the recommended default, and **cannot be selected**. Typing its device path
  in by hand is refused too.
- `ROOT`, `BOOT` and `EFI` default to your real install. The root default
  prefers the larger of two same-labelled candidates; `BOOT` and `EFI` then
  default to the partitions immediately below the root you chose, which on an
  Asahi layout are that install's own.
- Before the KDF benchmark it prints both systems side by side and asks you to
  type `SIBLING`:

  ```text
    Running FROM  : /dev/nvme0n1p9  [fedora]  20G
    Encrypting    : /dev/nvme0n1p6  [fedora]  250G
  ```

  The second line is the system that will ask for a passphrase at boot. If
  they are the wrong way round, abort.
- Later, the target's own `/etc/fstab` is read and the `BOOT` and `EFI` UUIDs
  are cross-checked against it. Picking another install's boot partition stops
  the run.

Everything after that is identical to the live-USB route:
[INSTALL.md → Step 3](INSTALL.md#step-3--run-the-encryption).

## Step 4 — Get the recovery material off this install

**Do this before you delete anything.**

On the live-USB route the LUKS header backup, the pre-encryption state and the
recovery key land on the stick, which you keep. Here they land in
`AsahiLocker/pre-luks-state-<timestamp>/` on a partition you are about to
erase. The script warns about this at the end; act on it.

```bash
# the encrypted target is still mounted at /mnt when the script finishes
/usr/bin/cp -a /root/AsahiLocker/pre-luks-state-* /mnt/root/
```

A USB stick is better still — this is the material that gets you back in if
the header is ever damaged, and keeping the only copy on the encrypted disk it
unlocks defeats the point. See
[INSTALL.md → Step 6](INSTALL.md#step-6--secure-the-recovery-bundle).

## Step 5 — Verify before you burn the bridge

Reboot (hold **power** to reach the boot picker) into the encrypted install,
enter the passphrase, and finish the normal post-encryption steps. Only once
it boots reliably on its own should you remove the minimal install — while it
still exists it is a working rescue environment for exactly the problems a
half-configured LUKS setup produces.

## Step 6 — Remove the minimal install from macOS

Boot macOS by holding the **power button** through startup.

**First, change the default boot target.** System Settings → General →
Startup Disk → pick your encrypted Fedora. If you delete the install that is
still the default, you are left picking the boot target by hand every time.

Then follow the Asahi Linux
[Partitioning Cheat Sheet](https://asahilinux.org/docs/platform/partitioning-cheatsheet/).
Use `diskutil` on the command line. **Do not use the graphical Disk Utility**
— Asahi's documentation is explicit that it mishandles non-standard layouts
and can damage them.

```bash
diskutil list                # read this carefully; do it before every command
```

The shape of it is:

1. Delete the minimal install's **stub APFS container** — the synthesized
   `/dev/diskN` whose volume is named after that install:
   `diskutil apfs deleteContainer diskN`
2. Erase its three **partitions** (EFI, boot, root) back to free space, one at
   a time: `diskutil eraseVolume free free disk0sN`
3. Grow the macOS container into the gap:
   `diskutil apfs resizeContainer disk0s2 0`

> **Every one of those identifiers will be different on your machine, and
> macOS renumbers synthesized disks between boots.** Re-run `diskutil list`
> and re-read it before each command. Each Asahi install owns its *own* stub
> container; deleting the wrong one takes out the bootloader of the install
> you meant to keep. Cross-check against `lsblk -f` from Linux, or against the
> partition list the Asahi installer prints, before you delete anything.

Removing the partitions also removes the entry from Startup Options — Apple
Silicon cleans those up with the container, so you are not left with a stale
boot entry.

---

## Why not just run it on the live system?

You cannot encrypt a filesystem from inside itself: `cryptsetup reencrypt`
would be rewriting the blocks the running kernel is reading and writing, and
the half-finished state is not recoverable by re-running anything. The script
refuses outright — this is the one gate with no override word.

## See also

- [LIVE-USB.md](LIVE-USB.md) — the recommended route, and `usb start`
- [UBOOT-BOOTFLOW.md](UBOOT-BOOTFLOW.md) — getting to the `=>` prompt
- [INSTALL.md](INSTALL.md) — the full walkthrough every route shares
- [RECOVERY.md](RECOVERY.md) — when something has already gone wrong
