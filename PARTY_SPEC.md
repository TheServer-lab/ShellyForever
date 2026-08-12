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

## 8. Input

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

## 9. Example programs

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

---

## Not in v0.1.11 (deliberately deferred)

- Arrays, or any collection type

This is the natural v0.3 candidate.
