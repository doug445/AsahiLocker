# Installation Guide

Encrypting the root filesystem of an installed Fedora Asahi Remix system, start
to finish. Budget **60–90 minutes** including the encryption itself.

You do **not** need to reinstall Fedora, repartition, or move your data. The
existing btrfs filesystem is wrapped in a LUKS2 container in place.

---

## Before you begin

### 1. Confirm your system is a candidate

Run this on the installed system:

```bash
lsblk -f
findmnt -no FSTYPE /
```

You need a **btrfs** root, a separate **ext4 `/boot`**, and a **vfat EFI**
partition. That is the standard Fedora Asahi Remix layout, so unless you
customised your install, you are fine. If your root is already `crypto_LUKS`,
you are already encrypted and there is nothing to do.

### 2. Take a backup — a real one

In-place re-encryption rewrites every sector of the root partition. If it is
interrupted at the wrong moment and the header backup is also lost, the data is
unrecoverable.

"A real backup" means one you have actually browsed or restored from. Verify it:

```bash
borg check /path/to/repo          # if you use borg
# or simply: mount the backup drive and open a few files from it
```

macOS lives on separate APFS partitions and is never touched by this tooling.

### 3. Plug in the charger

The script refuses to start below 50% battery without an explicit override.
Losing power mid-encryption is the main way to lose data here.

### 4. Choose your passphrase now

There is **no TPM on Apple Silicon** and therefore no recovery key. If you forget
this passphrase the data is gone permanently. Pick something strong that you will
still know in a year, and write it down somewhere physically safe before you
start — not on the machine you are about to encrypt.

---

## Step 1 — Build a Fedora Asahi live USB

You need a bootable **Fedora Asahi** USB. A stock Fedora ISO will not work —
Apple Silicon needs an aarch64 image with the Asahi kernel and firmware.

Full instructions, including build dependencies and the exact commands:
**[LIVE-USB.md](LIVE-USB.md)**

The short version, run from your existing Fedora Asahi install:

```bash
sudo dnf install arch-install-scripts bubblewrap dosfstools e2fsprogs \
                 gdisk mkosi openssl pandoc rsync systemd-container

git clone https://github.com/leifliddy/asahi-fedora-usb.git
cd asahi-fedora-usb

lsblk -o NAME,SIZE,TYPE,MODEL,VENDOR       # identify your USB — NOT nvme0n1

sudo su -                                   # the build script rejects `sudo` on itself
./build.sh -d /dev/sda                      # ← substitute YOUR usb device
```

> **`build.sh` erases the entire target device.** Confirm you have the right one.

The root password on the resulting USB is **`fedora`**.

> **Note for Apple Silicon:** a Mac with only macOS cannot boot USB media at all.
> USB booting works because the Asahi installer already put m1n1 + U-Boot on your
> internal drive. Since you are encrypting an existing Asahi install, that is
> already true for you.

### Copy this tooling onto the USB

```bash
sudo ./build.sh mount
sudo /usr/bin/cp -a /path/to/asahi-LUKS2-encrypter mnt_usb/root/
sudo sync
sudo ./build.sh umount
```

> **Why put it on the USB** rather than run it from the internal disk? Otherwise
> the script sits on the very filesystem it is about to encrypt. On the USB it
> stays readable no matter what happens.
>
> Note the absolute `/usr/bin/cp` — if your shell aliases `cp` to `cp -i`, an
> unnoticed prompt can silently skip files during a recursive copy.

Alternatively you can run it from the mounted (not-yet-encrypted) target after
booting the live USB — see Step 3.

---

## Step 2 — Boot the live USB

Easiest method: with the USB plugged in, run this **on the installed system**,
then reboot and pick the new entry from the GRUB menu:

