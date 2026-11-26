# Encrypting from a RAM-only rescue

The live USB is one way to run `luks-deploy.sh`, and a
[second Asahi install](SECOND-INSTALL.md) is another. This is the third, and
it needs neither a USB stick nor a second install: `bin/ram-rescue.sh` builds
a rescue image from your own kernel, GRUB boots it, and the system runs
entirely from RAM while `luks-deploy.sh` encrypts the root partition in place.

Nothing is installed alongside your system, nothing is plugged in, and the
macOS side is never touched: no new APFS volume, no m1n1 change. The rescue
is one image in `/boot` and one GRUB entry in a file of its own, and
`ram-rescue.sh remove` takes both away again.

---

## How it works

```text
  GRUB entry "AsahiLocker RAM rescue (encrypt in place)"
    └─ your kernel + /boot/initramfs-asahilocker-rescue.img
         (dracut image: luks-deploy.sh, cryptsetup, btrfs-progs, sgdisk,
          the cracklib dictionary, the `asahilocker` launcher)
    └─ rd.break=pre-mount  →  a root shell in RAM; nothing on the disk mounted
         └─ asahilocker  →  luks-deploy.sh, with root, /boot and EFI pinned
                            by GPT partition UUID  →  in-place encryption
```

`/boot` is a separate ext4 partition and is never encrypted, so the rescue
entry stays bootable at every stage. That is what makes this route survive a
power cut: boot the rescue entry again and type `asahilocker`. The script
sees the `online-reencrypt` flag in the LUKS header, repairs the journal if
the cut left it dirty, and finishes the job.

Three choices make that work at every stage:

- **The rescue finds your partitions by GPT partition UUID**, which stays the
  same before, during and after encryption. The root's filesystem UUID
  does not: it disappears the moment the LUKS header is written.
- **The GRUB entry names `/boot` as the initrd's root device.** That device is
  present in every state of the root partition, so the rescue reaches its
  prompt in seconds after a power cut, with no timeout. Nothing is mounted:
  `rd.break=pre-mount` stops before that.
- **The cracklib dictionary is inside the image.** cryptsetup checks a new
  passphrase in the rescue exactly as it does on the installed system, and
  refuses a weak one.

## Requirements

- The stock Fedora Asahi Remix layout: btrfs root, plus separate ext4 `/boot`
  and EFI partitions. `ram-rescue.sh` checks this and refuses anything else,
  including a root that is already encrypted.
- `gdisk` (for `sgdisk`) and `cracklib-dicts`: `sudo dnf install gdisk
  cracklib-dicts`. `ram-rescue.sh` lists anything else it misses.
- 200 MiB free on `/boot`. The image is about 55 MiB.
- AC power, and a backup. This route rewrites every block of the root
  partition, exactly as the other two do.

RAM is not a concern on any Apple Silicon Mac. The image is small, and the
Argon2id KDF needs at most the memory of the profile you pick (1–4 GiB).

## Step 1 — Build the rescue

On the Mac you are about to encrypt, booted normally:

```bash
git clone https://github.com/doug445/AsahiLocker.git
sudo ./AsahiLocker/bin/ram-rescue.sh build --arm
```

It prints what it found (disk, root, `/boot`, EFI, kernel) before it builds
anything. **Check the `root` line**: that partition is the one the rescue
will encrypt. Then it:

1. builds the image under a temporary name and checks that every tool,
   every kernel module between the root partition and the bus (a driver
   compiled into the kernel needs no file), the dictionary and the launcher
   are really inside it. Only then does it move
   the image into place;
2. writes `/etc/grub.d/42_asahilocker-rescue`, its own file, and regenerates
   `/boot/grub2/grub.cfg`. `40_custom` and any other file of yours are never
   touched. If the entry does not appear in `grub.cfg`, it takes it out again
   and stops;
3. with `--arm`, sets GRUB to boot the rescue **once**, at the next reboot.

The image belongs to this machine and this kernel. If a kernel update
removes that kernel before you use the rescue, `arm` says so; run `build`
again.

## Step 2 — Boot it

```bash
sudo reboot
```

The rescue stops at a `pre-mount:/root#` prompt, under a banner that names
the partition it will encrypt. Fedora locks the root account, so you are not
asked for a password. If you once gave root a password, you are asked for
it here.

## Step 3 — Encrypt

```bash
asahilocker
```

From here it is the normal `luks-deploy.sh` run. The only difference is that
there are no partition menus: the launcher pins root, `/boot` and EFI by
partition UUID. See [INSTALL.md](INSTALL.md) for what each prompt means.
`asahilocker --defaults` takes the recommended answer to every question that
has one, as `luks-deploy.sh --defaults` does.

The rescue also carries `luks-mount`, for looking inside an install without
encrypting anything: `luks-mount list`, then `luks-mount chroot /dev/...` opens
a shell inside it (unlocking it first if it is encrypted) and puts everything
back when you leave.

- **A weak passphrase is refused** ("it is based on a dictionary word"), and
  so are two entries that do not match. Nothing has been written at that
  point; the script checks the partition to prove it, then asks `Try again?`.
  Press Enter and choose another (three attempts in all).
