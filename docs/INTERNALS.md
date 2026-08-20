# Internals

What `luks-deploy.sh` actually does, why each step exists, and what it checks
before it lets you reboot.

---

## The eight steps

| Step | Action |
|------|--------|
| 1/8 | Shrinks btrfs by 32 MB to make room for the LUKS2 header |
| 2/8 | In-place encrypts the partition with LUKS2, checksum resilience enabled so an interrupted run can resume |
| 3/8 | Verifies the LUKS header (`luksDump`), opens the container, confirms btrfs is intact inside and the UUID was preserved |
| 4/8 | Resizes btrfs back to fill the container, mounts a chroot using the auto-detected subvolumes |
| 5/8 | Backs up the LUKS header to `/boot/` **and** to the script's own directory |
| 6/8 | Rewrites `crypttab`, `fstab`, `/etc/default/grub`, `/etc/kernel/cmdline`, dracut config |
| 7/8 | Rebuilds **all** initramfs images (with self-repair), updates **all** BLS entries via `grubby`, regenerates `grub.cfg` |
| 8/8 | 10-point verification gate — blocks the "you may reboot" message until every check passes |

The btrfs UUID is deliberately **preserved** through encryption, so anything
pinning it (fstab, snapshots, backup configs) keeps working.

---

## Every file that changes

```
/etc/crypttab            + fedora_crypt UUID=<LUKS_UUID> none luks,discard
/etc/fstab                 UUID=<btrfs_UUID> → /dev/mapper/fedora_crypt  (/ and /home)
/etc/default/grub        + GRUB_ENABLE_CRYPTODISK=y
                         + GRUB_CMDLINE_LINUX: rd.luks.uuid=… rd.luks.name=…=fedora_crypt
/etc/kernel/cmdline      + rd.luks.uuid=… rd.luks.name=…=fedora_crypt
/boot/loader/entries/*   + rd.luks.uuid + rd.luks.name on EVERY entry's options line
/etc/dracut.conf.d/99-luks.conf   (new) add_dracutmodules+=" crypt dm btrfs "
/boot/initramfs-*.img      rebuilt for every installed kernel
```

Originals are kept as `fstab.pre-luks`, `grub-defaults.pre-luks`,
`kernel-cmdline.pre-luks`, plus a full copy in `pre-luks-state-<timestamp>/`
next to the script.

### Why all four of cmdline, GRUB defaults, BLS entries and crypttab

They are not redundant — each covers a different moment:

- **`/boot/loader/entries/*.conf`** is what GRUB reads *at this boot*. Miss these
  and the kernel never receives `rd.luks.uuid`, so the initramfs never unlocks
  anything. Editing `/etc/default/grub` and running `grub2-mkconfig` does **not**
  update them — Fedora uses BLS. This is the single most common reason a
  hand-rolled LUKS conversion fails to boot.
- **`/etc/kernel/cmdline`** is the source of truth for `kernel-install`. Miss it
  and the *next* kernel update generates a BLS entry with no LUKS parameters —
  the box boots fine today and mysteriously fails weeks later.
- **`/etc/default/grub`** covers a full `grub2-mkconfig` regeneration.
- **`/etc/crypttab`** is what the running system and dracut use to know the mapper
  name.

### Why `rd.luks.name` and not just `rd.luks.uuid`

`rd.luks.uuid` alone opens the container as `/dev/mapper/luks-<UUID>`. But fstab
refers to `/dev/mapper/fedora_crypt`. The device exists under a different name,
root never mounts, and you get a dracut emergency shell. `rd.luks.name=<UUID>=fedora_crypt`
forces the mapper name to match.

---

## The 10-point verification gate

The script will not tell you it succeeded until all of these pass:

| Check | Verifies |
|-------|----------|
| V1 | `crypttab` has `fedora_crypt` with the correct LUKS UUID |
| V2 | `fstab` references `/dev/mapper/fedora_crypt`, with no stale btrfs UUID left |
| V3 | `/etc/default/grub` has `GRUB_ENABLE_CRYPTODISK`, `rd.luks.uuid`, `rd.luks.name` |
| V4 | `/etc/kernel/cmdline` has `rd.luks.uuid` and `rd.luks.name` |
| V5 | **Every** BLS entry in `/boot/loader/entries/` contains `rd.luks.uuid` |
| V6 | A GRUB config exists (BLS `blscfg` or inline LUKS parameters) |
| V7 | Non-rescue initramfs images exist and are larger than 5 MB |
| V8 | A LUKS header backup exists on the target (and, if available, on the USB) |
| V9 | `/etc/dracut.conf.d/99-luks.conf` is present with the `crypt` module |
| V10 | `/dev/mapper/fedora_crypt` is active |

