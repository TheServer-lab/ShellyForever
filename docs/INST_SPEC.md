# The `.inst` Language — A ShellyForever Installer Tutorial

This is a learning guide to `whattodo.inst`, the instruction language
that drives the Shelly Installer, and to the `.sin` packages it lives
inside. It walks through the concepts in order, with runnable examples
you can try directly at the `rush>` prompt.

By the end you'll be able to read an existing `whattodo.inst`, write
your own, and package it into a working `.sin` with `mksin`.

---

## 1. The big picture

Three file types work together:

| File          | What it is                                          |
|---------------|------------------------------------------------------|
| `.run`        | A compiled, executable ShellyForever program         |
| `.sin`        | An installer package (a ZIP-compatible archive)       |
| `whattodo.inst` | The install *script* inside a `.sin`                |

A `.sin` is just a stored-mode (uncompressed) ZIP archive with a fixed
shape:

```
example.sin
    |
    +-- whattodo.inst      <- what to do
    |
    +-- files/             <- what to copy
         +-- example.run
         +-- README.txt
```

`whattodo.inst` is the recipe. `files/` is the pantry. The installer
reads the recipe and copies ingredients out of the pantry onto the
target machine.

Running `install example.sin` does, in order:

1. Open the archive, confirm `whattodo.inst` and `files/` both exist.
2. Parse and run `whattodo.inst`, line by line.
3. Register the program (if the script says to) in
   `/home/sys/programs.sly`.

After that, the program can be launched just by typing its id — see
§7.

---

## 2. Why a restricted language?

`.inst` is deliberately **not** a general-purpose scripting language.
It has no variables, no loops, no conditionals, and — most
importantly — no way to run arbitrary shell commands. Every
instruction is drawn from a small, fixed vocabulary that the
installer already knows how to execute safely:

```
name  version  mkdir  copy  delete  program  finish
```

If an instruction isn't on that list, the installer refuses the
whole package rather than guessing what it might mean:

```
install: unknown instruction: run
install: installation stopped after an error
```

This is the same reasoning that keeps a recipe card from suddenly
containing "and now rewire the oven": installation should describe
*what gets installed*, not run programs, fetch things from the
network, or do anything the person running `install` didn't
explicitly agree to by choosing that package.

---

## 3. Syntax basics

Each line is one instruction: a keyword, then zero or more
arguments.

```
mkdir "/home/programs/example"
```

- Arguments with spaces need double quotes.
- Arguments without spaces don't strictly need them, but quoting
  consistently is good practice.
- Blank lines are ignored.
- `#` starts a comment that runs to the end of the line.

```
# This is a comment
mkdir "/home/programs/example"   # trailing comments work too... actually
                                  # no they don't — see the note below
```

> **Note:** unlike some languages, `.inst` comments must be the
> *whole* line (after leading whitespace) — put them on their own
> line, not after an instruction.

---

## 4. The instruction set

### `name "Program Name"`

Purely informational. The installer prints it while installing.

```
name "Example Calculator"
```

### `version "1.0"`

Also informational in this version of the language. Future versions
may use it for update checks — see §9.

```
version "1.2.3"
```

### `mkdir "path"`

Creates a folder on the target filesystem. Idempotent — if the folder
already exists, nothing bad happens.

```
mkdir "/home/programs/example"
```

The path **must be absolute** (start with `/`). You usually don't
need to `mkdir` a `copy` destination's parent folder explicitly —
`copy` creates any missing folders along the way — but `mkdir` is
still useful for folders that stay empty, or just for clarity.

### `copy "package-file" "destination"`

Copies a file out of the package's `files/` folder onto the target
filesystem.

```
copy "example.run" "/home/programs/example/example.run"
```

The **first** argument is relative to `files/` inside the package —
don't write `files/example.run`, the installer adds that prefix for
you. The **second** argument is the absolute destination path.

### `delete "path"`

Deletes a single file from the target filesystem. Two safety rules:

- It's a no-op (not an error) if the file doesn't already exist —
  this keeps `delete` idempotent, the same spirit as `mkdir`.
- It refuses to delete a **folder** — every use case in the spec
  targets a single file, and folder deletion is a much bigger hammer
  than an installer script should be swinging.

```
delete "/home/programs/example/old.run"
```

### `program "identifier" "path"`

Registers (or re-registers) a program so it can be launched by name.
This writes an entry into `/home/sys/programs.sly`:

```
program "example" "/home/programs/example/example.run"
```

becomes

```
program = example
path = /home/programs/example/example.run
```

If `example` was already registered, its old entry is replaced.

