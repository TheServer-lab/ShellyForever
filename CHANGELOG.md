# Changelog

All notable changes to ShellyForever are documented here. The format is
loosely based on [Keep a Changelog](https://keepachangelog.com/); the
project does not yet follow strict SemVer.

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
