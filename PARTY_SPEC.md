# Party (.pa) — Language Spec

Standalone scripting language for ShellyForever. Own variables, own
expression evaluator. No shell/command access from inside a script.

Invoked from the shell as:

```
party foo.pa
```

As of ShellyForever 0.1.9, the same source can also be compiled straight
to a `.run` executable instead of interpreted:

```
party compile foo.pa
```

writes `foo.run` alongside `foo.pa`; `run foo.run` (or a bare `foo.run`
at the prompt) then runs it. The full grammar below compiles, not just a
subset — this section is a language spec, and everything in it applies
whether a program is interpreted or compiled.

A third shell form fetches a module instead of running one:

```
party get modulename
```

Downloads `modulename.pa` over HTTPS from the community module repo
(`https://raw.githubusercontent.com/TheServer-lab/shellybin/.../party/modules/modulename.pa`)
and saves it as `modulename.pa` in the current directory — nothing
more; it doesn't lex, run, or otherwise validate the fetched text
beyond confirming the server actually returned it (a 404 is reported
as an error, not saved). `party get modulename outfile.pa` saves it
under a different local name instead. A module name is a bare name,
not a path — it may not contain `/`, and a redundant `.pa` typed on
the end (`party get modulename.pa`) is accepted and treated the same
as leaving it off. Once fetched, `module "modulename.pa"` in a script
splices it in exactly as if it had been written by hand (see §12).
This shares the same trust model as `stake`/`sgive` (§8's `rush`
still doesn't reach any of this — `get`, like `compile`, is a form of
the `party` shell command itself, not a script-callable builtin): the
connection is encrypted but the server's identity isn't verified, and
there's no signing or integrity check on what comes back, so only
fetch modules from sources you trust.

---

## 1. Lexical rules

- Comments: `// rest of line`
- Blocks always use `{ }` — never optional, never single-statement-no-braces.
- Statements end at the newline (no semicolons).
- Identifiers: `[a-zA-Z_][a-zA-Z0-9_]*`
- String literals: always double-quoted, e.g. `"Hello world"`.
  A bare word with no quotes is always a variable reference — never
  a string, even if it "looks like" one (e.g. `hi` means "the
  variable named hi", not the text hi).
- **String interpolation:** `{identifier}` inside a string literal
  is replaced with that variable's string form:

  ```
  vars name = "world"
  display "hello {name}"        // prints: hello world
  vars n = 5
  display "n is {n}"            // prints: n is 5 (int stringified)
  ```

  Only a bare, already-declared variable name — first char
  `[a-zA-Z_]`, rest `[a-zA-Z0-9_]`, same as any other identifier.
  Arbitrary expressions or function calls inside `{}` (e.g.
  `{n + 1}`, `{add(2,3)}`) are **not** supported yet — a natural
  follow-up, not in this revision. An undeclared name inside `{}` is
  a runtime error, same as using an undeclared variable anywhere
  else. An empty `{}`, a name starting with a digit, or an
  unterminated `{` with no matching `}` are also runtime errors.

  `{{` and `}}` escape to a literal `{` and `}` respectively. A
  lone `}` (not doubled) is always just a literal `}` — only `{`
  needs escaping, since only `{` can open a substitution.

  A string literal with no `{` in it behaves exactly as before —
  interpolation is opt-in per-literal and costs nothing otherwise.
  A string literal that *does* interpolate is built into a shared
  scratch buffer, the same aliasing model `read` already uses (see
  section 9): evaluating another interpolated literal overwrites an
  earlier one's text, so use/consume an interpolated string (display
  it, `rush` it, compare it, etc.) before evaluating a new one if the
  old text needs to survive.
- Numeric literals: `123`, `-45` (int), `3.14` (float)

## 2. Types

- **int** — 64-bit signed integer
- **float** — floating point
- **bool** — `true` / `false`
- **string** — quoted text

## 3. Variables

Declare with `vars`. A declaration lists one or more comma-separated
names, each optionally initialized with `= <expr>`:

```
vars a = "hi"
vars n = 5
vars ok = true
vars x, y = 7, z       // x = 0, y = 7, z = 0
```

A name given no value is declared with the default int `0` — handy
with `read` (below) so `vars name` then `read name` needs no bogus
initializer.

Reassignment (no `vars`, must already be declared):

```
a = "bye"
n = n + 1
```

Using an undeclared variable is an error, not a silent default.

## 4. Operators

