# Release history: v1.5.0 to v2.0.3

These versions were published as GitHub releases. On 2026-11-20 the
repository's history was rewritten to take a personal email address out of
the commit metadata. GitHub's immutable releases lock a release's tag for
good, so these 18 releases were removed and their notes are kept here.
GitHub retires the tag name of a removed immutable release, so these
version tags cannot be re-created.

Each version's code is unchanged in the current history, at the commit
listed. Commit IDs quoted inside the notes refer to the history before
2026-11-20.

Current releases: https://github.com/doug445/AsahiLocker/releases

---

## 2.0.3 — live-USB copy step fixed

Tag `v2.0.3` · published 2026-10-28 · commit `2f4b00fcd807`

### AsahiLocker 2.0.3 — the live-USB copy step, fixed

Documentation only. Nothing changes in how a volume is encrypted, in the
KDF, or in any volume an earlier release made.

#### What was wrong

**The copy onto the stick silently did nothing (#3).** `INSTALL.md` and
`LIVE-USB.md` said to run `sudo ./build.sh mount`. The USB builder refuses to
run under `sudo`: it prints a one-line notice and exits *successfully*. So
nothing was mounted, and the `cp` that followed created an ordinary
`mnt_usb/root/` folder on the build machine. The stick booted fine, then
`luks-deploy.sh` was `command not found`.

**The fallback could not work.** Step 3 offered mounting `subvol=root` and
running the script from `/mnt/home/<user>/`. Fedora Asahi keeps `/home` in
its own `home` subvolume, so that folder is empty. And the script must
unmount the target before encrypting it, which it cannot do while running
from it.

#### The steps now

- **Copy step:** run `./build.sh mount` from the root shell you built in,
  with no `sudo`. `findmnt mnt_usb` must print a line before you copy, and
  an `ls` afterwards confirms the script landed.
- **Already booted the stick without it?** No rebuild needed. Mount the
  internal `home` subvolume, copy AsahiLocker to `/root`, unmount, run. See
  `docs/INSTALL.md` → Step 3.

Thanks to @jbArchNovice for reporting it and for sticking with it.

---

## 2.0.2 — m1n1 stage 2 first

Tag `v2.0.2` · published 2026-10-23 · commit `ff0f23b29c18`

### AsahiLocker 2.0.2 — m1n1 stage 2 first; stage 1 only with care

This corrects 2.0.1. Nothing changes in how a volume is encrypted, in the
KDF, or in any volume an earlier release made.

#### What 2.0.1 left out

To get U-Boot to see a live USB on an M3 (#4), 2.0.1 suggested upgrading
m1n1 **stage 1** with the Asahi installer's option `m`. It gave no warning.
That upgrade worked on the M3 Air in #4. **On an M2 Max with system firmware
27 (macOS 27) it left the Asahi install unbootable.** The installer's
recoveryOS approval step showed a blue screen saying it was not the correct
recoveryOS. It asked for a user name and password, rebooted, and showed the
same screen again. It failed four times in a row. The upgrade does not
delete the old stage 1; it writes the new one beside it, and pointing the
boot back at the old one made the install bootable again. The recovery
procedure is in `docs/LIVE-USB.md`, under *If the stage 1 upgrade loops*.

#### The advice now, safest first

1. **Stage 2:** `sudo dnf upgrade m1n1`, then reboot. It is an ordinary
   package update; Fedora 44 has had 1.9.9 since October 2026.
2. **Stage 1:** only after reading the warning in `docs/LIVE-USB.md`, and
   with a way back. Check your system firmware first:
   ```bash
   tr -d '\0' < /proc/device-tree/chosen/asahi,system-fw-version; echo
   ```
3. **Or skip the USB:** the second-install route (`docs/SECOND-INSTALL.md`)
   needs none.

`luks-deploy.sh`'s M3 warning says the same and points to the docs before
anyone tries stage 1.

---

## 2.0.1 — M3 needs m1n1 1.9.1

Tag `v2.0.1` · published 2026-10-23 · commit `0b5b7c151b39`

### AsahiLocker 2.0.1 — an M3 needs m1n1 1.9.1 to boot a live USB

> **⚠️ See [2.0.2](https://github.com/doug445/AsahiLocker/releases/tag/v2.0.2) first.** This release suggested the Asahi installer's stage 1 m1n1 upgrade without a warning. It worked on an M3 Air but left an M2 Max on macOS 27 unbootable. Upgrade stage 2 with `dnf` first.

A patch release. Nothing changes in how a volume is encrypted, in the KDF,
or in any volume an earlier release made. The one code change is a warning.

#### M3: m1n1 1.9.1 or later (#4)

On an M3 MacBook Air with m1n1 1.6.x, U-Boot finds **no USB mass storage at
all**. `usb start` reports no storage device whatever stick and port you try,
so the live USB never shows up in `bootflow`. m1n1 1.9.1 fixes it. Reported
and solved by @ljrk0.

- **`docs/LIVE-USB.md`**: a new section, *M3: m1n1 1.9.1 or later*. It shows
  how to read both m1n1 stage versions from `/proc/device-tree/chosen/`, how
  each stage is upgraded (stage 1 through the Asahi installer's option `m`
  from macOS, stage 2 with `dnf upgrade m1n1`), and the second-install route,
  which needs no USB.
- **`luks-deploy.sh`**: on an installed M3 (`t8122`) system, it warns when
  either m1n1 stage is below 1.9.1 or has no version recorded. It is a
  warning only; nothing is refused.
- **`docs/COMPATIBILITY.md`**: the M3 MacBook Air row points to the section.

As of this release the regular installer (`alx.sh`, v0.9.2) still bundles
m1n1 **1.6.1**. Only the development installer (`alx.sh/dev`) has 1.9.x.

#### Also since 2.0.0

- `docs/LIVE-USB.md`: if a boot from the stick hangs on a `dev-disk-by-uuid`
  job, unplug and replug the stick. Linux never enumerates a USB device that
  was attached at power-on (AsahiLinux/linux#554). Reported in #3.
- The docs now state that AsahiLocker is for Apple Silicon (aarch64) only;
  every other machine is LinuxLocker's job.
- CI runs on aarch64 only, now with `actions/checkout` v7 (Node 24).
- README: the audit section names the audits for what they were, and the
  project is described as free and open source.

---

## 2.0.0 — a second supported environment, a hard refusal, and every M-series Mac on the record

Tag `v2.0.0` · published 2026-09-21 · commit `4c646ee31ef3`

### AsahiLocker 2.0.0 — a second supported environment, a hard refusal, and every M-series Mac on the record

The major is for what changed in the contract, not the size of the diff:

- **Two environments are supported to run the encryption from**, not one.
  A Fedora Asahi live USB, as before — or a second, minimal Asahi install on
  the same internal disk, for the many Apple Silicon machines that will not
  enumerate a USB stick in U-Boot at all. The script recognises which it is
  on, and the partition menus exclude the running system's devices outright.
- **The system you are booted from cannot be selected as the target.** There
  is no override word. Re-encrypting the blocks under a mounted root can be
  neither finished nor undone, so there is nothing to consent to. The old
  behaviour — a `LIVE` prompt up front and an obscure `umount /` failure an
  hour later — is gone.
- **`docs/COMPATIBILITY.md`** states, machine by machine, what is verified,
  what is expected and what is not claimed. Laptops and desktops, M1 through
  M4. M4 is listed as *not* supported: the kernel ships its device trees, but
  Asahi does not boot it yet.

No existing encrypted volume is touched by any of this, and nothing needs
re-running.

#### Since 1.13.1: nine review findings, each reproduced before it was fixed

A full read of `bin/`, `boot-guards/`, `extras/`, `tests/` and `tools/`. Five
of the nine were in the 1.13.0 second-install work; four predate it.

**`luks-deploy.sh`**

- The closing banner told the operator to copy the pre-luks state from
  `/mnt` after the run — but the EXIT trap has unmounted `/mnt` and closed the
  mapper by the time that banner is read, so the copy would have landed on the
  rescue install they were about to erase, and they would have deleted it
  believing the recovery material was safe. The script now makes that copy
  itself, while the target is still mounted, into the target's own `/root`;
  the banner says the recovery key *still* belongs on a USB stick, because a
  copy inside the volume it unlocks cannot help with a forgotten passphrase.
- `RUNNING_DEVS` was seeded from every mount on the box, so a target that
  udisks had automounted under `/run/media` — the documented live-desktop
  case — counted as "the running system": refused in every menu, with the
  unmount offer that exists for exactly that case never reached. Only the
  OS's own mountpoints count now.
- `partition_number()` read trailing digits, so a mapper's `dm-1` was
  partition 1 and the BOOT/EFI neighbour bonus could go to an unrelated
  unlocked volume. It reads `/sys/class/block/<p>/partition`, which the kernel
  does not create for dm devices.
- The manual-entry branch accepted any block device on `[ -b ]` alone: a
  whole disk, or the ESP typed at the BOOT prompt, would have been mounted as
  `/boot` after the point of no return. It gets the same fstype check and
  confirmation as the menu path.
- A rescue system on a Thunderbolt or USB4 NVMe enclosure (`TRAN=nvme`,
  `removable=0`) was classed as a sibling install and walked through the
  `SIBLING` confirmation. `TRAN` in `usb|thunderbolt|usb4`, or `HOTPLUG=1`, is
  live media; Apple's internal NVMe reports `HOTPLUG=0`, checked.
- One `block_slaves()` helper where there were two hand-rolled `/sys` walks.

**`save-luks-recovery-bundle.sh`** — the same dm-name path bug 1.13.0 fixed in
the partition menu, in a third place: `/dev/<dmname>` does not exist, so every
LUKS volume sitting on LVM or RAID was silently left out of the bundle with
`FAILS` still 0. `lsblk -rpno`, as `luks-tune.sh` already did.

**`boot-guards/install.sh`** — the shipped unit's `ConditionPathExists`
hard-codes `EFI/fedora` while the installer detects the vendor directory, so on
any other ESP layout the guard was installed, enabled and inert: the timer
fired every minute and the service was skipped on the unmet condition. A
drop-in now points the unit at the stub that was actually found.

**`extras/bin/luks-fetch-cache`** — run unprivileged with a cache past
`MAXAGE` (a two-hour suspend does that; the timer's clock is monotonic) it
printed *"no encrypted volumes detected"* on a fully encrypted machine. Non-root
now shows the cache root wrote.

#### `luks-fetch-cache` reads its own layout

The fastfetch readout's continuation lines were indented by a constant, 17 —
the width of `Disk Encryption: ` — with a comment asking that it be kept in
step with the config by hand. It now reads the config back: the calling user's
(`$SUDO_USER`'s through `sudo`), else the system one. The first module that
calls it supplies the key, `keyWidth` and separator that set the indent; the
number of such modules is the number of lines fastfetch will ask for, and with
more volumes than modules the last line carries `(+N more)` instead of
dropping them. The cache is stored unpadded and laid out for whoever reads it.
Rename the key or add lines freely; `sudo` in the module text is optional.

Testing that found a second unprivileged bug behind the one above: without
root, `luksDump` fails but the awk still printed a line — `nvme0n1p6  LUKS ,
iters,` — non-empty, so the stale-cache fallback never saw an empty sweep. A
dump that yields no version now yields no line.

#### Compatibility, all form factors

The shipped kernel (`7.1.13-402.asahi`, Fedora Asahi Remix 44) carries a device
tree for 37 Apple Silicon Macs. Nothing in the tooling reads the model: the
disk's sector size, the btrfs sectorsize, the initramfs contents and the power
supply are all read at run time, and Fedora Asahi's dracut ships the M1
(`spi-hid-apple`) and M2+ (`dockchannel-hid`) keyboard stacks in every image.

What a desktop changes, now written down: a Bluetooth keyboard cannot type the
passphrase and the initramfs check will still say `OK`; there is no battery to
ride out a mains dip, so use a UPS; check external display support before
encrypting on M3 and later; a Mac Pro's PCIe NVMe or a Thunderbolt enclosure
scores like the internal disk in the menu.

#### Also

- CI runs on aarch64 only; x86_64 in-place encryption is
  [LinuxLocker](https://github.com/doug445/LinuxLocker)'s job.
- The README badge says M1–M3.
- Contributions from an end-to-end run on any machine in the C or D tier are
  what moves it up — see the last section of `docs/COMPATIBILITY.md`.

---

**Upgrading:** nothing to do. No existing volume is touched, no configuration
changes, nothing needs re-running. If you installed the boot guards on a
non-Fedora ESP layout, re-run `boot-guards/install.sh` once so the drop-in is
written and the stub guard actually runs.

---

## 1.13.1 — CI on aarch64 only, and a test that cannot hold a runner

Tag `v1.13.1` · published 2026-09-21 · commit `024441b568df`

### AsahiLocker 1.13.1 — CI on aarch64 only, and a test that cannot hold a runner

A follow-up to 1.13.0. No change to `luks-deploy.sh` or to any volume it has
made; this is CI scope and documentation.

#### The x86_64 leg is gone

The loopback matrix ran on `ubuntu-latest` and `ubuntu-24.04-arm`. On
2026-09-21 the x86_64 job hung in `tests/multi-install-selection-test.sh`: it
printed the stage-1 header and then nothing for an hour, until the run was
cancelled. The identical tree passed on aarch64 in 48 seconds.

**The cause is not established, and this release does not claim to fix it.**
What it does is stop pretending x86_64 is this project's problem. AsahiLocker
is Apple Silicon tooling — the boot guards, the ESP stub handling and the
U-Boot work all assume the m1n1 → U-Boot → GRUB chain — and in-place LUKS2
encryption everywhere else is
**[LinuxLocker](https://github.com/doug445/LinuxLocker)**, which covers Fedora,
RHEL, Rocky, AlmaLinux, Debian, Ubuntu, Mint, Pop!_OS, Raspberry Pi OS, Arch,
Manjaro, EndeavourOS and openSUSE, handles systemd-boot and signed UKIs
alongside GRUB, and is tested on its own terms.

The README and [docs/FAQ.md](FAQ.md) now send non-Apple-Silicon readers
there, instead of the old half-claim that the core script "also works on"
Fedora x86_64, Arch and Manjaro. It still does; it is simply not where it is
developed or tested first.

#### A blocked test fails in five minutes, not an hour

The suite runs under `timeout 300` in CI, and `stage()` marks every
`pick_partition` call, so if it blocks again the log names the call that was in
flight when the timeout fired.

That guard is deliberately in the workflow and not in the script. An in-script
watchdog was written first and was worse: killing the watchdog subshell leaves
its `sleep` orphaned, and the orphan holds the inherited stdout open — so
anything reading the suite through a pipe hangs on after the tests have already
finished. It was caught locally, before it shipped.

---

**Upgrading:** nothing to do. No behaviour change in any script.

---

## 1.13.0 — encrypting from a second Asahi install, for machines that will not boot USB

Tag `v1.13.0` · published 2026-09-21 · commit `5ec84f63d399`

### AsahiLocker 1.13.0 — encrypting from a second Asahi install, for machines that will not boot USB

The live-USB route has always depended on something Apple Silicon is not
reliable about: U-Boot enumerating a USB mass storage device. The documented
fallback — a second, minimal Asahi install on the same internal disk — worked,
but the tooling did not know about it, and the one place that mattered got it
dangerously wrong.

This release comes almost entirely from a write-up of a real M3 MacBook Air
run by **[Noah Petherbridge](https://www.kirsle.net/)** ("Asahi Linux with LUKS
Encryption", 19 Sept 2026), who took that route and documented the parts that
did not go smoothly.

#### The bug it found (`luks-deploy.sh`)

> "when it listed the various disk partitions on my Macbook, it wanted to
> default to the AsahiRecovery partitions (the ones I was currently booted
> from!)"

That is exactly what it did, and the cause is the situation itself. Candidate
partitions were penalised 200 points for sitting on the same disk as the
running system — correct on a live USB, where the USB is the one device you
must never pick. From a sibling install the target is on the same disk by
definition, so the penalty applied to both installs equally and cancelled
itself out. Two Fedora roots, both labelled `fedora`, both on NVMe: the score
tied, and the recommendation fell to whichever the kernel enumerated first.
On a layout where the rescue install sits between macOS and the daily driver,
that is the rescue install.

Nothing protected against acting on it, either. Selecting the running system
failed late and obscurely — an hour of prompts later, when `umount /` refused.

#### What it does now

- **Every device the running system is on is off limits.** All mounts and
  swap, followed through device-mapper to the backing partition, are marked
  `IN USE` in the menus: never the recommendation, not selectable by number,
  and refused when the device path is typed by hand.
- **Targeting the running system is a hard stop**, checked before anything is
  touched, with no override word. Re-encrypting the blocks under a mounted
  root can be neither finished nor undone, so there is nothing to consent to.
- **The same-disk penalty applies only on live media.** On a sibling install
  the running partitions are excluded individually instead, so the penalty
  can no longer rule out the right answer along with the wrong one.
- **`BOOT` and `EFI` default to the neighbours of the chosen `ROOT`**, since an
  Asahi install lays its three partitions down consecutively. The fstab
  cross-check still has the final say; this only stops the default being wrong.
- **A root-vs-root tie breaks on size**, so a 20 GiB rescue install stops
  outranking a 250 GiB daily driver when both answer to `fedora`.
- **The `LIVE` prompt is gone.** Running from an installed system is a
  recognised environment now, not an override. It prints the install you booted
  and the install about to be encrypted, one above the other, and asks for a
  typed `SIBLING`. `LUKS_ACK_SIBLING=1` pre-acknowledges it for fleet use.
- **The recovery material gets a warning it badly needed.** On this route the
  header backup, the pre-encryption state and the recovery key land on the
  rescue install — which the operator then erases from macOS to reclaim the
  space. Said at the point of consent and again at the end of the run.

#### A device-mapper bug underneath it

Found while testing the above, and older than it. `lsblk` names a
device-mapper device by its dm name, and there is no `/dev/<dmname>` node —
only `/dev/mapper/<dmname>`. The menu built the former, so the path did not
exist, and `blkid`, `blockdev` and the in-use check all quietly did nothing
for that candidate. A rescue system whose own root is encrypted was therefore
offered its own container back as a target.

#### Tests

`tests/multi-install-selection-test.sh` builds a sparse, file-backed GPT disk
laid out like the real thing — two consecutive (EFI, boot, root) triplets, a
200 GiB daily driver and a 20 GiB rescue install, both labelled `fedora` — and
drives the real `pick_partition()` against it from the rescue install, from a
live USB and from the main install, plus the device-mapper case. 11 assertions,
run in CI on x86_64 and aarch64. The image is sparse, so the 230 GiB layout
costs a few MiB and no real disk is touched.

#### Documentation

- **`docs/SECOND-INSTALL.md`** — the route end to end: sizing and installing the
  minimal system, bringing it up (`nmcli`, `dnf install git`), what the new
  prompts mean, getting the recovery bundle off before you erase anything, and
  the `diskutil` cleanup with the Startup Disk change that has to come first.
- **`docs/LIVE-USB.md`** now leads its troubleshooting with **`usb start`**. A
  stick with no activity LED and nothing in `bootflow scan -l` is U-Boot's
  normal state *before* `usb start` — it does not power or enumerate the port
  until asked, and nothing asks on its own. That symptom reads exactly like a
  machine that cannot boot USB. There is also a new section on drive choice,
  because plenty of sticks build fine under Linux and are simply never visible
  to U-Boot.
- **README: 1035 → 418 lines.** The argon2id material moved to
  **`docs/CRYPTO.md`** and the questions to **`docs/FAQ.md`**; the parameter and
  profile tables and the case for `aggressive` stay on the front page.

#### Also

The logo lost the causeway leading into its base, sits on pure `#000000` with
no bloom, and its wordmark is recut as white type.

---

**Upgrading:** nothing to do. No existing volume is touched, no configuration
changes, and nothing needs re-running. This is a change to how the deployment
script chooses and guards its target, plus documentation.

---

## 1.12.1 — the full review, and the first end-to-end run on a test disk

Tag `v1.12.1` · published 2026-09-19 · commit `2ea2eb606c44`

### AsahiLocker 1.12.1 — the full review, and the first end-to-end run on a test disk

Every script read end to end against what the linux-backup-system restore
test bed and the U-Boot source established this week, then `luks-deploy.sh`
run for real: a plain, unencrypted copy of a Fedora Asahi Remix system built
on a 60 GiB loop image (booted in QEMU first, to prove the rig), encrypted in
place by the script — `fast` profile, recovery key, 4096-byte sectors, the
12-point gate `ALL CHECKS PASSED` — then booted in QEMU again with the
passphrase, to a login prompt. The recovery key opens it; the recovery bundle
ran against the mounted target in live-USB mode. No physical disk was
touched.

#### Found by that run, fixed

- **4096-byte sectors were unreachable on most 512-byte-sector disks.** GPT
  reserves 33 sectors at the end of a disk, so the last partition — an
  installer's "rest of the disk" root — is always 33 sectors short of a
  4096-byte multiple, and cryptsetup refuses `--sector-size 4096` on it
  ("Device size is not aligned to requested sector size"). 1.12.0 fell back
  to 512 with one warning. Now it is a choice: type `ALIGN` (or
  `LUKS_ALIGN_PARTITION=yes`) to move the partition's end down by the
  remainder — the table is backed up first to the state directory with the
  restore command logged, one `sgdisk` call keeps the number, start, type,
  name, unique GUID and attributes, the kernel's view is verified, and the
  filesystem (already 32 MiB smaller) loses nothing — or press Enter for
  512-byte sectors. Never a default. Exercised for real on the 60 GiB image
  (3,584 bytes moved) and in the loopback test against a GPT image whose
  partition ends on the reserved tail. On Apple's 4096-byte-sector NVMe the
  question never comes up.
- **The recovery bundle, in live-USB mode, copied every LUKS header it could
  see** — another machine's backup drive plugged into the rescue system
  included. It now keeps to the target's own volumes: its root and what its
  crypttab names; others are listed and skipped.
- **`esp-grub-stub-rebaseline` still assumed `EFI/fedora`**; it finds the
  vendor directory like the two guards do.
- **`luks-tune.sh` shows the encryption sector size** beside the keyslots, so
  a volume made before 1.12.0 (512-byte sectors on a 4096-byte disk) is
  recognisable there.

#### Confirmed by the review

`luks-deploy.sh`'s partition picker and pinning, the mapper cross-wiring
guard, the fstab cross-check, the resume and config-only paths, the
`luksAddKey --hash sha512` recovery slot, `GRUB_CMDLINE_LINUX_DEFAULT`
handling, the ESP-stub protection, the chroot rebuild with its dm-crypt and
keyboard-driver checks, and the verification gate all hold. Loopback test:
36 checks.

---

## 1.12.0 — 4096-byte encryption sectors; stale EFI entries removed where U-Boot actually keeps them

Tag `v1.12.0` · published 2026-09-19 · commit `a43f81df5869`

### AsahiLocker 1.12.0 — 4096-byte encryption sectors; stale EFI entries removed where U-Boot actually keeps them

Two things learned by restore-testing an M2 Max with linux-backup-system,
applied here.

#### 4096-byte LUKS sectors (`luks-deploy.sh`)

Apple NVMe is a 4096-byte-sector disk and btrfs writes 4096-byte blocks, but
cryptsetup's default encryption sector is 512 — so every volume this script
made, the author's own included (`sector: 512 [bytes]` on a 4096/4096 disk),
did eight XTS operations with eight IVs per filesystem block. `reencrypt
--encrypt` now gets `--sector-size 4096` whenever the btrfs sectorsize allows
it (always, on Asahi), the plan and pre-flight summary say so, and the
verification gate (V10) confirms the open container's sector size against the
plan. Verified in place on cryptsetup 2.8.8 for a 4096-byte-sector device and
a 512-byte one; `tests/loopback-core-test.sh` now covers both (27 checks).
`LUKS_SECTOR_SIZE=512|1024|2048|4096` pins it; it can never exceed the
filesystem's sectorsize. Existing volumes are unchanged — as secure as before,
just slower — and the README says how to change one (a full in-place
re-encryption, not a `luks-tune` job).

#### `clean-stale-efi-entries` finally cleans them

U-Boot keeps its non-volatile EFI variables in `ubootefi.var` on the ESP
(`lib/efi_loader/efi_var_file.c`) and writes that file only from its own
boot-time code. `efibootmgr -B` from Linux edits U-Boot's in-memory runtime
copy and nothing else (`efi_set_variable_runtime`; Kconfig
`EFI_RT_VOLATILE_STORE`: "the OS will be responsible for syncing the RAM
contents to the file, otherwise any changes made during runtime won't persist
reboots"). So the guard "deleted" the same stale entries at every boot and
they came back at every boot.

New `boot-guards/bin/uboot-efivar.py` parses the file with U-Boot's own
layout (`include/efi_variable.h`), decodes each `Boot####` load option's
device path, drops the entries whose GPT partition is on no attached disk,
takes them out of `BootOrder`, recomputes the CRC32 and replaces the file
atomically, keeping the previous one beside it. The guard runs it on U-Boot
hosts (then `efibootmgr -B` on the runtime copy so the running system
agrees); real UEFI firmware keeps the efibootmgr-only path. Installed by
`boot-guards/install.sh`, covered by `tests/uboot-efivar-test.sh` (14 checks,
in CI), verified against this machine's real file: `Boot0006`, a Fedora USB
installer's partition long unplugged, is the entry it removes.

#### Smaller

- The ESP vendor directory is found, not assumed: the directory under
  `EFI/` that holds this arch's GRUB or shim (`EFI/fedora` on Fedora Asahi
  Remix, whose os-release says `ID=fedora-asahi-remix`) — in both boot guards
  and their installer, `ESP_GRUB_CFG` still overriding.
- `save-luks-recovery-bundle.sh` saves `ubootefi.var` (the boot entries
  themselves) beside `efibootmgr.txt`, and its recovery notes say which of
  the two restores an entry under U-Boot.
- `docs/UBOOT-BOOTFLOW.md`: a section on where the EFI boot entries live,
  with the U-Boot source it comes from.

---

## v1.9.0 — luks-tune.sh always writes --hash sha512

Tag `v1.9.0` · published 2026-09-05 · commit `2d49b302d04d`

Fixed luks-tune.sh; hash parameter now always sha512, never sha256

luksConvertKey was called with no --hash, so cryptsetup substituted its
compiled-in sha256 default. Every re-cost silently downgraded the AF hash
of a slot luks-deploy.sh had formatted with --hash sha512, and never bumped
a pbkdf2 slot already on sha256. Now pinned to sha512 explicitly.

The volume-key digest is a separate field fixed at luksFormat time;
luksConvertKey cannot rewrite it, so it is now reported rather than
implied to have moved.

---

## v1.8.4 — Caps Lock gate at the prompt it protects

Tag `v1.8.4` · published 2026-09-02 · commit `cadb6d4598c4`

Moves the Caps Lock gate from the ENCRYPT confirmation to immediately before the cryptsetup call, and requires 'yes' in lower case — which cannot be typed with Caps Lock on, so accepting it is the proof.

cryptsetup asks "Are you sure? (Type 'yes' in capital letters)" one prompt before it asks for the new passphrase. Reaching for Caps Lock to type that YES leaves it on for the passphrase, which cryptsetup takes twice and inverts both times — so its verification passes and the boot prompt is where you find out. The old gate warned about this before the btrfs shrink and integrity check, far too early, and read a keyboard LED that reports nothing over Bluetooth.

Also guards the stage-6d /etc/kernel/cmdline redirect with mkdir -p: unguarded, it is the same silent 'set -e' abort as the stage-6c bug fixed in v1.8.2 (#2).

---

## v1.8.3

Tag `v1.8.3` · published 2026-08-28 · commit `dcee51d6d3d6`

Recovery-key default + doc fixes

---

## v1.8.2 — fix silent stage-6 abort on Asahi Remix

Tag `v1.8.2` · published 2026-08-28 · commit `24f8f43e985f`

Bug fix release. Recommended for anyone deploying onto Fedora Asahi Remix.

#### Fixed

**luks-deploy.sh aborted silently in stage 6 on Fedora Asahi Remix** (#2)

The script read the existing kernel command line with a `grep "^GRUB_CMDLINE_LINUX="` inside a command substitution. Under `set -euo pipefail`, a `/etc/default/grub` with no such line makes grep exit 1, which killed the script — with no error message, because nothing had printed one yet. The run stopped after `Updating /etc/default/grub...` and went straight to the cleanup trap.

Stock Fedora Asahi Remix ships `GRUB_CMDLINE_LINUX_DEFAULT` and no `GRUB_CMDLINE_LINUX` line at all, so every such install was affected. The bug has been present since the initial commit and only fires on targets that use the `_DEFAULT` name.

A second failure was hidden behind it: the `sed -i` that added the unlock arguments silently matched nothing when the line was absent, so even a run that survived could have dropped `rd.luks.uuid` / `rd.luks.name` without a word.

Stage 6c now updates `GRUB_CMDLINE_LINUX` and `GRUB_CMDLINE_LINUX_DEFAULT` — whichever exist, both if both do — appends `GRUB_CMDLINE_LINUX` when the file defines neither, creates the file if it is missing, and refuses to leave the stage unless `rd.luks.uuid` is actually on disk. Rewrites go through awk so a stray `&` or `|` in an existing command line cannot corrupt the replacement, and the file is written in place so its inode, mode, owner and SELinux label survive.

**post-encryption-setup.sh reported a splash restore that never happened**

Its splash-restore `sed` only matched `GRUB_CMDLINE_LINUX="`, so on Asahi it changed nothing and still printed `[ok]` — `sed` exits 0 when it matches nothing. It now matches either variable and verifies the tokens landed before reporting success.

#### Recovering an interrupted run

If a deployment stopped at this point, no data is at risk: the root partition is already encrypted and `/etc/crypttab` and `/etc/fstab` are already correct. Re-run `luks-deploy.sh` on the same target — it detects the existing LUKS container and offers **config-only** mode, which redoes every configuration step idempotently without touching the data.

#### Testing

Stage 6c was tested against 10 shapes of `/etc/default/grub`: Asahi `_DEFAULT`-only, plain Fedora, both variables, neither, single-quoted, unquoted, values containing sed metacharacters, commented-out lines, a missing file, and duplicate definitions — plus an idempotent second run.

Thanks to @Larsvanzijl for the report and a diagnostic bundle complete enough to find this from.

---

## v1.8.0 — audit release

Tag `v1.8.0` · published 2026-08-25 · commit `80bac60439f1`

### v1.8.0 — audit release

Full-repo audit: eight code defects fixed, stale and contradictory documentation corrected, README deduplicated. **No change to encryption parameters, the KDF floor, or the verification gate.** All scripts pass `bash -n` + `shellcheck -S warning`; the sed and awk fixes were verified against real LUKS2 headers.

#### Fixed

- **luks-deploy.sh**: the splash strip missed `rhgb`/`quiet` at the start of a line or just inside the opening quote of `GRUB_CMDLINE_LINUX`; "GRUB config rebuilt" was printed even when `grub2-mkconfig` failed; an initramfs whose name yields no parseable kernel version could pass the cryptsetup gate silently (now an error); a typo at the KDF profile menu aborted the whole run — it re-prompts.
- **luks-tune.sh**: pbkdf2 keyslots were invisible to the menu — the exact slots the README tells you to convert. They are now listed (`-` for memory/threads) and convertible to argon2id like any other slot.
- **post-encryption-setup.sh**: the splash marker is kept when the grubby restore fails, so a re-run can retry; the "is root encrypted" check now inspects root's *own* mapper (the btrfs `[/subvol]` suffix silently broke `cryptsetup status` before); the initramfs check matches `cryptsetup`/`dm-crypt` instead of any string containing "crypt"; unknown arguments are refused instead of ignored.
- **save-luks-recovery-bundle.sh**: the backing-device parse truncated device names containing `-`; it now takes `cryptsetup status`'s `device:` line verbatim.

#### Changed

- ESP stub guard caps drifted-copy forensics at the 5 newest `.broken.*` files; the stale-EFI cleaner also removes inactive (un-starred) entries; `luks-fetch-cache.service` dropped its unused `[Install]` section (could double-run the sweep at boot); the deploy prints LUKS2-format header fields and logs the KDF parameters the recovery keyslot is enrolled with.

#### Documentation

- **INSTALL**: removed the false "there is no recovery key" claim — the deploy offers one, default yes; unlock-time figures now match the README (2.1 / 3.8 / 9.5 s); the prompt table is in true runtime order and gains the missing unmount prompt.
- The last two retracted **"1 GiB hard GRUB ceiling"** claims (extras) now carry the measured position: the ceiling is the firmware's — 2 GiB works under U-Boot on an M2 Max, 4 GiB never, 1 GiB stays the portable default.
- **BOOT-ENCRYPTION-DESIGN** reconciled with its own probe results (stale "open questions" resolved or reframed; keyfile size settled at 4096 bytes); the 2026-08-23 probe postmortem is marked superseded.
- **CONTRIBUTING**: GRUB 2.14 build path now matches the probes' `GRUB_PREFIX` default; loopback pass counts explained for stage-5b `SKIP`s. **LIVE-USB**: caveat that Fedora's `GRUB_DISABLE_OS_PROBER=true` can hide Method A's USB entry.
- **README**: the two duplicate "change your KDF" sections merged into one canonical section with all four tiers and the strength graph (the FAQ entry is now a pointer); the stranded fleet-pinning paragraphs moved next to the KDF pinning they refer to; strength figures made self-consistent (28 years / ten days at 40 bits); broken fragments and grammar fixed; BOOT-ENCRYPTION-DESIGN added to the docs table.

---

## v1.7.2 — GRUB 2.14 + argon2id marked experimental

Tag `v1.7.2` · published 2026-08-25 · commit `2dce432467c5`

A documentation release. No script changed, and nothing in the encryption path
moved — there is nothing to re-run if you are already on v1.7.1.

##### Added

**An EXPERIMENTAL marker on unlocking `/boot` with GRUB 2.14 under argon2id.**

The README's note on GRUB and argon2id already made the important distinction:
none of the GRUB memory limits constrain your **root** volume, because GRUB
never unlocks it — the initramfs does. They only bind a volume that GRUB itself
has to open, which in practice means an encrypted `/boot`.

That path is now labelled experimental. Fedora's aarch64 GRUB 2.12 builds ship
no `argon2.mod` at all, so an argon2id `/boot` keyslot is not something the
stock toolchain can unlock; GRUB 2.14 is where the capability appears, and it
has not been exercised widely enough here to be called supported. Treat it as
research, not as a deployment recommendation. `docs/BOOT-ENCRYPTION-STATUS.md`
and `tools/boot-probe/` carry the measurements behind that judgement.

The unconditional rule alongside it is unchanged and still matters:

> **Never give GRUB a 4 GiB argon2id keyslot.** A 32-bit overflow in GRUB's
> `argon2_init` wraps the allocation size to zero, so it proceeds instead of
> rejecting the parameters.

pbkdf2 keyslots work on unmodified Fedora aarch64 GRUB and remain the path that
is actually known to boot.

##### Note on tag ordering

The commit in this release (`c612d49`) predates the one in v1.7.1 (`a041312`) —
the two were authored on separate lines and only met at merge `b2e4865`, after
v1.7.1 was cut. The tag is later; the content is older. Nothing is missing from
either release.

**Full changelog**: https://github.com/doug445/AsahiLocker/compare/v1.7.1...v1.7.2

---

## v1.7.1 — diceware snippet fix

Tag `v1.7.1` · published 2026-08-25 · commit `18f5b9e2a672`

A documentation fix. No script, no on-disk behaviour, and nothing in the
encryption path changed — if you are already running v1.7.0 there is nothing
here you need to re-run.

##### Fixed

**The diceware passphrase recipe in the README did not work, and overstated its
own entropy.**

The snippet carried the EFF wordlist URL as a comment and then went straight to
`shuf`, with no step that actually downloads the file. Anyone who had not
already fetched `eff_large_wordlist.txt` by hand got:

```
shuf: eff_large_wordlist.txt: No such file or directory
```

The second problem was quieter. The command used `shuf -n 8`, which samples
*without* replacement, while the paragraph directly above it computes strength
from `log2(7776) = 12.92` bits per word. That figure describes independent
draws. Sampling without replacement is a different model, and it cannot produce
the repeated word that a genuine sequence of dice rolls sometimes should.

The recipe now fetches the list, verifies it against a published SHA-256, and
draws with `shuf -r`:

```bash
### EFF long wordlist: 7,776 lines of "11111<TAB>abacus"
curl -O https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt

### Verify it before trusting it for entropy
echo 'addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e  eff_large_wordlist.txt' \
    | sha256sum -c

### Eight words, drawn with replacement, from the kernel CSPRNG
shuf -r -n 8 --random-source=/dev/urandom eff_large_wordlist.txt | cut -f2 | paste -sd' '
```

The checksum is not ceremony. A truncated or substituted wordlist lowers your
entropy silently — the passphrase still reads as eight ordinary English words.
A list cut to its first 100 lines yields 53 bits instead of 103, and nothing in
the output tells you that happened.

**Full changelog**: https://github.com/doug445/AsahiLocker/compare/v1.7.0...v1.7.1

---

## v1.7.0 — drive permissions

Tag `v1.7.0` · published 2026-08-24 · commit `4387d34858d5`

#### Security fix — `chmod` has been silently doing nothing on FAT deployment drives

`chmod(2)` on vfat, exfat and ntfs **returns success and changes nothing**. Those filesystems have no permission bits; the mode you see comes from the mount's `fmask`/`dmask`, not from the inode. So a script that runs `chmod 0600 recovery-key.txt` on a FAT stick is told it succeeded, logs nothing, and leaves the file readable by anyone who plugs the drive in.

The deployment drive is very often exactly such a stick. Measured on a vfat loop image:

```
chmod 0700 <dir>       rc=0   mode=755
install -m 600 <file>  rc=0   mode=755
chmod 0400 <file>      rc=0   mode=755
```

Three things were wrong, and they differ in severity depending on how the deployment drive is formatted.

- **The recovery key.** `install -m 600` was already being used, so on ext4/btrfs it was correct. On FAT it was a no-op and the key sat world-readable. This is the serious one: the recovery key is 64 plaintext hex characters that unlock the volume outright. There is nothing to crack.
- **The LUKS header backup copied to the drive** was created with plain `cp`, which uses `0666 & ~umask` — `0644` by default. It was world-readable on **every** filesystem, FAT or not. A header backup carries your keyslots. They are argon2id-protected rather than plaintext, but it hands someone an offline target that needs no further access to your machine.
- **`pre-luks-state-*/` itself** was created by a bare `mkdir -p` and left at `0755`, so the directory holding both of the above was world-listable.

| | ext4 / btrfs drive | FAT / exFAT drive |
|---|---|---|
| `recovery-key.txt` | `0600` — correct | `0755` — **plaintext key exposed** |
| `luks-header-backup.img` | `0644` — **exposed** | `0755` — **exposed** |
| `pre-luks-state-*/` | `0755` | `0755` |

##### What changed

- **New `harden_path` helper.** It sets the mode, reads it back with `stat`, and warns **once** if the mode did not take. It never returns non-zero — a drive that cannot hold permissions is a reason to warn loudly, not to abort an encryption that is already under way.
- **The warning fires before encryption starts.** The first `harden_path` call locks `pre-luks-state-*/` to `0700`, immediately after it is created, so an unsuitable deployment drive is reported while aborting still costs nothing. Locking the directory also covers the layout dumps, `crypttab` and the BLS entries copied into it.
- **The header backup is copied with `install -m 0400`, not `cp`.** `install` sets the mode as it creates the destination, so the header is never briefly world-readable between the copy and a `chmod` — and never permanently so if that `chmod` is a no-op.
- The recovery key and its README now verify their modes rather than assuming them.

The directory-plus-explicit-mode pattern is the one `bin/save-luks-recovery-bundle.sh` already used; this brings `luks-deploy.sh` in line with it.

A global `umask 077` would have fixed all of it in one line. It was rejected: the same script writes `/etc/fstab`, the BLS entries and the initramfs config on the target, and mode-restricting those is a boot-breaking change hiding inside a tidy one-liner.

##### If you have already deployed

Check what your deployment drive actually holds:

```bash
ls -la <drive>/pre-luks-state-*/
```

If the modes are `0700` / `0600` / `0400`, nothing was exposed beyond that drive. Move the recovery key and header backup to secure offline storage — which the deployment already told you to do — and you are done.

If they are `0755` or `0644`, treat the contents as having been readable by anything with access to that drive, and judge the exposure by where the drive has been. A stick that never left a desk drawer is a very different situation from one that was plugged into a shared machine.

**One thing worth knowing before you reach for the obvious fix.** If a *header backup* genuinely leaked, changing your passphrase does not neutralise it. `luksChangeKey` re-wraps the **same master key**; a header backup taken beforehand still contains a keyslot that unwraps that master key, and restoring it re-enables the old passphrase against your current data. The only real remedy is a new master key — full re-encryption, or a reinstall. A leaked *recovery key* is different: revoking that keyslot with `cryptsetup luksKillSlot` is sufficient, provided no header backup from before the revocation is also loose.

##### Not affected

`bin/save-luks-recovery-bundle.sh`, which already set `0700` on its bundle directory and `0400` on every header it wrote.

---

## v1.6.0 — KDF floor hardening + encrypted-/boot research (gated)

Tag `v1.6.0` · published 2026-08-24 · commit `4ee903ac3715`

#### Security fix — the `fast` profile was weaker than doing nothing

`fast` shipped **1 GiB × 4** through v1.5.0. cryptsetup's own default is argon2id at 1 GiB with iterations auto-tuned to `--iter-time` (2000 ms) — measured at **t=8** on an M2 Max. So `fast` was exactly **half** the work of a plain `luksFormat` with no arguments, while the README claimed every profile beat stock.

- **`fast` → 1 GiB × 9, and it is now a hard floor.** `LUKS_PBKDF_ACK_WEAK` is removed — there is no override. The floor tests two conditions because they fail differently: memory below 1 GiB loses memory-hardness, and total work below `fast` is cheaper per guess however the factors are traded.
- **`moderate` → 2 GiB × 8**, restoring separation from `fast`.
- **New runtime guard.** Before formatting, the installer reads what cryptsetup would choose unaided on *that* machine and refuses to ship weaker: a named profile below the bar is raised to 25% past it; pinned `LUKS_PBKDF_*` below it is fatal. The benchmark is sampled and the lowest reading wins, because it is load-sensitive and the errors are asymmetric.
- The pre-flight summary now prints the measured multiple: `= 2x the work of cryptsetup's own default here`.

| Profile | Memory | Iterations | Unlock, M2 Max | vs stock |
|---|---|---|---|---|
| `aggressive` | 4 GiB | 10 | 9.5 s (measured) | 5x |
| `moderate` (default) | 2 GiB | 8 | ~3.8 s | 2x |
| `fast` | 1 GiB | 9 | ~2.1 s | 1.125x |

#### Encrypted `/boot` — research published, still gated

**Not shipped, not enabled, no flag.** Every released version encrypts root only. Lifting the gate will be a major bump.

[docs/BOOT-ENCRYPTION-STATUS.md](https://github.com/doug445/AsahiLocker/blob/main/docs/BOOT-ENCRYPTION-STATUS.md) is a laboratory notebook of what has been measured on real hardware, what broke, and what is still unknown. Highlights from an M2 Max running GRUB 2.14 under U-Boot:

- argon2id **allocates and decrypts at 512 / 1024 / 2048 MiB**. The familiar "GRUB caps at 1 GiB" is an artefact of x86 vendor UEFI leaving GRUB a constrained heap — not a GRUB limit. The only unconditional rule is the u32 overflow at exactly 4 GiB.
- **GRUB's argon2 is 8.5× slower than the kernel's** for identical work — 9.5 s in the initramfs versus ~80 s in GRUB — and linear at ~2.0 s per GiB-pass. Encrypted `/boot` would cost **~20 s at every boot, minimum**.
- **2 GiB × 20 hard-resets the machine**, reproducibly, with no output. It allocates exactly what 2 GiB × 10 allocates, so the cause is *time*, not size: a wall between 40 s and 80 s of uninterrupted computation.
- `save_env` to the FAT ESP returns success and **writes nothing**.

**Contributions wanted** — especially probe results from other Apple Silicon Macs, and a base M1 in particular. `tools/boot-probe/` carries the harness; it builds throwaway LUKS containers holding nothing, chainloads a self-contained image, and leaves the installed bootloader alone. Open questions are listed at the end of the status doc.

---

## v1.5.0 — two /boot unlock architectures, and a hard 1 GiB GRUB rule

Tag `v1.5.0` · published 2026-08-23 · commit `6dea9b8dd30b`

v1.5.0 — two /boot unlock architectures, and a hard 1 GiB GRUB rule

Documentation release. No behavioural change to the deploy script; the
/boot work it describes is still design-only and gated on hardware
testing.

Two unlock options for encrypted /boot, instead of one imposed choice
- Option 1, one unlock: a passphrase at the GRUB prompt opens /boot, and
  a keyfile inside the encrypted initramfs opens root with no second
  prompt. Its cost is stated exactly - root's parameters are untouched
  but stop being load-bearing, since the keyfile opens root and the
  1 GiB /boot keyslot becomes the cheapest way in. If root is already at
  1 GiB there is no reduction at all.
- Option 2, two unlocks: no keyfile is generated, and root is opened by
  its own passphrase at its full KDF. Carries the warning it cannot ship
  without - this only works with a DIFFERENT passphrase for root, since
  reusing one hands an attacker root the moment they break the weaker
  /boot keyslot.
- /boot is pinned at 1 GiB / 10 iterations. Measured here, cryptsetup's
  own defaults with no KDF flags are argon2id 1 GiB / t=8, so fewer than
  8 iterations would ship a /boot weaker than a plain luksFormat.

The 1 GiB GRUB ceiling is now a prohibition, not a soft cap
- Every mention read as a performance note, which invites treating it as
  a number to tune toward. All of them now state it as a rule: 1 GiB is
  the hard ceiling for any volume GRUB itself must unlock, root excepted.
- Both failure modes are spelled out wherever the rule appears. Above
  1 GiB GRUB fails to allocate, which is not a slow boot but no boot. At
  exactly 4 GiB it is worse: argon2_init computes
  xtrymalloc (1024 * memory_blocks) in 32-bit unsigned arithmetic, so
  1024 * 4194304 wraps to 0 and GRUB proceeds instead of rejecting the
  parameters cleanly.

Also in this release
- luks-tune.sh offers the paranoid tier (4 GiB / 12) and gained --help
  plus an argument guard. Previously a mistyped --dry-run was silently
  ignored, which would re-cost a keyslot for real while the caller
  believed it was a rehearsal.
