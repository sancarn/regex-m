<img src="assets/icon.svg" width="64" height="64" alt="">

# Regex.m

[AI:X](0rwx.com)

A regular expression engine written entirely in Power Query M. It parses a
pattern into an AST, compiles it to bytecode, and executes that bytecode in a
backtracking virtual machine. The regex library needs no VBA, .NET regex,
JavaScript, external service, custom connector, or workbook integration.

## Use in Excel or Power BI

Create a blank Power Query query named **Regex** and paste the contents of
[Regex.m](Regex.m) into its Advanced Editor. Other queries can then use its
functions:

```powerquery
let
    Pattern = Regex[Compile]("(?<name>[A-Za-z]+)=(?<value>\d+)"),
    Found = Regex[Matches]("width=120 height=80", Pattern),
    Result = Table.FromRecords(List.Transform(Found, each [
        Name = [NamedGroups][name][Value],
        Value = Number.FromText([NamedGroups][value][Value])
    ]))
in
    Result
```

M string literals use a single backslash: write `"\d+"`, not `"\\d+"`.
M's own `#(...)` escapes still apply; write `"#(#)("` for the literal text `#(`.

```powerquery
Regex[Test]("ABC-123", "^[a-z]+-\d+$", [IgnoreCase = true])
// true

Regex[Replace]("Ada Lovelace", "(\w+) (\w+)", "$2, $1")
// "Lovelace, Ada"

Regex[Split]("red, green;blue", "[,;]\s*")
// {"red", "green", "blue"}
```

Compile once outside a row function to reuse the program across a table.
See [examples/ExtractFields.m](examples/ExtractFields.m) and
[examples/TransformTable.m](examples/TransformTable.m).

## API

All positions and lengths are **zero-based UTF-16 code-unit offsets**, matching
Power Query's `Text.Length` and `Text.Middle`. Input must be text; null input is
not silently converted to an empty string.

- `Compile(pattern, optional options)` returns a reusable compiled record with
  `Ast`, `Program`, `GroupCount`, `Names`, `Options`, `Pattern`, and `Version`.
- `Parse(pattern, optional options)` returns the AST and capture metadata.
  Lookbehind width checking happens during compilation.
- `Match(input, patternOrCompiled, optional options, optional startAt)` returns
  the first match, or `null`. `startAt` defaults to zero; an offset beyond the
  input returns `null` after validating the pattern.
- `Test(input, patternOrCompiled, optional options)` returns a logical value.
- `Matches(input, patternOrCompiled, optional options)` returns a lazy list of
  non-overlapping matches, including empty matches.
- `List(input, patternOrCompiled, format, optional options)` formats every match
  and concatenates the results into one text value, following `stdRegex.List`.
  Unmatched input is omitted; no matches returns `""`.
- `Replace(input, patternOrCompiled, replacement, optional options)` replaces
  all matches. `replacement` can be text or a function accepting a match record
  and returning text.
- `Split(input, patternOrCompiled, optional options)` returns the text between
  matches. Captured delimiters are omitted; leading and trailing empty pieces
  are preserved.
- `Escape(text)` quotes regex metacharacters for use outside a character class.
- `Validate(pattern, optional options)` returns `[Valid, Error]`. It forces a
  complete compilation and returns an M error record for invalid patterns.

A match has `Success`, `Index`, `Length`, `Value`, `Groups`, and `NamedGroups`.
`Groups{0}` is the whole match. Capturing groups are numbered from one in
opening-parenthesis order, including named groups. Each group has `Success`,
`Index`, `Length`, and `Value`. A group that did not participate has `Success =
false`, `Index = -1`, `Length = 0`, and `Value = null`; an empty capture has
`Success = true` and `Value = ""`. Repeated captures expose the last capture,
not a capture history. Named groups reference the same numbered group records.

Replacement text supports `$0`, `$&`, `$1`, `$12`, `${name}`, and `$$`.
Numbered tokens consume all consecutive digits; `$12` means group 12, never
group 1 followed by `2`. Unknown groups and unclosed `${...}` tokens raise
`Regex.Replacement` when expanded. Nonparticipating groups expand to an empty
string. Other dollar sequences are literal. A callback can implement other
replacement conventions.

