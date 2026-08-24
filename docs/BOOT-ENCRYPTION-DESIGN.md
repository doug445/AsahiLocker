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

## KDF ceiling for `/boot`

> ### THE RULE
>
> **Never configure a GRUB-unlocked volume at 4 GiB argon2id memory cost.** That
> one is absolute and has nothing to do with firmware — it is a 32-bit overflow
> in GRUB's own arithmetic, and it fails in the worst possible way.
>
> **Below 4 GiB, the usable maximum is a property of the firmware, not of GRUB.**
> It must be *measured* on the platform, never assumed from another one.
> AsahiLocker ships **1 GiB** for `/boot` — the conservative figure — and treats
> anything above it as opt-in, and only after measurement on the smallest
> machine you intend to support.
>
> Applies to `/boot` and any other volume GRUB itself must open. Does **not**
> apply to root, which the initramfs opens.

**An earlier version of this section stated 1 GiB as a hard ceiling that "GRUB
will not go above". That was wrong, and this project's own probe disproved it:**
2 GiB allocates *and* completes a real keyslot decryption under U-Boot on an
M2 Max — see the probe result below. The 1 GiB figure is real but it is
*x86-specific*: it comes from boxes running vendor UEFI, where it reflects how
much heap that firmware leaves GRUB, not a limit GRUB imposes on itself. It is
still confirmed in production on Manjaro, Linux Mint and Fedora x86, and it
remains our shipped default — now for portability and unlock latency rather than
because the memory is unreachable.

### Why 4 GiB specifically is never acceptable

Two failure modes, and both land at the worst possible moment — at the boot
prompt, on the volume that holds your kernel, before any recovery tooling
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

**2. Allocation failure above whatever the firmware actually affords.** GRUB is
a memory-constrained environment: its EFI heap starts at 32 MiB
(`DEFAULT_HEAP_SIZE 0x2000000`) and grows on demand through
`grub_efi_mm_add_regions`. How far it grows is the firmware's business, and it
differs by platform — which is exactly why the figure must be measured rather
than inherited. A request the firmware cannot satisfy means **the device does
not boot**, and whether it fails as a clean error or a silent hang at the
passphrase prompt is unverified on any platform. A hang is far worse than an
error, and a real machine is the wrong place to find out.

This is why "2 GiB worked on an M2 Max" is a licence to offer 2 GiB *on machines
where it has been measured*, and nothing more. An 8 GiB M1 is a different heap.

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

The allocation probe exists to answer exactly these two questions. **It must
never be pointed at 4096**: per the overflow above, that path does not produce a
usable answer.

### Probe result — 2026-08-24, M2 Max, GRUB 2.14 under U-Boot

```
RESULTS: 512M=OK  1024M=OK  2048M=OK   envwrite=OK
```

Every size allocated *and* completed a real keyslot decryption (`Slot "0"
opened`) — not merely a successful `malloc`. So:

- **1 GiB is reachable under U-Boot.** Question 1 answered; the conservative
  fallback is not needed.
- **The ceiling is higher here than on x86.** The widely-repeated "GRUB caps at
  1 GiB" figure comes from x86 boxes running vendor UEFI firmware. It is not a
  property of GRUB — it is a property of how much heap that firmware leaves
  available. U-Boot's EFI grows GRUB's heap differently, and 2 GiB works.
- **Question 2 is moot at these sizes** — nothing failed, so nothing had the
  chance to fail dirty.

**Still unknown, and both matter before this ships:**

1. **Unlock latency was not measured.** The probe deliberately used `t=4`, since
   it was measuring *memory*, not strength. GRUB's argon2 is not the kernel's:
   it is unoptimised and its parallelism lanes are not real threads, so a cost
   that takes 2 s in the initramfs may take far longer at the GRUB prompt. You
   pay this at every boot, before anything is on screen to explain the wait.
2. **Smaller machines are untested.** 2 GiB of GRUB heap on an 8 GiB M1 is a
   very different proposition from an M2 Max. Anything above 1 GiB must stay
   opt-in until measured on the smallest supported Mac.
3. **The 2–4 GiB range is untested**, and the overflow at exactly 4 GiB is
   unconditional regardless.

**Consequence for the design: `/boot` stays at 1 GiB by default.** The probe
raises the known ceiling; it does not change the recommendation, because the
binding constraint on `/boot` is now latency and portability, not allocation.

### Timing result — 2026-08-24, M2 Max, GRUB 2.14 under U-Boot

Measured with GRUB's own `time` command. (`date` is useless here: U-Boot
implements no EFI `GetTime` runtime service. But `grub_get_time_ms()` works —
which is the clock `sleep` and `time` both use.)

| case | GiB-passes | elapsed |
|---|---|---|
| 1 GiB x 4 | 4 | **8.096 s** |
| 1 GiB x 10 | 10 | **20.224 s** |
| 2 GiB x 10 | 20 | **39.624 s** |
| 2 GiB x 20 | 40 | **machine reset — no output, reproduced twice** |

