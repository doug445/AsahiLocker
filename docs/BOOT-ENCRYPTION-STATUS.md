# Encrypted `/boot` — research status, and a request for help

> ### ⚠️ NOT SHIPPED. NOT ENABLED. DO NOT RUN THIS ON A MACHINE YOU NEED.
>
> AsahiLocker encrypts **root only**. `/boot` is plain ext4 and stays that way
> in every released version. There is no `--encrypt-boot` flag, no menu entry,
> and no code path in `bin/` that touches `/boot`'s encryption state.
>
> This document is a **laboratory notebook**, not a feature. It records what has
> been measured on real hardware, what broke, and what is still unknown. The
> only executable code here lives in [`tools/boot-probe/`](../tools/boot-probe/),
> which creates throwaway LUKS containers holding nothing and never touches a
> real volume.
>
> The gate lifts when the open questions below are answered — not before. That
> will be a **major** version bump.

**Platform for everything below:** 2023 MacBook Pro, M2 Max, 32 GiB, Fedora
Asahi Remix 44, aarch64, U-Boot + GRUB, `cryptsetup 2.8.7`, kernel
`7.1.6-400.asahi.fc44.aarch64+16k`. Self-built **GRUB 2.14** for `arm64-efi`
with `argon2` (Fedora ships 2.12, which has no argon2 at all).

---

## Why this is hard

Root is unlocked by the **initramfs** — full Linux userspace, no meaningful
constraints. `/boot` would have to be unlocked by **GRUB**, which is a different
world: a single-threaded, memory-constrained environment with its own
implementation of argon2id. The two are not interchangeable, and this project
now has numbers proving how far apart they are.

Three things had to be established before any of it could ship:

1. Can GRUB allocate enough memory for a serious argon2id cost under U-Boot?
2. How long does GRUB actually take? (You pay it at every boot.)
3. Does failure fail *cleanly*, or does it hang/reset at the passphrase prompt?

All three now have answers. Two are good. One is not.

---

## Result 1 — allocation: better than the folklore says

**Every size tested allocated *and* completed a real keyslot decryption**
(`Slot "0" opened` — not merely a successful `malloc`):

```
RESULTS: 512M=OK  1024M=OK  2048M=OK   envwrite=OK
```

**The widely-repeated "GRUB caps argon2id at 1 GiB" is not a property of GRUB.**
It is a property of **x86 vendor UEFI**, which leaves GRUB a constrained heap.
GRUB's EFI heap starts at 32 MiB (`DEFAULT_HEAP_SIZE 0x2000000`) and grows on
demand via `grub_efi_mm_add_regions`; how far it gets is the firmware's
decision. Under Asahi's U-Boot it gets further — 2 GiB works here.

**The one unconditional rule is 4 GiB, and it has nothing to do with firmware.**
In `grub-core/lib/libgcrypt-grub/cipher/kdf.c`, `argon2_init` does:

```c
xtrymalloc (1024 * memory_blocks)      /* memory_blocks is unsigned int */
```

At exactly 4 GiB, `1024 * 4194304 == 2^32`, which wraps to **0**. GRUB then
calls `xtrymalloc(0)` and carries on instead of rejecting the parameters. Never
configure a GRUB-unlocked volume at 4 GiB.

---

## Result 2 — timing: GRUB is 8.5× slower than the kernel

Measured with GRUB's own `time` command:

| case | GiB-passes | elapsed |
|---|---|---|
| 1 GiB × 4 | 4 | **8.096 s** |
| 1 GiB × 10 | 10 | **20.224 s** |
| 2 GiB × 10 | 20 | **39.624 s** |
| 2 GiB × 20 | 40 | **machine reset — see Result 3** |

**Linear in memory × iterations, at ~2.0 s per GiB-pass** — 2.024 / 2.022 /
1.981, a 2.1 % spread across the three that finished.

For comparison, the same 40 GiB-passes (4 GiB × 10) is this machine's *root*
keyslot, and the initramfs derives it in **9.5 s** — 0.2375 s per GiB-pass.

> **GRUB is 8.5× slower than the kernel for identical argon2id work.**
> Initramfs timings do not transfer, and they are not off by a little.

Practical consequence: **encrypted `/boot` costs ~20 s at every boot minimum**,
on the fastest Apple Silicon Mac currently available.

---

## Result 3 — the failure: a reset wall, and it is not graceful

`2 GiB × 20` (≈80 s predicted) **never printed a result. The machine reset
instantly, twice, at the same point, with nothing on screen.**

