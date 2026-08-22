# AsahiLocker — in-place LUKS2 disk encryption for Fedora Asahi Remix on Apple Silicon

[![CI](https://github.com/doug445/AsahiLocker/actions/workflows/lint.yml/badge.svg)](https://github.com/doug445/AsahiLocker/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Apple Silicon](https://img.shields.io/badge/platform-Apple%20Silicon%20(M1--M4)-lightgrey.svg)](#requirements)
[![KDF: argon2id](https://img.shields.io/badge/KDF-argon2id-blue.svg)](#crypto-parameters--aes-256-xts-and-argon2id)

Encrypt the root filesystem of an **already-installed Fedora Asahi Remix** system
on Apple Silicon — in place, without reinstalling, without wiping macOS, and
without a second copy of your data.

`luks-deploy.sh` converts your existing btrfs root partition into a LUKS2
container holding that same filesystem. Your files, subvolumes, snapshots and
btrfs UUID all survive; the partition simply gains an encryption layer. It then
rewrites every piece of boot configuration that has to change (`crypttab`,
`fstab`, `/etc/kernel/cmdline`, GRUB defaults, **all** BLS entries, dracut
config, **all** initramfs images) and refuses to let you reboot until a 12-point
verification gate passes.

Works on every M-series Mac that Asahi supports — M1 / M1 Pro / M1 Max /
M1 Ultra, M2 / M2 Pro / M2 Max, M3, M4. Nothing in the tooling is model-specific:
partitions, subvolumes and boot layout are all auto-detected at runtime.

> **This is destructive-by-nature tooling.** It rewrites a live root filesystem.
> Read [`docs/INSTALL.md`](docs/INSTALL.md) before running anything, and have a
> verified backup. See [Risks](#risks--read-this).

---

## Quick start

```bash
# 1. On the installed system: get the kit, and build a Fedora Asahi live USB
#    to run it from  (see docs/LIVE-USB.md — a stock Fedora ISO will NOT boot)
git clone https://github.com/doug445/AsahiLocker.git

# 2. Boot the live USB. Easiest route, with the USB plugged in:
#      sudo grub2-mkconfig -o /boot/grub2/grub.cfg    # adds it to your GRUB menu
#    then reboot and select it.  (see docs/LIVE-USB.md for the U-Boot routes)

# 3. From the live environment, encrypt the installed root:
sudo ./AsahiLocker/bin/luks-deploy.sh

# 4. Reboot, enter your passphrase, then finish up on the encrypted system:
sudo ./AsahiLocker/bin/post-encryption-setup.sh
sudo ./AsahiLocker/boot-guards/install.sh
```

The deploy script auto-detects your disk layout and shows you what it found. You
confirm the selection, type `ENCRYPT`, and choose a passphrase. Everything after
that is automated, including recovery if a step fails partway.

Full walkthrough: **[docs/INSTALL.md](docs/INSTALL.md)**

---

## What you get

- **In-place btrfs → LUKS2 conversion.** No reinstall, no backup-and-restore
  round trip, no second disk. Subvolumes, snapshots and the btrfs UUID survive.
- **Pinned argon2id, never pbkdf2.** AES-256-XTS with argon2id at 4 / 2 / 1 GiB
  memory cost — memory-hard by design, so GPU and ASIC cracking stays expensive.
- **Benchmarked on *your* machine.** The installer measures your hardware and
  shows real unlock-latency estimates before you pick a KDF profile.
- **Every boot file rewritten, then verified.** `crypttab`, `fstab`,
  `/etc/kernel/cmdline`, GRUB defaults, all BLS entries, dracut config and all
  initramfs images — behind a 12-point gate that refuses to let you reboot into
  a broken system.
- **Resumable after any interruption.** LUKS2 re-encryption is journaled with
  checksum resilience; re-run the script and it detects the interrupted state
  and finishes it.
- **A `--dry-run` that really is dry.** The entire read-only half, including the
  exact `cryptsetup reencrypt` invocation it would issue, with nothing modified.
- **Recovery you can actually use.** Optional 64-hex recovery key in a second
  keyslot, plus a labeled bundle with the LUKS header and every changed config.
- **Asahi-specific boot guards.** Stops a stray `grub2-mkconfig` from bricking
  an encrypted boot, and clears U-Boot's stale EFI entries.
- **Tested in CI on every push**, x86_64 and aarch64, against a real loop device.

---

## What's in here

| Path | What it is |
|------|------------|
| `bin/luks-deploy.sh` | **The main event.** In-place LUKS2 encryption of the installed btrfs root, run from a live USB. Auto-detects everything, cross-checks the selected boot/EFI partitions against the target's own fstab, self-repairs failed initramfs/BLS steps, fixes SELinux labels, and gates the reboot behind 12 verification checks. Fully resumable: re-run it after any interruption and it finishes the encryption (`--resume-only`) or redoes just the config phase. |
| `bin/post-encryption-setup.sh` | Run once on the newly-encrypted system. Saves a recovery bundle, creates snapper subvolumes on the encrypted volume, enables the boot guards, verifies the result. Idempotent. |
| `bin/luks-tune.sh` | An ncurses front-end (`dialog`, falling back to `whiptail`) for inspecting and re-costing the argon2id parameters of keyslots on volumes that already exist. Shows the measured unlock time and what the cost buys against a GPU fleet before you commit, backs the header up first, and hands the passphrase prompt to `cryptsetup` rather than reading it. Never creates or destroys a keyslot, never changes a passphrase, never touches data. `--dry-run` prints the command and changes nothing. |
| `bin/save-luks-recovery-bundle.sh` | Assembles a labeled recovery bundle (LUKS header + `crypttab`/`fstab`/`cmdline`/BLS entries + a plain-English recovery README) so you are not dependent on a second USB. |
| `bin/post-encryption.conf.example` | Optional config for the above — snapper subvolumes and any extra units you want enabled post-encryption. |
| `boot-guards/` | Two small Asahi-specific boot guards, plus an installer: **ESP stub guard** (stops a stray `grub2-mkconfig` from bricking an encrypted boot) and **stale EFI entry cleaner** (removes U-Boot's leftover entries for unplugged USB installers). |
| `extras/` | Optional `luks-fetch-cache`: an aligned LUKS/BitLocker status readout for fastfetch. Public header metadata only, no key material. |
| `tests/` | `loopback-core-test.sh`: runs the exact encrypt/resume/recovery-key sequence against a throwaway file-backed loop device — including a hard-kill mid-reencrypt followed by `cryptsetup repair` + `--resume-only`. Runs in CI on every push (x86_64 + aarch64); safe to run locally with sudo. |
| `docs/` | [INSTALL](docs/INSTALL.md) · [LIVE-USB](docs/LIVE-USB.md) · [RECOVERY](docs/RECOVERY.md) · [U-Boot bootflow](docs/UBOOT-BOOTFLOW.md) · [Internals](docs/INTERNALS.md) · [Fleet deployment](docs/FLEET.md) |

---

## How the encrypted boot actually works on Apple Silicon

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

### Partition layout, before and after

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

## Crypto parameters — AES-256-XTS and argon2id

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

The KDF re-runs **in the initramfs at every boot**, so its memory cost must be
allocatable there — and you pay its full cost as unlock latency on every boot.

### Choosing an argon2id profile

Because you wait for it every time you start the machine, the installer asks you
to pick one of three profiles. It **benchmarks your machine first** and shows an
estimate for each from your own hardware, not someone else's. Above the memory
`cryptsetup benchmark` can allocate on the spot, the figure is scaled from a
smaller measurement rather than measured outright, and every figure shifts with
system load — at boot the machine is idle, so real unlocks land at the fast end:

![The luks-deploy.sh KDF profile prompt, showing three argon2id profiles with unlock times benchmarked on the running machine](docs/images/kdf-profile-menu.png)

*Times shown are from an M2 Max. Your machine is benchmarked at run time, so the
numbers you see will be your own.*

| Profile | Memory | Iterations | Threads |
|---------|--------|-----------|---------|
| `aggressive` | 4 GiB | 12 | 4 |
| `moderate` (default) | 2 GiB | 6 | 4 |
| `fast` | 1 GiB | 4 | 4 |

**All three are argon2id — none uses pbkdf2.** Memory cost only has to be
allocatable in the initramfs, which has the machine to itself, so any profile is
safe on any Asahi-supported Mac including an 8 GiB M1.

argon2id is memory-bandwidth-bound, so a base M1 is slower than an M2 Max for
identical parameters — which is exactly why the installer measures your hardware
rather than assuming.

Non-interactive selection, for scripted or fleet deployments:

```bash
sudo LUKS_PROFILE=fast ./bin/luks-deploy.sh                     # a named profile
sudo LUKS_PBKDF_MEMORY=1572864 LUKS_PBKDF_ITER=6 ./bin/luks-deploy.sh   # fully custom
```

Setting any `LUKS_PBKDF_*` variable pins the parameters and skips the menu.
Custom parameters below half the `fast` profile (512 MiB / 4 iterations) are
refused unless you also set `LUKS_PBKDF_ACK_WEAK=1` — a typo in the memory
figure should not silently produce a worthless KDF.

### Changing the KDF on a volume that already exists

Profiles apply at **format time only**. A header keeps whatever it was built
with, so changing a profile does nothing to a disk you already encrypted. Read
what a volume actually uses first:

```bash
sudo cryptsetup luksDump /dev/nvme0n1p6
```

Under each keyslot you get `PBKDF:`, `Memory:` (in KiB), `Time cost:` (the
iteration count) and `Threads:`. Every keyslot carries its own parameters — a
passphrase slot and a keyfile slot on the same volume are commonly different.

There is an ncurses front-end for all of this if you would rather not hand-type
the parameters — it shows the measured unlock time and the strength table below
for whatever you pick, before you commit to anything:

```bash
sudo ./bin/luks-tune.sh              # interactive
sudo ./bin/luks-tune.sh --dry-run    # show the command, change nothing
```

To do it by hand instead, re-cost a keyslot in place **without changing the
passphrase**:

```bash
sudo cryptsetup luksHeaderBackup /dev/nvme0n1p6 \
     --header-backup-file ~/luks-header-before.bin

sudo cryptsetup luksConvertKey --pbkdf argon2id \
     --pbkdf-memory 4194304 --pbkdf-force-iterations 12 --pbkdf-parallel 4 \
     /dev/nvme0n1p6
```

That converts the slot your passphrase opens. Add `-S <n>` to target a specific
slot, and repeat per slot you want re-costed. Take the header backup first and
keep it until the new parameters are confirmed by a successful boot — a keyslot
is the only copy of your key, wrapped.

Two things that trip people up:

- **`--pbkdf-force-iterations` disables cryptsetup's time benchmarking.** Left
  off, cryptsetup auto-tunes the iteration count to land near `--iter-time`
  (2000 ms by default). That is why a stock 4 GiB volume unlocks in about two
  seconds while these profiles take longer — the memory figure is the same, the
  iteration count is not.
- **`--pbkdf-memory` is in KiB**, not MiB or GiB. 4 GiB is `4194304`.

### Never use pbkdf2

Not as a fallback. Not to save memory. Not to shave a second off your boot.
`luksFormat` still accepts it and LUKS1 defaulted to it, so it is easy to end up
with by accident — treat that as a defect to fix, not a setting to keep.

pbkdf2 is not broken. It is **obsolete**, which is worse, because broken things
get ripped out and obsolete things linger in defaults for twenty-six years.

Understand what it actually is. pbkdf2 is a `for` loop. That is the entire idea:
take something cheap, do it a great many times, and hope the attacker finds the
repetition as tedious as you do. It was standardised in **RFC 2898, in the year
2000**, when the threat model was a person with a computer roughly like yours.
That assumption died the day general-purpose GPUs shipped, and pbkdf2 has had no
answer since, because it has nothing to spend except time — and time is the one
resource an attacker buys at a bulk discount and you pay for at retail.

It has **no memory requirement at all**. None. That single omission is the whole
catastrophe. Memory is what makes an attacker's silicon expensive; a KDF that
asks for none is a KDF that fits thousands of copies of itself onto one graphics
card, and asks each one for nothing but arithmetic — the exact thing that card
was built to do ten thousand times over. argon2id at 4 GiB tells a 24 GB GPU it
may run six guesses. pbkdf2 tells it to help itself.

So you are on a treadmill, and it is rigged. Every iteration you add costs you,
personally, at every single boot, on the hardware you already own. It costs your
attacker nothing they cannot buy back with next year's card — and they will,
while your boot time stays exactly where it is. You are the only participant in
this arrangement who pays more over time. Raising pbkdf2's iteration count is
not a defence; it is a subscription.

The cryptographic community reached this conclusion publicly and unanimously
over a decade ago. The **Password Hashing Competition ran from 2013 to 2015 for
precisely this reason** — that what everyone was using had aged out — and
Argon2 won it. That was eleven years ago. Every argument for pbkdf2 on a new
volume in 2026 is an argument that has already been had, in public, and lost.

Concretely, at the parameters below and against a human-chosen password: 32
years with argon2id, **twelve days** with pbkdf2. That is not a tuning
preference. That is the difference between a stolen laptop that keeps your life
private and one that hands it over inside a fortnight.

This tool selects argon2id and only argon2id. No profile offers pbkdf2, no
environment variable exposes it, no menu hides it behind an "advanced" tab, and
there is no supported configuration in which it is the right answer. If
`luksDump` shows `PBKDF: pbkdf2` on a volume you care about, that volume is
running on a twenty-six-year-old assumption about who is attacking it. Re-cost
that keyslot with the `luksConvertKey` command above, today.

### Your passphrase is the other half

The KDF sets the price of a single guess. Your passphrase sets how many guesses
are needed. Neither one carries the volume alone — a 4 GiB argon2id keyslot
protecting `hunter2` falls in an afternoon, and a magnificent passphrase behind
a cheap KDF is a lot cheaper to attack than you would like.

The numbers below assume the `aggressive` profile (4 GiB, 12 iterations) and a
well-funded attacker: **1,000 top-end GPUs, 24 GiB of VRAM each**, each running
as many concurrent guesses as 4 GiB per guess leaves room for — about six — at
the same per-guess cost this tool measures on your own machine. That is roughly
550 guesses per second for the whole fleet. Times are to search half the
keyspace, and they are orders of magnitude, not predictions.

| Passphrase | Entropy | Time to break | What has happened by then |
|---|---|---|---|
| 6 diceware words | 77 bits | ~10^13 years | A thousand times the present age of the universe. The last red dwarfs are still burning — just. |
| 7 diceware words | 90 bits | ~10^17 years | Star formation ended long ago. Nothing is left but cooling remnants. |
| 8 diceware words | 103 bits | ~10^21 years | Galaxies have dynamically evaporated; the remnants drift alone in the dark. |
| 10 diceware words | 129 bits | ~10^28 years | Approaching the era in which protons themselves may decay. |
| 11 diceware words | 142 bits | ~10^32 years | Ordinary matter is dissolving, if protons decay at all. |

For scale, the universe is about **1.4 × 10^10 years** old. Even the weakest row
here outlives it by a factor of a thousand. This is why the argument is over
*passphrase generation*, never over adding another symbol to a short one.

#### What a weak KDF costs you — the pbkdf2 column

Same fleet, same passphrases, but with the keyslot wrapped in pbkdf2 instead.
pbkdf2 needs essentially no memory per guess, so VRAM stops limiting how many
guesses run at once and the attacker's rate is bounded only by raw arithmetic.
The column below assumes they get **1000× the guess rate** — deliberately
conservative for a GPU fleet, since the real gap grows with every new card:

| Passphrase | Bits | argon2id 4 GiB | pbkdf2 |
|---|---|---|---|
| a human-chosen password | 40 | 32 years | **12 days** |
| a good non-diceware passphrase | 60 | 10^8 years | 10^5 years |
| 6 diceware words | 77 | 10^13 years | 10^10 years |
| 8 diceware words | 103 | 10^20 years | 10^17 years |
| 10 diceware words | 129 | 10^28 years | 10^25 years |

Read the bottom rows and the top row differently, because they say different
things. At high entropy both are past cosmic time — argon2id is not what saves
you there, your passphrase is. The KDF decides the outcome in the **top row**,
where most real passphrases actually live: thirty-two years versus twelve days
is the difference between a laptop that stays private and one that does not.

A 1000× cheaper KDF is exactly equivalent to deleting `log2(1000) ≈ 10 bits`
from your passphrase — near enough one whole diceware word, silently, after you
chose it. That is the entire argument, and it is why there is no pbkdf2 option
in this tool.

#### Quantum computing

Two algorithms matter, and only one of them applies here.

**Shor's algorithm does not touch this.** It breaks RSA and elliptic-curve
cryptography by exploiting their algebraic structure. LUKS uses none of that —
AES-XTS with a 512-bit key and argon2id have no structure for Shor to attack.
Nothing in this tool is on the "harvest now, decrypt later" list in the way a
TLS session key or an encrypted email is.

**Grover's algorithm does apply, and it halves your effective entropy.** It
searches an unstructured keyspace in √N instead of N, so a 103-bit passphrase
behaves like a 51-bit one against an idealised quantum attacker. Applying that
worst case to the table above:

| Passphrase | Bits | Effective vs. Grover | Time at 4 GiB argon2id |
|---|---|---|---|
| 6 diceware words | 77 | 38 | **11 years** |
| 8 diceware words | 103 | 51 | 10^5 years |
| 10 diceware words | 129 | 64 | 10^9 years |

That is the case for eight words as a floor and ten or eleven for anything you
expect to matter in thirty years. Six words is comfortable today and thin under
a machine that does not exist yet.

Two honest caveats, because this table is a ceiling and not a forecast. Grover
requires evaluating the *entire KDF in superposition* — a fault-tolerant quantum
computer would have to run argon2id at 4 GiB coherently, and memory-hard
functions are about the most hostile possible target for that; nothing close to
it is on any roadmap. Grover also parallelises badly: its speedup is sequential,
so a thousand quantum computers do not give you a thousandfold gain the way a
thousand GPUs do. Treat the middle column as a reason to buy entropy headroom
while it costs you two extra words, not as a prediction that anyone will do this.

**Use diceware, and generate it randomly.** The EFF long wordlist holds 7,776
words — exactly five six-sided dice per word, `log2(7776) = 12.92` bits each.
Roll real dice if you have them; five rolls select one word by lookup.

Without dice, use a CSPRNG explicitly — do not let a shell pick for you:

```bash
# EFF long wordlist: https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt
shuf --random-source=/dev/urandom -n 8 eff_large_wordlist.txt | cut -f2 | paste -sd' '
```

Eight words is a sound default for a machine you use daily. Ten or eleven is
appropriate for a volume you expect to outlive the hardware.

**The rules that actually matter:**

- **Generated, not chosen.** Entropy counts only if the selection was random.
  Words you picked yourself because they were memorable carry a small fraction
  of the bits their length suggests, because an attacker models the same
  preferences you have.
- **Never reused.** Not your login password, not your password manager's master
  passphrase, not a variation on either. A keyslot passphrase that appears in
  any breach corpus is worth zero bits regardless of its length.
- **Length beats complexity.** `correct horse battery staple` style beats
  `Xk7$q!2` — more entropy, and vastly easier to type correctly.
- **Stay in plain ASCII.** You type this at a bare console before any keymap is
  loaded, so a layout-dependent or non-ASCII character may be impossible to
  enter at the boot prompt even though it worked when you set it. Lowercase
  words and spaces are safe everywhere, which is a real practical argument for
  diceware over symbol soup on a boot passphrase specifically.
- **Watch Caps Lock.** `cryptsetup` confirms a new passphrase by asking twice,
  so an inverted one verifies happily and fails only at the next boot. The
  deploy script warns when the kernel reports Caps Lock on at the confirmation
  gate.
- **Write it down until it is memorised.** The realistic way to lose a
  correctly-configured encrypted volume is forgetting the passphrase, not
  someone breaking it. Paper in a safe beats a fifth backup of the header.
  Enrol a recovery key in a second keyslot as well — see
  [save-luks-recovery-bundle.sh](bin/save-luks-recovery-bundle.sh).

The partition menus can be pinned the same way (each pinned device is still
fstype-checked and cross-checked against the target's own fstab, and the typed
`ENCRYPT` confirmation still applies):

```bash
sudo LUKS_TARGET_ROOT=/dev/nvme0n1p6 LUKS_TARGET_BOOT=/dev/nvme0n1p5 \
     LUKS_TARGET_EFI=/dev/nvme0n1p4 ./bin/luks-deploy.sh
```

Fully hands-off (fleet imaging, automated testing): `LUKS_PASSPHRASE_FILE=<path>`
reads the passphrase from a file — its exact bytes, no trailing newline — and is
used for encrypt, resume, unlock, and as the existing key when enrolling the
recovery key. `LUKS_MAPPER_NAME=<name>` changes the device-mapper name (default
`fedora_crypt`; the companion scripts auto-detect a custom name from the booted
system).

### Dry run

```bash
sudo ./bin/luks-deploy.sh --dry-run     # or LUKS_DRY_RUN=1
```

Runs the entire read-only half — detection, selection menus, fstab
cross-checks, the KDF benchmark, the state backup to the deployment drive —
prints exactly what a real run would do (including the full
`cryptsetup reencrypt` invocation), and exits before the point of no return.
Nothing on the target is modified.

### Boot splash

The deploy strips `rhgb quiet` from the boot args, because with the splash
active the first LUKS passphrase prompt hides behind it and the boot looks
hung. `post-encryption-setup.sh` restores both tokens after the first
encrypted boot (via a marker in `/var/lib/asahilocker/`). Opt out
with `LUKS_KEEP_SPLASH=1`.

### Recovery key

During deployment the script offers to enroll a **recovery key**: 64 random hex
characters in a second LUKS keyslot, saved to the deployment drive (pin the
choice with `LUKS_RECOVERY_KEY=yes|no`). If the passphrase is ever forgotten,
the recovery key still unlocks the volume — type it at the boot prompt, or use
it as a `--key-file` from a live USB. It is enrolled *before* the header backup
is taken, so the backup contains the slot. **Move it to secure offline storage
after deployment** — anyone holding it can unlock the disk.

**Stay on argon2id.** It is memory-hard, which is the entire point — that is what
makes GPU and ASIC cracking expensive. Never substitute pbkdf2 to save memory or
time; argon2id at 1 GiB is dramatically stronger than pbkdf2 at any iteration
count. Verify what you got with `cryptsetup luksDump /dev/nvme0n1p6`.

> **Note on GRUB and argon2id:** none of this constrains the root volume, because
> GRUB never unlocks it — the initramfs does. It only matters if you have some
> *other* volume that GRUB itself must unlock: GRUB ≥ 2.14 does argon2id but is
> capped by its own heap at 1 GiB memory cost, and GRUB 2.12 (current in
> Fedora 44) has no argon2 support at all. Do not answer that by downgrading the
> volume to pbkdf2 — argon2id at 1 GiB is memory-hard, pbkdf2 is not, and the gap
> matters far more than the memory cost does.

---

## How this differs from encrypting by hand

The manual route — `cryptsetup reencrypt` followed by editing `crypttab`,
`fstab`, the kernel cmdline, GRUB defaults and the BLS entries yourself — works,
and there are guides for it. What this kit adds is the part those guides leave
to you:

| | Manual `cryptsetup reencrypt` | AsahiLocker |
|---|---|---|
| Partition selection | You identify root/boot/EFI yourself | Auto-detected, fstype-checked, and cross-checked against the target's own fstab |
| KDF parameters | `cryptsetup` auto-benchmarks — machine-dependent, and picks sha256 | Pinned argon2id + sha512, identical on every box, chosen from a menu benchmarked on your hardware |
| Boot config | You edit `crypttab`, `fstab`, cmdline, GRUB defaults and every BLS entry by hand | All rewritten, including *every* BLS entry and *every* initramfs image |
| Did it work? | You find out at reboot | 12-point verification gate refuses the reboot until it passes |
| Interrupted run | You debug the header state yourself | Detected and resumed automatically; `cryptsetup repair` path handled |
| SELinux | Relabel it yourself or boot to AVC denials | Relabelled and verified |
| Undo / recovery | Whatever you thought to save | Header backups plus a labeled bundle of every changed file |
| The Asahi footguns | `grub2-mkconfig` clobbering the ESP stub; stale U-Boot EFI entries | Boot guards install to prevent both |

If you want to understand what it changes before trusting it, `--dry-run` prints
every action, and [docs/INTERNALS.md](docs/INTERNALS.md) documents each one.

---

## Risks — read this

- **No TPM on Apple Silicon.** There is nowhere to seal a key, so you type the
  passphrase at *every* boot. That is by design, not a limitation of this tooling.
- **Forget the passphrase and the data is gone** — unless you enrolled the
  optional recovery key and can still find it. There is no backdoor. Back up the
  recovery bundle, keep the recovery key offline, and remember the passphrase.
- **Have a verified backup before you start.** Not "a backup" — one you have
  actually restored from or browsed. In-place re-encryption rewrites every sector
  of the root partition.
- **You cannot brick the Mac.** Apple Silicon DFU / System Recovery always works,
  and macOS is on separate APFS partitions this tooling never touches. An
  interrupted encryption is not fatal either: LUKS2 re-encryption is journaled
  with checksum resilience, and re-running the script detects the interrupted
  state and resumes it automatically. The header backups cover the remaining
  worst case of a damaged header.
- **LUKS protects data at rest, not boot integrity.** Only m1n1 stage 1 is
  cryptographically verified on Asahi; `/boot` is unencrypted and unsigned. An
  attacker with repeated physical access could tamper with the initramfs.
- **The passphrase prompt can hide behind boot text.** If the machine looks hung
  right after GRUB, it is probably waiting — type the passphrase and press Enter.
  Splash screen is disabled during 1st post-conversion boot, so prompt should be visible.

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

## Frequently asked questions

### Can I encrypt Fedora Asahi Remix *after* installing it?

Yes — that is exactly what this is for. The Asahi installer has no full-disk
encryption option, so encrypting normally means starting over. `luks-deploy.sh`
converts the existing btrfs root in place instead, so your installed system,
subvolumes, snapshots and btrfs UUID all survive.

### Does this touch or wipe macOS?

No. macOS lives on separate APFS partitions that this tooling never reads or
writes. Only the btrfs Linux root partition is converted. Apple Silicon DFU and
System Recovery remain available regardless.

### Why do I have to type a passphrase at every boot? Can't it use the Secure Enclave?

There is no TPM on Apple Silicon, and Asahi has no interface to seal a key in the
Secure Enclave, so there is nowhere to store an auto-unlock key that would still
be safe. The KDF re-runs in the initramfs on every boot and you type the
passphrase. That is a platform constraint, not a shortcoming of this kit.

### Which KDF does this use, and can I change it?

argon2id, always — it is *memory-hard*, and that memory requirement is what caps
how many guesses a GPU or ASIC can run at once. You can tune its memory,
iteration and thread costs freely, at deploy time or on an existing volume; see
[Changing the KDF on a volume that already exists](#changing-the-kdf-on-a-volume-that-already-exists).
What you cannot sensibly do is swap the algorithm out — see
[Never use pbkdf2](#never-use-pbkdf2).

### Why is `/boot` left unencrypted?

GRUB has to read the kernel and initramfs before anything is unlocked. The
encrypted root is opened by the *initramfs*, not by GRUB, so keeping `/boot`
plain avoids putting GRUB on the unlock path at all — where it would be capped
by its own heap (1 GiB argon2id memory cost on GRUB ≥ 2.14, and no
argon2 support at all in GRUB 2.12, which is current in Fedora 44). The trade-off
is that `/boot` is unsigned; see [Risks](#risks--read-this).

### What happens if the encryption is interrupted — power loss, a crash, a closed lid?

Nothing fatal. LUKS2 re-encryption is journaled with checksum resilience. Re-run
`luks-deploy.sh` and it detects the interrupted state and resumes it
(`--resume-only`), running `cryptsetup repair` first if the journal is dirty.
That exact sequence — including a hard kill mid-reencrypt — is what the CI
loopback test exercises on every push.

### Can I run it unattended across several machines?

Yes. `LUKS_PROFILE` or the `LUKS_PBKDF_*` variables pin the KDF,
`LUKS_TARGET_ROOT` / `_BOOT` / `_EFI` pin the partitions, and
`LUKS_PASSPHRASE_FILE` supplies the passphrase, so no menu appears. Read
[docs/FLEET.md](docs/FLEET.md) first — there is a real UUID-uniqueness footgun
when imaging several boxes from one source.

### Will this work on an M1 with only 8 GB of RAM?

Yes, on any profile including `aggressive` at 4 GiB. The memory cost only has to
be allocatable in the initramfs, which has the machine entirely to itself. A base
M1 is slower than an M2 Max at identical parameters because argon2id is
memory-bandwidth-bound — which is why the installer benchmarks your machine
instead of quoting someone else's numbers.

### Does it work on anything other than Asahi?

The core script also runs on Fedora x86_64, Arch and Manjaro with btrfs roots.
The boot guards and the U-Boot documentation are Apple-Silicon-specific.

### How do I check what I actually ended up with?

```bash
sudo cryptsetup luksDump /dev/nvme0n1p6
```

Look for `Cipher: aes-xts-plain64`, a 512-bit key, and `PBKDF: argon2id` with
the memory and iteration figures from the profile you chose.

---

## Documentation

| Doc | Covers |
|-----|--------|
| [INSTALL.md](docs/INSTALL.md) | Step-by-step install, start to finish, with what each prompt means |
| [LIVE-USB.md](docs/LIVE-USB.md) | Building a Fedora Asahi live USB, and the three ways to boot it |
| [RECOVERY.md](docs/RECOVERY.md) | Interrupted encryption, unbootable system, corrupt header, undoing a shrink |
| [UBOOT-BOOTFLOW.md](docs/UBOOT-BOOTFLOW.md) | Getting to the U-Boot prompt and booting the live USB |
| [INTERNALS.md](docs/INTERNALS.md) | Every config file changed, the 12-point gate, self-repair, why `/boot` stays plain |
| [FLEET.md](docs/FLEET.md) | Deploying across several M-series boxes, and the UUID-uniqueness footgun |

---

## Contributing

Bug reports and patches are welcome — open an
[issue](https://github.com/doug445/AsahiLocker/issues) or a pull request.

Because this tooling rewrites a live root filesystem and its bootloader, a
description of what went wrong is rarely enough to act on.
**[CONTRIBUTING.md](CONTRIBUTING.md)** has copy-pasteable commands for the
things that are: a read-only diagnostic bundle, running the loopback suite and
the CI lint checks locally, dry-running the deploy, and verifying the GRUB
argon2 constraint on your own machine. It also covers building GRUB 2.14 with
argon2 into a local prefix, for anyone working on the `/boot` question.

## License and contact

MIT — see [LICENSE](LICENSE).

- **Author:** William MacKinnon ([doug445](https://github.com/doug445))
- **Email:** spilled-bowline0j@icloud.com
- **Repository:** https://github.com/doug445/AsahiLocker

Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
