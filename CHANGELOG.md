# Changelog

All notable changes to ShellyForever are documented here. The format is
loosely based on [Keep a Changelog](https://keepachangelog.com/); the
project does not yet follow strict SemVer.

## [0.1.14] - 2026-08-14

### Added

- **Native software installer**: `install <file.sin>` and
  `uninstall <id>` (`install.asm`, new). A `.sin` package is a
  stored-mode `.zip` (reuses `zip.asm`'s `zip_find_eocd`/
  `zip_unpack_validate` as-is) containing `whattodo.inst` and a
  `files/` folder. `install` parses and runs the script line by line;
  unknown instructions abort the install with an error rather than
  being passed to Rush. Programs are tracked in a new registry file,
  `/home/sys/programs.sly` (`program = <id>` / `path = <path>` pairs,
  blank-line separated); `uninstall <id>` removes the one file
  recorded as that program's entry point plus its registry entry
  (not every file a `copy` instruction wrote, since the registry
  keeps no manifest of those — matches the spec's "SHOULD preserve
  unrelated files" rather than risking deleting something unrelated).
- **`whattodo.inst` instruction language**: `name`, `version`,
  `mkdir`, `copy`, `delete`, `program`, `finish`, plus `#` comments.
  Deliberately small — no variables, loops, conditionals, or shell
  access, so the installer can parse and run it directly without a
  general-purpose interpreter. `delete` is idempotent (a no-op if the
  target is already missing) and refuses to remove a folder.
- **Bare registered-program-id dispatch fallback**. Typing a
  program's id at the prompt (e.g. `calculator`, optionally with a
  trailing `-back`) now launches it via `reg_lookup_path`, the same
  way a bare `name.run` already did — wired into `kernel.asm`'s
  dispatch right before the "unknown command" fallthrough.
- **`mksin <folder>`** — builds a `.sin` package from a folder already
  laid out as one (`<folder>/whattodo.inst` + `<folder>/files/`),
  entirely inside the OS. Validates the folder shape and every line
  of `whattodo.inst` first — unknown instructions, missing arguments,
  non-absolute `mkdir`/`copy`/`delete`/`program` destinations, and any
  `copy` source missing from `files/` are all reported with a line
  number before anything is written — then hands off to the existing
  `pack` command to do the actual stored-mode zipping and renames the
  result from `<folder>.zip` to `<folder>.sin` in place (the same
  in-place `node_name` edit `rname` already uses). Deliberately
  doesn't reimplement archive writing: `zip.asm`'s actual byte-level
  ZIP writer wasn't available to hand-splice against safely, so
  `mksin` calls the real, already-tested `cmd_pack` instead of
  guessing at CRC32/header logic.
- **`INST_SPEC.md`** — a from-scratch tutorial covering the `.sin`
  package shape, every `whattodo.inst` instruction, a worked example,
  the `mksin` → `install` → `uninstall` workflow, what the registry
  looks like on disk, and a quick-reference cheat sheet.

### Changed

- Banner and build stamp bumped to `v0.1.14` (`kernel.asm`).
- README: new "Installing programs: `.sin` packages" section; `pack`/
  `unpack`/`install`/`uninstall`/`mksin`/bare-program-id rows added to
  the command table (the first two had never been documented despite
  already existing); a new top-level bullet under "What's actually in
  here"; a "Native software installer (v0.1.14)" entry at the top of
  "What's new".
- Party's two "Not in v0.1.14" deferred-feature callouts (bracket-
  syntax array indexing, growable arrays, `{<expr>}` interpolation,
  string concatenation, server-side networking) renumbered to "Not in
  v0.1.15" — those Party gaps are unchanged this release, just
  relabeled to keep pointing at the next version, per the project's
  usual convention of rolling that list forward each cycle.

### Verified

- `kernel.asm`/`install.asm` syntax-checked by symbol cross-reference
  (every label, message string, and buffer the new code touches
  confirmed defined exactly once, called from exactly where expected)
  rather than a real `nasm` build — `splash.asm`, `party.asm`,
  `tcp.asm`, `http.asm`, `browse.asm`, `mouse.asm`, and `zip.asm`
  weren't present in this sandbox to assemble against.
- Not exercised in a real boot/QEMU environment. Before relying on
  this release, worth running through: `mksin` on a small package
  (including an intentionally broken `whattodo.inst`, to check the
  line-numbered validation errors), `install` on the result, typing
  the bare id to launch it, and `uninstall` to remove it — plus
  confirming a pre-existing `name.run` bare-launch still works
  unchanged now that the dispatch fallback sits next to it.