**This is not an allocation failure**, and the reasoning matters:

> `2 GiB × 20` allocates *exactly the same memory* as `2 GiB × 10`, which had
> succeeded seconds earlier in the same session. Identical footprint; only the
> duration differs. Whatever kills it is a function of **time**, not size.

The leading hypothesis is a watchdog. GRUB *does* disable the EFI one —
`grub_efi_system_table->boot_services->set_watchdog_timer (0, 0, 0, NULL)` in
`grub-core/kern/efi/init.c` — so the suspect is Apple's **hardware** watchdog,
which U-Boot leaves running and which is only serviced when GRUB calls into
firmware (console output, `stall`). argon2 is a pure compute loop that calls
into nothing.

That also explains an apparent contradiction: ~82 s of *cumulative* probe time
before this case was survivable, because every `echo` and `sleep` between cases
hands the firmware a turn. It is **one uninterrupted computation** that starves
it.

**The wall is somewhere between 40 s and 80 s of uninterrupted computation, and
crossing it is a hard reset with no diagnostic output whatsoever.**

### Why this is the most important result

- **Matching a strong root keyslot inside GRUB is impossible on this machine.**
  A root at 4 GiB × 10 is 40 GiB-passes. 4 GiB is barred by the overflow, and
  2 GiB × 20 resets the box. There is no configuration that reaches it.
- **Parameters must be chosen against the slowest supported Mac, with real
  margin.** 2 GiB × 10 costs 39.6 s *here* and is already near the boundary. A
  base M1 has less memory bandwidth, so the same parameters take longer — and a
  machine that crosses the wall **cannot boot at all**, with nothing on screen
  to diagnose from. This is the strongest argument for keeping `/boot` at
  1 GiB: 20.2 s, roughly 2× headroom.

---

## Result 4 — `save_env` reports success and writes nothing

The first probe wrote results with `save_env` to a pre-allocated `grubenv` on
the FAT ESP. The screen said `grubenv writable: OK`. **Nothing reached the
disk.**

Verified by searching the raw partition — the only `probe_started=yes` on the
ESP is the literal string inside `grub.cfg`, while the grubenv block still reads
`probe_started=no`:

```bash
sudo dd if=/dev/nvme0n1p4 bs=1M 2>/dev/null | grep -a -o -b 'probe_started=[a-z]*'
# 410968347:probe_started=yes    <- the literal inside grub.cfg
# 410972304:probe_started=no     <- the actual env block, unchanged
```

Note `mtime` is **not** evidence either way: `save_env` writes raw blocks by
block list and never touches the FAT directory entry.

Curiously this is *not* a blanket "GRUB cannot write" — Fedora's GRUB 2.12 does
successfully clear `menu_show_once_timeout` from the grubenv on the **ext4**
`/boot`, on the same disk, through the same EFI block path. **Cause unresolved
— see Open questions.**

Operational rule taken from it: **never design anything that depends on GRUB
persisting state to the ESP, and never treat a `save_env` return value as proof
it wrote.** The screen is the only channel that has proven reliable.

---

## Failures along the way (all fixed — recorded so nobody repeats them)

**1. `insmod chain` failed; every kernel entry then appeared broken.**
Fedora ships `chain.mod` but never populates `/boot/grub2/arm64-efi/`, and
`chainloader` is not built into its prebuilt `grubaa64.efi`. Worse, the probe's
menu entry used `search --set=root`, which is **global and persists after the
entry fails** — so every BLS kernel entry selected afterwards resolved against
the wrong device and died with the same error. *Nothing was actually damaged.*
Fix: populate the module dir, and pin with a private variable instead:

```bash
sudo cp -a /usr/lib/grub/arm64-efi/*.{mod,lst} /boot/grub2/arm64-efi/
# and in the menuentry, never --set=root:
#   search --no-floppy --fs-uuid --set=probe_dev <ESP-UUID>
#   chainloader ($probe_dev)/asahilocker-probe/grub-argon2-probe.efi
```

⚠️ That module directory must stay version-locked to `grubaa64.efi`. Re-copy
after any `grub2-*` update or you reproduce this exact failure.

**2. The embedded config runs under GRUB's *rescue* parser.**
`grub-mkimage --config` is executed by `grub_load_config()` **before**
`grub_load_normal_mode()`, so it is parsed by `grub_rescue_parser`: simple
commands only, **no `if`/`then`/`else`**. Every measurement was inside an `if`,
so the probe could never have completed on any hardware. Then `normal` loaded,
found no `grub.cfg` at `$prefix`, **cleared the screen**, and dropped to a
prompt — destroying the output too.

