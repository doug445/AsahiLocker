# Security Policy

## Supported Versions

AsahiLocker is maintained by one person and carries no backport branches. Fixes
land on `main` and go out in the next tagged release. Only the newest release is
supported; there is no long-term-support line and older tags do not receive
patches.

| Version | Supported |
| ------- | --------- |
| `main` | :white_check_mark: fixes land here first |
| Newest tagged release | :white_check_mark: |
| Any earlier tag | :x: upgrade to the newest release |

The [releases page](https://github.com/doug445/AsahiLocker/releases) lists every
tag, newest first, and each release's notes record what changed in it. This
project keeps that history in the release notes rather than in a
`CHANGELOG.md`.

If you are running a checkout you pulled weeks ago, `git pull` and retry before
reporting — the issue may already be fixed. Include what you are running:

```bash
git -C /path/to/AsahiLocker describe --tags --always --dirty
```

A `-dirty` suffix means the working tree has local modifications, and a hash
with no tag means the checkout is somewhere between releases. Say so in the
report either way — it changes what I can reproduce.

## Reporting a Vulnerability

I take the security of AsahiLocker seriously. If you discover a security
vulnerability, please do not open a public issue.

Instead, please report it privately by emailing the report to: spilled-bowline0j@icloud.com

**What to expect:**
* **Acknowledgment:** You will receive an initial response to your report within 72 hours.
* **Updates:** I will keep you informed of my progress as I investigate the issue and develop a fix.
* **Resolution:** If the vulnerability is accepted, I will address it promptly in a new release and notify you. If declined, I will provide a clear explanation of my reasoning.

Please include as much detail as possible in your email, including steps to
reproduce. Read [Before you send diagnostics](#before-you-send-diagnostics)
first — this project's output can contain key material.

## What is in scope

This tooling runs as root from a live USB, rewrites every sector of a root
partition in place, enrolls keyslots, and edits `crypttab`, `fstab`, the
initramfs, the BLS entries and the ESP. A mistake here does not degrade a
feature — it loses a disk or hands one over. That is the interesting surface:

* **Key material going somewhere it should not.** The recovery key file, the
  LUKS header backups, and anything read from `LUKS_PASSPHRASE_FILE`. A secret
  written world-readable, left on a filesystem the user did not choose, echoed
  into a log or the journal, or passed on a command line where `ps` can see it
  is a real finding.
* **Weakening the crypto without saying so.** Falling back to pbkdf2, enrolling
  a keyslot below the documented argon2id floor, or reporting parameters that
  are not the ones actually written to the header. The `fast` profile's floor is
  a hard floor by design and is not meant to be reachable from outside.
* **A verification gate that passes when it should not.** `luks-deploy.sh` gates
  the reboot behind its verification checks; `post-encryption-setup.sh` verifies
  the result. Either reporting success on a system that is not actually
  encrypted, or that will not boot, is a vulnerability and not a cosmetic bug.
* **Writing to the wrong device.** Anything that touches a disk other than the
  detected target — in particular the macOS APFS partitions or another install's
  ESP, neither of which this tooling has any business modifying.
* **A resume that resumes the wrong thing.** `--resume-only` and the
  interrupted-state detection acting on a device or header that does not match
  the state it recorded.
* **The boot guards not guarding.** The ESP stub guard letting a stray
  `grub2-mkconfig` overwrite the stub an encrypted boot depends on, or
  `restore-esp-grub-stub.sh` restoring a stub that does not match the volume.
* **A read-only tool that writes.** `luks-tune.sh` must never create or destroy
  a keyslot, change a passphrase, or touch data; `extras/luks-fetch-cache` must
  read public header metadata and nothing else; `tools/boot-probe/` must touch
  no real volume. Any of those doing otherwise is in scope, `--dry-run`
  especially.

## What is out of scope

* **Bugs in the software AsahiLocker drives** — `cryptsetup`, LUKS2, the argon2
  implementation, GRUB, U-Boot, m1n1, systemd, dracut, SELinux. Report those
  upstream.
* **`/boot` being unencrypted and unsigned**, and the evil-maid class of attack
  that permits. This is architectural on Asahi today, not an oversight: only
  m1n1 stage 1 is cryptographically verified, and GRUB in Fedora 44 has no
  argon2 support at all. The research and its current blockers are written up in
  [`docs/BOOT-ENCRYPTION-STATUS.md`](docs/BOOT-ENCRYPTION-STATUS.md).
* **Having to type the passphrase at every boot.** There is no TPM on Apple
  Silicon and nowhere to seal a key. That is the platform, not a design choice.
* **GRUB's argon2 memory ceiling**, including the 4 GiB allocation overflow.
  Upstream's, and documented in the README — it does not affect the root volume,
  which the initramfs unlocks rather than GRUB.
* **Overwriting the ESP stub yourself.** Running `grub2-mkconfig -o` against
  `/boot/efi/EFI/fedora/grub.cfg` replaces the chainload stub an encrypted boot
  depends on. The docs warn against it, `luks-deploy.sh` detects it, and the
  boot guards exist to undo it — the guards *failing* to catch it is in scope
  above; typing the wrong output path is not a vulnerability in this tooling.
* **A forgotten passphrase, or a lost recovery key.** There is no backdoor. That
  is the product working.
* **A weak passphrase you chose.** The README covers what the KDF can and cannot
  buy you here.

## Before you send diagnostics

**Read this one.** Unlike a networking tool, the artefacts this project produces
can be the keys themselves.

* **Never send a LUKS header backup.** Not `/boot/luks-header-backup.img`, not
  the copy on the deployment drive, not one from a recovery bundle. It carries
  your keyslots. They are argon2id-protected rather than plaintext, but sending
  one hands an attacker everything they need to start guessing offline, with no
  access to your machine required. There is no bug report that needs it.
* **Never send a recovery key or a passphrase**, and never send the
  `LUKS_PASSPHRASE_FILE` you pointed the script at.
* **`cryptsetup luksDump` output is safe to share** — it prints parameters, not
  key material. **Never add `--dump-master-key`**, which prints exactly that.
* **Recovery bundles are not diagnostics.** They are built to unlock the volume.
  Send the piece you are asking about, never the bundle.
* **Read the deployment log before attaching it.** It carries device paths,
  UUIDs and your partition layout. Usually fine to send, occasionally more than
  you meant to.

Send the smallest thing that demonstrates the problem.