```
()                      grouping
* / %                   multiplicative (% is int-only: a float operand is an error)
+ -                     additive
< <= > >=               comparison (int/float)
== !=                   equality (any matching type)
&& ||                   logical and/or (any type, truthy coercion; no short-circuit)
=                       assignment (statement only, not an expression)
```

`&&` / `||` treat their operands like an `if` condition — `0`, `false`,
`""`, and `0.0` are falsy, everything else is truthy — and push a
bool result. Both sides are always evaluated (consistent with every
other operator; there's no short-circuit, so `f() && g()` calls `g()`
even when `f()` is false).

Precedence, high to low: unary `-`, then `* / %`, then `+ -`, then
`< <= > >=`, then `== !=`, then `&&`, then `||`.

## 5. Control flow

```
if (a == "hi") {
    display "true"
} else if (a != "hi") {
    display "false"
} else {
    display "IDK"
}

while (true) {
    display "This is a loop."
}
```

- `else if` / `else` optional, chain as many `else if` as needed.
- Braces are **mandatory** on every block, always — no exceptions.

## 6. Functions

```
func add(a, b) {
    return a + b
}

vars r = add(2, 3)
display r
```

- Fixed arity, no default args, no varargs.
- `return <expr>` exits the function with a value; a function with no
  `return` reached implicitly falls off the end (treated as returning
  nothing — calling it as an expression is an error).
- Recursion allowed, depth-limited by a fixed call-stack (interpreter
  detail, not a syntax concern) — hard error on overflow, not silent
  truncation.
- **No mandatory `main()`.** This keeps `helloworld.pa` (just one bare
  `display` line, no function at all) still valid. `func` is just
  another top-level declaration; execution runs top-level statements
  top-to-bottom the way it already did, and a function's body only
  runs when something calls it.
- A function can be called before its `func` block appears later in
  the file (declarations are collected in a first pass) — otherwise
  two functions that call each other couldn't both be written.

## 7. Output

- `display <expr>` — prints the value (string, int, float, or bool)
  followed by a newline.

## 8. Shell access — `rush`

```
rush <expr>
```

`<expr>` must evaluate to a **string**. That string is handed to the
Rush/ShellyForever shell exactly as if it had been typed at the
prompt — it goes through the same `;`-chaining, quoted-argument, and
alias handling as an interactive line, then dispatches to whatever
command it names. This is the *only* door from a Party script out to
the shell; there is still no other command/process access from
inside a script (see the file at the top of this spec).

Anything the shell can do, `rush` can do: create or edit files
(`mkf`, `mkfl`, `edit`, `cf`), list/inspect them (`ls`, `cat`,
`show`), networking (`net`, `dns`, `dhcp`, `netinfo`), and
`party compile <file>` — a Party script can shell out to compile
another (or its own) `.pa` file. `rush` takes one expression, so
chain multiple commands with `;` inside the string if you need more
than one:

```
vars f = "notes.txt"
rush "mkf " + f
rush "show " + f + " ; ls"
```

A non-string expression (`rush 5`, `rush true`) is a runtime error,
the same way `a % 3.0` is: caught at the point it runs, not at parse
time, since Party doesn't do static type-checking.

`rush` output prints to the same screen the script's own `display`
lines print to — there's no way yet to capture a `rush` command's
output back into a Party variable. That's a planned follow-up; see
`phases.txt`.

## 9. File access

Real file I/O, without shelling out through `rush`. These are
function-call-shaped **builtin functions**, not statements — a
script cannot declare a `func` with any of these names; the builtin
is always what runs.

```
vars h = fopen("notes.txt", "r")   // or "w" / "a"
vars text = fread(h)               // whole file, as a string
fwrite(h, "some text")             // appends to the file
fclose(h)
vars exists = fexists("notes.txt")
fdelete("notes.txt")
```

- `fopen(path, mode) -> int` — `mode` is exactly `"r"` (file must
  already exist), `"w"` (create if missing, truncate if it already
  exists), or `"a"` (create if missing, otherwise keep existing
  content). Returns an opaque int handle. A path that names a folder,
  a mode other than `"r"`/`"w"`/`"a"`, a non-string argument, or a
  `"r"` open on a file that doesn't exist are all runtime errors —
  `fopen` never returns an invalid handle.
- `fread(h) -> string` — reads the whole file's current contents.
- `fwrite(h, text)` — appends `text` (a string) to the file. A handle
  opened `"r"` is read-only; writing to it is a runtime error. Returns
  no value — call it as a statement, not inside an expression.