> **General lesson: an embedded GRUB config can hold only simple commands.** Put
> anything with control flow in a real `grub.cfg` at `$prefix` and let `normal`
> parse it. The embedded config should do nothing but pin the device and set
> `$prefix`.

**3. `date` is useless here.** U-Boot implements no EFI `GetTime` runtime
service, so every timestamp printed
`lib/efi/datetime.c:grub_get_datetime:38:can't get datetime using efi`.
But `sleep --verbose` worked in that same run — which proves
`grub_get_time_ms()` is fine, and that is exactly the clock
`grub-core/commands/time.c` uses. Switching to `time cryptomount …` gave
millisecond resolution with no video and no stopwatch.

**4. The menu is auto-hidden on a healthy system.** `GRUB_TIMEOUT` in
`/etc/default/grub` is not what you get: `grubenv` carries `menu_auto_hide=1`,
so after a successful boot `12_menu_auto_hide` forces `timeout_style=hidden`
with `timeout=1`. Force a menu for exactly one boot:

```bash
sudo grub2-editenv - set menu_show_once_timeout=30
```

`14_menu_show_once` runs after the auto-hide block so it wins, and clears the
variable as it fires. **Re-set it if you reboot more than once.**

---

## Prerequisite — building GRUB 2.14 with argon2

**Fedora 44 ships GRUB 2.12, which has no argon2 support at all.** Nothing here
works without a newer GRUB, so this is step zero.

Good news: **argon2 is upstream in GRUB 2.14 — no patches are needed.**
`grub-core/lib/argon2.c` is present and registered in
`grub-core/Makefile.core.def` at the `grub-2.14` tag.

On an Apple Silicon Mac this is a **native** build (`aarch64` host, `aarch64`
target), so no cross-toolchain is required.

```bash
# Fedora build deps. autoconf-archive is the one people miss --
# bootstrap fails confusingly without it.
sudo dnf install -y git autoconf automake autoconf-archive libtool \
                    flex bison gettext-devel texinfo python3 \
                    device-mapper-devel freetype-devel gcc make patch

git clone https://git.savannah.gnu.org/git/grub.git ~/Projects/grub-argon2-build
cd ~/Projects/grub-argon2-build
git checkout grub-2.14

# bootstrap pulls in gnulib. LC_ALL matters: it fails on some locales.
LC_ALL=C.UTF-8 ./bootstrap

./configure \
    --target=aarch64 \
    --with-platform=efi \
    --prefix="$PWD/install-root" \
    --disable-werror \
    --disable-nls \
    --disable-grub-mkfont \
    --disable-grub-themes \
    PYTHON=/usr/bin/python3

make -j"$(nproc)"
make install
```

That is the exact invocation this project's results were produced with,
recovered from the build tree's own `config.status`. `--disable-nls` and
`--disable-grub-mkfont`/`--disable-grub-themes` are there to avoid unrelated
build breakage; they have no bearing on the crypto.

Verify before going further — you want **2.14**, and `argon2.mod` must exist:

```bash
./install-root/bin/grub-mkimage --version        # (GRUB) 2.14
ls install-root/lib/grub/arm64-efi/argon2.mod
```

**Nothing is installed system-wide.** The build stays in its own prefix and the
probe scripts read it from there; your distro's GRUB is untouched.

> ### Do not replace your system GRUB with this
> Encrypted `/boot` will eventually need a GRUB with `argon2 luks2 cryptodisk
> ext2` built into the **core image** — modules cannot be read from inside the
> volume they are needed to unlock. That is a separate, riskier step which this
> research has not reached, and it is the point at which a mistake stops the
> machine booting. The probes deliberately **chainload** a self-contained image
> instead, leaving the installed bootloader alone.

---

## Reproducing this

Everything lives in [`tools/boot-probe/`](../tools/boot-probe/). It builds
throwaway LUKS containers with the passphrase `grubtest`, holding nothing, and
chainloads the self-contained GRUB 2.14 image that opens them. **No real volume
is touched.**

Point `GRUB_PREFIX` at your build's install root if it is not the default
`~/Projects/grub-argon2-build/install-root`.

