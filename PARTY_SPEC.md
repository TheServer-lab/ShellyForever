# Party (.pa) — Language Spec v0.1

Standalone scripting language for ShellyForever. Own variables, own
expression evaluator. No shell/command access from inside a script.

Invoked from the shell as:

```
party foo.pa
```

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

Declare with `vars`, value required at declaration:

```
vars a = "hi"
vars n = 5
vars ok = true
```

Reassignment (no `vars`, must already be declared):

```
a = "bye"
n = n + 1
```

Using an undeclared variable is an error, not a silent default.

## 4. Operators

```
()                      grouping
* /                     multiplicative
+ -                     additive
< <= > >=               comparison (int/float)
== !=                   equality (any matching type)
=                       assignment (statement only, not an expression)
```

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

## 8. Example programs

`helloworld.pa`
```
display "Hello world"
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

---

## Not in v0.1 (deliberately deferred)

- User input (`read` or similar)
- `%` modulo
- `&&` / `||` logical operators
- Arrays, or any collection type

These are natural v0.2 candidates once the interpreter skeleton
(lexer → parser → evaluator for this exact grammar) is running.