```bash
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

> Watch that output path. `-o /boot/grub2/grub.cfg` is correct; never
> `-o /boot/efi/EFI/fedora/grub.cfg`. On Asahi the ESP file must stay a small
> chainload stub, and overwriting it drops an encrypted system into a GRUB rescue
> prompt.

If you would rather not touch the internal GRUB config, interrupt U-Boot instead
(mash a key at **"Hit any key to stop autoboot"** to reach the `=>` prompt):

```text
=> usb start
=> bootflow scan -l
=> bootflow select <N>     # the entry on usb0, NOT nvme0 (that's the internal disk)
=> bootflow info           # sanity check: confirm it's the USB
=> bootflow boot
```

Both methods, plus a persistent `eficonfig` boot order and what to do when the
USB does not appear: **[LIVE-USB.md](LIVE-USB.md)** ·
**[UBOOT-BOOTFLOW.md](UBOOT-BOOTFLOW.md)**

Log in as `root` with password `fedora`.

---

## Step 3 — Run the encryption

From the live environment:

```bash
sudo /root/asahi-LUKS2-encrypter/bin/luks-deploy.sh
```

Or, if you did not copy it to the USB, mount the target and run it from there:

```bash
sudo mount -o subvol=root /dev/nvme0n1p6 /mnt
sudo /mnt/home/<user>/asahi-LUKS2-encrypter/bin/luks-deploy.sh
```

The script will ask you to choose a KDF profile (see the prompt table below); no
flags are needed. To pick one non-interactively instead:

```bash
sudo LUKS_PROFILE=fast /root/asahi-LUKS2-encrypter/bin/luks-deploy.sh
```

### What it will ask you

The script is interactive but every prompt has a sensible default. In order:

| Prompt | What it means | What to answer |
|--------|---------------|----------------|
| `Are you certain you are in a live/rescue environment?` | Only appears if it *cannot confirm* you booted from live media. If you really did boot the live USB, override. If you are on the installed system, **stop**. | `LIVE` to override, anything else aborts |
| `Continue on battery?` | Below 50% battery, no AC. | Plug in the charger and restart the script. `BATTERY` overrides. |
| `Select [1-N] or device path` | Numbered menu of candidate partitions for root / boot / EFI. Candidates are scored: NVMe is preferred, matching labels score higher, anything on the live USB is heavily penalised. The default is almost always right. | Press Enter to accept the default, or type a number |
| `Accept anyway? (yes/no)` | The chosen partition scored poorly (e.g. it looks like it is on the USB). | `no` unless you are certain |
| `Proceed? (yes/no)` | Your root/boot/EFI selections span different physical disks. | `no` unless that is genuinely your layout |
| `Keep or close? (keep/close)` | `/dev/mapper/fedora_crypt` is still open from an earlier run. | `keep` to reuse it (saves a passphrase prompt when re-running), `close` for a fresh start |
| `Resume the interrupted encryption now?` | The selected root has a LUKS header with an **unfinished** encryption (a previous run was interrupted). | `yes` — the script finishes it with `--resume-only`, then redoes the config phase |
| `Re-run configuration + verification?` | The selected root is fully encrypted already — either a previous run died during the config phase, or you picked a working encrypted system. | `yes` to repair a half-configured install; `no` if the system already boots fine |
| `Type 'MISMATCH' to override` | The BOOT or EFI partition you selected does **not** match the UUID the target's own fstab expects — you probably picked a partition belonging to a different install. | Almost always abort and re-select. Only override if you know the fstab is the thing that is wrong |
| `Continue anyway? (yes/no)` | The BLS boot entries disagree with `/etc/fstab` about which subvolume is root. | `no` — investigate first; see [RECOVERY.md](RECOVERY.md) |
| `Run btrfs integrity check?` | A read-only `btrfs check`. Takes 5–30 min. | **`Y`** — this is your last chance to find pre-existing corruption |
| `Select KDF profile [1-3]` | How hard your passphrase is to brute-force, versus how long you wait at every boot. The script benchmarks your machine and shows a measured estimate for each. All three are argon2id. | `1` aggressive (4 GiB, ~8 s), `2` moderate (2 GiB, ~4 s), `3` fast (1 GiB, ~2 s). Default is `2` |
| `Continue despite btrfs errors?` | The integrity check found problems. | Abort and repair the filesystem first. `FORCE` overrides |
| `Type 'ENCRYPT' to begin` | The point of no return, shown after a full pre-flight summary. In configuration-only mode (already-encrypted root) the word is `CONFIGURE` instead, and nothing is re-encrypted. | Read the summary carefully, then type `ENCRYPT` (or `CONFIGURE`) |
| `Press Enter once Caps Lock is OFF` | Only shown when the kernel reports Caps Lock on at the `ENCRYPT` gate — which is exactly what happens if you switched it on to type that all-caps word. | Turn Caps Lock off, then Enter. `cryptsetup` asks for the passphrase twice, so an inverted one verifies fine and only fails at the boot prompt |
| *LUKS passphrase (twice)* | `cryptsetup` prompting for the new passphrase. | Type it carefully — a typo here becomes your real passphrase |

If the script is interrupted at **any** point — power loss, closed lid, killed
terminal — just boot the live USB and run it again. It detects the interrupted
state and resumes or repairs automatically; see
[RECOVERY.md](RECOVERY.md#encryption-was-interrupted).

### The pre-flight summary

Before the `ENCRYPT` prompt you get a box like this. **Read it.** It is the last
checkpoint:

```
  ROOT    : /dev/nvme0n1p6  (UUID=89cb3d63-..., btrfs)
  BOOT    : /dev/nvme0n1p5  (UUID=725fee20-...)
  EFI     : /dev/nvme0n1p4  (UUID=A1B2-C3D4)
  Subvols : root=root, home=home
  Free    : 184320 MiB
  Arch    : aarch64
  Crypto  : cryptsetup 2.7.5
  Mode    : encrypt
  KDF     : argon2id moderate — 2048 MiB, 8 iterations, 4 threads
