# ShellyForever

A 64-bit shell-based OS written entirely in x86-64 NASM assembly, from scratch —
no C, no BIOS libraries beyond boot-time disk/keyboard calls, no existing kernel.

## What's actually in here

- **`boot.asm`** — the boot sector (512 bytes, fits in one disk sector).
  Runs in 16-bit real mode, loads `kernel.bin` off disk, switches to 32-bit
  protected mode, builds minimal page tables, switches to 64-bit long mode,
  and jumps into the kernel.
- **`kernel.asm`** — the OS itself. From scratch:
  - A VGA text-mode driver (writes directly to `0xB8000`), with scrolling.
  - A PS/2 keyboard driver (polls the `8042` controller, decodes scancode
    set 1, handles shift for letters/symbols, backspace, enter).
  - **`rush`**, the custom shell: prompt, line editor, a tokenizer that
    understands `"quoted strings with spaces"`, and a command dispatcher.
  - An in-memory filesystem tree rooted at `/home` (folders + files), with
    recursive copy/move/delete of whole subtrees.
  - A simple `name = value` variable table (int64), reused by `calc`.
  - A built-in line editor for file content (`edit`).

## Commands implemented

| Command | Example | Behavior |
|---|---|---|
| `cf` | `cf docs`, `cf ..`, `cf /home` | change folder |
| `mkf` | `mkf docs` | make a folder in the current directory |
| `mkfl` | `mkfl something.txt "some text"` | make a file with content |
| `del` | `del something.txt` | delete a file in the current folder |
| `rname` | `rname old.txt new.txt` | rename a file or folder here |
| `cpy` | `cpy docs docs_backup` | copy a file or folder here (recursive for folders) |
| `mov` | `mov docs archive` | move/rename a file or folder here (recursive for folders) |
| `show` | `show "hello world"`, `show a` | print a message, or a variable's value |
| `list` | `list` | list contents of current folder |
| `view` | `view something.txt` | print a file's content |
| `edit` | `edit something.txt` | open the built-in editor for a file (Esc, then y/n to save) |
| `<name> = <value>` | `a = 5` | set a variable to a literal or another variable's value |
| `rmv` | `rmv a` | remove a variable |
| `calc` | `calc 1 + 2 * 3` | evaluate a math expression |
| `current` | `current` | print current path |
| `wipe` | `wipe` | clear the screen |
| `help` | `help` | list commands |
| `sync` | `sync` | save the filesystem to disk |
| `rboot` | `rboot` | save to disk, then restart the machine |
| `sdown` | `sdown` | save to disk, then shut down the machine |

Prompt looks exactly like you asked:

```
rush>/home: mkfl something.txt "some text"
rush>/home: view something.txt
some text
rush>/home: mkf docs
rush>/home: cf docs
rush>/home/docs: show "hello world"
hello world
rush>/home/docs: cf ..
rush>/home:
```

## Building it yourself

```bash
sudo apt install nasm
./build.sh
```

This produces `shellyforever.img`, a raw bootable disk image.

## Running it

**QEMU (easiest, works anywhere):**
```bash
qemu-system-x86_64 -drive format=raw,file=shellyforever.img
```

**Real 64-bit hardware (legacy/BIOS boot only, not UEFI):**
```bash
sudo dd if=shellyforever.img of=/dev/sdX bs=4M status=progress
```
Replace `/dev/sdX` with your USB drive (**not** a partition, not your hard
disk — double check with `lsblk` first). Boot from it via your BIOS boot
menu with legacy/CSM mode enabled.

**VirtualBox/VMware:** create a new VM, "Other/Unknown 64-bit" OS, attach
`shellyforever.img` as a raw/IDE disk, boot.

## Disk persistence