## [0.1.13] - 2026-08-14

### Added

- **`rush <expr>` in Party**. Shells out to one Rush/ShellyForever
  command line from inside a Party script (`<expr>` must be a string;
  runtime type error otherwise). Runs through the kernel's
  `process_chain`, so `;` chaining and quoted args work the same as
  typing the line at the prompt. No output capture yet — a rushed
  command prints straight to the screen, with no way to pull that text
  back into a Party variable (a `rushcap` variant is a candidate for a
  later phase).
- **String interpolation in Party**. `"hello {name}"` splices an
  already-declared variable's string form into a literal; `{{` / `}}`
  escape a literal brace. Scoped to bare `{identifier}` only — no
  `{<expr>}` or `{fn(...)}` yet. An undeclared name inside `{}`, an
  empty `{}`, or an unterminated `{` are runtime errors rather than a
  silent blank. The lexer is unchanged (one `TOK_STR` per literal); the
  scan/substitution happens when the literal becomes a runtime value,
  so plain strings with no `{` are unaffected.
- **In-language file access API in Party**: `fopen(path, "r"|"w"|"a")`,
  `fread(h)` (whole-file read), `fwrite(h, text)`, `fclose(h)`,
  `fexists(path)`, `fdelete(path)`. Backed by a 12-entry handle table
  and the same `fs_resolve_path`/`fs_find_child`/`fs_create_node`/
  `fs_read_binary_file`/`fs_write_binary_file` calls `cmd_cat`/`cmd_mkfl`
  already use, so scripts get real file I/O without shelling out via
  `rush`. The builtin dispatcher (`party_call_builtin`) and builtin
  bodies already existed in the tree unwired; this release connects
  `party_parse_call` to it and adds the handle table, name strings, and
  error messages the bodies referenced but that didn't exist yet.
- **Fixed-size arrays in Party**: `arr_new(n)`, `arr_len(a)`,
  `arr_get(a, i)`, `arr_set(a, i, value)`, `arr_free(a)`. New `PV_ARRAY`
  value type; up to 4 arrays alive at once, 16 elements each
  (deliberately conservative — the array table is duplicated per
  background-process context by `run -back`, and `kernel.asm`'s
  `MAX_PROCESSES` was already trimmed to fit real-mode BSS under
  `0xA0000`). Elements are ordinary Party values, including nested
  arrays; `display` prints an array as `[e0, e1, ...]`, recursively.
  Function-shaped builtins rather than `[...]`/`a[i]` syntax, and
  handle/reference semantics rather than growable/deep-copy — both
  locked in up front to keep the diff small; bracket syntax and
  growable arrays are the first two items on the deferred list now.
  `party_ctx_table`/`PARTY_CTX_SIZE` (the background-process
  suspend/resume mechanism) updated to include the new array state,
  bumped `20226` → `22342`.

None of the four features need `party compile` changes — the compiler
embeds Party source into the `.run` file rather than ahead-of-time
compiling statements, so anything the interpreter can do, a compiled
script can do too, automatically.

### Changed

- Banner and build stamp bumped to `v0.1.13` (`kernel.asm`).
- `PARTY_SPEC.md` gets new sections for `rush` (8), file access (10,
  with a `files.pa` example), and arrays (11, with an `arrays.pa`
  example); string interpolation folds into section 1's rule set. The
  deferred-features list is renumbered and trimmed to "Not in v0.1.14":
  bracket-syntax array indexing, growable arrays, `{<expr>}`
  interpolation, string concatenation, and server-side networking
  (listen/accept — a larger, kernel-level `tcp.asm` feature, tracked
  separately).
- README's Party section updated: the new `rush`/interpolation/file
  API/array bullets, and a new "Party language expansion (0.1.13)"
  subsection with examples for all four features.

### Verified

- `party.asm` syntax-checked standalone with `nasm` after each
  feature; for `rush`/interpolation/file-access, the undefined-symbol
  set was diffed against an unmodified copy of the upload to confirm
  each fix resolved exactly its own symbols and introduced nothing new
  (a plain error count wasn't enough for the file-access fix, since its
  actual bug was a missing call site, not a syntax error — `nasm` only
  surfaces that as extra undefined symbols).
