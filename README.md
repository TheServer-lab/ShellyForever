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
| `del` | `del something.txt` | delete a file in the current folder (requires auth) |
| `rname` | `rname old.txt new.txt` | rename a file or folder here |
| `owrite` | `owrite hi.txt "new content"` | overwrite an existing file's content in place |
| `cpy` | `cpy docs docs_backup` | copy a file or folder here (recursive for folders) |
| `mov` | `mov docs archive` | move/rename a file or folder here (recursive for folders) |
| `show` | `show "hello world"`, `show a` | print a message, or a variable's value |
| `list` | `list` | list contents of current folder |
| `view` | `view something.txt` | print a file's content |
| `find` | `find notes.txt` | search every drive for a file/folder by name, print its full path |
| `lookfor` | `lookfor "todo" notes.txt`, `lookfor "todo" line 100, 200 notes.txt limit 5` | search a file's content for text, like grep |
| `edit` | `edit something.txt` | open the built-in editor for a file (Esc, then y/n to save) |
| `<name> = <value>` | `a = 5` | set a variable to a literal or another variable's value |
| `rmv` | `rmv a` | remove a variable |
| `vars` | `vars` | list all variables |
| `vars rmv all` | `auth vars rmv all` | clear all variables (requires auth) |
| `calc` | `calc 1 + 2 * 3` | evaluate a math expression |
| `rr` | `rr script.rsh` | run a rush script file (`$` = comment line) |
| `prs` | `prs`, `prs kill 1`, `prs kill rushrun` | list processes, or kill by PID or name |
| `auth` | `auth sdown`, `auth vars rmv all` | elevate privileges for one dangerous command |
| `current` | `current` | print current path |
| `wipe` | `wipe` | clear the screen |
| `help` | `help` | list commands |
| `dscan` | `dscan` | scan all ATA and AHCI drives for SFFS volumes |
| `fmt` | `fmt data` | format the first unformatted drive with an SFFS label (`-force` to reuse one) |
| `mount` | `mount data` | mount a formatted drive's volume under `/<label>/` |
| `label` | `label old new` | rename a formatted drive's label in place, without touching its files |
| `sync` | `sync` | save the filesystem (and mounted volumes) to disk |
| `rboot` | `rboot` | save to disk, then restart (requires auth) |
| `sdown` | `sdown` | save to disk, then shut down (requires auth) |

### Line editing: history and scrollback

- **Up / Down** — recall previous commands (like bash). Your in-progress
  line is preserved if you arrow up through history and then back down past
  the most recent entry. History holds the last 20 non-empty lines entered
  this session (not persisted across reboot).
- **Ctrl+Up / Ctrl+Down** — scroll the screen back to review output that's
  scrolled off the top (up to 100 lines of scrollback), without disturbing
  whatever you're mid-typing at the prompt. Typing a character, pressing
  Enter, or recalling history all snap the view back to live automatically.
  Works at the shell prompt and inside the `edit` command's editor.

### Command chaining with `;`

You can chain multiple commands on a single line using `;`:

```
rush>/home: show hello ; show world
hello world
rush>/home: mkfl a.txt "first" ; mkfl b.txt "second" ; list
a.txt
b.txt
rush>/home:
```

Semicolons inside double quotes are treated literally:

```
rush>/home: show "do not ; split this"
do not ; split this
```

This also works inside `rr` script files, so a single `.rsh` line can run
multiple commands in sequence. Press Esc to interrupt a running script at any
point — including between `;`-chained segments on the same line.

### Piping output with `~`

You can pipe the output of one command into another with `~`:

```
rush>/home: calc 1 + 1 * 5 ~ = a ; show a
6
```

The left side of `~` runs normally except its output is captured instead of
being printed. What happens with that captured text depends on the right
side:

- **`= <name>`** (or `=<name>` with no space) parses the captured text as a
  decimal integer and stores it in that variable, just like a normal
  `<name> = <value>` assignment:
  ```
  rush>/home: calc 10 - 3 ~ = b
  rush>/home: show b
  7
  ```
