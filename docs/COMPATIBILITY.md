# Apple Silicon compatibility

Every M-series Mac, laptop and desktop, and what is actually known about
AsahiLocker on each. Nothing in the tooling is model-specific — partitions,
subvolumes, the boot layout, the disk's sector size and the initramfs contents
are all read at run time — so the question is never "does the script know this
Mac" but "does Fedora Asahi Remix boot it, and has anyone run the encryption
there".

## How to read the tiers

| Tier | Meaning |
|---|---|
| **A — production** | Encrypted by this tooling and used daily; the passphrase typed at every boot |
| **B — reported** | An end-to-end run written up by someone else, with the result stated |
| **C — expected** | Fedora Asahi Remix supports the machine, and no code path here depends on anything the machine does differently. Untested by this project |
| **D — device tree only** | The kernel this tooling runs on ships a device tree for the machine, but Asahi installer and boot-chain support is not confirmed here. Treat as unsupported until Asahi says otherwise |

The device-tree column is a fact about the shipped kernel: on Fedora Asahi
Remix 44, `7.1.13-402.asahi`, `/usr/lib/modules/<kver>/dtb/apple/` carries
one file per machine below. A device tree is necessary for Linux to boot the
machine; it is not proof that the installer, m1n1 or U-Boot are there yet.

## The matrix

| SoC | Machine | Form | Tier | Evidence |
|---|---|---|---|---|
| **M1** `t8103` | MacBook Air (2020) `j313` | laptop | C | Asahi-supported since 2022 |
| | MacBook Pro 13" (2020) `j293` | laptop | C | Asahi-supported since 2022 |
| | Mac mini (2020) `j274` | desktop | C | Asahi-supported since 2022 |
| | iMac 24" (2021) `j456` / `j457` | desktop | C | Asahi-supported since 2022 |
| **M1 Pro** `t6000` | MacBook Pro 14" `j314s` | laptop | C | same SoC as the machine below |
| | MacBook Pro 16" `j316s` | laptop | **A** | This project's M1 Pro: `apple,j316s`, 16k-page kernel, 4096-byte NVMe, btrfs sectorsize 4096, LUKS2 argon2id, passphrase at every boot |
| **M1 Max** `t6001` | MacBook Pro 14" / 16" `j314c` / `j316c` | laptop | C | |
| | Mac Studio `j375c` | desktop | C | |
| **M1 Ultra** `t6002` | Mac Studio `j375d` | desktop | C | |
| **M2** `t8112` | MacBook Air 13" (2022) `j413` | laptop | C | |
| | MacBook Air 15" (2023) `j415` | laptop | C | |
| | MacBook Pro 13" (2022) `j493` | laptop | C | |
| | Mac mini (2023) `j473` | desktop | C | |
| **M2 Pro** `t6020` | MacBook Pro 14" / 16" `j414s` / `j416s` | laptop | C | |
| | Mac mini (2023) `j474s` | desktop | C | |
| **M2 Max** `t6021` | MacBook Pro 14" `j414c` | laptop | **A** | The author's daily machine — see [TESTED-SYSTEMS.md](TESTED-SYSTEMS.md): production volume plus the 1.12.1 end-to-end run on a test image |
| | MacBook Pro 16" `j416c` | laptop | C | same SoC |
| | Mac Studio `j475c` | desktop | C | |
| **M2 Ultra** `t6022` | Mac Studio `j475d` | desktop | C | |
| | Mac Pro (2023) `j180d` | desktop | C | See the Mac Pro note below |
| **M3** `t8122` | MacBook Air 13" / 15" (2024) `j613` / `j615` | laptop | **B** | M3 MacBook Air, September 2026, via the second-install route: encryption completed, passphrase prompt at boot, verified working. Noah Petherbridge, kirsle.net |
| | MacBook Pro 14" (2023) `j504` | laptop | C | Asahi M3 support landed September 2026 |
| | iMac 24" (2023) `j433` / `j434` | desktop | C | |
| **M3 Pro** `t6030` | MacBook Pro 14" / 16" `j514s` / `j516s` | laptop | C | |
| **M3 Max** `t6031` / `t6034` | MacBook Pro 14" / 16" `j514c` / `j516c` / `j514m` / `j516m` | laptop | C | |
| **M3 Ultra** `t6032` | Mac Studio (2025) `j575d` | desktop | D | device tree shipped; not confirmed further here |
| **M4** `t8132` | MacBook Air 13" / 15" (2025) `j713` / `j715` | laptop | D | device tree shipped; not confirmed further here |
| | MacBook Pro 14" (2024) `j773g` | laptop | D | |
| | Mac mini (2024) `j623` | desktop | D | |
| | iMac 24" (2024) `j604` | desktop | D | |
| **M4 Pro / M4 Max** `t6040` / `t6041` | MacBook Pro, Mac mini, Mac Studio | — | **none** | No device tree in the shipped kernel. Linux does not boot these yet |

