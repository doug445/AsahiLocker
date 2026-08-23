# Contributing to AsahiLocker

Bug reports and patches are welcome. Because this tooling rewrites a live root
filesystem and its bootloader, the bar for a useful report is higher than usual:
**a description of what went wrong is rarely enough to act on.** The commands
below collect what actually is.

Every command block is written to be pasted in one go.

---

## Golden rule for testing

**Never test changes against a system you care about.** The loopback harness in
`tests/` exercises the real encrypt / resume / repair / recovery-key sequence
against a throwaway file-backed device. Use it. If you need a full boot test, use
a spare disk or an external USB install — not your daily driver.

`luks-deploy.sh` refuses to encrypt the filesystem it is booted from, but that is
a backstop, not a substitute for judgement.

---

## Reporting a problem

### 1. The diagnostic bundle

Run this and attach the output file. It is read-only — it collects state and
changes nothing:

```bash
OUT="asahilocker-diag-$(date +%Y%m%d-%H%M%S).txt" && { \
  echo "=== os ==="; cat /etc/os-release; \
  echo "=== kernel ==="; uname -a; \
  echo "=== cryptsetup ==="; cryptsetup --version; \
  echo "=== grub packages ==="; rpm -q grub2-common grub2-efi-aa64 grub2-tools 2>&1; \
  echo "=== grub crypto modules ==="; ls /usr/lib/grub/arm64-efi/ 2>/dev/null | grep -E 'luks|crypt|argon|pbkdf2' | sort; \
  echo "=== secure boot ==="; mokutil --sb-state 2>&1; \
  echo "=== block layout ==="; lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT; \
  echo "=== fstab ==="; grep -v '^#' /etc/fstab | grep -v '^$'; \
  echo "=== crypttab ==="; sudo grep -v '^#' /etc/crypttab 2>/dev/null || echo none; \
  echo "=== kernel cmdline (running) ==="; cat /proc/cmdline; \
  echo "=== kernel cmdline (configured) ==="; sudo cat /etc/kernel/cmdline 2>/dev/null || echo none; \
  echo "=== BLS entries ==="; sudo grep -H '' /boot/loader/entries/*.conf 2>/dev/null || echo none; \
  echo "=== grub defaults ==="; sudo grep -v '^#' /etc/default/grub 2>/dev/null; \
  echo "=== dracut luks conf ==="; sudo cat /etc/dracut.conf.d/99-luks.conf 2>/dev/null || echo none; \
  echo "=== ESP ==="; sudo ls -la /boot/efi/EFI/*/ 2>/dev/null; \
  echo "=== ESP stub grub.cfg ==="; sudo cat /boot/efi/EFI/fedora/grub.cfg 2>/dev/null || echo none; \
} > "$OUT" 2>&1 && echo "wrote $OUT"
```

### 2. The LUKS header

**Never paste `luksDump --dump-master-key`, and never upload a header backup
image** — either one hands over your disk. Plain `luksDump` is safe: it shows
cipher, KDF and slot metadata, no key material.

```bash
sudo cryptsetup luksDump /dev/nvme0n1p6
```

Substitute your own root device. Confirm it first with `lsblk -f`.

### 3. If the deploy itself failed

`luks-deploy.sh` writes a state backup to the deployment drive before it touches
anything. Say which stage it stopped at (the script prints stage numbers), and
include the recovery command list it printed on exit — the cleanup trap tailors
that list to how far the run got.

### 4. If the machine will not boot

Read [`docs/RECOVERY.md`](docs/RECOVERY.md) first — it covers interrupted
encryption, corrupt headers and unbootable systems, and most cases are already
documented there. If you still need to report it, capture what the screen showed
and at which stage of [`docs/UBOOT-BOOTFLOW.md`](docs/UBOOT-BOOTFLOW.md) it
stopped.

---

## Reproducing before you report

### Run the test suite

This is the same suite CI runs. It creates loop devices and destroys them
afterwards; it does not touch any real disk:

```bash
sudo bash tests/loopback-core-test.sh
```

Expect `18 passed, 0 failed`. A `SKIP` line in stage 5b is normal — that stage
races a hard kill against a live re-encryption and reports honestly when it did
not manage to build the state it wanted.

### Run the CI lint checks

Exactly what `.github/workflows/lint.yml` runs, so you find failures before the
PR does:

```bash
for f in $(git ls-files '*.sh') boot-guards/bin/esp-grub-stub-rebaseline extras/bin/luks-fetch-cache; do \
  bash -n "$f" || echo "SYNTAX FAIL: $f"; \
done && shellcheck -S warning $(git ls-files '*.sh') \
  boot-guards/bin/esp-grub-stub-rebaseline extras/bin/luks-fetch-cache && echo "lint clean"
```

### Dry-run the deploy

Runs the whole read-only half — detection, menus, fstab cross-checks, the KDF
benchmark — prints the exact `cryptsetup reencrypt` it would issue, and stops
before the point of no return:

```bash
sudo ./bin/luks-deploy.sh --dry-run
```

---

## Verifying the GRUB / argon2 constraint

`/boot` encryption is unsupported because Fedora's aarch64 GRUB cannot open an
argon2id volume. Confirm that on your own machine rather than taking the docs'
word for it.

**Which crypto modules Fedora actually ships.** Note the absence of `argon2.mod`:

```bash
rpm -q grub2-efi-aa64 && ls /usr/lib/grub/arm64-efi/ | grep -E 'luks|crypt|argon|pbkdf2' | sort
```

**Which modules are baked into the installed EFI binary.** These are the ones
available before any filesystem is readable:

```bash
sudo strings /boot/efi/EFI/fedora/grubaa64.efi \
  | grep -oE '^(cryptodisk|luks|luks2|pbkdf2|argon2|gcry_[a-z0-9]+|search|ext2|part_gpt)$' \
  | sort -u | tr '\n' ' '; echo
```

**Whether Secure Boot would reject a replacement GRUB:**

```bash
mokutil --sb-state
```

---

## Building GRUB 2.14 with argon2 (for `/boot` work)

Fedora ships GRUB 2.12, which has no argon2 at all. Upstream added it in 2.14.
This builds into a local prefix and **installs nothing system-wide**:

```bash
sudo dnf install -y autoconf-archive gcc make bison flex autoconf automake \
  gettext-devel freetype-devel device-mapper-devel python3 && \
git clone https://git.savannah.gnu.org/git/grub.git ~/grub-argon2-build && \
cd ~/grub-argon2-build && git checkout grub-2.14
```

```bash
cd ~/grub-argon2-build && export LC_ALL=C.UTF-8 && ./bootstrap && ./configure \
  --target=aarch64 --with-platform=efi --prefix="$PWD/install-root" \
  --disable-werror --disable-nls --disable-grub-mkfont --disable-grub-themes && \
make -j"$(nproc)" && make install
```

`--disable-nls` is not cosmetic: the `po/` catalogs fail to build under a
non-UTF-8 locale (`Locale charset "ANSI_X3.4-1968" is different from input file
charset "UTF-8"`), and that failure aborts `make` after the modules have already
been built successfully. `LC_ALL=C.UTF-8` addresses the same root cause.

Confirm you got the module Fedora omits:

```bash
ls -la ~/grub-argon2-build/install-root/lib/grub/arm64-efi/argon2.mod
```

> **Do not install this over the system GRUB casually.** Secure Boot is disabled
> and the platform is in Setup Mode on Apple Silicon, so nothing will stop you —
> which is exactly why it is worth being deliberate. Have the recovery routes in
> [`docs/UBOOT-BOOTFLOW.md`](docs/UBOOT-BOOTFLOW.md) to hand first.

---

## Patches

- **Shell only.** Every script must pass `bash -n` and `shellcheck -S warning`;
  CI enforces both on x86_64 and aarch64.
- **Every script carries the MIT header**, immediately after the shebang. These
  scripts get copied onto live USBs and pulled out of the repo individually, so
  a bare "see LICENSE" would leave a standalone copy with no terms attached.
  Copy the block verbatim from any existing script. Check yours before opening a
  PR:

  ```bash
  for f in $(git ls-files '*.sh') boot-guards/bin/esp-grub-stub-rebaseline \
    extras/bin/luks-fetch-cache; do \
    grep -q 'SPDX-License-Identifier: MIT' "$f" || echo "MISSING LICENSE: $f"; \
  done && echo "all scripts licensed"
  ```
- **Match the surrounding style.** The existing scripts use explicit stage
  banners, `set -euo pipefail`, and cleanup traps that print a recovery command
  list on failure. Keep that.
- **Anything touching the encrypt path needs a test** in
  `tests/loopback-core-test.sh`. Build the state you want to assert against
  deterministically — do not race a `kill` and then guess what state you
  produced. Stage 5 uses `cryptsetup reencrypt --init-only` for exactly this
  reason.
- **Never assert on a cheaper probe than the one you are testing.**
  `cryptsetup isLuks` accepts headers that `cryptsetup open` rejects; they
  disagree on partially written headers, and that disagreement has produced a
  false CI pass before.
- **Do not weaken the KDF to work around a limitation.** Substituting pbkdf2 to
  satisfy an old GRUB is not an acceptable fix in this repo. See
  [`docs/INTERNALS.md`](docs/INTERNALS.md).
- **State what you tested.** If a change is untested on real hardware, say so in
  the PR. Documenting an unverified failure mode as though it were observed is
  worse than documenting nothing.

## Security issues

Do not open a public issue. See [`SECURITY.md`](SECURITY.md).

## Conduct

Technical disagreement is welcome — say why something is wrong and what you
tested, on what hardware. See [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