- `fclose(h)` — releases the handle. Returns no value.
- `fexists(path) -> bool` — `true`/`false`. Unlike the rest of this
  API, a path that simply doesn't resolve is **not** an error here —
  that's the whole point of an existence check — but a non-string
  argument still is.
- `fdelete(path)` — deletes a file or, if given a folder, that folder
  and everything under it. Deleting a path that doesn't exist **is**
  a runtime error (unlike `fexists`) — `fdelete` is an action the
  script expects to have an effect, so a silent no-op on a bad path
  would hide a bug.
- A file handle is just an `int`; there is no separate handle type.
  Passing an out-of-range or already-`fclose`d handle to `fread` /
  `fwrite` / `fclose` is a runtime error, not a silent no-op.
- No streaming/partial reads yet — `fread` always reads the entire
  file, matching how the underlying filesystem primitives already
  work (same as `rush "cat file"` under the hood).

```
vars h = fopen("greeting.pa.log", "w")
fwrite(h, "started\n")
fclose(h)

if (fexists("greeting.pa.log")) {
    vars h2 = fopen("greeting.pa.log", "r")
    display fread(h2)
    fclose(h2)
}
```

## 10. Arrays

Fixed-size arrays of any value type, created and used through builtin
functions rather than `[...]`/`a[i]` syntax (that syntax is a
possible follow-up — see the deferred-features list — this revision
covers the underlying storage without it):

```
vars a = arr_new(3)      // array of 3 elements, each starts as int 0
arr_set(a, 0, "hi")       // statement only, like fwrite
display arr_get(a, 0)    // "hi"
display arr_len(a)       // 3
arr_free(a)               // releases it
```

- `arr_new(n) -> array` — creates an array of exactly `n` elements,
  each initialized to the int `0`. `n` must be a non-negative int
  that fits the implementation's per-array capacity; a negative `n`,
  an oversized `n`, a non-int argument, or the array table itself
  being full are all runtime errors.
- `arr_len(a) -> int` — the element count fixed at `arr_new` time.
  There is no resize/append/push — an array's length never changes
  after creation.
