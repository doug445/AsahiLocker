# asahi-luks-tooling

Encrypt the root filesystem of an **already-installed Fedora Asahi Remix** system
on Apple Silicon — in place, without reinstalling, without wiping macOS, and
without a second copy of your data.

`luks-deploy.sh` converts your existing btrfs root partition into a LUKS2
container holding that same filesystem. Your files, subvolumes, snapshots and
btrfs UUID all survive; the partition simply gains an encryption layer. It then
rewrites every piece of boot configuration that has to change (`crypttab`,
`fstab`, `/etc/kernel/cmdline`, GRUB defaults, **all** BLS entries, dracut
config, **all** initramfs images) and refuses to let you reboot until a 10-point
verification gate passes.

Works on every M-series Mac that Asahi supports — M1 / M1 Pro / M1 Max /
M1 Ultra, M2 / M2 Pro / M2 Max, M3, M4. Nothing in the tooling is model-specific:
partitions, subvolumes and boot layout are all auto-detected at runtime.

> **This is destructive-by-nature tooling.** It rewrites a live root filesystem.
> Read [`docs/INSTALL.md`](docs/INSTALL.md) before running anything, and have a
> verified backup. See [Risks](#risks-read-this).

---

## Quick start

```bash
# 1. On the installed system: get the kit, and build a Fedora Asahi live USB
#    to run it from  (see docs/LIVE-USB.md — a stock Fedora ISO will NOT boot)
git clone https://github.com/doug445/asahi-luks-tooling.git

# 2. Boot the live USB. Easiest route, with the USB plugged in:
#      sudo grub2-mkconfig -o /boot/grub2/grub.cfg    # adds it to your GRUB menu
#    then reboot and select it.  (see docs/LIVE-USB.md for the U-Boot routes)

# 3. From the live environment, encrypt the installed root:
sudo ./asahi-luks-tooling/bin/luks-deploy.sh

# 4. Reboot, enter your passphrase, then finish up on the encrypted system:
sudo ./asahi-luks-tooling/bin/post-encryption-setup.sh
sudo ./asahi-luks-tooling/boot-guards/install.sh
```

The deploy script auto-detects your disk layout and shows you what it found. You
confirm the selection, type `ENCRYPT`, and choose a passphrase. Everything after
that is automated, including recovery if a step fails partway.

Full walkthrough: **[docs/INSTALL.md](docs/INSTALL.md)**

---

## What's in here

| Path | What it is |
|------|------------|
| `bin/luks-deploy.sh` | **The main event.** In-place LUKS2 encryption of the installed btrfs root, run from a live USB. Auto-detects everything, self-repairs failed initramfs/BLS steps, and gates the reboot behind 10 verification checks. |
| `bin/post-encryption-setup.sh` | Run once on the newly-encrypted system. Saves a recovery bundle, creates snapper subvolumes on the encrypted volume, enables the boot guards, verifies the result. Idempotent. |
| `bin/save-luks-recovery-bundle.sh` | Assembles a labeled recovery bundle (LUKS header + `crypttab`/`fstab`/`cmdline`/BLS entries + a plain-English recovery README) so you are not dependent on a second USB. |
| `bin/post-encryption.conf.example` | Optional config for the above — snapper subvolumes and any extra units you want enabled post-encryption. |
| `boot-guards/` | Two small Asahi-specific boot guards, plus an installer: **ESP stub guard** (stops a stray `grub2-mkconfig` from bricking an encrypted boot) and **stale EFI entry cleaner** (removes U-Boot's leftover entries for unplugged USB installers). |
| `extras/` | Optional `luks-fetch-cache`: an aligned LUKS/BitLocker status readout for fastfetch. Public header metadata only, no key material. |
| `docs/` | [INSTALL](docs/INSTALL.md) · [LIVE-USB](docs/LIVE-USB.md) · [RECOVERY](docs/RECOVERY.md) · [U-Boot bootflow](docs/UBOOT-BOOTFLOW.md) · [Internals](docs/INTERNALS.md) · [Fleet deployment](docs/FLEET.md) |

---

## How the encrypted boot actually works

```
iBoot → m1n1 stage 1 → m1n1 stage 2 → U-Boot → shim → GRUB → Linux
                                        │                 │
                       provides the UEFI environment      │
                                                          │
                        reads BLS entries from /boot/loader/entries/
                                                          ↓
                                            kernel + initramfs load
                                                          ↓
                                     initramfs reads rd.luks.uuid from the
                                     kernel cmdline, prompts for your
                                     passphrase, opens LUKS, mounts root
```

U-Boot is the firmware/UEFI layer on Apple Silicon; GRUB is the bootloader
running on top of it. Both are in the chain on Fedora Asahi Remix.

**`/boot` stays unencrypted** (plain ext4) so GRUB can read kernels and
initramfs images. The encrypted root is unlocked by the *initramfs*, not by
GRUB. `/boot` encryption is deliberately out of scope — see
[docs/INTERNALS.md](docs/INTERNALS.md#why-boot-stays-unencrypted).

### Layout, before and after

```
nvme0n1
  p1  APFS    iBootSystemContainer
  p2  APFS    macOS  ← untouched
  p3  APFS
  p4  vfat    EFI          → /boot/efi   ← stays plain
  p5  ext4    BOOT         → /boot       ← stays plain
  p6  btrfs   fedora       → / and /home ← becomes LUKS2(btrfs)
  p7  APFS    RecoveryOS
```

Partition *numbers* are auto-detected; this is just the common Asahi shape.

---

## Crypto parameters

Pinned explicitly rather than left to `cryptsetup`'s auto-benchmark, so every box
you deploy to ends up identical instead of picking a machine-dependent memory
cost and sha256.

| Parameter | Value |
|-----------|-------|
| Cipher | `aes-xts-plain64`, 512-bit key (AES-256-XTS) |
| KDF | argon2id (always — no profile selects pbkdf2) |
| Memory cost | 4 / 2 / 1 GiB, by profile |
| Iterations (time cost) | 10 / 8 / 4, by profile |
| Parallelism | 4 threads |
| Hash | sha512 — sets both the AF splitter hash and the LUKS2 volume-key digest |

The KDF re-runs **in the initramfs at every boot**, so the memory cost must be
allocatable there — and you pay its cost as unlock latency on every single boot.

### Choosing a profile

You pay the KDF cost as unlock latency on **every** boot, so the installer asks
you to pick one of three profiles. It **benchmarks your machine first** and shows
a real measured estimate for each — not numbers from someone else's hardware:

```
   1) aggressive    4 GiB, 10 iterations    unlock ~8.5 s
      Strongest. Best if you rarely reboot.

   2) moderate      2 GiB,  8 iterations    unlock ~4.0 s
      Balanced. Still strongly memory-hard.

   3) fast          1 GiB,  4 iterations    unlock ~2.0 s
      Snappy. Comfortable even on an 8 GiB M1.
```

| Profile | Memory | Iterations | Threads |
|---------|--------|-----------|---------|
| `aggressive` (default) | 4 GiB | 10 | 4 |
| `moderate` | 2 GiB | 8 | 4 |
| `fast` | 1 GiB | 4 | 4 |

**All three are argon2id — none uses pbkdf2.** Memory cost only has to be
allocatable in the initramfs, which has the machine to itself, so any profile is
safe on any Asahi-supported Mac including an 8 GiB M1.

The times above were measured on an M2 Max. argon2id is memory-bandwidth-bound,
so a base M1 will be slower for the same parameters — which is exactly why the
installer measures rather than assumes.

Non-interactive selection, for scripted or fleet deployments:

```bash
sudo LUKS_PROFILE=fast ./bin/luks-deploy.sh                     # a named profile
sudo LUKS_PBKDF_MEMORY=1572864 LUKS_PBKDF_ITER=6 ./bin/luks-deploy.sh   # fully custom
```

Setting any `LUKS_PBKDF_*` variable pins the parameters and skips the menu.

**Stay on argon2id.** It is memory-hard, which is the entire point — that is what
makes GPU and ASIC cracking expensive. Never substitute pbkdf2 to save memory or
time; argon2id at 1 GiB is dramatically stronger than pbkdf2 at any iteration
count. Verify what you got with `cryptsetup luksDump /dev/nvme0n1p6`.

> **Note on GRUB and argon2id:** none of this constrains the root volume, because
> GRUB never unlocks it — the initramfs does. It only matters if you have some
> *other* volume that GRUB itself must unlock: GRUB ≥ 2.13 does argon2id but is
> capped by its own heap at roughly 1 GiB memory cost, and GRUB 2.12 (current in
> Fedora 44) has no argon2 support at all. Do not answer that by downgrading the
> volume to pbkdf2 — argon2id at 1 GiB is memory-hard, pbkdf2 is not, and the gap
> matters far more than the memory cost does.

---

## Risks — read this

- **No TPM on Apple Silicon.** There is nowhere to seal a key, so you type the
  passphrase at *every* boot. That is by design, not a limitation of this tooling.
- **Forget the passphrase and the data is gone.** There is no recovery key and no
  backdoor. Back up the recovery bundle *and* remember the passphrase.
- **Have a verified backup before you start.** Not "a backup" — one you have
  actually restored from or browsed. In-place re-encryption rewrites every sector
  of the root partition.
- **You cannot brick the Mac.** Apple Silicon DFU / System Recovery always works,
  and macOS is on separate APFS partitions this tooling never touches. You *can*
  lose the Linux install if encryption is interrupted at the wrong moment — which
  is what the header backups and `--resume-only` recovery path are for.
- **LUKS protects data at rest, not boot integrity.** Only m1n1 stage 1 is
  cryptographically verified on Asahi; `/boot` is unencrypted and unsigned. An
  attacker with repeated physical access could tamper with the initramfs.
- **The passphrase prompt can hide behind boot text.** If the machine looks hung
  right after GRUB, it is probably waiting — type the passphrase and press Enter.

---

## Requirements

- An **already-installed** Fedora Asahi Remix system with a **btrfs** root.
- A **Fedora Asahi live USB** to run the encryption from — the script refuses to
  encrypt the filesystem it is booted from. A stock Fedora ISO will not boot on
  Apple Silicon; build one with
  [`asahi-fedora-usb`](https://github.com/leifliddy/asahi-fedora-usb) as described
  in [docs/LIVE-USB.md](docs/LIVE-USB.md).
- AC power connected (the script enforces AC or >50% battery).
- `cryptsetup` ≥ 2.4 (for `reencrypt --encrypt`), `btrfs-progs`, `dracut`,
  `grubby` — all present in the live environment.
- 15–60 minutes, depending on partition size.

The core script also works on Fedora x86_64, Arch and Manjaro with btrfs roots;
the boot guards and U-Boot documentation are Asahi-specific.

---

## Documentation

| Doc | Covers |
|-----|--------|
| [INSTALL.md](docs/INSTALL.md) | Step-by-step install, start to finish, with what each prompt means |
| [LIVE-USB.md](docs/LIVE-USB.md) | Building a Fedora Asahi live USB, and the three ways to boot it |
| [RECOVERY.md](docs/RECOVERY.md) | Interrupted encryption, unbootable system, corrupt header, undoing a shrink |
| [UBOOT-BOOTFLOW.md](docs/UBOOT-BOOTFLOW.md) | Getting to the U-Boot prompt and booting the live USB |
| [INTERNALS.md](docs/INTERNALS.md) | Every config file changed, the 10-point gate, self-repair, why `/boot` stays plain |
| [FLEET.md](docs/FLEET.md) | Deploying across several M-series boxes, and the UUID-uniqueness footgun |

## License

MIT — see [LICENSE](LICENSE).