`List` uses [stdRegex's legacy formatter](https://github.com/sancarn/stdVBA/blob/master/src/stdRegex.cls):
`$&` and `$0` represent the whole match, `$1` etc. numbered captures, and `$name`
named captures. `\r` and `\n` insert line breaks; `\\` and `\$` escape a
backslash and dollar. Unmatched captures become empty strings and unknown
tokens remain literal. Substitution is sequential: whole match, escapes,
numbered groups in ascending order, then names ordered by length and ordinal
text. Inserted text can undergo later substitutions. Consequently `$10` is
group 1 followed by `0` when group 1 exists, and `$$` is not a dollar escape.
These legacy rules are specific to `List`; `Replace` uses the token syntax above.

```powerquery
Regex[List]("a=1 b=2", "(?<key>\w+)=(?<value>\d+)", "$key,$value\n")
// "a,1" and "b,2", each followed by LF, in one text value
```

## Supported syntax

- Literals, escapes, `.`, concatenation, and ordered alternation `a|b`.
- Character classes `[abc]`, ranges `[a-z]`, negation `[^a-z]`, and shorthand
  classes `\d \D \w \W \s \S`, including inside brackets.
- Greedy, lazy, and possessive repetition: `*`, `+`, `?`, `{n}`, `{n,}`,
  `{n,m}`, with a trailing `?` or `+`.
- Captures `(...)`, noncapturing groups `(?:...)`, named captures `(?<name>...)`,
  numeric backreferences `\1`, and named backreferences `\k<name>`.
- `^`, `$`, `\A`, `\z`, `\Z`, `\b`, and `\B`.
- Positive and negative lookahead `(?=...)`, `(?!...)`; fixed-width positive
  and negative lookbehind `(?<=...)`, `(?<!...)`; atomic groups `(?>...)`.
- `\n \r \t \f \v \0`, two-digit `\xHH`, and four-digit `\uHHHH`.
  Surrogate-pair escapes such as `\uD83D\uDE00` are supported.

Options are an M record. Defaults:

```powerquery
[
    IgnoreCase = false,
    Multiline = false,
    DotAll = false,
    MaxSteps = 1000000,
    MaxPatternLength = 10000,
    MaxDepth = 64,
    MaxProgramSize = 20000
]
```

Options are case-sensitive and unknown fields are rejected. Pass options when
compiling, or when supplying pattern text. Passing options alongside a compiled
pattern is an error. Limits must be positive finite integers no greater than
2,147,483,647. Explicit repeat counts cannot exceed 1,000,000.

## Matching rules and limits

This is a documented regex dialect, not a claim of full PCRE, ECMAScript,
VBScript, or .NET compatibility:

- Search chooses the earliest start position and the first successful ordered
  path. Greedy/lazy ordering is preserved through backtracking. Atomic groups,
  possessive quantifiers, and lookarounds are not re-entered by later
  backtracking. Positive assertions export captures; negative assertions do not.
- `\d` is ASCII `0-9`; `\w` is ASCII letters, digits, and underscore;
  `\s` is space, tab, CR, LF, form feed, and vertical tab. Word boundaries use
  that same ASCII definition. Unicode literals and ranges are supported;
  Unicode property escapes and Unicode word categories are not.
- Literals and backreferences use M's ordinal case-insensitive comparer with
  `IgnoreCase`. Ranges also test the input unit's `en-US` upper/lower forms.
  Full Unicode case folding and locale-specific regex behavior are not promised.
- `.` excludes CR and LF unless `DotAll` is set. `^` matches the start, or
  immediately after LF in multiline mode. `$` matches the end, before a final
  LF, or before any LF in multiline mode. CR in CRLF remains an ordinary
  character for anchors; use `\r?$` to match a whole CRLF-terminated line.
  `\A` and `\z` are absolute; `\Z` also permits a final LF.
- A supplementary Unicode character occupies two units. Dot, classes,
  quantifiers, and empty-match advancement operate on units, not graphemes or
  Unicode scalar values. A match can contain a lone surrogate; exporting that
  value through JSON/UTF-8 may replace it. Match a full surrogate pair when
  preserving supplementary characters is required.
- A successful empty iteration ends an unbounded repetition once its minimum
  is met. Earlier alternatives remain available for backtracking. This
  prevents infinite loops and preserves the final empty capture.
- After a zero-length global match, searching resumes one UTF-16 unit later.
  An empty match at the end is returned once. Thus `Matches("a", "a*")`
  returns `"a"` and `""`; `Split("ab", "")` returns `{"","a","b",""}`.
- A backreference to a nonparticipating or not-yet-captured group fails.
  Unknown references and duplicate names are compile errors. Group names
  contain ASCII word characters and cannot start with a digit.
- Lookbehind must have a statically fixed width; equal-width alternatives and
  exact-count repeats are allowed, but backreferences in lookbehind are not.
- Inline flags, comments, recursion/subroutines, conditionals, balancing
  groups, octal escapes, class subtraction/intersection, and Unicode property
  escapes are rejected. Escape literal braces and brackets. `[]` matches
  nothing and `[^]` matches any unit, including line terminators.

The VM is a depth-first backtracking engine. Ambiguous nested repetitions can
take exponential time. `MaxSteps` bounds executed instructions across **all
start positions, assertions, and matches in one API call**; exhaustion raises
`Regex.Limit`, never a false negative or partial successful result. A lazy
`Matches` list can yield earlier items before a later item raises an error.
The limit is not a wall-clock timeout. Compilation has separate length,
nesting, and per-program instruction limits. Counted repetitions use counters
and do not expand the program per repetition. These controls do not make this
a linear-time engine.

Other error reasons are `Regex.Syntax` (with zero-based `Detail[Position]`),
`Regex.Options`, `Regex.Argument`, and `Regex.Replacement`. Compiled records
are intended for reuse, not arbitrary editing; their internal format may
change in a future version.

## Testing with the installed Power Query engine

The engine library is pure M. The development tests run in Windows PowerShell
5.1 against Microsoft's Mashup runtime installed by Excel or Power BI. No Excel
process or worksheet is created.

```powershell
powershell.exe -NoProfile -File .\tests\TestAll.ps1
powershell.exe -NoProfile -File .\tests\TestAll.ps1 -ResultsPath .\tests\results.json
```

The test rows follow [MGIS's test contract](https://github.com/sancarn/mgis/blob/master/tests/UnitTests.m):
`parent`, `description`, `tags`, `passed`, `expected`, and `actual`. Assertions
force nested M values inside `try`, so lazy errors cannot become passing tests.
The runner discovers every `Test*.m`, prints failures, optionally writes the
actual result rows as JSON, and exits nonzero on failure or empty suites.

It prefers the result-returning `Invoke-Mashup` host from the sibling
`powershell-mashup` project. Supply `-MashupModulePath` (or `MASHUP_MODULE_PATH`)
for a different location. With no module, it uses a standalone MGIS-style
minimal host that returns the complete JSON result rather than only a byte
count. `-UseMinimalHost` explicitly tests that path. Both support `-EnginePath`
and `MASHUP_ENGINE_PATH`; automatic discovery checks standard Excel and
Power BI installation paths. Runtime compatibility depends on Microsoft's
installed internal hosting interfaces.

```powershell
powershell.exe -NoProfile -File .\tests\TestAll.ps1 -UseMinimalHost
powershell.exe -NoProfile -File .\tests\TestDifferential.ps1 `
    -MashupModulePath C:\path\to\powershell-mashup\src\PowerShellMashup.psd1
```

`TestDifferential.ps1` generates independent .NET Regex expectations and checks
whole-match and capture values/spans against the M VM. It requires the optional
`powershell-mashup` module. Its corpus deliberately covers the common syntax;
the .NET engine is never called by `Regex.m`. The ordinary M suites separately
cover dialect differences, Unicode units, malformed patterns, replacements,
execution limits, and long consuming loops. See
[docs/architecture.md](docs/architecture.md) for the compiler and VM design.

## References

The implementation is written for M's immutable values and lazy evaluation.
The following projects informed its design and testing:

- [sihlfall/vba-regex](https://github.com/sihlfall/vba-regex), particularly its
  [bytecode definitions](https://github.com/sihlfall/vba-regex/blob/master/src/RegexBytecode.bas)
  and [nullable repetition analysis](https://github.com/sihlfall/vba-regex/blob/master/doc/nullable_priority.md).
- [ASF_RegexEngine](https://github.com/ECP-Solutions/ASF/blob/main/src/ASF_RegexEngine.cls),
  for the AST/lowering separation, regex API, capture behavior, and explicit limits.
- [MGIS](https://github.com/sancarn/mgis), for M assertion records, suite discovery,
  and execution through the installed Mashup engine.
- The local `powershell-mashup` project, for returning actual M values to the
  PowerShell pipeline. Its implementation remains an optional development dependency.