- **An early warning that the script directory is held in RAM.** It is: the
  log, the pre-encryption state and the recovery key live there until the end
  of the run.

Whatever the outcome, the launcher copies the deploy log, `dmesg`, `lsblk`,
dracut's `rdsosreport.txt` and the key-free part of the pre-encryption state
to `/boot/asahilocker-rescue-logs/<time>/`. The files are named one by one:
the recovery key and the LUKS header backup are never among them.

### If the power goes, or the run stops

Boot the Mac, choose **AsahiLocker RAM rescue (encrypt in place)** in the
GRUB menu, and type `asahilocker` again. The `--arm` one-shot is used up, so
you pick the entry by hand; GRUB shows its menu after a boot that did not
finish. The script finds the interrupted encryption and offers to resume it.
If the power cut left the reencryption journal dirty, it asks you to confirm
a `cryptsetup repair` (type `YES`) and asks for the passphrase. The
configuration phase then runs as usual.

## Step 4 — Keep the recovery material

At the end of a successful run, the script copies its whole state directory
onto the encrypted system, to `/root/asahilocker-pre-luks-state-<time>/`, and
tells you so in a box headed **BEFORE you reboot**. It holds the LUKS header
backup, the pre-encryption fstab, GRUB and BLS state and, if you enrolled
one, the recovery key.

**That copy of the recovery key is inside the volume it unlocks.** It is no
use for the one case it exists for: a forgotten passphrase. Before you
reboot, write it down:

```bash
cat /root/AsahiLocker/bin/pre-luks-state-*/recovery-key.txt
```

or, after the first boot, move the directory from `/root` to offline storage.
The header backup is also at `/boot/luks-header-backup.img`.

If a run stops after the recovery key was enrolled but before that copy, the
launcher says so and shows where the only copy is. Write it down, or run
`asahilocker` again before you reboot.

## Step 5 — Reboot into the encrypted system

```bash
reboot -f
```

Enter the passphrase at the prompt. Then finish as on any route:

```bash
sudo ./AsahiLocker/bin/post-encryption-setup.sh
sudo ./AsahiLocker/boot-guards/install.sh
```

`post-encryption-setup.sh` puts the boot splash back. To keep it off, so the
passphrase prompt stays visible at every boot, run it with
`--keep-splash-off`.

No SELinux policy is loaded in the rescue, so nothing written there gets a
label by itself. The deploy labels what it wrote with the installed system's
own policy and reads the labels back, and the rescue's logs take the label of
`/boot`. A system encrypted from the rescue with 3.0.0 or earlier has those
files unlabeled: `post-encryption-setup.sh` from 3.1.0 labels them.

## Step 6 — Remove the rescue

```bash
sudo ./AsahiLocker/bin/ram-rescue.sh remove
```

That removes the image and `42_asahilocker-rescue`, regenerates `grub.cfg`,
and clears the one-shot if it is still set. `/boot/asahilocker-rescue-logs/`
is kept; it holds logs only, so delete it when you like.
`sudo ./AsahiLocker/bin/ram-rescue.sh status` shows what is installed at any
time.

## What is different in RAM

`luks-deploy.sh` treats a `rootfs` root as live media (`ENV_KIND=live`), the
same way it treats a live USB's overlay. On top of that:

| | Live USB | RAM rescue |
|---|---|---|
| Partitions | chosen from menus | pinned by GPT partition UUID |
| Log, state and recovery key | written to the stick | written to RAM, copied into the encrypted `/root` at the end |
| Passphrase quality check | the stick's dictionary | the image's dictionary. Without one, the target's own copy is lent to the run (`/run` + a `pwquality.conf.d` drop-in, removed at exit). Only if neither exists is the check turned off, with a warning |
| `dracut` / `grub2-mkconfig` | on the stick | only inside the target's chroot; the target is checked for them before anything is written |
| Resume after an interruption | boot the stick again | boot the rescue entry again |

## Tested

Tested end to end in a KVM guest running the official Fedora Asahi Remix 45
image, including a power cut in the middle of the encryption and tested and
deployed on a M2 Max. 

## Troubleshooting

| You see | It means |
|---|---|
| `the partitions this rescue was built for are not here` | The rescue only acts on the disk it was built on. It is not portable between Macs. |
| `arm`: `built for kernel …, which is no longer in /boot` | A kernel update removed the rescue's kernel. Run `build` again. |
| No banner, no `asahilocker` command | You booted a normal entry, not the rescue. Check `ram-rescue.sh status`. |
| `Resume still failing after repair` | Do not wipe anything. Run `asahilocker` again; see [RECOVERY.md](RECOVERY.md). |

## See also

- [INSTALL.md](INSTALL.md): the prompts, step by step
- [RECOVERY.md](RECOVERY.md): if something goes wrong
- [SECOND-INSTALL.md](SECOND-INSTALL.md) and [LIVE-USB.md](LIVE-USB.md):
  the other two routes