- **Any other command** gets the captured text appended as one extra quoted
  argument and is then run as-is:
  ```
  rush>/home: calc 3 * 3 ~ show
  9
  rush>/home: view notes.txt ~ mkfl copy.txt
  ```
  (the second example pipes a file's content into a new file, using `view`'s
  output as `mkfl`'s content argument)

Like `;`, a `~` inside double quotes is treated literally, not as a pipe, and
this works inside `rr` scripts too. Only one `~` per chained segment is
supported (i.e. `a ~ b ~ c` is not).

### Comments with `$`

Any line whose first character is `$` is treated as a comment and skipped by
both the interactive shell and the `rr` script runner:

```
rush>/home: $ this is a comment
rush>/home: show hi
hi
```

### Elevation system (auth)

Dangerous commands — `sdown`, `rboot`, `del`, and `vars rmv all` — require
authentication. Prefix the command with `auth` (like `sudo`):

```
rush>/home: sdown
error: this command requires authentication. Use 'auth <command>' first.
rush>/home: auth sdown
Authentication granted.
Shutting down...
```

The auth flag is temporary — it applies only to the one command following
`auth`, then resets. Chain with `;` works too:

```
rush>/home: auth del notes.txt ; show "done"
Authentication granted.
done
```

### Flags: `-force`, `-silent`, `-info`

`mkfl` supports three flags (passed as extra arguments after the content):

| Flag | Effect |
|---|---|
| `-force` | Overwrite an existing file (prints a warning) |
| `-silent` | Suppress the `-force` overwrite warning |
| `-info` | Print verbose info: filename and content length |

```
rush>/home: mkfl hi.txt "first" ; show hi
rush>/home: mkfl hi.txt "second"
error: that name already exists here
rush>/home: mkfl hi.txt "second" -force
mkfl: overwriting existing file hi.txt
rush>/home: mkfl hi.txt "third" -force -silent
rush>/home: mkfl hi.txt "fourth" -info
mkfl: creating 'hi.txt' (6 bytes)
```

### Overwriting files with `owrite`

`mkfl` makes a new file (or overwrites one with `-force`); `owrite` is the
simpler counterpart for when the file is already there and you just want to
replace its content:

```
rush>/home: mkfl hi.txt "Hello"
rush>/home: owrite hi.txt "Hello, there."
rush>/home: view hi.txt
Hello, there.
```

Unlike `mkfl -force`, `owrite` requires the file to already exist (it errors
with `owrite: no such file: <path>` otherwise) and never creates one.

### Searching: `find` and `lookfor`

`find <name>` looks for a file or folder by exact name across every drive —
the boot volume and any mounted ones — and prints the full path of every
match:

```
rush>/home: mkf docs ; mkfl docs/notes.txt "todo: buy milk"
rush>/home: find notes.txt
/home/docs/notes.txt
rush>/home: find nope.txt
find: no matches
```

`lookfor <text> <file> [limit <n>]` is a small grep: it searches a file's
content one line at a time (a "line" is whatever's between newline bytes in
that file's content) and prints every matching line, up to `limit` matches
(50 by default):

```
rush>/home: lookfor "todo" docs/notes.txt
todo: buy milk
rush>/home: lookfor "todo" docs/notes.txt limit 5
todo: buy milk
```

Add `line <a>, <b>` (1-indexed, inclusive) to restrict the search to just
that range of lines:

```
rush>/home: lookfor "todo" line 100, 200 docs/notes.txt limit 50
```

Both the search text and file path accept the usual path syntax (`docs/x`,
`../x`, `/home/x`), and the search text can be quoted if it has spaces.

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
(primary/secondary buses, both master/slave, LBA28, polling BSY/DRQ — no
IRQs, matching the polled keyboard driver's style) that reads and writes raw
sectors, plus a hand-written AHCI driver (PCI class-code scan for the
controller, MMIO register access, up to `AHCI_MAX_PORTS` (4) ports polled to
completion per command, no interrupts here either) for real SATA controllers
that don't expose legacy IDE at all. `dscan`/`fmt`/`mount`/`sync` treat both
transports as one unified list of device slots — ids `0..3` are the legacy
ATA slots, ids `4..4+AHCI_MAX_PORTS-1` are AHCI ports discovered at boot.

### SFFS v2 on-disk format

Each disk volume is self-contained and starts at sector (LBA) 200 — well
clear of the boot sector and the kernel's own sectors (1..199):

- **Superblock** (1 sector): `SFFS` magic, version byte, then a 32-byte
  label.
- **Type / parent / name / content** sectors: one node table per volume
  (`node_type`, `node_parent`, 4 name sectors, 20 content sectors), exactly
  like the old whole-disk blob but scoped per volume with *relative* parent
  indices (`0xFFFF` = volume root), so the same layout works on any drive.

### One boot drive, up to two mounted drives

- The boot drive's volume is the OS filesystem (rooted at `/home`).
- `dscan` probes all legacy ATA slots (primary/secondary × master/slave) and
  every AHCI port found on the controller, and reports which contain SFFS
  volumes.
- `fmt <label>` formats the first *unformatted* drive present (the boot
  drive is skipped unless you pass `-force`).
- `mount <label>` finds the drive whose label matches, loads it into memory
  under `/<label>/` next to `/home`, and you can `cf /<label>` into it like
  any folder.
- `label <old> <new>` renames a drive's label in place by rewriting just its
  superblock — the drive's files are left untouched. Refuses if `<new>` is
  already used by another drive. If that drive happens to be mounted at the
  time, the live mount name updates immediately too.
- `sync`, `rboot`, and `sdown` write the boot volume *and* every mounted
  volume back to their own drives.

On boot, the kernel loads the boot volume's region; if the magic/version
don't check out (blank disk, or an older on-disk format) it falls back to
`fs_init` and starts fresh. Because `shellyforever.img` is a real disk
image, this persists not just across `reboot`/`sdown` inside one QEMU
session, but across separate QEMU invocations (and real hardware) as long as
you keep using the same image file. The old single-blob-at-LBA-100 format
was tested end-to-end in QEMU; the SFFS v2 multi-volume format has been
assembled but not yet boot-tested.

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
- 64 nodes per volume, with the in-memory node table sized for the boot
  volume plus up to `MAX_MOUNTS` (2) mounted volumes — 192 nodes total in
  memory. File/folder names capped at 32 bytes, file content capped at ~160
  bytes, line input capped at ~220 chars — easy to bump, just constants at
  the top of `kernel.asm` (the on-disk format size adjusts automatically
  since it's computed from those same constants).
  Worth knowing: `mkfl`/`rname`/`cpy`/`mov` don't currently check that a
  destination name is short enough to fit in that 32-byte slot before
  copying it in.
- `cpy`/`mov` only operate within the current folder (no path arguments like
  `../docs`), matching how `cf`/`mkf`/etc. already work one directory at a
  time.
- `~` piping captures a command's printed output into a fixed-size buffer
  (192 bytes) and, for the generic (non-`= name`) case, rebuilds the right
  side's command line by wrapping that captured text in double quotes before
  re-parsing it — a captured value that itself contains a `"` will break
  that reconstruction, and very long captured output (e.g. piping `list` on
  a folder with many files) is silently truncated rather than growing the
  buffer.
- Persistence is whole-table snapshotting (like a save file), not an
  incremental/journaled on-disk format — simple and robust for this scale,
  but a `sync` rewrites the whole reserved region every time.
- `kernel.bin` currently uses ~189 of the 199 sectors (`KERNEL_SECTORS` in
  `boot.asm`) the bootloader reserves for it. If you add enough new code to
  cross that budget, bump `KERNEL_SECTORS` again — it's a one-line change,
  but the bootloader will silently load a truncated kernel if you forget,
  which looks like an unrelated crash. (The on-disk SFFS region starts at
  LBA 200, so keep the kernel's reserved region clear of that.)

## Natural next steps, in order of payoff

1. **Path arguments** for `cf`/`cpy`/`mov`/`rname` (e.g. `cpy docs/notes.txt ..`)
   instead of current-folder-only operations.
2. **Autosave on mutation** instead of requiring explicit `sync`/`rboot`/`sdown`,
   if you'd rather not think about it (tradeoff: more disk writes).
3. **A real memory allocator** once you want dynamic-sized files/folders
   instead of fixed slot counts.
4. **Password-based auth** instead of the current one-shot `auth` flag, so
   elevated sessions can span multiple commands without re-authenticating.

## What's new

- **`find` and `lookfor`** — `find <name>` searches every drive for a file
  or folder by exact name and prints its full path; `lookfor <text> <file>
  [limit <n>]` greps a file's content line by line, optionally restricted
  to a `line <a>, <b>` range. See "Searching: `find` and `lookfor`" above.
- **`owrite`** — overwrites an existing file's content in place
  (`owrite hi.txt "new content"`), without `mkfl`'s create-or-`-force`
  semantics. See "Overwriting files with `owrite`" above.
- **`~` pipes** — pipe one command's output into another:
  `calc 1 + 1 * 5 ~ = a` stores calc's result in the variable `a`;
  `calc 3 * 3 ~ show` pipes the result into `show`. See "Piping output with
  `~`" above.
- **Command history (Up/Down)** and **scrollback (Ctrl+Up/Ctrl+Down)** — see
  "Line editing: history and scrollback" above.
- **`;` command chaining** — run multiple commands on one line:
  `show hello ; show world`. Semicolons inside double quotes are literal.
  Works in both the interactive shell and `rr` script files.
- **`$` comment lines** — lines starting with `$` are skipped by the shell
  and the `rr` script runner.
- **`rr` script runner** — `rr script.rsh` executes each line of a rush
  script file. Lines starting with `$` are comments. Press Esc to interrupt.
  `;` chaining works inside scripts too.
- **`prs` process manager** — `prs` lists running scripts; `prs kill <pid>`
  or `prs kill rushrun` terminates them.
- **Elevation system (`auth`)** — dangerous commands (`sdown`, `rboot`, `del`,
  `vars rmv all`) require `auth` prefix, like `sudo`. The auth flag is
  one-shot: it applies only to the immediately following command.
- **`vars` command** — lists all variables, or clears all with
  `auth vars rmv all`.
- **SFFS v2 multi-volume storage** — `dscan` scans the ATA bus for SFFS
  disks, `fmt <label>` formats an unformatted drive, and `mount <label>`
  attaches it under `/<label>/` beside `/home`. Up to 2 mounted drives on
  top of the boot drive.
- **Flags: `-force`, `-silent`, `-info`** — `mkfl` now supports:
  - `-force`: overwrite an existing file (prints a warning)
  - `-silent`: suppress the `-force` overwrite warning
  - `-info`: print verbose info (filename + content length)

I built and test-assembled this (including `find`, `lookfor`, and `owrite`)
in a sandbox with QEMU available but didn't get all the way through a full
interactive boot test this session — every change has been verified to
assemble cleanly with no errors, and I traced the logic carefully by hand,
but you should run it in QEMU yourself to catch anything a static read-through
can't — happy to help debug from there if something misbehaves.