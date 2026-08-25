# Probe postmortem — 2026-08-23: `chain.mod` not found, "all kernels" erroring

> **Dated lab notebook — superseded.** The questions still open at the bottom
> of this file were answered the following day; the current record is
> [BOOT-ENCRYPTION-STATUS.md](BOOT-ENCRYPTION-STATUS.md). Kept unedited as the
> postmortem of the chainloader failure. (The `read-results.sh` path mentioned
> below now lives at `tools/boot-probe/read-results.sh`.)

Written from the recovery USB after the internal (Route B) argon2id probe run
failed. Everything below was verified against the mounted main system, then
fixed in place. **The main system was never actually broken — see below.**

## What the screen said

```
error: ../../grub-core/fs/fshelp.c:find_file:257:file `/grub2/arm64-efi/chain.mod' not found.
error: ../../grub-core/script/function.c:grub_script_function_find:119:can't find command `chainloader'.
```

## Root cause — two separate problems

### 1. Fedora ships `chain.mod` but never installs it where GRUB looks

Fedora's `grubaa64.efi` is a prebuilt image; `chainloader` is **not** built into
it, and Fedora never populates `/boot/grub2/arm64-efi/` (its prefix module dir)
— the directory simply didn't exist. So `insmod chain` failed (error 1), the
script kept going, and `chainloader` was an unknown command (error 2). The
probe image itself is fine: it has chainloader, loopback, cryptomount and
argon2 built in, prefix pinned to `/asahilocker-probe` on the ESP.

The fix was sitting on disk the whole time: `grub2-efi-aa64-modules-2.12-64.fc44`
is installed and **exactly version-matches** the installed `grubaa64.efi`.

### 2. The menu entry hijacked `$root` — that's the "all kernels fail" mystery

The Route B entry did:

```
search --no-floppy --file --set=root /asahilocker-probe/MANIFEST.txt
```

`search --set=root` is **global and persists after the menuentry fails**. Once
the probe entry errored out, `$root` pointed at an ESP for the rest of that
GRUB session. The BLS kernel entries resolve `/vmlinuz-*` against `$root`, so
every kernel selected afterwards died in the same `fshelp.c find_file` path —
visually "the same error." Nothing on disk was damaged; a clean power cycle
(with the USB unplugged) would have auto-booted the saved 7.1.6 default.

Bonus bug: `--file` search is now ambiguous anyway, because the **USB ESP
(3051-D434) carries an identical payload** from the old Route A staging — the
current recovery USB *is* that USB (runbook says it no longer exists; it does).
So the entry could latch onto either ESP nondeterministically.

## What was changed (from the recovery USB, 2026-08-23)

1. **Main system**: created `/boot/grub2/arm64-efi/` and copied all `*.mod` +
   `*.lst` from the main install's `/usr/lib/grub/arm64-efi/` (2.12-64.fc44).
   This is exactly what upstream `grub-install` does; purely additive. `chain`
   deps (`boot efinet net`) verified present. ~5 MB; /boot at 57%.
2. **Main `/boot/grub2/custom.cfg`**: entry now pins the internal ESP by UUID
   and no longer touches `$root`:
   ```
   search --no-floppy --fs-uuid --set=probe_dev 2FA7-65AB
   chainloader ($probe_dev)/asahilocker-probe/grub-argon2-probe.efi
   ```
   The `### BEGIN/END AsahiLocker argon2id probe` markers are preserved, so
   `remove-probe-internal.sh` still works unmodified.
3. **Recovery USB**: same module copy into its `/boot/grub2/arm64-efi/` (from
   its own 2.12-43.fc43 package), and its grub.cfg probe entry switched from
   `--set=root` to `--set=probe_dev`. Its `3051-D434` search target is correct.
4. **Nothing else touched.** grub.cfg (main), BLS entries, grubenv, ESP, fstab
   all verified intact and internally consistent (UUIDs cross-checked against
   blkid). grubenv still has `menu_show_once_timeout=30` queued, so the next
   main boot shows the menu for 30 s.

## Running the probe next time

1. **Unplug the recovery USB first.** Two reasons: U-Boot may grab the USB's
   GRUB instead of the internal one (both menus contain an identically-titled
   probe entry — you can't tell them apart on screen), and the probe's own
   embedded `search -f -s root /asahilocker-probe/MANIFEST.txt` will latch onto
   whichever payload it finds first, deciding where results get written. With
   the USB out, both resolve to the internal ESP.
2. Boot → menu (30 s window is still armed) → select the probe entry.
3. Photograph the screen, type `reboot`, then read results:
   `sudo ~/Projects/asahilocker-boot-test/read-results.sh /boot/efi/asahilocker-probe/grubenv`
   If that shows `nottried`, also check the USB copy of grubenv before
   concluding the probe didn't write.

## Ideas / follow-ups

- **Chainloader-free launch path (good fallback + useful for AsahiLocker
  proper):** run the probe straight from U-Boot, no Fedora GRUB involved:
  ```
  # at the U-Boot autoboot prompt (Hit any key to stop autoboot)
  load nvme 0:4 ${kernel_addr_r} /asahilocker-probe/grub-argon2-probe.efi
  bootefi ${kernel_addr_r}
  ```
  This also isolates variables: it tests argon2-under-U-Boot without Fedora
  GRUB's chainloader (LoadImage/StartImage under U-Boot's EFI) in the chain.
