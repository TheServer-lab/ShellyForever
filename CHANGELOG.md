# Changelog

All notable changes to ShellyForever are documented here. The format is
loosely based on [Keep a Changelog](https://keepachangelog.com/); the
project does not yet follow strict SemVer.

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
