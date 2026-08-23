# Encrypted `/boot` — design

> **STATUS: DESIGN ONLY. NOT IMPLEMENTED. NOTHING HERE HAS BEEN TESTED ON
> HARDWARE.** No part of AsahiLocker encrypts `/boot` today. This document
> records the intended architecture and the measurements it depends on, so the
> decisions are reviewable before any of it ships. Do not read any statement
> below as a description of working behaviour.

## The objective

Everything encrypted except `/boot/efi` — parity with what UKI + Secure Boot
tooling achieves on x86. `/boot/efi` is the irreducible remainder: firmware has
to read it before anything can be unlocked, on any platform.

**What this reaches, and what it does not.** Encrypting `/boot` closes the
confidentiality gap completely — kernels, initramfs images and their embedded
keyfile all come off the disk unreadable. It does **not** buy the integrity half
of the x86 arrangement, and that difference is the platform's, not this
tooling's.

On x86, an unencrypted ESP is safe because the firmware refuses to execute a
UKI that is not validly signed. Asahi verifies only m1n1 stage 1; Secure Boot is
disabled and the platform sits in Setup Mode, so `grubaa64.efi` and the ESP stub
remain modifiable by anyone with physical access to the machine. An attacker who
can write to the ESP can capture the `/boot` passphrase on the next boot, and no
KDF cost anywhere in the chain affects that. The ESP stub guard raises the noise
floor; it is not a substitute for signature verification.

So the honest statement of the goal is *full confidentiality, with boot
integrity still bounded by what Asahi verifies*. Anything stronger waits on the
platform.

## Why this is hard on Fedora Asahi

Fedora's `grub2-efi-aa64-2.12` builds **no `argon2.mod`** for `arm64-efi`. It
ships `cryptodisk.mod`, `luks.mod`, `luks2.mod` and `pbkdf2.mod`, and the
installed `grubaa64.efi` has `cryptodisk`, `luks2` and `pbkdf2` baked in — so it
can open a LUKS2 volume whose keyslot uses **pbkdf2**, and can never open an
**argon2id** one. Upstream added argon2 in **2.14**.

Dropping `/boot` to pbkdf2 to satisfy the stock GRUB is not an acceptable
answer here; see [INTERNALS.md](INTERNALS.md). So encrypted `/boot` requires
shipping a GRUB that the distro does not yet provide.

## KDF ceiling for `/boot` — 1 GiB, absolutely

> ### THE RULE
>
> **A GRUB-unlocked volume gets argon2id at 1 GiB. Never more. Not "prefer
> less", not "1 GiB is recommended" — 1 GiB is the hard ceiling and there is
> no configuration in which exceeding it is correct.**
>
> This applies to `/boot` and to any other volume GRUB itself must open. It
> does **not** apply to root, which is opened by the initramfs.

1 GiB is confirmed in production on Manjaro, Linux Mint and Fedora x86. GRUB
will not go above it.

### Why nothing above 1 GiB is acceptable

Two separate failure modes, and both land at the worst possible moment — at the
boot prompt, on the volume that holds your kernel, before any recovery tooling
exists.

**1. Integer overflow at exactly 4 GiB.** In `argon2_init`
(`grub-core/lib/libgcrypt-grub/cipher/kdf.c`), the allocation is

```c
xtrymalloc (1024 * memory_blocks)
```

`memory_blocks` is `unsigned int`, so this is 32-bit unsigned arithmetic. At
exactly 4 GiB, `1024 * 4194304 == 2^32`, which wraps to **0**. GRUB then calls
`xtrymalloc(0)` — it does not reject the parameters, it does not report that the
memory cost is unsupported, it asks the allocator for nothing and proceeds from
there. A clean rejection would be recoverable. This is not a clean rejection.

