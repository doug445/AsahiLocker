# Recovery

Every failure mode this tooling can produce, and how to get out of it.

> **Interactive-shell warning.** These commands are typed by hand, often at 3am.
> Many shells alias `cp='cp -i'`, `rm='rm -i'`, `cat=bat`, `find=fd`. An
> interactive prompt you do not notice can silently skip a critical copy. Use
> absolute paths (`/usr/bin/cp -f`) or prefix with `command`.

---

## First: what state are you in?

Boot the Fedora Asahi live USB ([UBOOT-BOOTFLOW.md](UBOOT-BOOTFLOW.md)) and look:

```bash
lsblk -f
sudo cryptsetup luksDump /dev/nvme0n1p6 | head -20
```

| What you see | State | Go to |
|---|---|---|
| Root partition still `btrfs`, no LUKS header | Encryption never started | [Undo the shrink](#encryption-never-started--undo-the-btrfs-shrink) |
| `luksDump` shows a LUKS2 header **and** "online reencryption in progress" | Interrupted mid-encryption | [Resume](#encryption-was-interrupted) |
| Valid LUKS2 header, container opens fine, but the box will not boot | Encryption fine, boot config wrong | [Repair boot config](#encrypted-fine-but-it-will-not-boot) |
| Passphrase accepted, root mounts, then services fail en masse | SELinux mislabels | [Relabel](#first-boot-fails-with-selinux-denials) |
| `luksDump` fails / "device is not a valid LUKS device" | Header damaged | [Restore the header](#corrupt-or-missing-luks-header) |
| Boots to a GRUB `rescue>` prompt | ESP stub was overwritten | [Restore the ESP stub](#grub-rescue-prompt--the-esp-stub-was-overwritten) |

---

## Encryption never started — undo the btrfs shrink

Step 1 shrinks btrfs by 32 MB to make room for the LUKS header. If the script
died between that and the encryption itself, the filesystem is intact but 32 MB
short. Give it back:

```bash
sudo mount /dev/nvme0n1p6 /mnt
sudo btrfs filesystem resize max /mnt
sudo umount /mnt
```

The system boots normally again. Nothing was lost.

---

## Encryption was interrupted

Power loss, a closed lid, a killed terminal. LUKS2 re-encryption is journaled
with checksum resilience precisely for this — it can pick up where it stopped.

**The easy way: just re-run `luks-deploy.sh`.** It reads the LUKS2
`online-reencrypt` requirement flag from the header, offers to resume, finishes
the encryption with `cryptsetup reencrypt --resume-only`, and then runs the
whole configuration + verification phase as if nothing had happened. You will
be asked for the passphrase you set.

By hand, the resume step alone is:

```bash
sudo cryptsetup reencrypt --resume-only /dev/nvme0n1p6
```

If resume reports no re-encryption in progress but the header is valid, the data
phase finished and only the config steps are missing → next section.

---

## Encrypted fine, but it will not boot

The container is good; something in the boot chain does not know about it.

**The easy way: just re-run `luks-deploy.sh`.** When it finds a complete LUKS
header on the selected root, it offers a **configuration-only mode**: it unlocks
the container, redoes every config step (crypttab, fstab, kernel cmdline, GRUB
defaults, BLS entries, dracut config, all initramfs images — all idempotent) and
re-runs the full verification gate. No data is touched.

To do the same by hand instead: open, mount, chroot, and repair.

```bash
# 1. Open the container
sudo cryptsetup open /dev/nvme0n1p6 fedora_crypt

# 2. Confirm the filesystem inside is intact
sudo blkid /dev/mapper/fedora_crypt        # → TYPE="btrfs"

# 3. Mount root (use the subvol from your fstab — usually 'root')
sudo mount -o subvol=root /dev/mapper/fedora_crypt /mnt

# 4. Mount the rest
sudo mount /dev/nvme0n1p5 /mnt/boot
sudo mount /dev/nvme0n1p4 /mnt/boot/efi
for i in dev dev/pts proc sys run; do sudo mount --bind "/$i" "/mnt/$i"; done

# 5. Chroot
sudo chroot /mnt /bin/bash
```

Inside the chroot, check each of the five things that must be right:

```bash
LUKS_UUID=$(cryptsetup luksUUID /dev/nvme0n1p6)
echo "LUKS UUID: $LUKS_UUID"

cat /etc/crypttab              # → fedora_crypt UUID=<LUKS_UUID> none luks,discard
cat /etc/fstab                 # → / and /home on /dev/mapper/fedora_crypt
cat /etc/kernel/cmdline        # → contains rd.luks.uuid= and rd.luks.name=
grep rd.luks /boot/loader/entries/*.conf     # → EVERY entry has both
cat /etc/dracut.conf.d/99-luks.conf          # → add_dracutmodules+=" crypt dm btrfs "
```

Fix whatever is missing:

```bash
# crypttab
echo "fedora_crypt UUID=$LUKS_UUID none luks,discard" >> /etc/crypttab

# kernel cmdline (source of truth for future kernel installs)
echo " rd.luks.uuid=$LUKS_UUID rd.luks.name=$LUKS_UUID=fedora_crypt" >> /etc/kernel/cmdline

# dracut modules
echo 'add_dracutmodules+=" crypt dm btrfs "' > /etc/dracut.conf.d/99-luks.conf

# rebuild every initramfs
dracut --regenerate-all --force

# update every BLS entry
grubby --update-kernel=ALL \
       --args="rd.luks.uuid=$LUKS_UUID rd.luks.name=$LUKS_UUID=fedora_crypt"

# regenerate the real grub.cfg — note the /boot path, NOT the ESP path
grub2-mkconfig -o /boot/grub2/grub.cfg
```

Then exit, unmount, reboot:

```bash
exit
sudo umount -R /mnt
sudo cryptsetup close fedora_crypt
sudo reboot
```

### The two mistakes that cause most non-booting systems

1. **`rd.luks.name` missing.** `rd.luks.uuid` alone creates
   `/dev/mapper/luks-<UUID>`, but fstab says `/dev/mapper/fedora_crypt`. The
   names do not match, root never mounts. You need *both* parameters.
2. **BLS entries not updated.** Fedora uses Boot Loader Specification entries.
   Editing `/etc/default/grub` and running `grub2-mkconfig` does **not** touch
   `/boot/loader/entries/*.conf`. Use `grubby --update-kernel=ALL`.

---

## First boot fails with SELinux denials

Files written from the live environment (crypttab, the dracut conf, edited
fstab) can end up mislabeled — the live system's policy did the labeling, not
the target's. `luks-deploy.sh` runs `restorecon` on everything it touched from
inside the chroot, but if you edited files by hand during a manual repair, the
boot can still die on denials (root mounts, then systemd units fail en masse,
or the boot hangs after the passphrase).

Fix: at the GRUB menu, press `e`, append `enforcing=0` to the `linux` line, and
boot once. Then relabel and re-enable:

```bash
sudo restorecon -RFv /etc /boot
sudo setenforce 1
```

Then reboot normally. (For a full relabel instead: `sudo touch /.autorelabel &&
sudo reboot` — takes a few minutes on first boot.)

---

## Corrupt or missing LUKS header

The header is 16 MB at the start of the partition holding your key slots. Without
it the data is undecryptable — which is why this tooling backs it up in three
places.

Find a backup:

```bash
ls /boot/luks-header-backup.img                      # written by luks-deploy
ls /root/LUKS-RECOVERY-*/luks-header-*.img           # the recovery bundle
ls <live-usb>/pre-luks-state-*/luks-header-backup.img
```

Restore it:

```bash
sudo cryptsetup luksHeaderRestore /dev/nvme0n1p6 \
     --header-backup-file /boot/luks-header-backup.img
```

> A restored header restores the key slots **as they were when it was backed up**.
> If you changed your passphrase since, the *old* passphrase is what works now.

---

## GRUB `rescue>` prompt — the ESP stub was overwritten

Almost always caused by running `grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg`.
On Asahi that file must stay a small chainload stub, not a full config.

From the live USB, mount the EFI partition and restore the stub by hand:

```bash
sudo mount /dev/nvme0n1p4 /mnt/efi
sudo mount /dev/nvme0n1p5 /mnt/boot         # to read the /boot UUID
BOOT_UUID=$(blkid -s UUID -o value /dev/nvme0n1p5)

sudo tee /mnt/efi/EFI/fedora/grub.cfg >/dev/null <<STUB
search --no-floppy --root-dev-only --fs-uuid --set=dev $BOOT_UUID
set prefix=(\$dev)/grub2
export \$prefix
configfile \$prefix/grub.cfg
STUB
sudo sync
```

Install `boot-guards/` afterwards so it cannot happen again.

---

## Passphrase change

If you mistyped during `luksFormat` and want to change it, **pair the change with
the same KDF flags** — otherwise `cryptsetup` silently reverts that keyslot to
its benchmarked defaults (sha256, machine-dependent memory):

```bash
sudo cryptsetup luksChangeKey /dev/nvme0n1p6 \
     --pbkdf argon2id \
     --pbkdf-memory 4194304 \
     --pbkdf-force-iterations 10 \
     --pbkdf-parallel 4 \
     --hash sha512
```

Verify afterwards with `cryptsetup luksDump`, and take a **fresh header backup** —
your old backup no longer matches the current key slots.

---

## Emergency: get the data out without fixing the boot

If you only need your files back:

```bash
sudo cryptsetup open /dev/nvme0n1p6 fedora_crypt
sudo mount -o subvol=home /dev/mapper/fedora_crypt /mnt
# copy /mnt somewhere else, then:
sudo umount /mnt && sudo cryptsetup close fedora_crypt
```

Mount with `-o subvolid=5` instead to see the top level with every subvolume.

---

## Nothing here worked

You cannot brick the Mac — Apple Silicon DFU / System Recovery always works, and
macOS is on separate APFS partitions this tooling never touches. Worst case you
reinstall Fedora Asahi and restore from the backup you took in Step 2.

When asking for help, include:

```bash
sudo cryptsetup luksDump /dev/nvme0n1p6 | head -30
cat /etc/crypttab /etc/fstab /etc/kernel/cmdline
grep options /boot/loader/entries/*.conf
```

plus the `luks-deploy-*.log` from the run.
