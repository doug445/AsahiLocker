# Tested systems

The machines behind the ✅ claims: every row here has had a real in-place
encryption by `luks-deploy.sh` and boots from it, or an end-to-end run of the
script on a disk image that was then booted — with what was found on the way.
Nothing is listed on the strength of a dry run or a unit test alone. Same
format as [linux-backup-system's](https://github.com/doug445/linux-backup-system/blob/main/docs/TESTED-SYSTEMS.md).

| Distro (arch) | Machine | Layout | Verified |
|---|---|---|---|
| Fedora Asahi Remix 44 (aarch64) | 2023 MacBook Pro 14" (M2 Max, 12 cores, 32 GB RAM, 8 TB Apple NVMe with 4096-byte sectors, Broadcom BCM4388 Wi-Fi; macOS 13.5 firmware, m1n1 1.6.1, U-Boot 2026.07) | btrfs root (`root` + `home` subvolumes) on LUKS2 argon2id **`aggressive`** (4 GiB × 10, 4 threads, sha512 AF hash and volume-key digest; **512-byte encryption sectors — a volume made before 1.12.0**), unlocked by passphrase in the initramfs by dracut + systemd-cryptsetup (`rd.luks.uuid=`), ext4 `/boot`, ESP at `/boot/efi` beside the Asahi stub (`m1n1/`, `vendorfw/`, `ubootefi.var`), shim → GRUB 2.12 on `arm64-efi` behind m1n1/U-Boot, BLS entries, 16k-page kernel 7.1.13, SELinux enforcing, KDE Plasma 6.7 on Wayland | **in-place encryption ✅ — production**: the author's daily machine, the passphrase typed at every boot. **End-to-end run on a test image ✅ — 2026-09-19, 1.12.1**: a 60 GiB loop image on a USB drive holding a plain, unencrypted copy of this very system (booted in QEMU first — login in 50 s — to prove the rig), then `luks-deploy.sh` for real: `fast` profile, recovery key, the partition's end moved down 3,584 bytes so 4096-byte sectors were possible (the GPT reserved tail), in-place encryption, `ALL CHECKS PASSED (12-point gate)`, then booted in QEMU with the passphrase to a login prompt in **40 s**; passphrase and recovery key both open it; `save-luks-recovery-bundle.sh --target /mnt` bundled it. **Found and fixed on the way**: 4096-byte sectors had been unreachable on any partition ending on the GPT tail (now the typed `ALIGN` choice); the recovery bundle in live-USB mode had copied every LUKS header plugged into the rescue system, and on a rescue system whose own root is encrypted it had bundled the rescue machine (`--target` added). Not a run on this Mac's own disk — that volume predates 1.12.0 and keeps its 512-byte sectors |
| Fedora Asahi Remix (aarch64) | MacBook Pro (M1 Pro) | btrfs root on LUKS2 argon2id **`aggressive`** (4 GiB × 10) — **9.5 s unlock measured from the boot journal**, the figure the KDF profile table is built on — GRUB on `arm64-efi` behind m1n1/U-Boot | **in-place encryption ✅ — production**, the development platform since August 2026. Once left unbootable by an earlier release: `main` had been rewound behind the v1.8.2/1.8.3 tags, so the machine ran a `luks-deploy.sh` without the issue #2 fix (a `grep` for `GRUB_CMDLINE_LINUX` — a line Fedora Asahi Remix does not have — exiting stage 6c silently under `pipefail`); recovered from the live USB in configuration-only mode, and the fix is on `main` since 2026-09-02 |

The loopback suite (`tests/loopback-core-test.sh`, 36 checks) runs on every
push on x86_64 and aarch64 runners: shrink, in-place reencrypt with the
script's exact flags, header and content survival, recovery-key enrolment
with the AF hash pinned, resume after `--init-only` and after a hard kill
(`cryptsetup repair`), 4096-byte sectors on a 4Kn and a 512-byte device, and
the GPT-tail alignment run by the script's own function. It is not a boot.