**GRUB's argon2 is linear in memory x iterations**, at **~2.0 s per GiB-pass**
(2.024 / 2.022 / 1.981 — a 2.1% spread across the three that completed).

**And it is 8.5x slower than the kernel.** Root's keyslot is 4 GiB x 10 — the
same 40 GiB-passes — and the initramfs derives it in **9.5 s**, or 0.2375 s per
GiB-pass. This is the concrete form of the warning above: *initramfs timings do
not transfer to GRUB*, and they are not off by a little.

### There is a wall, and crossing it resets the machine

`2 GiB x 20` never printed a result. The machine rebooted instantly, twice, at
the same point.

**This is not an allocation failure, and the reasoning is worth keeping:**
`2 GiB x 20` allocates *exactly the same memory* as `2 GiB x 10`, which had just
succeeded moments earlier in the same session. The memory footprint is
identical; only the duration differs. So whatever kills it is a function of
**time**, not size.

The likely mechanism is a watchdog. GRUB does disable the EFI one —
`grub_efi_system_table->boot_services->set_watchdog_timer (0, 0, 0, NULL)` in
`grub-core/kern/efi/init.c` — so the suspect is Apple's hardware watchdog, which
U-Boot leaves running and which is only serviced when GRUB calls into firmware
(console output, `stall`). argon2 is a pure compute loop that calls into
nothing, so a long enough single derivation starves it. That also explains why
the ~82 s of *cumulative* probe time before this case was survivable while a
single ~80 s computation was not: every `echo` and `sleep` between cases hands
the firmware a turn.

**The wall is somewhere between 40 s and 80 s of uninterrupted computation, and
it is not a graceful failure — it is a hard reset with nothing on screen.**

#### What this constrains

1. **Matching root's KDF inside GRUB is impossible on this machine.** 40
   GiB-passes is ~80 s, which is past the wall. There is no configuration in
   which a GRUB-unlocked `/boot` is as expensive to attack as a 4 GiB x 10 root
   keyslot — 4 GiB is barred by the overflow, and 2 GiB x 20 resets the box.
2. **Parameters must be chosen against the slowest machine you support, with
   real margin.** 2 GiB x 10 costs 39.6 s here and is *already* close to the
   observed-safe boundary. A base M1 has less memory bandwidth, so the same
   parameters take longer there — potentially past the wall, on a machine that
   then **cannot boot at all**. This is the strongest argument yet for keeping
   `/boot` at 1 GiB: 20.2 s here, with roughly 2x headroom.
3. **Encrypted `/boot` costs ~20 s at every boot, minimum**, on the fastest
   Apple Silicon Mac available. That is the honest UX figure, and it should be
   stated before anyone opts in — not discovered afterwards.

### GRUB cannot be trusted to write the ESP

The probe reported `grubenv writable: OK` — `save_env` returned success — but
**nothing reached the disk**. Confirmed by searching the raw partition: the only
`probe_started=yes` on the ESP is the literal string inside `grub.cfg`, while
the grubenv block still reads `probe_started=no`. (`save_env` writes raw blocks
by block list, so the FAT directory mtime never updates either way — mtime is
not evidence here.)

Note this is *not* a blanket "GRUB cannot write": Fedora's GRUB 2.12 does
successfully clear `menu_show_once_timeout` from the grubenv on the **ext4**
`/boot`, on the same disk, through the same EFI block path. Whatever the cause,
the operational rule is: **design nothing that depends on GRUB persisting state
to the ESP, and never treat a `save_env` return value as proof it wrote.**
Encrypted `/boot` needs no such writes.

## Retrofit: choosing the unlock architecture on an already-encrypted root

Converting `/boot` after the fact is the normal case, not the exception — every
existing deployment is in it. The choice between the two unlock options is
**not** a matter of taste there, because root's keyslot cost is already fixed
and can be read. The converter must compute the trade and state it, rather than
printing generic advice.

### The rule

Read root's keyslot with `cryptsetup luksDump` and compare **work**
(memory x iterations) against the `/boot` keyslot about to be written:

| condition | what it means | what to show |
|---|---|---|
| `/boot` work >= root work | Option 1 costs nothing. The keyfile is reachable only by breaking a keyslot at least as expensive as root's. | Say so plainly, with both figures. |
| `/boot` work < root work | Option 1 makes the cheapest way in **N times cheaper than today**, where N is the ratio. Nothing about root's header changed — it simply stopped being the barrier. | State N, and state what `/boot` parameters would bring N to 1. |

**Then ask, with no option pre-selected.** The converter's job is to make the
consequence impossible to miss, not to choose. Convenience versus a 4x cheaper
attack is a judgement about the owner's threat model, their physical security,
and how many times a day they reboot — none of which this script knows. A
`[1-2, default N]` prompt quietly makes that judgement for them, so the retrofit
prompt takes no default and accepts no empty answer. For unattended runs the
choice comes from the environment (e.g. `LUKS_BOOT_UNLOCK=1|2`), which is an
explicit choice too — just made earlier.

