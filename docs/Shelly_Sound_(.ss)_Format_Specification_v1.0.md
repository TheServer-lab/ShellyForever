# Shelly Sound (`.ss`) Format Specification v1.0

## 1. Overview

The `.ss` format is a plain-text, human-readable music notation language designed for the ShellyForever operating system. It encodes sequences of notes, rests, and control commands intended for playback on the PC speaker (or any frequency-generating audio device).

### Key Principles

- **Simplicity:** The parser fits in < 1 KB of assembly.
- **Zero dependencies:** No floating-point, no heap allocation.
- **Human-readable:** Editable in any text editor.
- **Hardware-agnostic:** Works on any x86 machine with a PC speaker or PWM-capable timer.

**File Extension:** `.ss`  
**MIME Type:** `text/x-shelly-sound`

---

## 2. Syntax Rules

### 2.1 Character Encoding

- **ASCII only** (`0x00–0x7F`). UTF-8 is not supported.
- **Line endings:** CR (`0x0D`), LF (`0x0A`), or CRLF (`0x0D 0x0A`) are all accepted.
- **Whitespace:** Spaces (`0x20`) and tabs (`0x09`) are treated as delimiters.
- Multiple spaces and tabs are collapsed.

### 2.2 Comments

- Any line beginning with `;` (semicolon) is ignored.
- Inline comments are **not** supported. The `;` must be at the start of the line.

### 2.3 Case Sensitivity

Commands and note names are **case-insensitive**.

```text
note C4
NOTE c4
Note C4
```

All three are equivalent.

### 2.4 Line Structure

Each non-empty line follows the pattern:

```text
<command> [<arg1>] [<arg2>]
```

Commands and arguments are separated by whitespace.

Arguments may be:

- Numbers
- Note names
- Keywords

---

# 3. Commands

## 3.1 `note` — Play a Note

### Syntax

```text
note <note_name> [<duration>]
```

### Arguments

- `<note_name>` — A note in scientific pitch notation, such as `C4`, `F#5`, or `Bb3`.
- The octave number (`0–9`) is optional. If omitted, the current octave is used.
- `<duration>` — Optional duration value. `1` = whole note, `2` = half note, `4` = quarter note, `8` = eighth note, etc.
- If duration is omitted, the current duration is used.

### Examples

```text
note C4 4
note A5 8
note F#
```

---

## 3.2 `rest` — Silence

### Syntax

```text
rest <duration>
```

### Arguments

- `<duration>` — Same duration format used by `note`.

### Example

```text
rest 4
```

---

## 3.3 `tempo` — Set Tempo

### Syntax

```text
tempo <bpm>
```

### Arguments

- `<bpm>` — Beats per minute.
- Valid range: `20–400`.
- Default: `120`.

### Example

```text
tempo 140
```

---

## 3.4 `octave` — Set Base Octave

### Syntax

```text
octave <n>
```

### Arguments

- `<n>` — Octave number from `0–9`.
- Default: `4`.

### Example

```text
octave 5
```

All subsequent notes without an explicitly specified octave use octave 5.

---

## 3.5 `duration` — Set Default Duration

### Syntax

```text
duration <n>
```

### Arguments

- `<n>` — Duration value such as `1`, `2`, `4`, `8`, `16`, etc.
- Default: `4`.

### Example

```text
duration 8
```

All subsequent notes use eighth-note duration unless overridden.

---

## 3.6 `transpose` — Shift All Notes by Semitones

### Syntax

```text
transpose <n>
```

### Arguments

- `<n>` — Signed integer.
- Positive values shift notes upward.
- Negative values shift notes downward.
- Default: `0`.

### Example

```text
transpose +5
```

This shifts all subsequent notes up by five semitones.

---

## 3.7 `volume` — Set Volume

### Syntax

```text
volume <n>
```

### Arguments

- `<n>` — Value from `0–15`.
- `0` = mute.
- `15` = maximum.
- On the PC speaker this command may be ignored.
- Reserved for future hardware with volume control.

### Example