```bash
# allocation probe — how much memory can GRUB get?
./tools/boot-probe/build-probe.sh /boot/efi

# timing probe — how long does it take? (edit PAIRS to change cases)
./tools/boot-probe/build-timing-probe.sh /boot/efi

# add a menu entry to /boot/grub2/custom.cfg pointing at the payload
# (create the file if absent; Fedora's grub.cfg already sources it):
#
#   menuentry 'AsahiLocker: argon2id allocation probe (GRUB 2.14)' {
#       insmod part_gpt
#       insmod fat
#       insmod chain
#       search --no-floppy --fs-uuid --set=probe_dev <YOUR-ESP-UUID>
#       chainloader ($probe_dev)/asahilocker-probe/grub-argon2-probe.efi
#   }
#
# ...and the same for the timing probe, pointing at
#   ($probe_dev)/asahilocker-timing/grub-argon2-timing.efi
#
# Fedora does not populate its module dir, so chainloader is missing:
sudo mkdir -p /boot/grub2/arm64-efi
sudo cp -a /usr/lib/grub/arm64-efi/*.{mod,lst} /boot/grub2/arm64-efi/

# then force the menu for one boot:
sudo grub2-editenv - set menu_show_once_timeout=30

# afterwards
sudo ./tools/boot-probe/read-results.sh /boot/efi/asahilocker-probe/grubenv
./tools/boot-probe/remove-probe-internal.sh
./tools/boot-probe/remove-timing-probe.sh
```

`grub.cfg` is never modified. Fedora's already sources `custom.cfg` from
`$prefix`, so the menu entry goes in a file of its own and survives
`grub2-mkconfig`. **Photograph the screen** — it is the only result channel that
has proven trustworthy.

---

## Open questions — this is where help is wanted

**If you have Apple Silicon running Asahi and are willing to run a probe that
touches no real volume, these are the gaps.** Please open an issue with your
machine model, RAM, and the photographed screen.

1. **Where exactly is the reset wall?** We know 40 s survives and ~80 s does
   not. A bisect at 1 GiB × 20 / 25 / 30 / 35 (≈40 / 50 / 60 / 70 s — memory
   constant, only duration varying) would find the edge and turn "stay under
   40 s and hope" into a real margin. **Highest value question here.**
2. **Is it really the Apple hardware watchdog?** If so, can GRUB pet it, or can
   argon2's inner loop be made to yield to firmware periodically? A fix here
   would raise the ceiling for every Asahi user, not just this project.
3. **What are the numbers on other Macs** — especially a base **M1 with 8 GiB**?
   Both the allocation ceiling and the per-GiB-pass cost are expected to differ,
   and the *slowest* machine sets the safe parameters for everyone.
4. **Why does `save_env` succeed-but-not-write on the FAT ESP** while working on
   ext4 `/boot` on the same disk? U-Boot EFI block-write quirk, GRUB FAT
   block-list bug, or something else?
5. **Does argon2id fail cleanly when it cannot allocate?** Never observed — every
   size tested succeeded. A silent hang at the passphrase prompt would be far
   worse than an error, and it would force a much more conservative default.
6. **Is `2 GiB` reachable on non-Apple U-Boot platforms?** If the ceiling
   tracks firmware rather than GRUB, other U-Boot boards should show it too.

### Not looking for help with

- Making `/boot` use pbkdf2 to satisfy stock GRUB 2.12. It is memory-hard or it
  is not worth doing; see [INTERNALS.md](INTERNALS.md).
- Anything at 4 GiB. The overflow is unconditional.

---

## Design work already done

The architecture, the two unlock options and their trade-offs, the retrofit
rules for an already-encrypted root, and the release plan are in
**[BOOT-ENCRYPTION-DESIGN.md](BOOT-ENCRYPTION-DESIGN.md)**. Short version of the
part that most affects contributors:

- Both unlock architectures stay available and the user chooses explicitly —
  one passphrase with a keyfile inside the encrypted `/boot`, or two separate
  passphrases. **Neither is pre-selected**, because the right answer depends on
  the owner's threat model, and the converter's job is to compute and show the
  real consequence rather than to decide.
- On a machine whose root is stronger than what GRUB can reach, the keyfile
  option **measurably lowers** the cheapest way in. The converter must read the
  root keyslot with `cryptsetup luksDump` and state the ratio.
- The keyfile option makes `/boot` backups secret-bearing, and revoking it means
  removing the keyslot *and* regenerating every initramfs — not deleting a file.

---

## Contributing

Issues and PRs welcome: <https://github.com/doug445/AsahiLocker/issues>

Probe results are the most useful contribution right now — a photograph of the
screen, plus your machine model and RAM, moves this further than anything else.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the general rules.