- **A suspicious data point worth one controlled test:** `menu_show_once_timeout`
  was still set and `boot_success` still 1 *after* the failed session — the main
  GRUB either never ran grub.cfg that evening (i.e. the session was actually the
  USB's GRUB), or `save_env` isn't persisting to the ext4 /boot. After the next
  successful main boot, run `sudo grub2-editenv - list`: if
  `menu_show_once_timeout` is *still* there, GRUB can't write grubenv on this
  ext4 and anything relying on boot-counting/one-shot menus is silently broken.
  (The probe's own results are safe either way — its grubenv lives on FAT.)
- **`efibootmgr` is a dead end on Asahi** for registering the probe as a boot
  entry: U-Boot's EFI has no runtime SetVariable; variables live in
  `ubootefi.var` on the ESP and are only written by U-Boot itself.
- **Package-update hazard:** `/boot/grub2/arm64-efi/` must stay version-locked
  to `grubaa64.efi`. After any `grub2-*` update, re-copy:
  `sudo cp -a /usr/lib/grub/arm64-efi/*.{mod,lst} /boot/grub2/arm64-efi/`
  — a mismatched module fails to load (magic/symbol check) and you're back to
  this exact failure. Worth a tiny `dnf` post-transaction hook, or fold it into
  the monthly update routine.
- **Full revert** (if ever wanted): `remove-probe-internal.sh` handles the
  entry+payload; the module dir is extra — `sudo rm -rf /boot/grub2/arm64-efi`.
- **For the production design:** the probe result decides the ceiling, but
  either way Fedora's 2.12 `grubaa64.efi` has no argon2 at all — the real
  AsahiLocker boot path will need the self-built 2.14 core image (as
  `EFI/fedora/grubaa64.efi` replacement or a first-stage that chainloads it),
  with `luks2 argon2 cryptodisk ext2 part_gpt` built in and an embedded early
  config, since modules for a LUKS2 `/boot` can't be read from inside the
  encrypted `/boot`. Keep the known constraint: never configure ≥4 GiB argon2id
  memory cost for a GRUB-unlocked volume (32-bit `1024 * memory_blocks`
  overflow in libgcrypt-grub's `argon2_init`).


---

# Second run, same evening: chainload OK, bare GRUB 2.14 prompt

With `chain.mod` in place and the entry pinned by UUID, the chainload worked —
the machine reached a **GRUB 2.14** prompt, which is proof the self-built image
loaded (Fedora's is 2.12). But the probe recorded nothing:
`probe_started=no`, and the ESP `grubenv` mtime was still the deploy time.

## Root cause: the embedded config is parsed by the RESCUE parser

`grub-mkimage --config` embeds a config that `grub_main()` executes via
`grub_load_config()` **before** `grub_load_normal_mode()`. At that point the
current parser is `grub_rescue_parser`, which executes one simple command per
line. It has **no `if`/`then`/`else`, no control flow at all.**

Every measurement in the probe was of the form:

```
if cryptomount -p grubtest (lo1) ; then set p_512M=OK ; else set p_512M=FAIL ; fi
```

so the probe could never have completed, on any hardware. This was never an
Asahi or U-Boot problem.

## Why nothing was left on screen either

When the embedded config finished (or died), `grub_load_normal_mode()` ran
`normal`, which looked for `$prefix/grub.cfg` — `/asahilocker-probe/grub.cfg`,
which did not exist — **cleared the screen** and dropped to the command line.
Any output that had escaped was gone. Hence "it just goes to a GRUB 2.14
prompt".

## v2 design (deployed 2026-08-23 20:53)

Split the two roles:

* **Embedded config** — rescue-parser safe, simple commands only:
  ```
  search --no-floppy --fs-uuid --set=root 2FA7-65AB
  set prefix=($root)/asahilocker-probe
  ```
* **`grub.cfg` on the ESP** — the real probe, executed by `normal` with the
  full script parser, so `if` works.

Plus three changes that matter regardless of the parser bug:

1. **The screen is the primary result channel.** The script ends with
   `sleep --verbose --interruptible 900`, because `normal` clears the screen the
   instant the script returns. Any key ends it.
2. **`save_env` success is measured, not assumed.** Whether GRUB can write the
   FAT grubenv through U-Boot's EFI block layer was never established, so the
   script reports `grubenv writable: OK|FAILED` and the results carry
   `envwrite=`.
3. **`loopback` failure is distinguished** from a KDF failure (`NOLOOP` vs
   `FAIL`), so a payload problem can't be misread as an argon2 ceiling.
4. **2048 MiB added**, ordered last so it cannot affect the earlier results.
   This turns "1 GiB is the assumed ceiling" into a measurement. 2048 MiB is
   safe from the u32 overflow (`1024 * 2097152` = 2^31); **4096 is not**.
5. **The ESP UUID is read by `build-probe.sh`** from the deploy target and baked
   into the image, instead of `search -f` by filename — which was ambiguous
   while the recovery USB carried an identical payload.

## Resolved: GRUB *can* write grubenv on this ext4 `/boot`

The previous note flagged this as suspicious, because `menu_show_once_timeout`
survived the failed session. After the run that reached the 2.14 prompt,
`grub2-editenv - list` shows it **gone** — consumed as designed. So `save_env`
to the ext4 `/boot` works, and the earlier survival is explained by that session
never having run the main `grub.cfg`. Boot-counting and one-shot menus are not
broken. (The FAT ESP is a separate question — see `envwrite` above.)

## Still open

* Does argon2id allocate at 1 GiB inside GRUB under U-Boot? — the whole point of
  the probe, still unanswered.
* Does `save_env` work on the FAT ESP under U-Boot's EFI block layer? — v2
  answers this as a side effect.