```text
volume 10
```

---

## 3.8 `loop` / `endloop` — Repeat a Block

### Syntax

```text
loop <n>
    ...
endloop
```

### Arguments

- `<n>` — Number of repetitions.
- Valid range: `1–255`.
- Nested loops are **not supported**.

### Example

```text
loop 3
    note C4 4
    note E4 4
    note G4 4
endloop
```

The sequence plays three times.

---

## 3.9 `speed` — Modify Note Duration

### Syntax

```text
speed <n>
```

### Arguments

The speed multiplier affects the duration of subsequent notes.

The implementation should use fixed-point arithmetic rather than floating-point.

Recommended representation:

- `50` = `0.5×`
- `100` = `1.0×`
- `200` = `2.0×`

The recommended internal format is 16-bit fixed-point with 8 fractional bits:

```text
1.0 = 0x0100
```

### Example

```text
speed 2
```

Doubles playback speed by making notes half as long.

---

## 3.10 `define` — Define a Macro

### Syntax

```text
define <name>
    ...
enddefine
```

**Status:** Reserved for future use. Not implemented in v1.0.

---

# 4. Note Names

## 4.1 Pitch Classes

| Note | Frequency at C4 reference (Hz) |
|---|---:|
| C | 261.63 |
| C# / Db | 277.18 |
| D | 293.66 |
| D# / Eb | 311.13 |
| E | 329.63 |
| F | 349.23 |
| F# / Gb | 369.99 |
| G | 392.00 |
| G# / Ab | 415.30 |
| A | 440.00 |
| A# / Bb | 466.16 |
| B | 493.88 |

## 4.2 Octave Numbers

- **Octave 0:** C0–B0 (`16.35–30.87 Hz`)
- **Octave 4:** C4–B4 (`261.63–493.88 Hz`)
- **Octave 8:** C8–B8 (`4186.01–7902.13 Hz`)

Middle C is `C4`.

The PC speaker cannot reliably reproduce frequencies below approximately `20 Hz` or above approximately `20 kHz`.

Notes outside the supported frequency range should be clamped or ignored according to the implementation.

---

## 4.3 Frequency Calculation

The standard frequency calculation is:

```text
freq = 440 * 2^((n - 69) / 12)
```

Where:

- `n` is the MIDI note number.
- `A4` = MIDI note `69`.
- `C4` = MIDI note `60`.

For a minimal assembly implementation, a lookup table for the 12 pitch classes combined with octave shifting is recommended.

---

# 5. Duration Values

| Value | Name | Relative Duration |
|---:|---|---:|
| 1 | Whole note | 4 beats |
| 2 | Half note | 2 beats |
| 4 | Quarter note | 1 beat |
| 8 | Eighth note | 0.5 beat |
| 16 | Sixteenth note | 0.25 beat |
| 32 | Thirty-second note | 0.125 beat |

The standard duration calculation is:

```text
ms = (60 * 1000 / tempo) / duration
```

### Dotted Notes

Dotted notes can be represented by multiplying the duration by `1.5`.

For example, a dotted half note can be approximated using:

```text
duration 2
speed 1.5
```

Direct dotted-duration syntax is not supported in v1.0.

---

# 6. Binary Format (`.sbb`) — Optional

While `.ss` is text-based, an optional compiled binary format, `.sbb`, may be used for faster playback and smaller file sizes.

## 6.1 Header

The `.sbb` header is 8 bytes:

| Offset | Size | Value |
|---:|---:|---|
| `0` | 4 bytes | Magic: `0x53534201` (`SSB\x01`) |
| `4` | 2 bytes | Tempo (BPM, little-endian) |
| `6` | 2 bytes | Note count (`N`) |

## 6.2 Body

Each note entry is 4 bytes:

| Offset | Size | Value |
|---:|---:|---|
| `0` | 2 bytes | Frequency in Hz, little-endian |
| `2` | 2 bytes | Duration in milliseconds, little-endian |

A frequency of `0` represents a rest.

## 6.3 Playback

