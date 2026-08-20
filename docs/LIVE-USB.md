# Creating and Booting a Fedora Asahi Live USB

`luks-deploy.sh` must run from a live environment — it refuses to encrypt the
filesystem it is booted from. This is how to build that USB and boot it.

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

### 1c. Identify your USB drive — carefully

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,VENDOR,LABEL
```

Find the entry matching your USB stick by **size and model**. Confirm it is not
`nvme0n1` — that is the internal drive with macOS and your Fedora install on it.

> **The build script repartitions and erases the entire target device.** Naming
> the wrong device here destroys whatever is on it. Verify twice.

### 1d. Build

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

### 1e. Copy this tooling onto the USB

While the drive is still mounted on your build machine:

```bash
sudo ./build.sh mount
sudo /usr/bin/cp -a /path/to/asahi-LUKS2-encrypter mnt_usb/root/
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

1. **`usb start` first.** Some U-Boot builds do not enumerate USB until told to.
   Then re-run `bootflow scan -l`.
2. **Check U-Boot can see it at all:** `bootdev list`. If `usb0` is absent, the
   drive is invisible to U-Boot — no boot method will work.
3. **Diagnose:** `bootflow scan -ale` lists entries *including* failures and why.
4. **Try another port**, then **another USB stick**. Some controllers enumerate
   fine under Linux but never appear to U-Boot; some are simply extremely slow.
   This is a firmware/controller quirk, not a problem with your build.
5. **Verify the build actually completed** — re-run `./build.sh -wd /dev/sdX`.

---

## Once booted

Log in as `root` / `fedora`, then continue with
**[INSTALL.md → Step 3](INSTALL.md#step-3--run-the-encryption)**:

```bash
sudo /root/asahi-LUKS2-encrypter/bin/luks-deploy.sh
```
