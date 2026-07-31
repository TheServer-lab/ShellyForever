# ShellyForever

ShellyForever is a tiny, from-scratch, bare-metal x86-64 operating system.
It boots directly off a raw disk image via BIOS, walks itself up through
16-bit real mode → 32-bit protected mode → 64-bit long mode, and lands in a
single flat kernel binary that implements its own text-mode shell ("rush"),
its own tiny in-memory/on-disk filesystem, its own PS/2 keyboard driver, and
even its own USB (UHCI) mass-storage driver for moving projects between
machines. There is no BIOS/UEFI runtime dependency once boot is complete, no
interrupts (the keyboard is polled), and no third-party kernel code — it's
one self-contained, hand-written system.

This document covers how to build it, how to run it, and how to use every
command the shell understands.

---

## Table of contents

1. [How it boots](#how-it-boots)
2. [Requirements](#requirements)
3. [Building](#building)
4. [Running](#running)
5. [Using the shell](#using-the-shell)
   - [The prompt](#the-prompt)
   - [Line editing, history, and scrollback](#line-editing-history-and-scrollback)
   - [Comments and chaining](#comments-and-chaining)
   - [Paths](#paths)
6. [Command reference](#command-reference)
   - [Filesystem commands](#filesystem-commands)
   - [Variables and math](#variables-and-math)
   - [System commands](#system-commands)
   - [Scripts and processes](#scripts-and-processes)
   - [Privilege / auth](#privilege--auth)
   - [USB commands](#usb-commands)
7. [Persistence: how the filesystem is saved](#persistence-how-the-filesystem-is-saved)
8. [Project file layout](#project-file-layout)
9. [Troubleshooting](#troubleshooting)

---

## How it boots

Booting a 400KB+ kernel from BIOS in one shot isn't reliable (real-mode
`INT 13h` transfers are effectively bounded by 64KB segment windows), so
ShellyForever boots in two stages:

1. **`boot.asm`** — the classic 512-byte MBR boot sector. BIOS loads it at
   `0x7C00`. Its only job is to load `stage2` (a fixed 32-sector/16KB
   region starting at LBA 1) into memory and jump to it.
2. **`stage2.asm`** — not size-constrained like the boot sector, so it does
   everything else: loads the real kernel from disk in safe 32KB chunks,
   enables the A20 line, sets up a GDT, enters 32-bit protected mode, builds
   page tables, and finally enters 64-bit long mode before jumping into the
   kernel at `0x8000`.
3. **`kernel.asm`** — the OS itself. Runs flat in long mode with the first
   64MB (later expanded to 4GB) identity-mapped. No IDT is installed —
   the keyboard is polled directly via ports `0x60`/`0x64` rather than
   using interrupts.

If something goes wrong early in boot, you'll see single-character debug
checkpoints (`1`, `2`, `K`, etc.) printed in the corner of the screen in
white-on-red — these mark how far boot got before failing, and are useful
for diagnosing a botched build rather than being part of the shell itself.

## Requirements

- **NASM** (`nasm -f bin`) to assemble all three stages.
- **Python 3** — `build.sh` uses it to pad the binaries to fixed sizes.
- **QEMU** (`qemu-system-x86_64`) — or any way to boot a raw disk image —
  to actually run the OS.

On Debian/Ubuntu:

```bash
sudo apt install nasm qemu-system-x86
```

## Building

```bash
chmod +x build.sh
./build.sh
```

This assembles `boot.asm`, `stage2.asm`, and `kernel.asm`, pads `stage2`
out to its fixed 32-sector budget (so the kernel always starts at a known
LBA), concatenates everything into `shellyforever.img`, and pads that image
out to a standard 1.44MB floppy/USB size. Output looks like:

```
Built shellyforever.img (1474560 bytes)
  boot.bin:   512 bytes (stage1, LBA 0)
  stage2.bin: 16384 bytes padded, actual code 526 bytes (LBA 1)
  kernel.bin: 115440 bytes (LBA 33)
Run it with:  qemu-system-x86_64 -drive format=raw,file=shellyforever.img
```

If `stage2.bin` or `kernel.bin` ever outgrow their sector budgets
(`STAGE2_SECTORS` in `build.sh`/`boot.asm`, `KERNEL_SECTORS` in
`stage2.asm`), the build stops with an error telling you which constant to
bump — bump it in **both** places for that stage before rebuilding.

## Running

```bash
qemu-system-x86_64 -drive format=raw,file=shellyforever.img
```

That's it — QEMU boots the image like a real BIOS machine would. You can
also write the image to a real USB stick with `dd` (`dd if=shellyforever.img
of=/dev/sdX bs=4M status=progress`) and boot real hardware with it, though
QEMU is the easiest way to try it.

## Using the shell

Once booted, you land in **rush**, ShellyForever's shell.

### The prompt

```
rush>/home: _
```

The prompt is always `rush>` followed by your current path, then `: `. On a
fresh boot you start in `/home`.

### Line editing, history, and scrollback

While typing a command, the following work exactly like you'd expect from a
normal terminal:

| Key             | Effect                                                        |
|-----------------|----------------------------------------------------------------|
| Backspace       | delete the previous character                                  |
| Enter           | submit the line                                                 |
| **Up / Down**   | recall previously entered commands (command history)            |
| **Ctrl+Up / Ctrl+Down** | scroll the *screen* back/forward through past output   |

**History (Up/Down).** ShellyForever remembers your last 16 typed lines.
Press **Up** to walk backwards through them (most recent first), **Down**
to walk forwards again. If you start typing something, then hit Up to
browse history, then hit Down enough times to come back past the newest
entry, you get back exactly what you had typed before you started
browsing — nothing is lost. Empty lines and immediate repeats of the last
command aren't added to history.

**Scrollback (Ctrl+Up/Ctrl+Down).** The screen is only 25 rows tall, so
long output (like `help` or a big `list`) scrolls old lines off the top.
Press **Ctrl+Up** to scroll the *view* back and see those lines again — up
to about 10 screenfuls (256 rows) of history. **Ctrl+Down** scrolls back
toward the bottom. This only changes what's displayed; it doesn't affect
the command you're typing. As soon as you press any other key (type a
character, Backspace, Enter, or use Up/Down for history), the view snaps
straight back to the live bottom of the screen — just like a normal
terminal emulator.

### Comments and chaining

- A line starting with `$` is a comment and is ignored:
  ```
  rush>/home: $ this line does nothing
  ```
- Multiple commands can be chained on one line with `;`:
  ```
  rush>/home: show hi ; show bye
  hi
  bye
  ```
  (Semicolons inside double quotes don't split the line.)

### Paths

Anywhere a command takes a `<path>`, you can use:

- A plain name (`notes.txt`) — relative to the current folder.
- A relative path with subfolders (`docs/notes.txt`).
- `..` to go up a level, `.` for the current folder.
- An absolute path starting with `/` (`/home/x`).

Folder/file names are capped at 31 characters.

---

## Command reference

Run `help` in the shell at any time to see a condensed version of this list.

### Filesystem commands

| Command | Description |
|---|---|
| `cf <path>` | Change folder. `cf ..` goes up one level, `cf /home` jumps to root. |
| `mkf <path>` | Make a new folder. |
| `mkfl <path> "text"` | Make a file at `<path>` containing `text` (the content must be in double quotes). |
| `mkfl -force <path> "text"` | Overwrite the file if it already exists. |
| `mkfl -silent <path> "text"` | Same as `-force`, but suppresses the overwrite warning. |
| `mkfl -info <path> "text"` | Verbose mode — prints the filename and content length after creating it. |
| `list` | List the contents of the current folder. |
| `view <path>` | Print a file's contents. |
| `edit <name>` | Open the built-in full-screen text editor on a file. Press **Esc** when done, then **y**/**n** to save or discard. |
| `del <path>` | Delete a file. **Requires `auth`.** |
| `rname <path> <new>` | Rename a file or folder in place (the new name stays in the same parent folder). |
| `cpy <src> <dest>` | Copy a file or folder — both arguments can be full paths. |
| `mov <src> <dest>` | Move/rename a file or folder — both arguments can be full paths. |
| `current` | Print the current path. |

**Examples:**

```
rush>/home: mkf docs
rush>/home: cf docs
rush>/home/docs: mkfl notes.txt "shopping list: eggs, milk"
rush>/home/docs: view notes.txt
shopping list: eggs, milk
rush>/home/docs: cf ..
rush>/home: cpy docs/notes.txt docs/notes_backup.txt
rush>/home: mov docs/notes_backup.txt archive/notes_backup.txt
rush>/home: rname docs backup_docs
```

### Variables and math

| Command | Description |
|---|---|
| `<name> = <value>` | Set a variable to a number, or to the value of another variable. |
| `show "text"` | Print a literal message. |
| `show <name>` | If `<name>` matches a variable, print its value instead of the literal text. |
| `rmv <name>` | Remove a variable. |
| `vars` | List all variables and their values. |
| `vars rmv all` | Clear every variable. **Requires `auth`.** |
| `calc <expr>` | Evaluate a math expression (`+ - * /`, standard precedence, integer arithmetic, any number of terms). |

**Examples:**

```
rush>/home: a = 10
rush>/home: b = 5
rush>/home: show a
10
rush>/home: calc a + b * 2
20
rush>/home: vars
a = 10
b = 5
rush>/home: rmv b
```

### System commands

| Command | Description |
|---|---|
| `wipe` | Clear the screen. |
| `sync` | Save the current filesystem to disk. |
| `rboot` | Save to disk, then restart the machine. **Requires `auth`.** |
| `sdown` | Shut down the machine. **Requires `auth`.** |
| `help` | Show the command list. |

### Scripts and processes

| Command | Description |
|---|---|
| `rr <script.rsh>` | Run a "rush script" file — a file full of shell commands (`$` still marks comment lines inside the script), executed line by line as a tracked background process named `runrush <filename>`. |
| `prs` | List running processes (PID, name, state). |
| `prs kill <pid>` | Kill a running process by its PID. |
| `prs kill rushrun` | Kill the currently running `rr` script. |

While a script is running, pressing **Esc** at the shell also sets a kill
flag that script execution checks between lines, so a runaway script can be
interrupted without waiting for `prs kill`.

**Example:**

```
rush>/home: mkfl setup.rsh "$ demo script
mkf project
cf project
show hello from a script"
rush>/home: rr setup.rsh
rush>/home: prs
```

### Privilege / auth

A handful of commands are considered dangerous (`del`, `rboot`, `sdown`,
`vars rmv all`) and are gated behind a one-shot authorization:

```
auth <command> [args...]
```

`auth` grants privilege for exactly **one** command, runs it immediately,
and then revokes the privilege again — there's no persistent "logged in"
state.

**Examples:**

```
rush>/home: auth del docs/notes.txt
rush>/home: auth vars rmv all
rush>/home: auth sdown
```

### USB commands

ShellyForever includes its own minimal UHCI USB driver and a small,
purpose-built (not FAT/exFAT) archive format for moving whole project
folders to and from a USB mass-storage drive. The typical flow is:

```
rush>/home: dscan          $ scan the PCI bus for a UHCI USB controller
rush>/home: usbinfo        $ address the device found by dscan and probe it
rush>/home: usbdisk        $ probe it as a mass-storage device
rush>/home: usb list       $ list projects already stored on the drive
```

| Command | Description |
|---|---|
| `dscan` | Scan the PCI bus for a UHCI USB host controller. |
| `usbinfo` | Assign a USB address to the controller found by `dscan` and probe its descriptors. |
| `usbdisk` | Probe a USB mass-storage device found by `usbinfo` (vendor info, capacity, a raw sector read). |
| `usb list` | List project archives already stored on the USB drive. |
| `usb info` | Show USB device info. |
| `usb export <name>` | Export a folder from the current filesystem to the USB drive as a project archive. (Needs `dscan` + `usbinfo` first.) |
| `usb import <name>` | Import a project archive from the USB drive back into the filesystem. |
| `usb delete <name>` | Delete a project archive from the USB drive. |
| `usb rename <a> <b>` | Rename a project archive on the USB drive from `<a>` to `<b>`. |

Each USB drive can hold up to 16 project archives, each capped at 16KB of
serialized folder content — plenty for typical text-based projects, but
worth knowing if an export unexpectedly fails.

---

## Persistence: how the filesystem is saved

ShellyForever keeps its whole filesystem in memory while running. On boot,
it tries to load a previously saved filesystem from disk; if none is found,
it starts fresh and tells you so:

```
ShellyForever v0.1 -- 'help' for commands
No saved filesystem found - starting fresh.
```

Nothing you create is written to disk automatically — run `sync` whenever
you want to persist your current files/folders, or use `rboot`, which
syncs and then restarts for you. If the disk itself isn't available (e.g.
running from read-only media), the shell warns you at boot and `sync`
simply won't have anywhere to write.

## Project file layout

| File | Purpose |
|---|---|
| `boot.asm` | Stage 1: 512-byte MBR boot sector. |
| `stage2.asm` | Stage 2: real-mode kernel loader, A20/GDT/paging/long-mode setup. |
| `kernel.asm` | The OS itself: shell, filesystem, keyboard driver, USB driver. |
| `build.sh` | Assembles all three stages and links them into `shellyforever.img`. |
| `shellyforever.img` | The bootable disk image produced by `build.sh`. |

## Troubleshooting

- **Stuck on a single debug character (`1`, `2`, etc.) after boot.** That's
  one of `boot.asm`'s or `stage2.asm`'s checkpoint markers — it means boot
  failed before reaching that stage. Rebuild with `./build.sh` and check
  for assembly errors; a mismatched `STAGE2_SECTORS`/`KERNEL_SECTORS`
  between `build.sh` and the `.asm` files is the most common cause.
- **"disk not available" warning at boot.** The shell still works — you just
  won't be able to `sync`/persist a filesystem or use `usb export`/`import`
  writes to that same disk. This is normal when booting from certain
  read-only or emulated media.
- **A dangerous command refuses to run.** `del`, `rboot`, `sdown`, and
  `vars rmv all` all require you to prefix them with `auth`, e.g.
  `auth del somefile.txt`.