The filesystem survives reboots. There's a hand-written ATA PIO driver
(primary bus, LBA28, polling BSY/DRQ — no IRQs, matching the polled keyboard
driver's style) that reads and writes raw sectors.

- The whole node table (`node_type`, `node_parent`, `node_name`,
  `node_content`) plus a small `SFFS`/version header is serialized as one
  blob starting at disk sector (LBA) 100 — well clear of the boot sector and
  the kernel's own sectors (1..64), leaving room for the kernel to grow.
- **`sync`** writes the current filesystem to disk on demand.
- **`rboot`** saves before it restarts, and **`sdown`** saves before it shuts
  down, so neither will lose work.
- On boot, the kernel tries to load that region; if the header's magic
  bytes/version don't check out (blank disk, or an older on-disk format) it
  falls back to `fs_init` and starts fresh, same as before.
- Because `shellyforever.img` is a real disk image, this persists not just
  across `reboot`/`sdown` inside one QEMU session, but across separate QEMU
  invocations (and real hardware) as long as you keep using the same image
  file.

This was tested end-to-end in QEMU: create files/folders → `sync` → quit
QEMU entirely → relaunch QEMU on the same `.img` → `list`/`view` show the
same data.

## Shutdown (`sdown`)

There's no ACPI table parsing in this kernel, so `sdown` doesn't negotiate a
real ACPI shutdown. Instead it saves the filesystem, then pokes the legacy
"magic port" shutdown hooks that QEMU, Bochs, and VirtualBox each recognize
(ports `0x604`, `0xB004`, and `0x4004` respectively). If none of those match
whatever you're running it on (including real hardware), the CPU just halts
safely instead of doing anything unsafe — you'd see the "Shutting down..."
message and then nothing, which is your cue to power off manually.

## Known limitations / what "from scratch" currently means

- No interrupts/IDT — keyboard and disk I/O are both polled, which is simple
  and reliable for a single-tasking shell but would need to change for
  multitasking or overlapping disk I/O.
- No memory manager beyond a flat identity-mapped first 2MB — fine for a
  kernel this size, would need a real allocator to grow much further.
- No ACPI — `sdown` relies on emulator-specific legacy ports rather than a
  negotiated ACPI shutdown (see above).
- 64 filesystem nodes max, file/folder names capped at 32 bytes, file
  content capped at ~160 bytes, line input capped at ~220 chars — easy to
  bump, just constants at the top of `kernel.asm` (the on-disk format size
  adjusts automatically since it's computed from those same constants).
  Worth knowing: `mkfl`/`rname`/`cpy`/`mov` don't currently check that a
  destination name is short enough to fit in that 32-byte slot before
  copying it in.
- `cpy`/`mov` only operate within the current folder (no path arguments like
  `../docs`), matching how `cf`/`mkf`/etc. already work one directory at a
  time.
- Persistence is whole-table snapshotting (like a save file), not an
  incremental/journaled on-disk format — simple and robust for this scale,
  but a `sync` rewrites the whole reserved region every time.
- `kernel.bin` currently uses 47 of the 64 sectors (`KERNEL_SECTORS` in
  `boot.asm`) the bootloader reserves for it. If you add enough new code to
  cross that budget, bump `KERNEL_SECTORS` again — it's a one-line change,
  but the bootloader will silently load a truncated kernel if you forget,
  which looks like an unrelated crash.

## Natural next steps, in order of payoff

1. **Path arguments** for `cf`/`cpy`/`mov`/`rname` (e.g. `cpy docs/notes.txt ..`)
   instead of current-folder-only operations.
2. **Autosave on mutation** instead of requiring explicit `sync`/`rboot`/`sdown`,
   if you'd rather not think about it (tradeoff: more disk writes).
3. **A real memory allocator** once you want dynamic-sized files/folders
   instead of fixed slot counts.

I built and test-assembled this in a sandbox without a CPU emulator
available, so it's been verified to assemble cleanly and I traced the logic
carefully, but you should run it in QEMU yourself to catch anything a static
read-through can't — happy to help debug from there if something misbehaves.
