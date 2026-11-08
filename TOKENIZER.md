# The tokenizer

## What is a tokenizer?

A STEP file is plain text. To a computer it is just a long run of bytes:

```
#12=CARTESIAN_POINT('',(1.,2.E0,-3.));
```

Nothing in those bytes says that `#12` is a reference, that `1.` is a number, or that the two quote
marks are an empty string. Something has to read the bytes and cut them into meaningful pieces first.

A *tokenizer* (also called a lexer) is that step. It walks along the text and hands back one **token**
at a time: the smallest piece that means something on its own. It does not understand what the pieces
add up to. It only answers "what is the next piece?".

```
bytes ──▶ tokenizer ──▶ tokens ──▶ parser ──▶ values ──▶ the importer
          (this file)             (STEPFile)
```

The line above becomes 15 tokens:

| Text | Token |
| --- | --- |
| `#12` | reference 12 |
| `=` | symbol `=` |
| `CARTESIAN_POINT` | word `CARTESIAN_POINT` |
| `(` | symbol `(` |
| `''` | string "" |
| `,` | symbol `,` |
| `(` | symbol `(` |
| `1.` | real 1.0 |
| `,` | symbol `,` |
| `2.E0` | real 2.0 |
| `,` | symbol `,` |
| `-3.` | real -3.0 |
| `)` `)` `;` | three symbols |

White space and comments are not tokens. They are skipped.

## The kinds of token

`STEPTokenizer.Token` has these cases:

| Token | Looks like | Notes |
| --- | --- | --- |
| `.reference(Int)` | `#12` | The number must be a positive integer that fits. `#`, `#0`, `#-1` and `#a` are errors. |
| `.word(String)` | `CARTESIAN_POINT`, `END-ISO-10303-21`, `!MY_KEYWORD` | Letters, digits, `_` and `-`. Always upper-cased, so `cartesian_point` is the same word. A `!` starts a user-defined keyword. |
| `.string(String)` | `'it''s'` | Two quotes in a row are one quote. Escape codes such as `\X2\00E9\X0\` are decoded afterwards (`STEPStringEscapes`). |
| `.integer(Int)` | `7`, `-12`, `+3`, `007` | No dot and no exponent. |
| `.real(Double)` | `1.`, `.5E3`, `-2.5`, `1E5`, `1.0E+00` | A dot or an exponent makes it a real. `1E999` is refused, not turned into infinity. |
| `.enumeration(String)` | `.T.`, `.CURVE_3D.` | Upper-cased, the dots dropped. |
| `.symbol(UInt8)` | `( ) , ; = $ *` | Stored as the byte value. `$` means "not set", `*` means "derived". |
| `.end` | | The text is used up. It keeps coming back if you ask again. |

## How it works

The tokenizer holds the file's bytes (`Data`) and a position. `next()` is the whole interface: it
moves the position forward and returns one token.

```swift
var lexer = STEPTokenizer(data: data)
while true {
    let token = try lexer.next()
    if token == .end { break }
    // use the token
}
```

Each call does the same few things, in this order:

1. **Skip what is not a token.** Spaces, tabs and new lines, and `/* ... */` comments. Comments are
   only recognised here, between tokens. Inside a string, `/*` is just text.
2. **Look at the first byte**, which decides what kind of token this is:

   | First byte | Kind | What it does |
   | --- | --- | --- |
   | `'` | string | reads to the closing quote, turning `''` into one `'` |
   | `#` | reference | reads the digits that follow |
   | letter, `_` or `!` + letter | word | reads letters, digits, `_`, `-`; upper-cases the result |
   | `.` + letter | enumeration | reads to the closing `.` |
   | digit, `+`, `-`, or `.` | number | reads digits, an optional `.`, an optional exponent |
   | `( ) , ; = $ *` | symbol | returns it at once |
   | anything else | | an error |

3. **Return the token** and leave the position just after it.

Two rules need a little care:

- A `.` can start an enumeration (`.T.`) or a number (`.5`). The byte after it tells them apart: a
  letter means enumeration, anything else means number.
- A number is only an integer if it has no `.` and no exponent. `1E5` is a real even though it has
  no dot.

The tokenizer works on bytes, not on `String` characters, and never copies the file. A token's text
is only built when the token needs it (a word, a string). That keeps the cost of a pass over a
big file low.

## Where it is used

There are two stages, and both use the same tokenizer.

### Stage 1: indexing (`STEPFile.init`)

Reading the whole file into values up front would be slow and would waste memory, since most
entities are never looked at. So `STEPFile` makes one quick pass:

```
ISO-10303-21;  HEADER; ... ENDSEC;  DATA;  #1=...;  #2=...;  ...  ENDSEC;  END-ISO-10303-21;
```

It checks the framing (the header, `DATA;`, the closing lines) and, for every record
`#id=TYPE(...)`, it remembers three things: the id, the type, and the **byte range** of the
parameter list. It finds the end of the list by counting brackets. It does not read the parameters.
A complex record `#5=( A(1) B(2) )` becomes one id with two ranges.

### Stage 2: reading parameters on demand (`STEPParameterParser`)

When the importer asks for entity `#12`, a second tokenizer is started over just that record's
byte range. `STEPParameterParser` turns the tokens into `STEPValue`s (`.integer`, `.real`,
`.string`, `.reference`, `.list`, `.typed`, `.unset`, `.derived`). The result is cached, so each
entity is read at most once. Errors in the parameters (a missing comma, a trailing comma) only
show up here, when something actually asks for that entity.

## Limits and errors

A file can be damaged or hostile, so the tokenizer never trusts it:

| Limit | Value | What happens |
| --- | --- | --- |
| Nesting depth of `(` | 128 | `ParseError`, kind `.limitExceeded` |
| Size of one token | 1 MiB | `ParseError`, kind `.limitExceeded` |
| Entities in a file | `Options.maximumEntityCount`, 2,000,000 | `.limitExceeded` |
| Complex record components | 128 | `.limitExceeded` |

Errors say what went wrong and where (`Invalid number at byte 1234`). The `kind` tells a cut-off
file from a damaged one:

- `.truncated`: the text ended where more was due (an unterminated string or comment, a missing
  `END-ISO-10303-21;`).
- `.malformed`: the text is there but wrong (a bad number, a stray byte, a missing `=`).
- `.notSTEP`: the very first thing in the file is not `ISO-10303-21;`.

Parsing can be cancelled. The tokenizer checks for cancellation on every token and every 4096 bytes
inside a long comment or string, so a `Task` that is cancelled stops within a moment even in the
middle of a huge file.

## Why write it by hand?

Regular expressions and `Scanner` work on `String`, which means converting the file's bytes first,
and they make it harder to enforce limits, report byte positions, or stop part-way. A small
hand-written loop over bytes is short, easy to test one rule at a time, and does the same work on
every run.

## Tests

- `STEPTokenizerTests` checks each rule above one at a time, including the awkward spellings
  (`1.`, `.5E3`, a lone `-`, `''`, `/*/`).
- `STEPFileStructureTests` checks the indexing pass: complex records, truncation, nesting, and that
  every shorter prefix of a valid file is refused.
- `STEPFuzzTests` feeds damaged files and random bytes to the tokenizer and requires that it either
  returns tokens or throws a `ParseError`, and always moves forward.