Model names are matched to the `j`-codes from Asahi's platform list. If a
specific code matters to you, confirm it against `/proc/device-tree/model` on
the machine.

## What the tooling actually touches, and why none of it is model-specific

- **Disk.** Apple's internal NVMe presents 4096-byte logical sectors on every
  M-series Mac, which is what the 4096-byte LUKS sector logic is built around.
  The script reads the sector size and the btrfs sectorsize at run time and
  never assumes either.
- **Keyboard at the passphrase prompt.** Fedora Asahi's dracut ships the whole
  Apple input stack in every initramfs regardless of which Mac built it —
  `spi-hid-apple` + `spi-apple` (M1 laptops), `dockchannel-hid` (M2 and later
  laptops), `hid-apple`, `dwc3-apple` + `xhci-plat-hcd` (USB). Verified by
  `lsinitrd` on the M1 Pro above. The deploy's own dracut config adds only
  `crypt dm btrfs` and pins `dm-crypt`; it leaves input to the distro, and its
  verification pass checks that an input driver is present.
- **Power.** The battery check walks `/sys/class/power_supply` and applies only
  where a battery exists. On a desktop it finds none and moves on.
- **Boot chain.** m1n1 → U-Boot → GRUB, the ESP stub, `ubootefi.var`, BLS
  entries: identical across the line. The boot guards do not look at the model.

## Desktops: read this before you start

The laptops are where this has been run. Desktops share every code path, but
they change the operating conditions in ways the script cannot detect:

1. **A Bluetooth keyboard cannot type the passphrase.** There is no Bluetooth
   stack in the initramfs. An Apple Magic Keyboard paired over Bluetooth — the
   default on an iMac, and common on a Mac mini or Studio — is a brick wall at
   the LUKS prompt. **Plug a keyboard in over USB** (a Magic Keyboard on its
   charging cable enumerates as USB HID and works) before the first encrypted
   boot, and keep one within reach after. The deploy's initramfs check will
   report `OK` here, because the USB driver *is* present; it has no way to know
   your only keyboard is wireless.
2. **No battery means no buffer.** The script refuses to run on a laptop below
   50% without AC because power loss mid-encryption is the worst case. A desktop
   has no battery at all: a mains dip is an instant interruption. The encryption
   is resumable — re-run the script and it finishes with `--resume-only` — but
   a UPS turns a recovery exercise into a non-event. Use one.
3. **Have a display attached for the first encrypted boot.** The prompt is on
   the console. A headless Mac mini or Studio can still be unlocked blind over a
   USB keyboard, but you want to see the first one. On M3 and later, external
   display support through DCP is still maturing in Asahi; check that your
   monitor works under Linux *before* encrypting, not after.
4. **Extra disks score like the internal one.** A Mac Pro with PCIe NVMe cards,
   or any Mac with a Thunderbolt NVMe enclosure, presents more than one
   `nvme*` device, and the partition menu's NVMe preference applies to all of
   them. The label scoring and the fstab cross-check still identify the right
   install; read the menu rather than pressing Enter on reflex.

**Mac Pro (2023).** Same M2 Ultra as the Mac Studio and the same device tree
family; the differences are the PCIe slots and their contents. Nothing here
cares, but nothing here has been run on one either.

## What would move a machine up a tier

A run on any C or D machine, written up like the M2 Max entry in
[TESTED-SYSTEMS.md](TESTED-SYSTEMS.md): the model string, the kernel, what the
deploy reported for sector sizes, the `ALL CHECKS PASSED` line, and whether the
passphrase prompt took keystrokes from the keyboard you actually use. Open an
issue or a PR with it.