**2. Allocation failure anywhere above 1 GiB.** GRUB is a memory-constrained
environment: its EFI heap starts at 32 MiB (`DEFAULT_HEAP_SIZE 0x2000000`) and
grows on demand through `grub_efi_mm_add_regions`. Asking it for more than
1 GiB is, at best, untested; realistically it fails to allocate, and a failure
here means **the device does not boot**. Whether the failure is a clean error or
a silent hang at the passphrase prompt is itself unverified — a hang is a far
worse outcome than an error, and there is no reason to find out on a real
machine.

Note the practical consequence: a volume configured this way is not merely slow
or weakly protected. It is a volume GRUB cannot open, holding the kernel needed
to boot the system, and the only way back in is external recovery media.

### Why root is different

Root runs argon2id at up to 4 GiB because the **initramfs** derives that key —
full userspace, no allocator constraint, and fast on Apple Silicon. These two
figures are not interchangeable and must never be copied from one volume to the
other. `/boot` is derived by GRUB. GRUB is not userspace.

### Still to confirm on this platform

The x86 systems above run standard UEFI firmware; Asahi runs U-Boot's EFI
implementation. So even the 1 GiB figure needs confirming here:

1. Whether 1 GiB is reachable under U-Boot at all. Nobody has measured whether
   GRUB's heap gets there on this hardware.
2. Whether a failure is clean. A hang at the passphrase prompt would force a
   more conservative default than 1 GiB — never a more generous one.

The allocation probe exists to answer exactly these two questions, and it
deliberately tests 512 MiB and 1024 MiB only. **It must never be pointed at
4096**: per the overflow above, that path does not produce a usable answer.

## Unlock architecture — two options, user's choice

`/boot` is opened by GRUB at argon2id **1 GiB / 10 iterations / 4 threads**.
That figure is fixed by the ceiling above and by one measurement: `cryptsetup`'s
own defaults on this hardware are argon2id at **1 GiB / t=8**, so 1 GiB with
fewer than 8 iterations would ship a `/boot` weaker than what a plain
`luksFormat` gives you for free. Ten iterations clears that bar deliberately.

What differs between the options is how **root** is opened once `/boot` is
readable.

### Option 1 — one unlock (quick access)

```
GRUB      -> passphrase          -> unlocks /boot   argon2id 1 GiB / t=10
initramfs -> keyfile, no prompt  -> unlocks /       root's own KDF, unchanged
```

You type one passphrase per boot. The initramfs — which now lives inside the
encrypted `/boot` — carries a random 64-byte keyfile that opens root silently.

**What it costs, stated exactly.** Root's keyslot parameters are untouched, but
they stop being what stands between an attacker and your data, because breaking
the `/boot` passphrase yields the keyfile and the keyfile opens root. The
cheapest path in becomes the 1 GiB `/boot` keyslot.

Two things make that far less alarming than it first sounds:

- **If root is already at 1 GiB, there is no reduction at all.** The chain is
  1 GiB either way, and this option is strictly free. Anyone running the `fast`
  profile is in exactly this position.
