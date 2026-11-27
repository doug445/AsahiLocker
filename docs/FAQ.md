# Frequently asked questions

## Can I encrypt Fedora Asahi Remix *after* installing it?

Yes — that is exactly what this is for. The Asahi installer has no full-disk
encryption option, so encrypting normally means starting over. `luks-deploy.sh`
converts the existing btrfs root in place instead, so your installed system,
subvolumes, snapshots and btrfs UUID all survive.

## Does this touch or wipe macOS?

No. macOS lives on separate APFS partitions that this tooling never reads or
writes. Only the btrfs Linux root partition is converted. Apple Silicon DFU and
System Recovery remain available regardless.

## Why do I have to type a passphrase at every boot? Can't it use the Secure Enclave?

There is no TPM on Apple Silicon, and Asahi has no interface to seal a key in the
Secure Enclave, so there is nowhere to store an auto-unlock key that would still
be safe. The KDF re-runs in the initramfs on every boot and you type the
passphrase. That is a platform constraint, not a shortcoming of this kit — and
it is why the KDF here is argon2id and the passphrase advice is not optional:
[How this compares with FileVault](CRYPTO.md#how-this-compares-with-filevault--the-kdf-macos-gives-the-same-disk)
lays out what the Secure Enclave does for macOS and what stands in for it here.

## Which KDF does this use, and can I change it?

argon2id, always — it is *memory-hard*, and that memory requirement is what caps
how many guesses a GPU or ASIC can run at once. You can tune its memory,
iteration and thread costs freely, at deploy time or on an existing volume; see
[Changing the KDF on a volume that already exists](CRYPTO.md#changing-the-kdf-on-a-volume-that-already-exists).
What you cannot sensibly do is swap the algorithm out — see
[Never use pbkdf2](CRYPTO.md#never-use-pbkdf2).

## Why is `/boot` left unencrypted?

Because that is the normal LUKS arrangement, and because encrypting it on a
Mac would cost a great deal and protect almost nothing.

- **It is how encrypted Linux is normally installed.** Fedora's own installer,
  with "Encrypt my data" ticked, leaves `/boot` unencrypted; so do Ubuntu's and
  Debian's. The kernel and initramfs are read from `/boot`, and the initramfs
  unlocks the root. That is exactly what AsahiLocker sets up.
- **On Apple Silicon it would move the weak spot, not remove it.** m1n1
  stage 2, U-Boot and GRUB live on the EFI partition, which nothing can
  encrypt and nothing on this platform verifies (only m1n1 stage 1 is
  verified). Anyone who could change `/boot` could change those instead.
- **GRUB is the wrong place to run argon2id.** Measured on an M2 Max, GRUB's
  argon2id is 8.5 times slower than the kernel's. The root's 4 GiB x 10 would
  take about 80 seconds there, past the point where the machine was seen to
  reset (somewhere between 40 and 80 seconds of uninterrupted work), and GRUB
  cannot take 4 GiB at all: a 32-bit overflow in its `argon2_init`. Whatever
  fits is a weaker keyslot than the root's, and so the cheapest way in.
  GRUB 2.12, the one in Fedora 45, has no argon2 support at all.

The research that measured all this is retired and kept as a record:
[BOOT-ENCRYPTION-STATUS.md](BOOT-ENCRYPTION-STATUS.md). What is left open by
an unencrypted, unsigned `/boot`, and what helps (the optional boot tripwire
that reports changes to it), is in
[What this protects, and what it does not](../README.md#what-this-protects-and-what-it-does-not).

## What happens if the encryption is interrupted — power loss, a crash, a closed lid?

Nothing fatal. LUKS2 re-encryption is journaled with checksum resilience. Re-run
`luks-deploy.sh` and it detects the interrupted state and resumes it
(`--resume-only`), running `cryptsetup repair` first if the journal is dirty.
That exact sequence — including a hard kill mid-reencrypt — is what the CI
loopback test exercises on every push.

A mistyped passphrase is not an interruption at all: `cryptsetup` asks for it
before it writes anything, so if the two entries differ, or it refuses the
passphrase as too weak, the script checks that the partition is untouched and
asks again.

## Will a quantum computer break this?

No — not the part of the system this tool builds. The quantum threat is
specific, and none of it lands on a LUKS2 volume at rest:

- **Shor's algorithm breaks public-key cryptography** — RSA, ECDH, ECDSA. LUKS2
  contains none: the header holds keyslots, salts and a digest, and the data
  is symmetric AES. There is no public key to factor, and nothing was ever
  transmitted, so "harvest now, decrypt later" — which is about recorded TLS
  key exchanges — has no analogue for a disk in a drawer.
- **Grover's algorithm halves symmetric key strength**, and that is the whole of
  its effect on AES. This tool uses AES-256-XTS (a 512-bit XTS key), so the
  theoretical quantum brute force is 2^128 operations — the same class as
  brute-forcing AES-128 classically, which is considered infeasible for the
  age of the universe. NIST rates AES-256 as quantum-safe at its highest
  category; it is the recommendation *for* the post-quantum era, not a victim
  of it.
- **The sha512 in the header** (anti-forensic splitter, volume-key digest) is a
  preimage target, not a collision target; Grover leaves it at 2^256.
- **The passphrase is the only lever, and argon2id guards it.** Grover could in
  principle square-root a passphrase search — but every one of those guesses
  is a full argon2id evaluation, 1 to 4 GiB of memory-hard, sequential work,
  and nobody has a design for running that inside a quantum computer at any
  useful rate. The memory cost that stops a GPU fleet stops this too. If you
  want margin anyway, the fix is available today and costs nothing: ten
  diceware words instead of eight.

What quantum *will* eventually change, for context: TLS and SSH key exchange,
GPG or age files encrypted to RSA/ECC public keys, and the RSA signatures that
Secure Boot verifies (not used on Asahi). Those are the
firmware and protocol ecosystems' migrations, they are not a way into the data
on this disk, and the disk does not need to wait for them.

## Can I run it unattended across several machines?

Yes. `LUKS_PROFILE` or the `LUKS_PBKDF_*` variables pin the KDF,
`LUKS_TARGET_ROOT` / `_BOOT` / `_EFI` pin the partitions, and
`LUKS_PASSPHRASE_FILE` supplies the passphrase, so no menu appears. Read
[docs/FLEET.md](FLEET.md) first — there is a real UUID-uniqueness footgun
when imaging several boxes from one source.

## Will this work on a Mac with only 8 GB of RAM?

Yes. On any Mac with 8 GB, M1, M2 or M3 alike, the default profile is
`moderate`, 2 GiB x 8: twice the work per guess of `cryptsetup`'s own default,
and the one the menu and `--defaults` choose there. The KDF's memory has to be
free in the initramfs at every boot or the volume does not open; 4 GiB is half
of an 8 GB machine, and the initramfs only grows as firmware and GPU support are
added to it. The rule is the RAM, not the chip. `aggressive` stays on the menu,
and `LUKS_PROFILE=aggressive` takes it. Every Mac with more than 8 GB keeps
`aggressive` as the default.

A base M1 is slower than an M2 Max at identical parameters because argon2id is
memory-bandwidth-bound, which is why the installer benchmarks your machine
instead of quoting someone else's numbers.

## Can swap leak what the encryption protects?

Only if it is on the disk outside the encryption. Fedora Asahi Remix swaps to
**zram**, compressed RAM that never reaches the disk; that needs nothing. A
swap *partition*, or a swap *file* on any filesystem but the root (on `/boot`,
say), stays plain: whatever the kernel swaps out, keys, passwords and open
documents included, lands on the disk unencrypted, root encrypted or not. A
swap file on the root filesystem is inside the encryption and fine.

`luks-deploy.sh` reads the install's fstab and its `.swap` units before it
encrypts, names any such swap and stops until you type `swap`;
`post-encryption-setup.sh` checks again what is actually swapping.

Two ways to fix it, on the encrypted system:

**Swap to zram only, Fedora's default** (the simple one):

```bash
sudo swapoff /boot/swapfile     # the swap the check named
sudoedit /etc/fstab             # delete its line
sudo rm /boot/swapfile
```

For a swap partition, `swapoff` it and delete its fstab line the same way. Its
old contents are still on it in plain text: `sudo blkdiscard /dev/nvme0n1pN`
discards them; then reuse or delete the partition.

**Keep a disk swap, encrypted with a new random key at every boot.** In
`/etc/crypttab`, and in `/etc/fstab` in place of the old swap line:

```text
swap  PARTUUID=<its PARTUUID>  /dev/urandom  swap,cipher=aes-xts-plain64,size=512,sector-size=4096
/dev/mapper/swap  none  swap  defaults  0 0
```

Name the partition by `PARTUUID` (`lsblk -o NAME,PARTUUID`), never `UUID=` or
`LABEL=`: the random key rewrites the swap signature at every boot, and the
filesystem UUID with it. Nothing survives a reboot, so there is no hibernation,
which Asahi does not offer anyway.

## Does it work on anything other than Asahi?

No. AsahiLocker is for Fedora Asahi Remix on Apple Silicon (aarch64) only. The
boot guards, the ESP stub handling and the U-Boot documentation are
Apple-Silicon-specific, and Apple Silicon is the only platform it is developed
and tested on.

For anything else, use **[LinuxLocker](https://github.com/doug445/LinuxLocker)**.
Same in-place LUKS2 conversion, aimed at the rest of the world: it identifies
the distro and package manager, resolves the filesystem tools once it knows
what the target uses, handles systemd-boot as well as GRUB, and rebuilds and
re-signs Unified Kernel Images for Secure Boot. AsahiLocker is the Apple
Silicon sibling of it.

## How do I check what I actually ended up with?

```bash
sudo cryptsetup luksDump /dev/nvme0n1p6
```

Look for `Cipher: aes-xts-plain64`, a 512-bit key, `PBKDF: argon2id` with
the memory and iteration figures from the profile you chose, and under
*Data segments* `sector: 4096 [bytes]`. A volume made by a release before
1.12.0 shows `sector: 512 [bytes]` — it is exactly as secure, just doing eight
XTS operations per filesystem block instead of one. It can be changed only by
a full in-place re-encryption (`cryptsetup reencrypt --sector-size 4096
/dev/nvme0n1p6`, from the live USB, header backed up first — hours, and the
same interrupt-and-resume rules as the original encryption); `luks-tune.sh`
does not offer it, because it is not a KDF change.

## Changing your KDF after installation

You are not stuck with the profile you picked. `luksConvertKey` re-wraps a
keyslot's key under new argon2id parameters **in place** — no passphrase
change, no re-encryption, not a byte of filesystem data touched, seconds of
work. The header-backup step, commands for all four tiers (including
`paranoid`), and the strength graph are in
[Changing the KDF on a volume that already exists](CRYPTO.md#changing-the-kdf-on-a-volume-that-already-exists);
the menu version is [`bin/luks-tune.sh`](../bin/luks-tune.sh).

---

More detail: [CRYPTO.md](CRYPTO.md) for the KDF, [INSTALL.md](INSTALL.md) for
the walkthrough, [RECOVERY.md](RECOVERY.md) when something has gone wrong, and
the [README](../README.md) for the overview.
