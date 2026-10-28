# Creating and Booting a Fedora Asahi Live USB

`luks-deploy.sh` must run from outside the system it is encrypting — it refuses
to encrypt the filesystem it is booted from. This is how to build that USB and
boot it.

If the stick will not boot, **start with [`usb start`](#if-the-usb-will-not-boot)**;
if that genuinely gets you nowhere, a second minimal Asahi install on the
internal disk does the same job — see
[SECOND-INSTALL.md](SECOND-INSTALL.md).

---

## The Apple Silicon prerequisite

> **A Mac with only macOS installed cannot boot a USB drive at all.**

Apple's iBoot will not boot arbitrary removable media. USB booting only becomes
possible once **m1n1 + U-Boot** are installed on the *internal* drive — which is
exactly what the Asahi installer puts there.

For this repo that is a non-issue: you already have Fedora Asahi installed, so
m1n1 and U-Boot are already on the internal NVMe, and U-Boot can boot USB media.
But it means you cannot use this tooling to encrypt a system that does not exist
yet — install Fedora Asahi Remix first, then encrypt it.

### M3: m1n1 1.9.1 or later

On an **M3 MacBook Air** with m1n1 1.6.x, U-Boot finds **no USB mass storage
at all**: `usb start` reports no storage device, whatever stick and port you
try. On the M3 the USB ports are reached over SPMI rather than I2C, and the
m1n1 that understands this is **1.9.1**. Upgrading m1n1 fixes it; nothing in
AsahiLocker or the stick is at fault. Reported and solved by
[@ljrk0](https://github.com/ljrk0) in
[issue #4](https://github.com/doug445/AsahiLocker/issues/4).
The MacBook Pro 14" M3 (`j504`) and the M3 iMac use the same chip (`t8122`)
and are likely affected, but this is unconfirmed. The M3 Pro / Max / Ultra
have not been reported either way.

Check what you are running from Linux. m1n1 records both of its stages in the
device tree:

```bash
for s in 1 2; do tr -d '\0' < /proc/device-tree/chosen/asahi,m1n1-stage$s-version; echo; done
```

The two stages are upgraded separately, and **they carry different risk**.

1. **Stage 2 — do this first.** It lives on the ESP and comes from Fedora's
   `m1n1` package: `sudo dnf upgrade m1n1`, then reboot. Fedora 44 has
   shipped 1.9.9 since October 2026. It is an ordinary package update. Then
   try the stick again.
2. **Stage 1 — the fix reported on the M3 Air.** It lives in the macOS-side
   boot stub and is only changed by the Asahi installer, run from macOS
   (option **`m` — Upgrade m1n1 on an existing OS**). That option then
   repeats the installer's second step: shut down, boot the install from the
   boot picker, and approve it in recoveryOS. The fix in
   [issue #4](https://github.com/doug445/AsahiLocker/issues/4) was this,
   using the development installer (`curl https://alx.sh/dev | sh`). As of
   **October 2026** the regular installer (v0.9.2) still bundles m1n1
   **1.6.1**.

   > **⚠️ This step can leave the install unbootable.** On an **M2 Max** with
   > system firmware 27 (macOS 27), the approval step showed a blue screen
   > saying it was not the correct recoveryOS. It asked for a user name and
   > password, rebooted, and showed the same screen again. It failed four
   > times in a row. On the M3 Air in #4 the upgrade worked; which macOS
   > version that was is not yet known. Read your system firmware version
   > before you start:
   >
   > ```bash
   > tr -d '\0' < /proc/device-tree/chosen/asahi,system-fw-version; echo
   > ```
   >
   > An older stage 2 m1n1 may print `unknown` here.
   >
   > **The way back:** the upgrade does not delete the old stage 1. Pointing
   > the boot back at it made the M2 Max bootable again. See
   > [If the stage 1 upgrade loops](#if-the-stage-1-upgrade-loops) below.
3. **Or skip the USB altogether** with the
   [second-install route](SECOND-INSTALL.md). It is the route the first
   M3 MacBook Air encryption took.

It is not yet known whether stage 2 alone is enough. If it is, stage 1 never
needs touching for this. `luks-deploy.sh` warns about all of this when it runs
on an installed M3 system (the run that sends you here for a USB stick).

#### If the stage 1 upgrade loops

This procedure recovered the M2 Max. It puts the **old** stage 1 back in use;
it does not install the new one.

**Why it works.** Option `m` does not replace the installed m1n1. It writes
the new one to `Finish Installation.app/Contents/Resources/boot.bin` on the
stub. It then hides the stub as an unfinished install by renaming two files,
so that the next boot of the stub runs step 2. Only step 2's
`kmutil configure-boot` installs the new m1n1. Until that succeeds, the old one
is still the boot object. When step 2 completes, its "Wrapping up" renames the
two files back. Doing those two renames by hand returns the stub to its old,
working m1n1. (Source: the installer's `stub.py` and `step2/step2.sh`.)

Boot **macOS**: hold the power button and pick macOS in the startup picker.
Then open Terminal. Set `V` to the Asahi stub volume, named as it appears in
the startup picker (`ls /Volumes` lists them):

```bash
V="/Volumes/Fedora Asahi"
```

**Check first**, so the fix is not applied to the wrong situation:

```bash
# 1. The stub is in the hidden state -- both files should exist:
ls -la "$V/.IAPhysicalMedia" "$V/System/Library/CoreServices/SystemVersion-disabled.plist"

# 2. The rename targets do not already exist -- both should say "No such file":
ls "$V/IAPhysicalMedia-disabled.plist" "$V/System/Library/CoreServices/SystemVersion.plist"

# 3. An m1n1 was installed before. Get the volume group ID, which the
#    step 2 screen also prints:
grep '^VGID=' "$V/Finish Installation.app/Contents/Resources/step2.sh"
#    ...then the "coih" line must show a hash, not "absent":
sudo bputil -d -v <VGID> | grep -E "coih|Security Mode"
```

**Check 3 is the important one.** If `coih` is `absent`, the original install
never finished step 2, so there is no old m1n1 to go back to. These commands
will not help. Run the installer again and use its repair option (`p`).

**Then undo the two renames.** They are the same two that step 2's "Wrapping
up" makes. Step 2's `kmutil configure-boot` is skipped, so the new m1n1 is
never installed:

```bash
sudo mount -u -w "$V"
sudo mv "$V/.IAPhysicalMedia" "$V/IAPhysicalMedia-disabled.plist"
sudo mv "$V/System/Library/CoreServices/SystemVersion-disabled.plist" "$V/System/Library/CoreServices/SystemVersion.plist"
```

The stub's system volume mounts read-only; the `mount -u -w` makes it writable.

**Afterwards**, `bless --info --getBoot` should show the stub's system volume
(`/dev/diskXs2`). If it does not, choose the Asahi volume as the startup disk
in System Settings → General → Startup Disk. Then reboot.

Good to know:

- **It is safe to repeat.** Running option `m` again hides the stub again, and
  the installer accepts either file name. The new m1n1 waits in
  `Finish Installation.app/Contents/Resources/boot.bin` until a step 2
  succeeds.
- **The file dates are misleading.** A rename does not change a file's
  modification time, so the files still show the original install date.
  `stat -f "%Sc" <file>` shows the change time, which is when option `m`
  renamed them.
- **This does not update m1n1.** It only puts the old one back. An M3 that
  needs the newer m1n1 for USB still has to get step 2 to complete, or use the
  [second-install route](SECOND-INSTALL.md) instead.

---

## Step 1 — Build the USB

Apple Silicon needs an aarch64 image with the Asahi kernel and firmware; a stock
Fedora Everything ISO will not boot. The established tool is
**[leifliddy/asahi-fedora-usb](https://github.com/leifliddy/asahi-fedora-usb)**,
which builds a minimal bootable Fedora Asahi system onto a USB drive with `mkosi`.

You can build it **from your existing Fedora Asahi install** (or any aarch64
Fedora box; on x86_64 you additionally need `qemu-user-static`).

### 1a. Install the build dependencies

```bash
sudo dnf install arch-install-scripts bubblewrap dosfstools e2fsprogs \
                 gdisk mkosi openssl pandoc rsync systemd-container
```

> `mkosi` moves fast and the build script tracks specific versions. Check the
> upstream README for the currently supported range; if your distro's `mkosi` is
> too new, install a known-good version instead:
> ```bash
> python3 -m pip install --user git+https://github.com/systemd/mkosi.git@v25
> ```

### 1b. Clone the builder

```bash
git clone https://github.com/leifliddy/asahi-fedora-usb.git
cd asahi-fedora-usb
```

### 1c. Choosing a drive

Not every USB stick works here, and the ones that fail do not fail gracefully —
they build fine under Linux and are then simply absent from U-Boot. There is no
list of blessed hardware; what there is, is experience:

- **SanDisk drives have been the most reliable** in practice. If you have a
  choice of sticks, start with one.
- **Have a second stick ready.** Swapping the drive is the cheapest test there
  is, and it resolves more of these than any amount of U-Boot poking.
- **Try a different port**, and a **powered hub** if you have one. Some sticks
  draw more at enumeration than the port will give them before U-Boot has
  initialised the controller.
- A drive that works perfectly on a PC tells you nothing about this. U-Boot's
  USB stack is not Linux's, and it is far less forgiving of slow or quirky
  controllers.

None of that is a reason to give up on encrypting the machine: if no stick
works, [SECOND-INSTALL.md](SECOND-INSTALL.md) gets you there without one.

### 1d. Identify your USB drive — carefully

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,VENDOR,LABEL
```

Find the entry matching your USB stick by **size and model**. Confirm it is not
`nvme0n1` — that is the internal drive with macOS and your Fedora install on it.

> **The build script repartitions and erases the entire target device.** Naming
> the wrong device here destroys whatever is on it. Verify twice.

### 1e. Build

Run as a real root shell — the script rejects `sudo` on itself:

```bash
sudo su -
cd /path/to/asahi-fedora-usb
./build.sh -d /dev/sda        # ← substitute YOUR usb device
```

The build downloads a Fedora package set and installs it to the drive; expect
10–30 minutes depending on your connection.

To rebuild onto a drive you have already used, `-w` wipes it without
repartitioning:

```bash
./build.sh -wd /dev/sda
```

### What you get

A 3-partition USB (vfat EFI + ext4 boot + ext4 root) running Fedora Asahi with
the 16 KB-page Asahi kernel. **The root password is `fedora`.**

It ships with everything `luks-deploy.sh` needs — `cryptsetup`, `btrfs-progs`,
`dracut-asahi`, `grub2-efi-aa64`, `grubby`, `e2fsprogs` — plus two handy rescue
helpers:

```bash
/usr/local/sbin/chroot.asahi     # mounts the internal Fedora install at /mnt and chroots in
/usr/local/sbin/umount.asahi     # unmounts it again
```

To get online from the live USB:

```bash
nmcli dev wifi connect <ssid> password <password>
```

### 1f. Copy this tooling onto the USB

Still in the root shell from 1e — no `sudo`:

```bash
./build.sh mount
findmnt mnt_usb          # must print a line; if it prints nothing, stop here
/usr/bin/cp -a /path/to/AsahiLocker mnt_usb/root/
ls mnt_usb/root/AsahiLocker/bin/luks-deploy.sh
sync
./build.sh umount
```

**Do not put `sudo` in front of `build.sh`.** It refuses to run under
`sudo`, prints a one-line notice and exits *successfully*. Nothing is
mounted, and the `cp` then quietly creates `mnt_usb/root/` as an ordinary
folder on your build machine. The stick boots fine with no AsahiLocker on it
([issue #3](https://github.com/doug445/AsahiLocker/issues/3)). The `findmnt`
line catches that.

Note the absolute `/usr/bin/cp` — if your shell aliases `cp` to `cp -i`, an
unnoticed prompt can silently skip files during a recursive copy.

---

## Step 2 — Boot the USB

Three methods, easiest first.

### Method A — add it to the internal GRUB menu (easiest)

With the USB plugged in, run this **on the installed system**:

```bash
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

`os-prober` picks up the USB and adds an entry (e.g. `/dev/sda3`) to your normal
GRUB menu. Reboot, pick it, done.

> **If no USB entry appears**, os-prober is probably disabled — recent Fedora
> defaults to `GRUB_DISABLE_OS_PROBER=true`. Set it to `false` in
> `/etc/default/grub` (and `sudo dnf install os-prober` if the tool is absent),
> re-run the command, and revert the setting afterwards if you prefer. Or skip
> this method entirely and use Method B or C below — they need no config change.

> **Watch the output path.** `-o /boot/grub2/grub.cfg` is correct. Never run
> `grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg` — on Asahi that ESP file must
> stay a small chainload stub, and overwriting it drops an encrypted system into
> a GRUB rescue prompt. That is precisely what `boot-guards/` defends against.

Re-run the same command after you are finished to drop the stale USB entry.

### Method B — U-Boot `eficonfig` (persistent boot order)

Power on with the USB connected and interrupt the autoboot countdown (mash a key
at **"Hit any key to stop autoboot"**) to reach the `=>` prompt.

```text
=> eficonfig
```

Then, in the menu:

1. Choose **"Change Boot Order"**.
2. Put **`usb0`** at the top. The reliable way is to deselect everything except
   `usb0`, hit **Save**, then re-enter "Change Boot Order" (now `usb0` is on top)
   and also select the first **`Fedora`** entry.
3. **Save**, then **Quit** (or press Escape twice) to return to the `=>` prompt.
4. Boot with:

```text
=> run bootcmd
```
or
```text
=> bootd
```

You should land in the USB drive's GRUB menu. With this order saved, the machine
boots the USB when it is plugged in and the internal drive when it is not.

### Method C — U-Boot `bootflow` (one-shot, nothing persisted)

Best when you want to boot the USB exactly once without changing any settings:

```text
=> usb start
=> bootflow scan -l
=> bootflow select <N>     # the entry on usb0 — NOT nvme0, that's the internal disk
=> bootflow info           # sanity check before committing
=> bootflow boot
```

Full command reference: **[UBOOT-BOOTFLOW.md](UBOOT-BOOTFLOW.md)**

---

## If the USB will not boot

**Do `usb start` before you conclude anything.** This is the single most common
dead end, and it looks convincing: no activity LED on the stick, nothing in
`bootflow scan -l`, the drive apparently unpowered until Linux boots later and
lights it up. That is U-Boot's normal state — the USB subsystem is not
initialised, and the port is not powered, until something asks for it. Nothing
asks for it on its own.

```text
=> usb start          # powers the port and enumerates; prints what it finds
=> usb tree           # the stick should be listed here now
=> bootflow scan -l   # re-scan only after usb start has reported a device
```

If `usb start` prints `0 Storage Device(s) found`, then work through:

1. **Check U-Boot can see it at all:** `bootdev list`. If `usb0` is absent, the
   drive is invisible to U-Boot — no boot method will work.
2. **On an M3, check m1n1 first.** m1n1 older than 1.9.1 leaves U-Boot
   with no USB storage on any stick or port — see
   [M3: m1n1 1.9.1 or later](#m3-m1n1-191-or-later).
3. **Diagnose:** `bootflow scan -ale` lists entries *including* failures and why.
4. **Try another port**, then **another USB stick** — and prefer a SanDisk if
   you have one, they have been the most consistently visible to U-Boot here.
   Plenty of drives enumerate fine under Linux and never appear to U-Boot at
   all; some are simply extremely slow. This is a firmware/controller quirk,
   not a problem with your build. A powered hub sometimes helps where a
   bus-powered stick does not. See
   [Choosing a drive](#1c-choosing-a-drive).
5. **Verify the build actually completed** — re-run `./build.sh -wd /dev/sdX`.

Still nothing? Do not give up on encrypting the machine — take the other route.
A second, minimal Asahi install on the internal NVMe is a supported environment
for `luks-deploy.sh`, and the script has explicit guards for the fact that the
tool and its target then share a disk:
**[SECOND-INSTALL.md](SECOND-INSTALL.md)**.

### Boot starts, then hangs on a `dev-disk-by-uuid` job

GRUB appears, the kernel starts, and then boot stops on a line like:

```text
A start job is running for /dev/disk/by-uuid/d747cb2a-… (… / no limit)
```

where the UUID is the USB's root partition (`sdX3`). U-Boot read the stick
fine — that is how the kernel and initramfs got loaded — but once Linux takes
over, a USB device that was attached at power-on is never enumerated, so the
initramfs waits forever for its root filesystem. This is an Asahi kernel/U-Boot
bug, not a problem with your build:
[AsahiLinux/linux#554](https://github.com/AsahiLinux/linux/issues/554).

**Workaround: unplug the stick and plug it back in while it is hung.** The
replug makes Linux enumerate it, the job completes, and boot continues on its
own. Root is not mounted yet, so this is safe.

It has nothing to do with `resume=` — do not go editing the kernel command line
for it. If the replug does not help, use
**[SECOND-INSTALL.md](SECOND-INSTALL.md)**, which needs no USB at all.

---

## Once booted

Log in as `root` / `fedora`, then continue with
**[INSTALL.md → Step 3](INSTALL.md#step-3--run-the-encryption)**:

```bash
sudo /root/AsahiLocker/bin/luks-deploy.sh
```

If that says `command not found`, the copy in [1f](#1f-copy-this-tooling-onto-the-usb)
never reached the stick.
[INSTALL.md → Step 3](INSTALL.md#step-3--run-the-encryption) shows how to fetch it from the
internal disk without rebuilding.