- None of the four features were exercised in a real boot/QEMU
  environment this release (none was available); see `phases.txt` for
  the specific smoke tests recommended before relying on each one
  (`rush "mkf x ; ls"`, interpolation with declared/undeclared names
  and `{{}}`, an `fopen`/`fwrite`/`fclose`/`fexists`/`fread` round
  trip, and an `arr_new`/`arr_set`/`arr_get`/`display` sequence).
- A full real `nasm` build in the actual dev tree (with `splash.asm`/
  `browse.asm`/`mouse.asm`/`boot.asm` present) is still outstanding —
  this sandbox only had `party.asm`, `kernel.asm`, `tcp.asm`, and
  `http.asm` to check standalone.

## [0.1.12] - 2026-08-13

### Fixed

- **Background Party scripts silently eating keystrokes**. A
  background process's `while` loop (`.pes_while_loop` in `party.asm`)
  called `kbd_poll` unconditionally on every iteration to check for
  Esc-to-kill. `kbd_poll` reads and discards whatever byte is waiting
  at the `8042` keyboard controller — so a `run <file> -back` script
  with a `while` loop would consume characters the user was typing at
  the live shell prompt, one dropped keystroke per loop iteration,
  while it ran in the background. The top-level statement loop in
  `party_exec_stmts` already skipped `kbd_poll` while
  `party_bg_active` is set (a background process has its own kill path
  via `prs kill`, and stealing prompt input isn't safe since the shell
  is live), but that same guard was missing from the `while`-loop's
  own `kbd_poll` call. Added the same `party_bg_active` check there, so
  background scripts no longer touch the keyboard at all.

### Changed

- Banner and build stamp bumped to `v0.1.12` (`kernel.asm`).

## [0.1.11] - 2026-08-11

### Added

- **`%` modulo operator in Party**. New `%` token (int-only — a float
  operand is a type error), multiplicative precedence, and a remainder
  branch in the interpreter's arithmetic path with the same divide-by-zero
  guard `/` has. Works in interpreted scripts and shows up correctly in
  `party foo.pa -tokens`.
- **`&&` / `||` logical operators in Party**. New two-char tokens, a
  precedence tier between equality and the rest (`|| < && < ==/!= <
  relational < additive < multiplicative`), and `party_op_logical`, which
  coerces both operands with the interpreter's truthiness rule (falsy:
  `0`, `false`, `0.0`, `""`) and pushes a bool. Eager — both sides are
  evaluated, matching every other binary operator (no short-circuit).
- **Multi-name `vars` declarations in Party**. `vars a, b = 5, c`
  declares several variables in one statement; each name may carry its own
  `= <expr>` initializer, and a bare name is declared as int `0` (so
  `vars name` + `read name` needs no dummy initializer).
- **`read <var>` — user input in Party**. Reads one keyboard line into an
  already-declared variable as a string, echoing printable characters and
  handling Backspace, terminating on Enter, and aborting the whole script
  on Esc (via `kbd_poll`/`kill_flag`, same as a running loop). Strings land
  in a single shared `party_read_buf` (128 bytes), so a later `read`
  overwrites an earlier one.
- **Token names** for all four new tokens (`MOD`/`AND`/`OR`/`READ`), so
  `party foo.pa -tokens` renders them instead of `ERROR`.

### Changed

- Banner and build stamp bumped to `v0.1.11` (`kernel.asm`).
- `PARTY_SPEC.md` rewritten for v0.1.11: multi-var `vars` with optional
  per-name initializers, `%`, `&&`/`||` (with precedence table and the
  eager/truthy semantics), a new Input section, updated example programs,
  and the deferred list trimmed to arrays/collections only.
- README's Party section updated to match.

## [0.1.10] - 2026-08-10

### Added

- **In-line cursor movement at the shell prompt (`read_line`)**.
  Left/Right now step the cursor one character at a time through the
  current line without disturbing already-typed text; Home/End jump it
  to the start or end of the line in one keystroke; Delete forward-deletes
  the character ahead of the cursor. Typing a character or pressing
  Backspace with the cursor mid-line inserts or removes right there and
  reflows the rest of the line, rather than only ever appending at the
  end. Command history (Up/Down) and scrollback (Ctrl+Up/Ctrl+Down)
  behave as before.