The player should:

1. Read the header.
2. Read each note entry.
3. If frequency is `0`, sleep for the specified duration.
4. Otherwise, call the audio subsystem with the specified frequency and duration.

---

# 7. Error Handling

Implementations should follow these rules:

| Error | Behavior |
|---|---|
| Unknown command | Ignore the line and continue |
| Malformed note name | Ignore the line and continue |
| Out-of-range frequency | Clamp to supported range |
| Negative duration | Treat as positive |
| Empty file | Play nothing |
| Missing optional argument | Use current/default value |

The player should avoid terminating playback because of a single malformed line.

---

# 8. Implementation Notes

## 8.1 Memory Usage

The reference implementation is designed for extremely low memory usage.

Recommended runtime state:

```text
tempo       : 2 bytes
octave      : 1 byte
duration    : 1 byte
transpose   : 1 byte
speed       : 2 bytes
```

A 12-entry note lookup table can use:

```text
12 × 4 bytes = 48 bytes
```

The parser should avoid heap allocation.

---

## 8.2 Performance

The format is designed for simple parsing on low-level hardware.

Recommended goals:

- No floating-point operations.
- No dynamic memory allocation.
- Playback may block the OS on single-threaded systems.
- Note lookup should use a small static table.

---

## 8.3 Example Parser Structure

A minimal NASM-style parser could use state variables similar to:

```nasm
; State variables
ss_tempo:     dw 120
ss_octave:    db 4
ss_duration:  db 4
ss_transpose: db 0

; Parse loop
parse_line:
    call skip_whitespace

    cmp byte [rsi], ';'     ; Comment?
    je .next_line

    cmp byte [rsi], 0       ; EOF?
    je .done

    ; Check command
    cmp word [rsi], 'no'    ; "no" -> note
    je parse_note

    cmp word [rsi], 're'    ; "re" -> rest
    je parse_rest

    cmp word [rsi], 'te'    ; "te" -> tempo
    je parse_tempo

    ; ... additional commands ...

.next_line:
    call skip_to_next_line
    jmp parse_line

.done:
    ret
```

---

# 9. Example `.ss` File

### `startup.ss`

```text
; ShellyForever Startup Chime
; C Major Arpeggio - Bright and Uplifting

tempo 160
octave 4
duration 8

note C4
note E4
note G4
note C5 4

rest 8

; Echo
octave 5
note G5 8
note E5 8
note C5 8
```

### Expected Playback

The PC speaker should produce approximately:

| Note | Frequency | Duration |
|---|---:|---:|
| C4 | 261.63 Hz | 125 ms |
| E4 | 329.63 Hz | 125 ms |
| G4 | 392.00 Hz | 125 ms |
| C5 | 523.25 Hz | 250 ms |
| G5 | 783.99 Hz | 125 ms |
| E5 | 659.25 Hz | 125 ms |
| C5 | 523.25 Hz | 125 ms |

---

# 10. Future Extensions

The `.ss` format is designed to be extended without breaking existing v1.0 files.

Potential future commands include:

### `effect`

Add audio effects such as:

- Reverb
- Delay
- Echo

### `channel`

Support multiple simultaneous tracks or channels when more capable audio hardware is available.

### `include`

Include another `.ss` file:

```text
include "common.ss"
```

### Additional Possibilities

Future versions may also introduce:

- Waveform selection
- Volume envelopes
- Instrument definitions
- ADSR envelopes
- Stereo channels
- Digital PCM samples
- Sound effects
- Percussion
- Metadata
- Music titles and authors

---

# 11. License

The `.ss` format and its reference implementation are released under the **ShellyForever Public License**.

You may use, modify, and distribute the format and its implementations freely, provided that you credit the original author.

---

## Document Information

| Field | Value |
|---|---|
| Format | Shelly Sound |
| Extension | `.ss` |
| MIME Type | `text/x-shelly-sound` |
| Specification Version | `1.0` |
| Date | `2026-08-22` |
| Author | ShellyForever Development Team (the one-person army) |