- `arr_get(a, i) -> value` — returns element `i` (a copy; mutating
  the returned value, e.g. for a string, doesn't affect the array).
  Any value type may be stored, including another array. `i` must be
  an int with `0 <= i < arr_len(a)`; out of that range is a runtime
  error, same as a non-int index or a non-array first argument.
- `arr_set(a, i, v)` — replaces element `i` with `v` (any type).
  Statement only, like `fwrite` — returns no value, so it can't be
  used inside an expression. Same index rules/errors as `arr_get`.
- `arr_free(a)` — releases the array. Using the handle again
  afterwards (`arr_len`, `arr_get`, `arr_set`, or a second
  `arr_free`) is a runtime error, the same as reusing a closed file
  handle (section 9).
- **Arrays are reference types.** Assigning `vars b = a`, passing `a`
  to a function, or returning `a` from one, copies the array's
  *handle*, not its contents — `a` and `b` (or the parameter, or the
  caller's original) all still refer to the same underlying storage,
  so a change through one is visible through the other. This is the
  same tradeoff `fopen`'s int handle already makes, just with its own
  type instead of a bare int.
- `display` on an array prints `[e0, e1, ...]`, each element
  formatted the same way `display` already formats that type on its
  own (so a string element prints unquoted, same as `display` of a
  bare string) — including a nested array, printed the same way,
  recursively.
- These are ordinary function-shaped builtin names — like `fopen`
  et al. (section 9), a script cannot declare its own `func arr_new`
  etc.; the builtin always wins.

```
vars nums = arr_new(3)
arr_set(nums, 0, 10)
arr_set(nums, 1, 20)
arr_set(nums, 2, 30)
display nums              // [10, 20, 30]
display arr_len(nums)     // 3

vars alias = nums
arr_set(alias, 0, 99)
display arr_get(nums, 0)  // 99 - alias and nums share storage

arr_free(nums)
```

## 11. Input

- `read <var>` — reads one line from the keyboard into the
  already-declared variable as a string. **Esc** aborts the whole
  script, the same as a running loop. The read string lives in a
  single shared buffer, so a later `read` overwrites an earlier one
  (same pointer-into-buffer model string literals use).

```
vars name = ""
read name
display name
```

## 12. Modules

A script can be split across files. A line of the form

```
module "utils.pa"
```

splices that file's whole text in at that point, *before* lexing —
a textual include, the same idea as C's `#include`. This runs as a
preprocessing pass over the raw source, not as part of the grammar
itself: `module` is not a keyword the lexer or parser knows about,
so it has no effect (and isn't recognized) anywhere except as this
exact line shape.

For a line to be treated as a module include:

- After trimming leading spaces/tabs, the line must start with
  `module`, then at least one space or tab, then a double-quoted
  path, with nothing but optional trailing spaces/tabs after the
  closing quote. Anything else on the line — including a trailing
  `// comment` — makes it a malformed module statement (a runtime
  error), not a silently-ignored line.
- A line that doesn't start with `module` (leading whitespace
  aside) is left untouched, so `// module "x"` in a comment is never
  mistaken for a real include.
- The path is resolved the same way the top-level script's own path
  is — relative to the shell's current directory, **not** relative
  to the file containing the `module` line. A module nested inside
  another module still resolves its own `module "..."` lines against
  that same current directory.

A module is typically just `func` definitions meant to be called
from the including script, but nothing stops it from having
top-level statements too — those run in place, in file order, same
as if they'd been pasted in by hand. A module doesn't have to be
hand-written locally — `party get modulename` (see the intro above)
downloads one from the community module repo and saves it as
`modulename.pa` in the current directory, ready to `module` it in.

- Modules may include modules, up to 3 levels deep; exceeding that
  is a runtime error (`modules nested too deeply`), so a module that
  (perhaps indirectly) includes itself fails cleanly instead of
  recursing forever.
- Up to 8 distinct module files may be included in one run; a 9th
  is a runtime error (`too many modules included`).
- Each distinct module is only spliced in once, even if multiple
  files `module` it. "Distinct" is judged by the path text as
  written, not the resolved file — `module "utils.pa"` and
  `module "./utils.pa"` are treated as two different includes even
  if they resolve to the same file.
- A module path that doesn't resolve to a file is a runtime error
  (`module file not found: <path>`), as is a path longer than 199
  characters (`module path too long`) or an expansion that grows the
  combined source past the interpreter's size limit
  (`expanded script too large`).

```
// utils.pa
func double(n) {
    return n * 2
}
```

```
// main.pa
module "utils.pa"

display double(21)      // 42
```

## 13. Random and time builtins

Like the file and array functions (sections 9–10), these are
builtin functions, not statements or keywords — a script cannot
declare its own `func` with any of these names.

```
vars f = rand()             // float in [0, 1)
vars n = randint(1, 6)      // int, inclusive both ends - a d6 roll
randseed(42)                // reseed for a repeatable sequence

vars t = time()             // int seconds since a fixed reference point
vars d = datestr()          // "YYYY-MM-DD"
vars c = timestr()          // "HH:MM:SS"
```

- `rand() -> float` — takes no arguments. Returns a pseudo-random
  float in `[0, 1)`.
- `randint(lo, hi) -> int` — both `lo` and `hi` must be ints, and
  `lo <= hi`; otherwise a runtime error (`randint requires two ints`
  or `randint: lo must be <= hi`). Returns a pseudo-random int in
  `[lo, hi]`, inclusive on both ends.
- `randseed(n)` — reseeds the generator from the int `n`. Statement
  only, like `fwrite`/`arr_set` — returns no value. Without ever
  calling it, `rand`/`randint` still work: the generator lazily
  seeds itself from the hardware clock the first time either is
  called, so two runs started a second or more apart already get
  different sequences. Call `randseed` explicitly when a run needs a
  repeatable sequence instead (e.g. a test).
- `time() -> int` — takes no arguments. Seconds since a fixed
  reference point (2000-01-01 00:00:00), derived from the hardware
  real-time clock. This is **not** a true Unix timestamp, but it's
  monotonic across a run — good for measuring elapsed time or for
  seeding, not for exchanging timestamps with anything that expects
  a real epoch.
- `datestr() -> string` — takes no arguments. The current date as
  `"YYYY-MM-DD"`.
- `timestr() -> string` — takes no arguments. The current time as
  `"HH:MM:SS"`.

## 14. Screen and timing builtins

Like the file, array, and random/time builtins (sections 9, 10, 13), these
are ordinary function-shaped builtins, not statements or keywords — a
script cannot declare its own `func sleep` or `func gotoxy`; the builtin
is always what runs.

```
sleep(250)         // busy-waits ~250ms before the next statement runs
gotoxy(10, 5)       // moves the cursor to column 10, row 5
display "hi"        // now prints starting at that cell
```

- `sleep(ms)` — busy-waits for `ms` milliseconds before continuing.
  `ms` must be a non-negative int; a non-int argument or a negative
  `ms` are runtime errors. Statement only, like `fwrite`/`arr_set` —
  returns no value. **Esc** still aborts a long `sleep` early, the
  same as it aborts any other running statement.
- `gotoxy(x, y)` — moves the cursor to column `x`, row `y` (both
  0-based ints) without drawing or scrolling anything itself — the
  next `display` output starts from that cell instead of wherever
  the cursor last was left. The screen is 80x25, so `x` must be in
  `[0, 79]` and `y` in `[0, 24]`; an out-of-range `x`/`y` is a
  runtime error rather than a silent clamp, the same way `randint`'s
  `lo > hi` is. Returns no value.

`display` always follows its output with a newline, so writing to the
true last screen cell (column 79, row 24) forces a scroll that shifts
every glyph already drawn by one row — which would desync a script's
own column/row bookkeeping if it's addressing cells directly via
`gotoxy`. A script drawing across the whole screen this way typically
sidesteps that by only ever drawing into columns 0-78 and rows 0-23,
one short of each true edge.

## 15. Example programs

`helloworld.pa`
```
display "Hello world"
```

`modulo.pa`
```
vars a = 17
vars b = 5

display a % b
```

`logic.pa`
```
vars a = 1
vars b = 0
if (a == 1 && b == 0) {
    display "and-ok"
}
if (b == 1 || a == 1) {
    display "or-ok"
}
```

`loop.pa`
```
while (true) {
    display "This is a loop."
}
```

`ifelse.pa`
```
vars a = "hi"

if (a == "hi") {
    display "true"
} else if (a != "hi") {
    display "false"
} else {
    display "IDK"
}
```

`read.pa`
```
vars name = ""
read name
display "hello "
display name
```

`interp.pa`
```
vars name = "world"
vars n = 5
display "hello {name}, n is {n}"
display "escaped: {{not a var}}"
```

`files.pa`
```
vars h = fopen("greeting.pa.log", "w")
fwrite(h, "started\n")
fclose(h)

if (fexists("greeting.pa.log")) {
    vars h2 = fopen("greeting.pa.log", "r")
    display fread(h2)
    fclose(h2)
}

fdelete("greeting.pa.log")
```

`arrays.pa`
```
vars nums = arr_new(3)
arr_set(nums, 0, 10)
arr_set(nums, 1, 20)
arr_set(nums, 2, 30)
display nums              // [10, 20, 30]
display arr_len(nums)     // 3

vars alias = nums
arr_set(alias, 0, 99)
display arr_get(nums, 0)  // 99 - alias and nums share storage

arr_free(nums)
```

`dice.pa`
```
randseed(1)
vars roll = randint(1, 6)
display "you rolled a {roll}"

vars today = datestr()
display "today is {today}"
```

`screen.pa`
```
gotoxy(0, 0)
display "top-left"
gotoxy(20, 10)
display "middle of the screen"
sleep(500)
```

`main.pa` + `utils.pa` (modules)
```
// utils.pa
func double(n) {
    return n * 2
}
```
```
// main.pa
module "utils.pa"

display double(21)      // 42
```

---

## Not in v0.1.14 (deliberately deferred)

- `[...]` array-literal syntax and `a[i]` / `a[i] = x` indexing
  expressions — arrays themselves now exist (section 10) but only
  through `arr_new`/`arr_get`/`arr_set`/`arr_len`/`arr_free`; bracket
  syntax would need new lexer tokens, a new expression production,
  and a new assignment-target grammar, deliberately left for a
  follow-up (see phases.txt for the tradeoff notes)
- Growable arrays (append/push/resize) — an array's length is fixed
  at `arr_new` and never changes
- Full expression / call interpolation (`"{n + 1}"`, `"{add(2,3)}"`)
  — string interpolation itself now exists (section 1) but is
  limited to a bare `{identifier}`
- An HTTP 1.0 client callable from a script
- Listening/server sockets callable from a script
- `rush` capturing a command's output into a variable

`rush` (added earlier) covers the *shell-out* half of file and
network access, by delegating to the existing `mkf`, `edit`, `cat`,
`net`, `dns`, `party compile`, etc. commands, and section 9 now gives
scripts **first-class, in-language** file access (real string types
passed to `fopen`, no shelling out and re-parsing text output) on top
of that. The items above still need the same treatment for HTTP and
for server sockets — build order and technical notes for both live in
`phases.txt`, alongside the source, since it's too much for one
sitting.