```

Confirm `ROOT` is the partition you expect and the subvolumes match your fstab.

### Then wait

Encryption runs for **15–60 minutes** depending on partition size. Progress is
printed continuously. Do not close the terminal, do not let the machine sleep,
do not unplug.

The script runs 8 steps, then a 12-point verification gate. **If any check fails
it tells you and refuses to declare success** — do not reboot until you have
resolved it. See [RECOVERY.md](RECOVERY.md).

Everything is logged to `luks-deploy-<timestamp>.log` next to the script, and
pre-encryption state (fstab, GRUB defaults, kernel cmdline, blkid, BLS entries,
LUKS header) is saved to `pre-luks-state-<timestamp>/` in the same directory.

---

## Step 4 — First encrypted boot

Reboot and remove the USB.

You will be asked for your passphrase early in boot. **The prompt frequently
scrolls behind boot log text** — if the screen looks frozen shortly after GRUB,
it is almost certainly waiting for you. Type the passphrase and press Enter.

Unlock takes a few seconds: argon2id at 4 GiB is deliberately expensive.

If it does not boot, do not panic — nothing is lost yet. Go to
**[RECOVERY.md](RECOVERY.md)**.

---

## Step 5 — Finish on the encrypted system

Once booted encrypted, run:

```bash
sudo ./asahi-LUKS2-encrypter/bin/post-encryption-setup.sh
```

This saves a labeled recovery bundle, creates the snapper snapshot subvolumes
(which must be made *after* encryption so they live on the encrypted volume),
enables the boot guards, and verifies the result. It is idempotent — safe to
re-run.

To also enable your own units afterwards, copy the example config:

```bash
cp bin/post-encryption.conf.example bin/post-encryption.conf
# edit EXTRA_UNITS=( ... ), then re-run the script
```

### Install the boot guards

```bash
sudo ./asahi-LUKS2-encrypter/boot-guards/install.sh
```

Two guards, both worth having on an encrypted Asahi box:

- **ESP stub guard** — `/boot/efi/EFI/fedora/grub.cfg` on Asahi is a tiny 4-line
  stub that chainloads the real config from `/boot`. Plenty of guides tell you to
  run `grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg`, which replaces that stub
  with a full generated config that has no idea how to reach an encrypted root —
  and you land in a GRUB rescue prompt. This guard hashes the stub every 60s and
  restores it if it drifts. The baseline is generated from *your* stub at install
  time, since it embeds your own `/boot` UUID.
- **Stale EFI entry cleaner** — U-Boot auto-registers an EFI boot entry for every
  `shim.efi` it finds on removable media. They persist after you unplug the
  installer USB and produce `can't find boot XXXX` errors. This removes entries
  whose partition is no longer attached.

### Optional: encryption status readout

```bash
sudo ./asahi-LUKS2-encrypter/extras/install.sh
```

Adds `luks-fetch-cache` for fastfetch — an aligned per-volume summary of LUKS and
BitLocker volumes (KDF, cipher, key size). Public header metadata only.

---

## Step 6 — Secure the recovery bundle

`post-encryption-setup.sh` writes a bundle to `/root/LUKS-RECOVERY-<host>-<date>/`
containing the LUKS header, your boot configuration, and a recovery README.

**Copy it off the machine.** Right now it sits on the very drive it protects,
which makes it useless if that drive dies. Put it on an encrypted USB stick or
another machine.

The header contains key *slots*, not your key — it cannot decrypt anything
without your passphrase — but treat it as sensitive anyway.

---

## Step 7 — Verify

```bash
# Root is on a LUKS mapper:
lsblk -f | grep crypt

# KDF is what you asked for:
sudo cryptsetup luksDump /dev/nvme0n1p6
#   → PBKDF: argon2id  Memory: 4194304  Time cost: 10  Threads: 4
#   → AF hash: sha512   Digests: Hash: sha512

# Boot entries carry the LUKS parameters:
grep rd.luks /boot/loader/entries/*.conf

# Nothing broken:
systemctl --failed
```

Then take a fresh backup, so the encrypted box has its own first snapshot with
the new `crypttab`/`fstab`.

---

## Uninstalling the guards

```bash
sudo ./boot-guards/install.sh --uninstall
sudo ./extras/install.sh --uninstall
```

Removing the *encryption* is a different matter: `cryptsetup reencrypt
--decrypt` can do it, but back up first and expect to reverse the fstab,
crypttab, cmdline and BLS changes by hand.