- **In-line cursor movement in `edit`**. The same Left/Right/Home/End/
  Delete handling is now available inside the `edit` command's editor:
  the cursor can move freely through a file's existing content instead of
  only sitting at the append point, and inserts, deletes, and newlines
  happen wherever the cursor is placed. The visible page (and the
  hardware cursor's on-screen position) is redrawn around the cursor on
  every keystroke, same as before.
- **`shelly` splash screen shows the build version**. `cmd_shelly` now
  prints a `v0.1.10` line under the rainbow `ShellyForever OS` title and
  above the developer credit and copyright line, so the splash banner
  doubles as a quick "what build is this" check.

### Changed

- Banner and build stamp bumped to `v0.1.10` (`kernel.asm`).
- README updated: the line-editing section now covers cursor movement at
  the shell prompt and inside `edit`, and the `shelly`/`edit` command
  table rows and "What's new" section reflect both changes.

## [0.1.9] - 2026-08-09

### Added

- **Party compiler — `party compile <file.pa>`**. Compiles a Party
  script straight to a ShellyForever `RUN 0.1` executable (writing
  `<file>.run` alongside the source) instead of only interpreting it.
  The compiled binary uses the same three-line header and kernel API
  table (`print_string`, `print_string_attr`, `get_char`, kill-check)
  as a hand-assembled `.run` file, so it runs with plain `run
  <file>.run` (or a bare `name.run`), shows up in `prs`, and is
  killable with `prs kill` exactly like any other compiled program.
  The full v0.1 language compiles — variables, all operators,
  `if`/`else if`/`else`, `while`, `func`/`return` with recursion — not
  just a subset.
- **SFFS v4 — 256 nodes per volume**. `OS_NODES` raised from 64 to
  256; `NAME_LBA`/`CONTENT_LBA` are now computed from the node count
  instead of hardcoded, so the two regions can't collide as it changes
  again later. Raises the practical per-file cap from ~10 KB to 40 KB
  (`EDIT_MAX = VOL_NODES * CONTENT_LEN`). v2 and v3 volumes (64-node,
  at their old fixed offsets) still load and read fine; a `sync`
  upgrades them to v4 in place, first clearing nodes 64..255 of that
  volume's slice so the bigger table is already in use the moment you
  next `mkfl`/`mkf`/`edit`. Each volume now needs ~100 sectors past
  `FS_LBA_START` (was ~28). See "SFFS v4 on-disk format" in the
  README.
- **`sys reset` — factory reset (requires auth)**. `auth sys reset`
  wipes every file and folder on the OS volume back to an empty root
  (keeping the volume's existing label), clears all session variables
  and aliases, recreates the default `/sys` files (`alias.sly`,
  `sysconfig.sly`), and saves the result to disk immediately. Mounted
  external drives are left untouched. Meant as a clean-slate recovery
  path for when a system's state is badly wrong. This cannot be
  undone.

### Changed

- **Party interpreter completed** — the interpreter now fully
  implements every feature in the v0.1 language spec
  (`PARTY_SPEC.md`) end-to-end. The grammar and semantics in
  `PARTY_SPEC.md` are unchanged; this is completion of the
  implementation against that existing spec, not a new feature set.
- Banner and build stamp bumped to `v0.1.9` (`kernel.asm`).
- README updated: the SFFS v3 section is replaced with SFFS v4,
  `sys reset` is documented under the elevation system and in its own
  section, and `party compile` is documented alongside `party`.

## [0.1.8] - 2026-08-09

### Added

- **Compiled executable format — `run <file.run>`**. `run` (and a bare
  `name.run` typed at the prompt) loads a compiled ShellyForever
  `RUN 0.1` binary: a three-line plain-text header (`[ShellyForever]` /
  `[run 0.1]` / `program = v1`) followed immediately by raw x86-64
  machine code. `cmd_run` reads the file, validates the header line by
  line, allocates a process slot so the program shows up in `prs` and
  can be stopped with `prs kill`, builds a small kernel API table
  (`print_string`, `print_string_attr`, `get_char`, a newline pointer,
  and a kill-check poll routine) in `rdi`, and jumps into the code. An
  invalid/missing header or missing file both fail cleanly with an
  error message instead of jumping into arbitrary bytes.
- **System configuration persistence — `/sys/sysconfig.sly`**.
  `ensure_sys_folder` now seeds a `/sys` folder (already home to
  `alias.sly`) with a second file, `sysconfig.sly`, holding default
  `mouse = off`, `internet = on`, `auto_sync = on` settings. Like every
  other file, it's stored as a normal (chained) SFFS node, so it
  persists across `sync`/`rboot`/`sdown` and reloads with the rest of
  the filesystem on the next boot — no separate save/load path needed.
  Seeding only happens once, on a fresh (or freshly `fmt`'d) filesystem;
  an existing volume's `/sys` loads as-is, seeded or hand-edited.

### Changed

- Banner and build stamp bumped to `v0.1.8` (`kernel.asm`).
- README updated with a `run` command-table entry, a "Compiled programs:
  `run`" section, and a "System configuration: `sysconfig.sly`" section.

### Known limitations

- `sysconfig.sly` is persisted but not yet parsed back into the live
  `mouse`/`net`/auto-sync toggles at boot — unlike `alias.sly`, which
  `aliases_load` actively re-applies. Wiring that up is tracked as a
  natural next step in the README.

## [0.1.7] - 2026-08-08

### Added

- **`browse <url>` — a text-based web browser (`browse.asm`)**. A
  Lynx-style plain-text browser built on the Milestone D http/tcp stack:
  fetches an HTTP page, strips the HTML to readable text (in-place,
  staged via `http_rx_buf`), collects `<a href>` links, and renders them
  as `[N]` markers in the text. Pressing a number follows that link;
  `[b]ack` / `[f]wd` move through a session history, `[a]dd-bm` /
  `[l]ist-bm` handle session bookmarks, `[t]save` saves the current
  page's raw body to a file, `[q]uit` returns to the shell. Page text
  lives in `tcp_rx_buf` (up to `BROWSE_PAGE_MAX`).
- **Keypad scancode support** — the number-pad digits `0`-`9`
  (scancodes 0x47-0x53) now map to their ASCII digits in both `kbd_unshift`
  and `kbd_shift`, and the `0xE0`-prefixed extended keypad keys work too:
  keypad Enter, keypad `/`, `-`, and `+` are translated and returned
  through the normal keyboard path. This makes `browse` fully usable from
  the keypad (digits + Enter follow links).
- **Browse-aware Ctrl+Up / Ctrl+Down routing** — while `browse` is the
  active input loop (`browse_active` set), Ctrl+Up/Down no longer hijack
  the keys for scrollback; the browser keeps them. Scrollback Ctrl+Up/Down
  still works outside the browser.
- **`browse` help text** — listed in the command table and `help <cmd>`.

### Changed

- Banner bumped to `v0.1.7`.
- `KERNEL_SECTORS` bumped 440 → 480 for the browser (Milestone E), then
  to 486 when the browse render/link-marker fixes grew it again (`boot.asm`).

### Fixed

- **Browser link navigation** — following a numbered link now
  navigates correctly (buffer pointers are advanced on the same register
  the caller keeps using, so the fetched page isn't written over the URL
  being resolved). Link-following verified end-to-end in QEMU: browsing a
  page with links and pressing a number + Enter lands on the target page.

## [0.1.6] - 2026-08-06

### Fixed

- **`rtc_sec_now` torn-read fix** — the RTC seconds read was neither
  guarded against a mid-update transition (an update could start between
  address-select and data-read, returning a torn byte) nor converted from
  BCD, so elapsed-time math in the network wait-loop error paths could
  come out wrong once a start/end reading straddled a tens-digit boundary
  (a real ~5-6s wait was reported as `elapsed: 0`). Now it double-reads
  with a UIP guard around each read and retries when the two disagree,
  and converts BCD exactly like `rtc_update` (only when status register B
  bit 2 is actually clear).

### Changed

- Banner bumped to `v0.1.6`.

## [0.1.5] - 2026-08-07

### Added

- **HTTP `take` / `give`** (`http.asm`) — `take <url> <file>` does an
  HTTP/1.0 GET and saves the response body to a local file; `give <url>
  <file>` reads a local file and POSTs its content to a server.
  - URL parser handles `http://host[:port]/path`.
  - DNS resolution, TCP handshake + send + receive + FIN close, all
    Esc-cancelable.
  - `take` strips HTTP response headers (CRLF-CRLF scan) and writes the
    raw body via `fs_write_file` into the SFFS v3 chained-file system.
  - `give` includes `Content-Type: text/plain` and `Content-Length`
    headers.
  - `http_rx_buf` (3072 bytes), `http_tx_big` (1200 bytes), URL scratch
    buffers (`http_host_buf`, `http_path_buf`, `http_port`).
- **`take` / `give` help text** and command-table entries.
- **README coverage** for `take` / `give` with usage examples and QEMU
  testing notes.

### Changed

- Banner bumped to `v0.1.5`.

## [0.1.4] - 2026-08-05

### Added

- **`tcp <host> <port> [payload]`** — a minimal polled TCP engine
  (`tcp.asm`): 3-way handshake (SYN → SYN-ACK → ACK), sequence/ack
  tracking, checksums, a 1024-byte receive buffer, a polled
  retransmit-on-no-ACK, and a read-until-FIN response accumulator that
  prints what came back. Esc-cancelable while waiting.
- **`tcp` help text** — the command list and `help <command>` both cover
  `tcp` now.

### Fixed

- **RTL8139 RX starvation / "infinite receive loop"** — `nic_fetch_rx`
  never cleared a descriptor's ROK bit after consuming it, so once
  inbound traffic stopped, a wrapped ring re-delivered the same frames
  forever. The driver now zeroes the descriptor status word after both
  advance and skip (`kernel.asm`).
- **TCP FIN never ACKed** — payload-0 segments were being skipped, so
  the peer fast-retransmitted FIN forever and flooded the RX ring. Every
  accepted segment carrying payload or FIN is now ACKed.
- **TCP ACK echo loop** — pure ACKs were being ACKed in return, echoing
  an empty-ACK loop with a stale sequence. Only payload/FIN segments are
  now ACKed, never a peer's pure ACK.
- **NASM `label changed during code generation` build failure** — a
  leftover reference to a removed `netpoll.np_drained` label made NASM
  mis-guess branch sizes between passes. Fixed the reference; the kernel
  reassembles cleanly with the larger network buffers.

### Changed

- Banner bumped to `v0.1.4`.
- `TCP_PAYLOAD_MAX` raised to 1024; `tcp_rx_buf`/`tcp_tx_buf` sized from
  it, and `net_build_buf` grown to 4096 bytes to fit the build area.
- **RTL8168 RxMaxSize fixed for real hardware** — the bring-up wrote
  `0x1FFF` (8191 bytes) to the RxMaxSize register, which is larger than
  the 2048-byte RX buffers; a jumbo frame would have DMA-truncated into
  the buffer while the descriptor still reported the full length, so the
  RX copy would overrun the buffer. Now `0x0640` (1600, the value Linux's
  r8169 driver uses for MTU 1500), comfortably above any 1518-byte
  Ethernet frame and safely within the buffers.
- `netpoll` debug instrumentation (per-frame hex dump, `nic_rx_seen`
  counter, seq/flags prints) removed from the source; the final kernel
  is clean. (The instrumented build is what confirmed the ROK/FIN/ACK
  root causes above.)

### Verified

- End-to-end QEMU test (WHPX, slirp user networking): `tcp 10.0.2.2 8000`
  against Python's `http.server` — full 870-byte directory listing
  captured and printed, clean close, shell returned. Both the 256-byte
  and 1024-byte receive-buffer builds pass.

## [0.1.3] - 2026-08-05

### Added

- **Networking commands** — `bounce`, `monitor`, and `dhcp`:
  - `bounce <host>` — send a single ICMP echo request (ping) with a
    ~2-3s timeout.
  - `monitor <host>` — ping repeatedly, one line per reply, until Esc.
  - `dhcp` — request IP address, subnet mask, gateway, and DNS server
    via DHCP on the active NIC.
- **`party`** — a simple programming language interpreter (files with
  a `.pa` extension). Declared variables (`vars`), int/float/bool/string
  types, operators, `if`/`else if`/`else`, `while`, `func`/`return`
  with recursion, and `display` output. See `PARTY_SPEC.md` for the
  language spec. `party foo.pa` runs a script file.
- **Party lexer/executor** (`party.asm`) — tokenizer, expression
  parser/evaluator, statement runner, and the `cmd_party` shell entry
  point.

### Changed

- Banner bumped to `v0.1.3`.
- DHCP success output now prints the full lease (IP, mask, gateway,
  DNS); DHCP failure distinguishes "no frames arrived" from "frames
  arrived but no OFFER/ACK recognized".
- Networking stack documentation updated in `README.md` (NIC drivers,
  `netinfo`/`net`/`dns`/`bounce`/`monitor`/`dhcp` commands).

### Fixed

- DNS/DHCP resolution on real hardware: the DHCP option scan is now
  bounded by the UDP length field with a minimum scan floor, so it no
  longer stops early and misses the OFFER/ACK when a router reports a
  short UDP length.
