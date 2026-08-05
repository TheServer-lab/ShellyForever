# ShellyForever

**Version:** 0.1.4

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
  - Multi-block (chained) files — a single file can span multiple
    filesystem nodes, so it's no longer capped at one node's content size.
    See "Multi-block files (SFFS v3)" below.
  - A polled networking stack: hand-written drivers for the RTL8139
    (legacy), Intel e1000, and Realtek RTL8168/8169/8161 ("PCIe GBE
    Family Controller") NICs, plus Ethernet II + ARP + IPv4 + ICMP echo +
    UDP + a DNS client. See "Networking" below.

## Commands implemented

| Command | Example | Behavior |
|---|---|---|
| `cf` | `cf docs`, `cf ..`, `cf /home` | change folder |
| `mkf` | `mkf docs` | make a folder in the current directory |
| `mkfl` | `mkfl something.txt "some text"` | make a file with content (`-force`/`-silent`/`-info`/`-test`) |
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
| `date` | `date` | print the current date (from the RTC clock chip) |
| `time` | `time` | print the current time, HH:MM:SS 24-hour (from the RTC) |
| `wig` | `wig time` | live clock widget in the top-right corner, updates every second (Esc to stop) |
| `shelly` | `shelly` | print the splash banner: a rainbow ShellyForever OS title, the developer credit, and the copyright line |
| `write` | `show hi ~ write file.txt` | write text to a file (creates it, or overwrites); handy as a `~` pipe target |
| `rr` | `rr script.rsh` | run a rush script file (`$` = comment line) |
| `party` | `party hello.pa` | run a program in **Party** (`.pa`), a small built-in scripting language — own variables, expressions, `if`/`else`, `while`, `func`/`return`, and `display` output. See "Party" below and `PARTY_SPEC.md` |
| `prs` | `prs`, `prs kill 1`, `prs kill rushrun` | list processes, or kill by PID or name |
| `auth` | `auth sdown`, `auth vars rmv all` | elevate privileges for one dangerous command |
| `current` | `current` | print current path |
| `wipe` | `wipe` | clear the screen |
| `help` | `help` | list commands |
| `dscan` | `dscan` | scan all ATA and AHCI drives for SFFS volumes (shows each drive's `disk<N>` target label) |
| `fmt` | `fmt data` | format the first unformatted drive with an SFFS label (`-force` to reuse one) |
| `fmt` | `fmt disk1 data` | format a SPECIFIC drive by the `disk<N>` label `dscan` shows for it |
| `mount` | `mount data` | mount a formatted drive's volume under `/<label>/` |
| `unmount` | `unmount data` | detach a mounted drive's volume (data stays on disk; `mount` re-attaches it) |
| `label` | `label old new` | rename a formatted drive's label in place, without touching its files |
| `ali` | `ali gs list ~ show` | create an alias: shorthand for a stored command (or chain of commands) |
| `alis` | `alis` | list all aliases and their bodies |
| `rmv ali` | `rmv ali gs` | remove one alias |
| `color` | `color cyan`, `color list`, `color reset` | change the normal-text output color (16 VGA colors) |
| `sync` | `sync` | save the filesystem (and mounted volumes) to disk |
| `rboot` | `rboot` | save to disk, then restart (requires auth) |
| `sdown` | `sdown` | save to disk, then shut down (requires auth) |
| `netinfo` | `netinfo` | show the NIC's MAC address and static IP/mask/gateway/DNS config |
| `net` | `net ip 10.0.2.20`, `net gw 10.0.2.2`, `net dns 8.8.8.8` | change the static IP, gateway, or DNS config |
| `dns` | `dns google.com` | resolve a hostname via the configured DNS server |
| `bounce` | `bounce 10.0.2.2` | send one ICMP echo (ping) with a ~2-3s timeout |
| `monitor` | `monitor google.com` | ping repeatedly, one line per reply, until Esc |
| `tcp` | `tcp 10.0.2.2 8000` | open a TCP connection, send a payload, and print the reply |

### Line editing: history, tab completion, and scrollback

- **Tab** — command / filename completion (see below).
- **Up / Down** — recall previous commands (like bash). Your in-progress
  line is preserved if you arrow up through history and then back down past
  the most recent entry. History holds the last 20 non-empty lines entered
  this session (not persisted across reboot).
- **Ctrl+Up / Ctrl+Down** — scroll the screen back to review output that's
  scrolled off the top (up to 100 lines of scrollback), without disturbing
  whatever you're mid-typing at the prompt. Typing a character, pressing
  Enter, or recalling history all snap the view back to live automatically.
  Works at the shell prompt and inside the `edit` command's editor.

### Tab completion

Pressing **Tab** at the prompt completes what you're typing:

- **First token on the line** — completes a built-in command name.
  `vi` + Tab becomes `view ` (a unique match gets a trailing space).
- **Any later token** — completes a file or folder name directly inside the
  current directory. `view aa` + Tab becomes `view aaa.txt`; a folder match
  gets a trailing `/` (`cf doc` + Tab → `cf docs/`).
- **Ambiguous prefix** — completes as far as all candidates agree; if that's
  already the whole shared prefix, the candidates are listed on their own
  line and the prompt and line are redrawn, so you can keep typing and Tab
  again (`d` + Tab lists `del dscan date`).

```text
rush>/home: ca<Tab>                      ->  rush>/home: calc
rush>/home: view a<Tab>                  ->  rush>/home: view aaa.txt
rush>/home: view b<Tab>
bbb.txt bcd.txt
rush>/home: view b
```

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

Dangerous commands — `sdown`, `rboot`, `del`, `vars rmv all`, and `rmv ali
all` — require authentication. Prefix the command with `auth` (like `sudo`):

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

### Flags: `-force`, `-silent`, `-info`, `-test`

`mkfl` supports four flags (passed as extra arguments after the content):

| Flag | Effect |
|---|---|
| `-force` | Overwrite an existing file (prints a warning) |
| `-silent` | Suppress the `-force` overwrite warning |
| `-info` | Print verbose info: filename and content length |
| `-test` | Dry run: report what would happen, make no changes |

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

`-test` works with or without content, and reports the same outcome a real
run would have without ever touching the filesystem:

```
rush>/home: mkfl newfile.txt -test
mkfl: [test] would create 'newfile.txt' (0 bytes) - test mode, no changes made
rush>/home: mkfl hi.txt -test
mkfl: [test] 'hi.txt' already exists - would fail (use -force to overwrite)
rush>/home: mkfl hi.txt "changed" -force -test
mkfl: [test] would overwrite 'hi.txt' (7 bytes) - test mode, no changes made
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

### Party: the built-in scripting language

`party <file.pa>` runs a program in **Party**, a small scripting language
with its own variables, expression evaluator, and control flow — no shell
command access from inside a script. The full spec is in `PARTY_SPEC.md`.

```
vars a = "hi"
vars n = 5

func double(x) {
    return x * 2
}

if (a == "hi") {
    display "Hello world"
    display double(n)
}
```

What's in there:

- **Types:** `int`, `float`, `bool`, `string` (quoted text; a bare word is
  always a variable reference, never a string).
- **Variables:** declare with `vars name = value` (value required), reassign
  with `name = value`; using an undeclared variable is an error.
- **Operators:** `()`, `* /`, `+ -`, comparisons `< <= > >=`, equality
  `== !=`, and statement-level `=`.
- **Control flow:** `if` / `else if` / `else` and `while`, with mandatory
  `{ }` braces on every block.
- **Functions:** `func name(a, b) { return ... }` — fixed arity, recursion
  allowed (depth-limited call stack), callable before their `func` block
  appears. No mandatory `main()`: top-level statements run top-to-bottom.
- **Output:** `display <expr>` prints the value followed by a newline.
- **Not in v0.1:** no user input, `%`, `&&`/`||`, or arrays (see
  `PARTY_SPEC.md`).

`party foo.pa -tokens` dumps the raw token stream instead of executing, and
**Esc** interrupts a running script.

### The RTC clock: `date`, `time`, and `wig time`

The kernel reads the MC146818 RTC/CMOS clock chip (ports `0x70`/`0x71`,
waiting out the update-in-progress flag, decoding BCD, and normalizing 12-hour
to 24-hour) to back three commands:

- **`date`** — prints the current date as `YYYY-MM-DD`.
- **`time`** — prints the current time as `HH:MM:SS` (24-hour).
- **`wig time`** — the "widget" command: draws a live clock in the top-right
  corner of the screen that updates every second, until you press **Esc**.
  It writes straight to VGA memory, so your prompt and cursor aren't disturbed
  while it runs.

Both `date` and `time` are normal commands, so their output flows through the
`~` pipe just like anything else — `date ~ write today.txt` saves the date
into a file.

### Writing piped output to a file: `write`

`write <path> <content>` creates a file with that content, or overwrites an
existing file's content in place. It's designed to be the target of a `~`
pipe, which appends the captured output as the content argument:

```
rush>/home: show hi ~ write file.txt
rush>/home: view file.txt
hi
rush>/home: date ~ write today.txt ; view today.txt
2038-08-03
rush>/home: calc 2 + 2 ~ write sum.txt ; view sum.txt
4
```

It also works standalone (`write notes.txt "some text"`). It refuses if a
*folder* already has the name (use `del`/`rname` to resolve), but happily
overwrites an existing file — like a shell `>` redirect.

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

The boot volume itself isn't pinned to device 0 anymore, either: on boot,
the kernel tries device 0 (legacy ATA) first, and if nothing answers there —
the normal case on a real, SATA-only board with no PATA/IDE controller — it
falls back to whichever AHCI port slot actually has a disk, remembering
which device the OS volume lives on for `sync`/`rboot`/`sdown` to write back
to. Without this, a real machine whose only disk is SATA would report "No
disk detected" forever even though `dscan` could see the drive just fine.

### SFFS v3 on-disk format

Each disk volume is self-contained and starts at sector (LBA) 400 — well
clear of the boot sector and the kernel's own sectors (the kernel has grown
enough, mostly from the networking stack, that the filesystem region moved
up from LBA 200 to stay clear of it):

- **Superblock** (1 sector): `SFFS` magic, version byte, then a 32-byte
  label.
- **Type / parent / next / name / content** sectors: one node table per
  volume (`node_type`, `node_parent`, `node_next`, 4 name sectors, 20
  content sectors), scoped per volume with *relative* parent indices
  (`0xFFFF` = volume root), so the same layout works on any drive.
- **Older v2 volumes** (no `node_next` sector; content starts one sector
  earlier) still load and read fine — a `sync` upgrades them to v3 in
  place.

### Multi-block files (SFFS v3)

A file's content used to be capped at a single node's ~160-byte slot. Now a
file whose content is longer than that is stored as a chain: its own node
holds the first ~159 bytes, and `node_next` points at a continuation node
(a new node type, invisible to path lookup, `list`, and the allocator) that
holds the next ~159 bytes, and so on until `node_next` is `0xFFFF`. Deleting
a file frees every node in its chain.

This raises the practical cap on a single file's size from ~160 bytes to
~10 KB (a lone big file can use the volume's entire 64-node table if
nothing else needs a node) — plenty for text, notes, and config files.
`view`, `show`, `lookfor`, `find`, `edit`, `owrite`, and `del` all work
transparently across chained files; nothing about how you use those
commands changes.

```
rush>/home: mkfl big.txt "..." ; view big.txt
```
behaves exactly the same whether `big.txt` fits in one node or spans a
dozen — the chaining is invisible from the shell.

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
- `unmount <label>` detaches a mounted volume: the mount slot is dropped
  (so `sync` stops writing that drive) and `/<label>/` disappears from the
  filesystem, but the drive's data is left untouched — `dscan` + `mount`
  re-attach it later. It refuses while your current directory is inside the
  volume.
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

## Networking

The kernel brings up whichever NIC it finds at boot — a hand-written driver
for each of three chips, tried in this order:

1. **RTL8139** — the classic QEMU default NIC (`-nic model=rtl8139` /
   the emulator's default), a simple ring-buffer RX/TX design.
2. **Intel e1000** — QEMU's `-nic model=e1000`, and a common real/virtual
   gigabit chip, using descriptor rings.
3. **Realtek RTL8168/8169/8161** ("PCIe GBE Family Controller") — the
   gigabit Realtek chip found on most real desktop motherboards. Also
   descriptor-ring based, but reached over port I/O like the RTL8139
   driver rather than MMIO like the e1000 driver.

If none of the three is present, every networking command reports there's
no NIC and the rest of the OS behaves exactly as it always did — networking
is entirely additive.

All three drivers, including the RTL8168 path most real desktop boards will
actually use, are now verified working end-to-end on real hardware (`dhcp`,
`netinfo`, and `tcp` all confirmed), not just QEMU. Getting there took a few
real-hardware-only fixes that QEMU's virtual devices never exercise: the
e1000 backend's MMIO registers needed the same uncached identity-map
treatment the AHCI driver already had (a cacheable mapping could read back
a stale value instead of what the device just wrote), and the RTL8168 PHY
needed an explicit power-up/renegotiate poke — without it, a PHY left
powered-down by firmware meant the link never came up even though the MAC
reset succeeded and the driver reported the NIC as present. See
`milestones.txt` for the full writeup.

On top of whichever driver is active: Ethernet II framing, ARP (with a
small resolve cache), IPv4 with checksums, ICMP echo (ping), UDP, a DNS client,
a DHCP client, and a minimal polled **TCP** engine. IP/mask/gateway/DNS default
to QEMU's `slirp` user-networking
values (`10.0.2.15` / `255.255.255.0` / gw `10.0.2.2` / dns `10.0.2.3`), and can be
configured automatically via **`dhcp`** (recommended for real hardware) or manually with `net`.

| Command | Example | Behavior |
|---|---|---|
| `netinfo` | `netinfo` | print the NIC's MAC address and current IP/mask/gateway/DNS |
| `net` | `net ip 10.0.2.20`, `net gw 10.0.2.2`, `net dns 8.8.8.8` | change the static IP, gateway, or DNS server |
| `dhcp` | `dhcp` | request IP address, subnet mask, gateway, and DNS server via DHCP |
| `dns` | `dns google.com` | resolve a hostname to an IPv4 address via the configured DNS server |
| `bounce` | `bounce 10.0.2.2` | send a single ICMP echo request; prints the reply or times out (~2-3s) |
| `monitor` | `monitor google.com` | ping repeatedly, one line per reply, until you press **Esc** |
| `tcp` | `tcp 10.0.2.2 8000` | open a TCP connection to a host/port, optionally send a payload, print the reply |

```
rush>/home: netinfo
MAC : 52:54:00:12:34:56
IP  : 10.0.2.15
MASK: 255.255.255.0
GW  : 10.0.2.2
DNS : 10.0.2.3
rush>/home: dns google.com
google.com = 142.250.premium.address
rush>/home: bounce 10.0.2.2
reply from 10.0.2.2, 32 bytes
rush>/home: monitor google.com
reply from 172.217.x.x, 32 bytes
reply from 172.217.x.x, 32 bytes
^[
rush>/home:
```

Everything is polled (no interrupts), matching the keyboard and disk
drivers — `bounce`/`monitor`/`dns`/`tcp` block the shell while they wait, and
`monitor` and `tcp` check for **Esc** on every poll so they can be interrupted
like `wig time` or a running `rr` script.

### TCP: the `tcp` command

`tcp <host> <port> [payload]` runs a minimal client TCP exchange: it resolves
the host (raw IPv4 address directly, or a hostname via the configured DNS
server), does a 3-way handshake (SYN → SYN-ACK → ACK) with sequence/ack
tracking, sends the payload if one was given, advertises a small receive
window, and accumulates the peer's reply until the connection closes (FIN),
printing what came back. It reads up to 1024 bytes of response. It is
Esc-cancelable while it waits.

```
rush>/home: tcp 10.0.2.2 8000
tcp: connecting to 10.0.2.2:8000
tcp: connected.
tcp: sent 0 bytes.
tcp: received 870 bytes.
HTTP/1.0 200 OK
Content-type: text/html; charset=utf-8
...
rush>/home:
```

Because it reads until FIN (no content-length handling yet), the peer should
close the connection when it's done — plain HTTP/1.0 servers like Python's
`http.server` do. Retransmission is polled with a 1s RTC tick and is bounded;
a full RTO with exponential backoff is still future work.

**Testing in QEMU:** add a NIC to your invocation, e.g.
```bash
qemu-system-x86_64 -drive format=raw,file=shellyforever.img \
  -netdev user,id=n0 -device rtl8139,netdev=n0
```
(swap `rtl8139` for `e1000` or a modern Realtek gigabit model to exercise
the other two drivers). `slirp` user networking answers ARP/ICMP/DNS itself
and doesn't require any host firewall changes. To test `tcp` end-to-end, run
`python -m http.server 8000 --bind 127.0.0.1` on the host — `slirp`'s gateway
(10.0.2.2) is the host's loopback, so `tcp 10.0.2.2 8000` reaches it.

**Not yet implemented:** there's no HTTP `take`/`give` (get/put) yet — the
`tcp` command is a raw byte exchange. Turning it into
`take http://host/path <file>` and `give http://host/upload <file>` (HTTP/1.0
GET/POST with content-length) is planned next; see `milestones.txt`.

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
  memory. File/folder names capped at 32 bytes, a single node still holds
  ~160 bytes but files now chain across nodes (see "Multi-block files"
  above) up to ~10 KB, line input capped at ~220 chars — easy to bump, just
  constants at the top of `kernel.asm` (the on-disk format size adjusts
  automatically since it's computed from those same constants).
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
- `kernel.bin` occupies LBA 1..404 — `KERNEL_SECTORS` in `boot.asm` has
  already been bumped twice, from its original 199, to make room for the
  filesystem chaining and networking code. If you add enough new code to
  cross that budget again, bump `KERNEL_SECTORS` once more — it's a
  one-line change, but the bootloader will silently load a truncated kernel
  if you forget, which looks like an unrelated crash. (The on-disk SFFS
  region now starts at LBA 400 — bumped from 200 for the same reason — so
  keep the kernel's reserved region clear of that.)

## Natural next steps, in order of payoff

1. **`take`/`give` (HTTP get/put)** — the raw `tcp` command already does a
   real client exchange end-to-end; wrapping it in `take http://host/path
   <file>` and `give http://host/upload <file>` (HTTP/1.0 GET/POST with
   content-length and response-header parsing) would let you actually move
   files over the network. See `milestones.txt` for the in-progress plan.
2. **Path arguments** for `cf`/`cpy`/`mov`/`rname` (e.g. `cpy docs/notes.txt ..`)
   instead of current-folder-only operations.
3. **Autosave on mutation** instead of requiring explicit `sync`/`rboot`/`sdown`,
   if you'd rather not think about it (tradeoff: more disk writes).
4. **A real memory allocator** once you want dynamic-sized files/folders
   instead of fixed slot counts.
5. **Password-based auth** instead of the current one-shot `auth` flag, so
   elevated sessions can span multiple commands without re-authenticating.

## What's new

- **Real-hardware bring-up fixes (v0.1.4)** — three bugs that only show up
  on real hardware (invisible to QEMU's virtual devices), found and fixed
  after `tcp` reached a real RTL8168 board and initially failed:
  - The boot filesystem was pinned to device 0 (legacy ATA); a SATA-only
    board with no PATA/IDE controller always reported "No disk detected"
    even though the AHCI driver had found the drive. `fs_load` now falls
    back to the AHCI slots `ahci_init` found when device 0 doesn't answer.
  - The e1000 driver's MMIO registers weren't marked uncached (AHCI's ABAR
    already was) — could read back stale values on real silicon.
  - The RTL8168 PHY power-up/renegotiate routine existed but was never
    called, so a PHY left powered-down by firmware meant the link never
    came up — silently, since `nic_present` still got set regardless.
  `tcp` (and `dhcp`/`netinfo`) are now confirmed working end-to-end on real
  hardware. See `milestones.txt` for the full writeup.
- **`tcp` command (v0.1.4)** — a minimal polled TCP engine: handshake,
  send, and read-until-FIN against any reachable host. Also fixed three
  real bugs that surfaced while bringing it up (RTL8139 RX starvation
  from uncleared ROK bits, never-ACKed FINs, and an ACK echo loop). See
  "TCP: the `tcp` command" above.
- **Networking (v0.1.3)** — a polled Ethernet/ARP/IPv4/ICMP/UDP/DNS stack,
  with drivers for the RTL8139, Intel e1000, and Realtek RTL8168 NICs.
  New commands: `netinfo`, `net ip|gw|dns <a.b.c.d>`, `dns <host>`,
  `bounce <host>`, `monitor <host>`, `dhcp`. See "Networking" above.
- **`party` (v0.1.3)** — a simple built-in scripting language with its own
  variables, expressions, `if`/`else`/`while`, `func`/`return`, and
  `display` output. `party foo.pa` runs a program. See "Party" above and
  `PARTY_SPEC.md`.
- **Multi-block files / SFFS v3 (v0.1.3)** — files are no longer capped at
  one node's ~160-byte content slot; they chain across nodes up to ~10 KB.
  Older v2 volumes still load fine and are upgraded on `sync`. See
  "Multi-block files (SFFS v3)" above.
- **`unmount <label>` (v0.1.2)** — detach a mounted drive's volume. The mount
  slot is dropped (so `sync` stops writing that drive back) and `/<label>/`
  disappears from the filesystem, but the data on the drive is left untouched.
  It refuses while your current directory is inside the volume. See "One boot
  drive, up to two mounted drives" above.
- **RTC clock: `date`, `time`, and `wig time`** — a new CMOS/RTC driver (ports
  `0x70`/`0x71`, BCD decode, 12→24-hour conversion) backs a `date` command
  (`YYYY-MM-DD`), a `time` command (`HH:MM:SS`), and `wig time`, a live clock
  widget drawn in the top-right corner of the screen that updates every second
  until you press Esc. See "The RTC clock" above.
- **`write`** — `show hi ~ write file.txt` pipes a command's output into a
  file, creating it or overwriting an existing file's content (like a `>`
  redirect). See "Writing piped output to a file" above.
- **`-test` flag for `mkfl`** — dry run: reports whether a file would be
  created, overwritten, or rejected (already exists, no `-force`), and the
  content length that would be written, without touching the filesystem.
  Works whether or not content text is given (`mkfl new.txt -test` or
  `mkfl new.txt "text" -test`). See "Flags" above.
- **Aliases (`ali`/`alis`/`rmv ali`)** — `ali <name> <commands>` stores a
  command (or `;`/`~` chain) verbatim under `<name>`; running `<name>`
  re-runs it fresh, so it always sees the current variables/files. Aliases
  can call other aliases (nested up to 8 deep). `alis` lists them all;
  `rmv ali <name>` removes one; `auth rmv ali all` clears every alias.
  ```
  rush>/home: ali testmath calc 5 + 5 ~ = a ; show a
  rush>/home: testmath
  10
  rush>/home: alis
  Aliases:
  testmath: calc 5 + 5 ~ = a ; show a
  rush>/home: rmv ali testmath
  ```
- **`color`** — change the color normal output (`show`, `list`, etc.) is
  printed in. All 16 standard VGA colors are available, with dark/light
  variants: `color cyan`, `color dblue`, `color list` (see every name),
  `color reset` (back to green). Prompt (yellow) and error (red) text are
  left alone, since those colors are meaningful cues.
- **Targeted `fmt`** — `dscan` now shows an original `disk<N>` label for
  every drive that isn't already an SFFS volume, so you can format a
  *specific* drive instead of whichever happens to be first-unformatted:
  ```
  rush>/home: dscan
    device 1 (primary slave): present, not SFFS - fmt target: disk1
  rush>/home: fmt disk1 backups
  Formatted backups on primary slave. Use 'sync' to save, then 'mount backups'.
  ```
  `fmt <label>` (no target) still works exactly as before, for when there's
  only one drive to format. Reformatting a drive that already has an SFFS
  volume - whether targeted by its `disk<N>` label or its current label -
  requires `-force`, same as before.
- **Loading spinner** — `dscan`, `fmt`, `mount`, and `sync` animate a small
  `|/-\` spinner in place while they scan, load, or write sectors, so a
  multi-drive scan, a format, a mount, or a filesystem save doesn't look
  like the shell has frozen.
- **`shelly`** — a splash banner command: prints the `ShellyForever OS`
  title one rainbow-colored character at a time, followed by the developer
  credit (`Developed by Sourasish Das`) and the copyright line
  (`Copyright 2026. All rights reserved.`).
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
  "Line editing: history, tab completion, and scrollback" above.
- **Tab completion** — Tab completes command names on the first token and
  file/folder names in the current directory on later tokens, listing
  ambiguous candidates. See "Tab completion" above.
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
  - (`-test` added later — see the entry at the top of this section)

I built and test-assembled this (including `find`, `lookfor`, and `owrite`)
in a sandbox with QEMU available. The `-test` flag was verified end-to-end
with an automated QEMU boot (screendump of the running shell confirmed the
create/overwrite/blocked-without-`-force` messages all print correctly and
no file content changes on disk). Earlier features were checked by assembling
cleanly with no errors and a careful hand trace of the logic, but weren't all
run interactively — worth exercising yourself in QEMU to catch anything a
static read-through can't, and happy to help debug from there if something
misbehaves.

The multi-block-file and networking work described above (v0.1.3) was
assembled cleanly with `nasm -f bin` and hand-traced, including a fix to
`nic_fetch_rx` (it was missing its RTL8168 branch entirely — RX for that
driver silently ran the RTL8139 ring-buffer code instead of walking its own
descriptor ring). No QEMU was available in the environment used for this
pass, so none of it has been boot-tested yet — exercise `bounce`/`monitor`/
`dns`/`net`, and a chained-file round trip (`mkfl` a file bigger than ~160
bytes, then `view`/`sync`/reboot it), yourself before relying on it.