The same comparison should be printed on the fresh-install path, where the
asymmetry can be identical (root at 4 GiB, `/boot` capped by GRUB). The existing
fresh-install prompt carries `default 1`; if the retrofit takes no default, that
one is worth revisiting for consistency.

Worked example, a real machine: root at argon2id **4 GiB x 10** = 40 GiB-passes.
`/boot` at 1 GiB x 10 is 10 — Option 1 would make the cheapest path in **4x**
cheaper. Since 4 GiB is unusable in GRUB (the overflow), the only parameters
that match root are **2 GiB x 20**. Allocation at 2 GiB is proven; whether t=20
is tolerable at every boot is a latency question, which is what the timing probe
exists to answer. **On that machine the timing probe does not decide anything by
itself — it tells the owner what Option 1 would actually cost them, so the
preference can be an informed one.**

### Option 2 has a failure mode the converter can actually detect

Two passphrases are only two barriers if they are **different**. Reuse the same
one and an attacker who breaks the cheaper `/boot` keyslot has the root
passphrase too — you have paid for two prompts and bought one barrier, the
weaker one.

This is checkable rather than merely advisable: after enrolling the `/boot`
passphrase, test it against root with

```bash
cryptsetup open --test-passphrase --key-file - /dev/<root>
```

If it succeeds, the user has reused the passphrase. Refuse to finish, or warn in
the strongest terms — this silently converts Option 2 into a worse Option 1.

### Option 1 hazards specific to retrofitting

- **The keyfile ends up in every initramfs**, and initramfs images accumulate in
  `/boot`. Deleting the key file alone revokes nothing. Backing out means
  `cryptsetup luksRemoveKey` on that keyslot **and** regenerating every
  initramfs, in that order.
- **Backups of `/boot` become secret-bearing.** Once the keyfile is inside the
  encrypted `/boot`, any tool that reads `/boot` from the *running* system —
  Borg, Back In Time, rsync, a `tar` snapshot — captures the root keyfile in the
  clear. That backup is now equivalent to the disk's key. Either exclude
  `/boot`, or treat the backup repository as exactly as sensitive as the
  passphrase. This surprises people, and it should be stated at the prompt, not
  in a footnote.
- **The keyslot the keyfile occupies does not need an expensive KDF.** The
  keyfile is **4096 random bytes** (owner's choice; cryptsetup accepts up to
  8192 kB, and the 512-character limit in `--help` applies to *interactive*
  passphrases only). 64 bytes would already be 512 bits — unguessable at any
  iteration count — so 4096 buys nothing cryptographically, but it costs
  nothing either. Because the entropy makes the KDF irrelevant here,
  `luksAddKey` cost on this slot is cosmetic; pass the parameters explicitly
  anyway rather than letting it re-benchmark, so the header stays uniform.
  Generate it as raw binary (`dd if=/dev/urandom bs=4096 count=1`) and never
  let a text tool near it — a stray newline changes the secret.
- **`/boot` must be encrypted before the keyfile-bearing initramfs is written
  into it.** Getting that order wrong leaves the key in the clear on an
  unencrypted partition, which is the exact failure the feature exists to
  prevent.

### What each option costs to undo

Reversibility differs sharply, and it belongs in front of the user at the prompt
rather than discovered later:

- **Option 2** adds no keyslot and creates no key material at rest. Root's
  header is never touched. Backing out is decrypting `/boot`, which puts you
  exactly where you started.
- **Option 1** adds a keyslot to root and puts a key on disk. Backing out is
  `cryptsetup luksRemoveKey` **then** regenerating every initramfs — in that
  order, because the key is baked into each one. It also changes what your
  backups contain, permanently, for every backup taken while it was in effect.

That asymmetry is a fact about the two designs, not an argument for either. A
machine that boots twice a year and one that boots twenty times a day are
answering different questions, and only the owner knows which they have.

## Release plan

Encrypted `/boot` is a **major version bump**, not a point release, and it
carries a documentation rewrite with it: every place that says "`/boot` is
deliberately left unencrypted" becomes a description of a choice the installer
now offers, and the threat-model section changes shape.

The installer must offer **both**, and keep root-only as a first-class option
rather than a legacy path:

- **root only** — what ships today. `/boot` in the clear, no GRUB argon2
  dependency, no self-built GRUB. This stays the default until encrypted
  `/boot` has real mileage on more than one machine.
- **root + `/boot`** — the new path, gated on the allocation probe below.

Nothing here ships until the probe answers the two questions in the previous
section. A `/boot` that hangs at the GRUB passphrase prompt is a worse outcome
than a `/boot` in the clear.

## Unlock architecture — two options, user's choice

`/boot` is opened by GRUB at argon2id **1 GiB / 10 iterations / 4 threads**.
The probe shows 2 GiB is also reachable on an M2 Max, but 1 GiB remains the
default for portability and unlock latency (see the probe result above). The
figure is fixed by that choice and by one measurement: `cryptsetup`'s
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
encrypted `/boot` — carries a random **4096-byte** keyfile that opens root silently.

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