V8's "USB copy" half is a **warning**, not a gate — the authoritative header
backup always goes to `/boot`, so a second USB is never required.

---

## Self-repair

Failures in the fragile steps are retried rather than fatal:

| Failure | Automatic repair |
|---------|-----------------|
| `dracut --regenerate-all` fails | Falls back to rebuilding per kernel |
| Per-kernel dracut fails | Retries with explicit `--add "crypt dm btrfs"` |
| Initramfs lacks cryptsetup | Rebuilds with `--add "crypt dm"`, then `--install /usr/sbin/cryptsetup` |
| `grubby --update-kernel=ALL` fails | Tries kernels individually, then direct `sed` on the BLS entry files |
| Chroot subvol mount fails | Falls back to a `subvolid=5` top-level mount |

Crucially, **old initramfs images are never deleted**. The script uses
`dracut --force` to overwrite in place, so a failed rebuild leaves the previous
working image intact rather than leaving you with zero bootable kernels.

---

## Safety features

| Feature | What it prevents |
|---------|-----------------|
| Live-environment check | Encrypting the filesystem you are booted from |
| Battery / AC check | Power loss mid-encryption (refuses below 50% without override) |
| Stale mapper detection | Colliding with a half-finished previous run |
| Same-disk sanity check | Root/boot/EFI selections silently spanning different disks |
| Already-encrypted check | Double-encrypting an already-LUKS partition |
| Subvolume auto-discovery | Modifying the wrong (stale or restored) root subvolume |
| BLS consistency check | Boot entries and fstab disagreeing about which subvolume is root |
| Optional `btrfs check` | Encrypting a filesystem that is already corrupt |
| UUID preservation check | Silent btrfs UUID change breaking fstab and backups |
| Pre-encryption state backup | Having nothing to compare against when repairing |
| Dual header backup | A single point of failure for the LUKS header |
| Cleanup trap | Leaving mounts and mappers dangling after an error |

The cleanup trap also prints a tailored recovery command list on any non-zero
exit, matched to how far the run got.

---

## Why `/boot` stays unencrypted

`/boot` remains plain ext4 so GRUB can read kernels and initramfs images. The
encrypted root is unlocked by the *initramfs*, using `rd.luks.uuid` from the BLS
entry.

Encrypting `/boot` too is a separate and much harder problem: GRUB itself would
have to unlock the container, and GRUB is far more KDF-constrained than the
initramfs. GRUB ≥ 2.13 supports argon2id but is capped by its own heap allocation
at roughly 1 GiB memory cost; GRUB 2.12 — current in Fedora 44 — has no argon2
support at all.

The answer to that is **not** to weaken the KDF. Dropping a volume to pbkdf2 to
satisfy an old GRUB trades a memory-hard KDF for one that GPUs and ASICs chew
through cheaply, which is a far worse outcome than leaving `/boot` unencrypted.
Keeping `/boot` out of GRUB's unlock path entirely — what this tooling does — lets
the root volume keep full-strength argon2id.

Attempting to combine the two on GRUB 2.12 reliably produces boot loops. It is
deliberately out of scope for this tooling.

What this means for your threat model: an attacker with repeated physical access
could modify the unencrypted kernel or initramfs. LUKS here protects **data at
rest** — a lost or stolen machine, or a drive pulled from one — not boot
integrity. There is no Secure Boot chain to lean on either; only m1n1 stage 1 is
cryptographically verified on Asahi.

---

## Apple Silicon specifics

- **No TPM.** Nothing to seal a key against, so the passphrase is entered at every
  boot. This is a platform fact, not a configuration choice.
- **The prompt hides behind boot text.** The passphrase prompt is frequently
  scrolled off by kernel messages. A "hung" boot is usually a waiting prompt.
- **Unlock costs a few seconds.** argon2id at 4 GiB is deliberately expensive.
- **You cannot brick the machine.** DFU and System Recovery always work, and macOS
  sits on separate APFS partitions this tooling never touches.
- **16 KB pages.** Asahi kernels use a 16 KB page size; this affects nothing in the
  LUKS path but explains the `+16k` kernel package suffix you will see.
