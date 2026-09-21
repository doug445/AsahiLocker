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

While the drive is still mounted on your build machine:

```bash
sudo ./build.sh mount
sudo /usr/bin/cp -a /path/to/AsahiLocker mnt_usb/root/
sudo sync
sudo ./build.sh umount
```

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
2. **Diagnose:** `bootflow scan -ale` lists entries *including* failures and why.
3. **Try another port**, then **another USB stick** — and prefer a SanDisk if
   you have one, they have been the most consistently visible to U-Boot here.
   Plenty of drives enumerate fine under Linux and never appear to U-Boot at
   all; some are simply extremely slow. This is a firmware/controller quirk,
   not a problem with your build. A powered hub sometimes helps where a
   bus-powered stick does not. See
   [Choosing a drive](#1c-choosing-a-drive).
4. **Verify the build actually completed** — re-run `./build.sh -wd /dev/sdX`.

Still nothing? Do not give up on encrypting the machine — take the other route.
A second, minimal Asahi install on the internal NVMe is a supported environment
for `luks-deploy.sh`, and the script has explicit guards for the fact that the
tool and its target then share a disk:
**[SECOND-INSTALL.md](SECOND-INSTALL.md)**.

---

## Once booted

Log in as `root` / `fedora`, then continue with
**[INSTALL.md → Step 3](INSTALL.md#step-3--run-the-encryption)**:

```bash
sudo /root/AsahiLocker/bin/luks-deploy.sh
```
