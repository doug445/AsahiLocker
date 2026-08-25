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
| 7/8 | Rebuilds **all** initramfs images (with self-repair), updates **all** BLS entries via `grubby`, regenerates `grub.cfg`, then `restorecon`s every file the deployment wrote (against the *target's* SELinux policy, inside the chroot) |
| 8/8 | 12-point verification gate — blocks the "you may reboot" message until every check passes |

## Resume and re-entrancy

The script never has to be babysat through a failure — re-running it recovers
both interruption classes automatically:

| Where it died | How re-running recovers |
|---|---|
| **Mid-encryption** (power loss, killed terminal) | The LUKS2 header carries the `online-reencrypt` requirement flag. The script detects it, offers to finish with `cryptsetup reencrypt --resume-only`, then continues into the normal config phase. |
| **During the config phase** (steps 5–8) | The header is complete but boot config is half-written. The script offers **configuration-only mode**: it unlocks the container, discovers subvolumes *through the mapper*, skips the shrink/encrypt steps, redoes every config step (all idempotent — fstab conversion, crypttab dedupe, grubby, dracut), and re-runs the full verification gate. Confirmation word is `CONFIGURE` instead of `ENCRYPT`. |
| **Header unreadable** (`luksDump` fails on a `crypto_LUKS` partition) | Refuses with a pointer to `cryptsetup repair` — nothing destructive is attempted. |

A stale open mapper from a previous run can be kept (`keep`) and is reused,
saving a passphrase prompt in config-only mode.

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
                                        add_drivers+=" dm-crypt "
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

## The 12-point verification gate

The script will not tell you it succeeded until all of these pass:

| Check | Verifies |
|-------|----------|
| V1 | `crypttab` has `fedora_crypt` with the correct LUKS UUID |
| V2 | `fstab` references `/dev/mapper/fedora_crypt`, with no stale btrfs UUID left |
| V3 | `/etc/default/grub` has `rd.luks.uuid`, `rd.luks.name` (`GRUB_ENABLE_CRYPTODISK` is a warn — `/boot` is unencrypted, GRUB never opens the LUKS volume) |
| V4 | `/etc/kernel/cmdline` has `rd.luks.uuid` and `rd.luks.name` |
| V5 | **Every** BLS entry in `/boot/loader/entries/` contains `rd.luks.uuid` |
| V6 | A GRUB config exists (BLS `blscfg` or inline LUKS parameters), and the ESP `grub.cfg` is still the chainload **stub**, not a full generated config |
| V7 | Non-rescue initramfs images exist and are larger than 5 MB |
| V8 | A LUKS header backup exists on the target (and, if available, on the USB) |
| V9 | `/etc/dracut.conf.d/99-luks.conf` is present with the `crypt` module |
| V10 | `/dev/mapper/fedora_crypt` is active |
| V11 | Every initramfs carries `dm-crypt` (module or builtin) — auto-repaired with `--add-drivers` if missing (in-chroot check) |
| V12 | Every initramfs carries a keyboard/input driver (`dockchannel-hid`, `hid-apple`, `usbhid`, …) — **warn-only**, because without one you cannot *type* the passphrase at boot (in-chroot check) |

V8 (both halves) and V12 are **warnings**, not gates — the header backup is
written unconditionally at step 5 (its absence at V8 means something removed it
mid-run, which is loud but not itself fatal), a second USB is never required,
and many kernels build generic HID support in. The script's own output labels
the main-gate checks V1–V10; V11 and V12 here are the two in-chroot module
checks, whose failures surface through the chroot error count rather than as
`V`-labelled lines.

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
| **fstab cross-validation** | Picking a boot/EFI partition that belongs to a *different* install on the same machine: the UUIDs of the selected BOOT and EFI partitions are checked against the `/boot` and `/boot/efi` entries in the target's own fstab, and a mismatch requires a typed `MISMATCH` override |
| Already-encrypted check | Double-encrypting an already-LUKS partition (now offers resume / config-only instead of aborting) |
| SELinux relabel | Files written from the live environment carrying the live system's labels (or none) into the target — `restorecon` runs in the chroot against the target's policy, and anything it cannot fix is reported with the `enforcing=0` escape hatch |
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
initramfs. GRUB ≥ 2.14 supports argon2id; GRUB 2.12 — current in Fedora 44 —
has no argon2 support at all.

> ### The KDF limit for a GRUB-unlocked volume is set by the firmware
>
> **Never configure a volume GRUB must open at 4 GiB of argon2id memory.
> Ever.** That one is unconditional — see the overflow below. It applies only
> to volumes GRUB unlocks, never to root, which the initramfs opens at up to
> 4 GiB quite happily.
>
> **Below 4 GiB the usable maximum belongs to the firmware, not to GRUB**, and
> must be measured per platform. GRUB's EFI heap starts at 32 MiB
> (`DEFAULT_HEAP_SIZE 0x2000000`) and grows on demand through
> `grub_efi_mm_add_regions`; how far it gets is the firmware's decision.
>
> On **x86 vendor UEFI, more than 1 GiB has never worked** — that firmware
> leaves GRUB too constrained an environment, which is where the widely-quoted
> "GRUB caps at 1 GiB" comes from. On **Asahi / U-Boot it is not the same
> number**: this project measured 2 GiB allocating *and* completing a real
> keyslot decryption on an M2 Max. Treat 1 GiB as the portable default and
> anything above it as opt-in and measured — an 8 GiB M1 is a different heap
> from an M2 Max.
>
> A request the firmware cannot satisfy lands at the boot prompt on the volume
> holding your kernel — the device does not boot, and the way back in is
> external recovery media.
>
> At **exactly 4 GiB it is worse than a failure**. In `argon2_init`
> (`grub-core/lib/libgcrypt-grub/cipher/kdf.c`), `xtrymalloc (1024 *
> memory_blocks)` is 32-bit unsigned arithmetic; `1024 * 4194304 == 2^32`
> wraps to **0**, so GRUB calls `xtrymalloc(0)` and carries on rather than
> rejecting the parameters cleanly. Copying the root volume's 4 GiB figure
> onto a GRUB-unlocked volume walks directly into this.

> **Note:** work is on-going to encrypt `/boot` at that 1 GiB ceiling. It is
> possible with GRUB ≥ 2.14, but testing continues because of the complexity of
> the Fedora Asahi Remix boot chain.

The answer to that is **not** to weaken the KDF. Dropping a volume to pbkdf2 to
satisfy an old GRUB trades a memory-hard KDF for one that GPUs and ASICs chew
through cheaply, which is a far worse outcome than leaving `/boot` unencrypted.
Keeping `/boot` out of GRUB's unlock path entirely — what this tooling does — lets
the root volume keep full-strength argon2id.

On Fedora Asahi Remix today the combination is not merely discouraged, it is
impossible: `grub2-efi-aa64-2.12` builds no `argon2.mod` for `arm64-efi` at all.
`/usr/lib/grub/arm64-efi/` ships `cryptodisk.mod`, `luks.mod`, `luks2.mod` and
`pbkdf2.mod`, and the installed `grubaa64.efi` has `cryptodisk`, `luks2` and
`pbkdf2` baked in — so GRUB 2.12 can open a LUKS2 volume whose keyslot uses
pbkdf2, and cannot open an argon2id one under any configuration. Upstream added
argon2 in **2.14** (`grub-core/lib/argon2.c`; `luks2.c` parses `argon2i` and
`argon2id`), which Fedora does not yet package.

Encrypted `/boot` is therefore out of scope for the current release **as
unsupported**, not as a known-failing configuration — no failure mode is claimed
here, because on stock Fedora the argon2id path cannot be exercised at all until
a GRUB carrying `argon2.mod` is in place. That is the work the note above refers
to.

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
- **Unlock time tracks memory x iterations, not memory alone.** Measured from
  the journal on an M2 Max — the gap between systemd-cryptsetup accepting the
  passphrase and the volume opening — argon2id at 4 GiB / 10 iterations / 4
  threads costs **9.5 s**, consistent to +/-0.1 s across three boots. That works
  out to ~0.24 s per GiB-pass. The `aggressive` profile IS that measurement
  (4 GiB x 10); the others scale from it to roughly 3.8 s (moderate,
  2 GiB x 8) and 2.1 s (fast, 1 GiB x 9).
  Memory size alone is cheap on modern hardware: the 4 GiB in that 9.5 s
  accounts for about 1 s of it, and the rest is the iteration count. Do not read
  a large `--pbkdf-memory` as a slow boot, or a small one as a speed win.
- **Why the paranoid tier buys cost in iterations.** Per second of user wait,
  memory is normally the better buy than iterations — it caps how many hashes an
  attacker fits in VRAM at once, which iterations do not. But **4 GiB is
  argon2id's maximum memory cost**: `cryptsetup` rejects anything above
  4194304 KiB outright (*"Requested maximum PBKDF memory cost is too high"*).
  This is a hard protocol limit, not a property of any particular machine's RAM.
  Memory therefore has nowhere left to go, and above it iterations are the only
  remaining lever.
- **You cannot brick the machine.** DFU and System Recovery always work, and macOS
  sits on separate APFS partitions this tooling never touches.
- **16 KB pages.** Asahi kernels use a 16 KB page size; this affects nothing in the
  LUKS path but explains the `+16k` kernel package suffix you will see.