### `finish`

Marks the end of the script. Anything after `finish` is ignored.
Always end your script with it.

```
finish
```

---

## 5. A complete example

```
# Example Calculator
name "Example Calculator"
version "1.0"

mkdir "/home/programs/example"
copy "example.run" "/home/programs/example/example.run"
copy "README.txt" "/home/programs/example/README.txt"

program "example" "/home/programs/example/example.run"

finish
```

Reading it top to bottom: make the program's folder, copy in its
executable and a readme, register it under the id `example`, done.
Nothing here could do anything other than exactly that.

---

## 6. Building the package with `mksin`

You don't need a separate tool on another machine — ShellyForever can
build `.sin` packages itself.

**Step 1 — lay out the folder exactly like the finished package:**

```
mkf example
mkf example/files
```

**Step 2 — write the script:**

```
mkfl example/whattodo.inst "name \"Example Calculator\"
version \"1.0\"

mkdir \"/home/programs/example\"
copy \"example.run\" \"/home/programs/example/example.run\"
copy \"README.txt\" \"/home/programs/example/README.txt\"

program \"example\" \"/home/programs/example/example.run\"

finish"
```

**Step 3 — put the real files where the script expects them:**

```
cpy example.run example/files/example.run
cpy README.txt example/files/README.txt
```

**Step 4 — build it:**

```
mksin example
```

`mksin` checks, in order:

1. `example/` has both `whattodo.inst` (a file) and `files/` (a
   folder) directly inside it.
2. Every line of `whattodo.inst` parses: known instruction, required
   arguments present, `mkdir`/`copy`/`delete`/`program` destinations
   are absolute paths.
3. Every `copy` source (`example.run`, `README.txt` above) actually
   exists under `example/files/`.

Only if all of that passes does it zip the folder (the same way
`pack` does) and produce `example.sin`. If something's wrong, you get
a precise error instead of a package that fails install on someone
else's machine:

```
mksin: copy source not found under files/: example.run (line 6)
```

**Step 5 — try it:**

```
install example.sin
example
```

That last line works because installing registered `example` as a
program id — see the next section.

---

## 7. What installing actually does to the system

Two on-disk structures matter:

**The install directory**, conventionally one folder per program
under `/home/programs/`:

```
/home/programs/
    example/
        example.run
    calc/
        calc.run
```

**The registry**, `/home/sys/programs.sly` — a flat, blank-line
separated list:

```
program = example
path = /home/programs/example/example.run

program = calc
path = /home/programs/calc/calc.run
```

Once a program is registered, typing its id at the prompt launches
it directly — `example` works exactly like `run
/home/programs/example/example.run`, just shorter. `program`
identifiers should be lowercase, and may use digits, `-`, and `_`;
they must be unique, since the registry can't hold two active entries
with the same id (a re-run of `program` for an existing id replaces
it rather than creating a duplicate).

---

## 8. Removing a program

```
uninstall example
```

This looks up `example` in the registry, deletes the one file
recorded as its entry point, and removes the registry entry. It does
**not** delete every file a `copy` instruction ever wrote, on
purpose — the registry keeps no manifest of those, and guessing
would risk deleting files the person still wants. If your package
copies more than one file, plan for that: e.g. put everything a
program needs in its own folder under `/home/programs/<id>/`, so a
person can always clean up manually by deleting that folder.

---

## 9. What's deliberately *not* here (yet)

Version 0.1 intentionally leaves out:

- Variables, loops, conditionals — no programming, just installing.
- Network access or downloading — a `.sin` is a closed, self-
  contained archive.
- Executing programs during install — nothing in `whattodo.inst` can
  ever launch code, only place files and register an id.
- Dependency resolution, version checks, uninstall instructions,
  package signatures — all flagged as possible future work.

Keeping the language this small is what lets the installer parse and
run it directly, without needing a full interpreter, and lets anyone
read a `whattodo.inst` and know exactly what it will do before
running `install`.

---

## 10. Quick reference

```
# comment

name "Program Name"                          informational
version "1.0"                                informational

mkdir "/absolute/path"                       create folder
copy "pkg-relative-file" "/absolute/dest"    copy from files/
delete "/absolute/path"                      remove one file (no folders)
program "id" "/absolute/path-to/executable"  register (spec §6: lowercase,
                                              digits, -, _; must be unique)

finish                                       end of script
```

**Building & installing:**

```
mksin <folder>          build <folder>.sin from <folder>/whattodo.inst + files/
install <file.sin>       run a package's installer
uninstall <id>           remove a registered program
<id>                     launch a registered program
```