- **Even against a 4 GiB root, the result is not a weak configuration.** 1 GiB
  argon2id at 10 iterations is *more* work per guess than `cryptsetup`'s own
  measured default, and the difference from 4 GiB is a 4x factor on attacker
  parallelism — real, but linear, and dwarfed by passphrase entropy. See
  [Your passphrase is the other half](../README.md#your-passphrase-is-the-other-half).

Choose this if you want the convenience and your passphrase is strong.

**Keyfile hygiene, non-negotiable when this option is taken:**

- Generated at deploy time from `/dev/urandom`, 64 bytes, never reused across
  machines.
- It exists only inside the encrypted `/boot` initramfs and in the recovery
  bundle. It must never land on the ESP, in an unencrypted initramfs, or in a
  backup that is not itself encrypted.
- **Every dracut regeneration must reproduce it.** A kernel update that rebuilds
  the initramfs without the keyfile turns the next boot into an unexpected
  second passphrase prompt at best, and an unbootable system at worst. This
  needs a boot-guard check, not a note in the documentation.
- The recovery bundle must capture *both* headers. A keyfile on root opens
  `/boot`, and a keyfile in `/boot` opens root; losing either volume entirely
  leaves the other recoverable only via the passphrase.

### Option 2 — two unlocks (root's KDF stays the barrier)

```
GRUB      -> passphrase  -> unlocks /boot   argon2id 1 GiB / t=10
initramfs -> passphrase  -> unlocks /       root's own KDF, up to 4 GiB / t=12
```

You type twice per boot. **No keyfile is generated and none exists anywhere**,
so root's full KDF is genuinely what an attacker has to break. Nothing about
`/boot` weakens it.

> **This only works with a *different* passphrase for root.**
>
> If you use the same passphrase for both volumes, an attacker who breaks the
> 1 GiB `/boot` keyslot has your passphrase — and therefore has root as well,
> at which point option 2 has cost you a second prompt at every boot and bought
> you nothing. The whole point of this option is that root's 4 GiB keyslot is
> the cheapest way in, and that is only true if `/boot` does not hand over the
> secret that opens it.
>
> The installer must state this at the point of choosing, and must not let
> someone pick option 2 believing it is stronger while reusing one passphrase.

Choose this if you want the strongest configuration available and accept two
prompts.

### What the installer will ask

Wording is fixed here so the implementation is unambiguous:

```
  ════════════════════════════════════════════════════════════
   /boot IS ENCRYPTED. HOW SHOULD ROOT BE UNLOCKED?
  ════════════════════════════════════════════════════════════

   1) One unlock   — type your passphrase once, at the GRUB prompt.
      A keyfile inside the encrypted /boot opens root with no
      second prompt. Convenient. Because that keyfile opens root,
      the 1 GiB /boot keyslot becomes the cheapest way in — still
      stronger per guess than cryptsetup's own default, and no
      reduction at all if root is also at 1 GiB.

   2) Two unlocks  — type a passphrase at GRUB for /boot, and a
      SECOND, DIFFERENT one for root. No keyfile is created, so
      root's full KDF stays the barrier. Strongest available.
      Using the same passphrase twice defeats the entire point.

  ════════════════════════════════════════════════════════════
   Select [1-2, default 1]:
```

Neither option changes root's stored KDF parameters. Option 1 changes what those
parameters are worth; option 2 leaves them load-bearing.

### Implementation status

**Not implemented.** The script half of this waits on the allocation probe: if
1 GiB turns out to be unreachable under U-Boot's EFI, there is no encrypted
`/boot` to offer either option for, and the whole prompt is moot. Building the
menu before that answer exists would be building on an unverified assumption.

Runtime detail that applies to both options: the running system needs `/boot`
mounted for kernel and initramfs updates, so `/boot` needs its own `crypttab`
entry with a keyfile stored on root. That is not circular — root is already open
by the time systemd processes it — and it is required under option 2 as well,
where it is the *only* keyfile in the design.

## Detached headers — the stronger option

For users who want the disk to carry no keyslots at all, LUKS supports a
detached header. GRUB implements it: `cryptomount -H <file>` reads the header
via `grub_file_read`.

**What it actually buys:** without the header the partition is indistinguishable
from random data, so there is nothing on the disk to mount a passphrase attack
against, and the volume gains deniability. This is a genuine step up from the
single-passphrase design above.

**What it does not buy — do not call this "total security":**
- It does not give boot integrity. `grubaa64.efi`, `shim` and the ESP stub stay
  on plain vfat and remain modifiable. Asahi verifies only m1n1 stage 1, and
  there is no Secure Boot to lean on.
- It does not help if the header USB is seized alongside the machine, which is
  the common real-world case for a laptop.

**Platform caveat, and it is a serious one.** GRUB must *read* the detached
header before it can unlock anything, so the header's medium has to be
enumerated by U-Boot at boot. USB enumeration on this hardware is not
dependable: on the M2 Max in question, two separate USB drives were invisible to
U-Boot's `bootdev list` after `usb start`, while the SanDisk Asahi installer USB
is seen reliably. Putting the header on a USB therefore makes *booting at all*
contingent on that enumeration succeeding. Anyone choosing this route needs a
tested recovery path before they rely on it, and the documentation must say so
rather than presenting it as a free upgrade.

## ESP architecture

Our GRUB lives at its **own ESP path**, never overwriting the distro's:

```
/boot/efi/EFI/
  fedora/
    grubaa64.efi     2.12   <- dnf keeps updating this; harmless, ignored
    grub.cfg
  asahilocker/
    grubaa64.efi     2.14+  <- ours, with argon2; dnf never touches it
    grub.cfg                <- cryptomount stub for the encrypted /boot
```

The boot entry points at `EFI/asahilocker/grubaa64.efi`.

**Consequences of this choice, deliberately taken:**

- **Nothing has to be blocked.** No `excludepkgs`, no versionlock, no held-back
  GRUB security updates. The distro package and ours never contend for a path.
- **A guard failure is not fatal.** If the boot entry is ever lost, the machine
  falls back to Fedora's GRUB, which cannot open an argon2id `/boot` — so you
  land at a GRUB prompt with the disk intact, rather than at an unbootable
  system. This is the main reason for the separate path.
- **Retirement is one change.** See below.

## Acquiring GRUB

Built from upstream source **on the installed system**, not from the live USB —
the live environment is not guaranteed to have a toolchain, and the build needs
`gcc`, `bison`, `flex`, `autoconf-archive` and friends.

The release tags are GPG-signed by the GRUB maintainer, and the build script
**verifies the tag signature against a pinned fingerprint**
(`BE5C23209ACDDACEB20DB0A28C8189F1988C2166`, Daniel Kiper) before building.
A tool that fetches and installs its own bootloader has no business skipping
that check.

Two build quirks, both non-obvious:

- `autoconf-archive` is required before `./bootstrap`.
- `--disable-nls` **and** `LC_ALL=C.UTF-8` are required: `po/` fails on the
  German catalogs under a non-UTF-8 locale and aborts `make` *after* every
  module has already built successfully.

## The guard, and its retirement

A guard keeps the boot entry pointed at our image, following the same pattern as
the existing ESP stub guard: a known-good reference plus a periodic check.

It is **version-aware and self-retiring**. Once Fedora Asahi ships
`grub2-efi-aa64` **>= 2.15**, the distro GRUB is newer than ours and there is no
reason to keep overriding it: the guard points the boot entry back at
`EFI/fedora`, stops enforcing, and says so. The intent is to stop being in the
boot path as soon as the distro makes us unnecessary.

## Open questions — all blocking

1. **Is 1 GiB reachable under U-Boot on Apple Silicon?** The ceiling itself is
   settled at 1 GiB; what is unmeasured is whether U-Boot's EFI memory map can
   deliver it. If not, `/boot` takes the lower figure.
2. **Does the allocation fail cleanly or hang?** A clean failure is recoverable;
   a hang at the passphrase prompt is a much worse user experience and changes
   how conservative the default must be.
3. ~~One passphrase or two?~~ **Resolved: offer both**, one unlock as the
   default and two unlocks for anyone who wants root's KDF to stay the barrier.
   See "Unlock architecture" above. What remains open is only the wording of the
   warning that option 2 is pointless with a reused passphrase — it must be
   impossible to miss at the point of choosing.
4. **What does encrypted `/boot` actually buy on Asahi?** It does **not** close
   the evil-maid hole: `grubaa64.efi` and the ESP stub stay on plain vfat and
   remain modifiable, and LUKS provides confidentiality, not integrity. The real
   gain is that kernels and initramfs contents stop being readable, which is
   what makes a keyfile in the initramfs safe. Any documentation that ships with
   this feature must say so plainly rather than implying full-disk coverage.
