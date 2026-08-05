# Changelog

All notable changes to ShellyForever are documented here. The format is
loosely based on [Keep a Changelog](https://keepachangelog.com/); the
project does not yet follow strict SemVer.

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
