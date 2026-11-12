# Parser, compiler, and virtual machine

`Regex.m` is a single importable M expression returning a record of functions.
There is no generated binary or host regex call. PowerShell and .NET are used
only by the development test infrastructure.

## Parsing

The recursive-descent grammar is `expression = sequence ('|' sequence)*`,
`sequence = piece*`, and `piece = atom quantifier?`. Sequences, alternatives,
class scanning, and decimal scanning iterate with `List.Generate`. Only nested
groups recurse, subject to `MaxDepth`.

Each parse result carries a node, the next input offset, a group count, and the
name-to-group mapping. After parsing, a traversal resolves numbered and named
backreferences against the complete group table. This allows syntactically
valid forward references; they fail at runtime until a capture exists.

Nodes are plain M records: `Sequence`, `Alternation`, `Literal`, `Any`, `Set`,
`Class`, `Anchor`, `Capture`, `Backref`, `Repeat`, `Look`, and `Atomic`.
Possessive repetition lowers to an atomic wrapper around a greedy repeat.
M errors include their pattern offset. Parsing and compilation explicitly
serialize their result to force all nested lazy fields, including otherwise
unused alternatives, before returning a usable result.

## Compilation

The compiler builds a buffered list of instruction records. Addresses are
zero-based list indices. `Program[Entry]` identifies the first instruction;
it is not necessarily index zero. Index zero is the accepting `Match`.

Lowering takes a node, a continuation address, and the existing instruction
list. A sequence is lowered right to left. All alternative branches point to
the same continuation, and ordered `Split` instructions connect their entries.
This avoids an address-patching pass for ordinary branches.

- `Literal`, `Any`, `Set`, and `Class` test a unit and advance to `Next`.
- `Anchor` tests the current boundary without consuming.
- `Backref` compares a captured slice and advances by its length.
- `Save` writes the current offset to a capture slot and advances to `Next`.
  Group `g` uses slots `2*g` and `2*g+1`. The whole match is recorded by search.
- `Split` tries `X`, saving `Y` as a backtracking choice.
- `RepeatInit` resets a counter and jumps to its `Repeat` instruction.
- `Repeat` tests minimum/maximum counts, then orders the body and continuation
  according to greedy or lazy preference.
- `RepeatEnd` increments the counter. It returns to `Repeat`, or advances to
  the continuation after a zero-progress iteration once the minimum is met.
- `Look` and `Atomic` contain separately compiled subprograms. Lookbehind also
  stores its statically computed width. Variable widths are compile errors.
- `Match` accepts the current frame.

A repeat reserves its head address, emits its tail and body, then fills the
head with the body address. This is the only local fixup. `a{1000000}` has five
instructions, the same count as `a{1}`. Programs are ordinary inspectable M
data, for example `Table.FromRecords(Regex[Compile]("(a|b)+")[Program][Code])`.
Different opcode shapes produce missing/null columns when converted to a table.

## VM state

The VM's current frame contains `PC`, `Pos`, `Caps`, and `Repeats`. The choice
stack contains complete immutable frames, so popping a choice restores both
captures and repeat counters. Input text and the program are shared.

`List.Generate` dispatches instructions until success or exhaustion of the
choice stack. Matching a long string does not add one M function call per
character. Atomic and assertion subprograms call the same VM, with call depth
bounded by `MaxDepth`; their internal loops still iterate. Positive assertions
return capture changes without advancing the outer input position. Negative
assertions discard those changes. Atomic groups advance and retain captures
from their first successful internal path. None retain internal choices after
returning to the outer VM.

Nullable loops need special care: after a successful empty body, the VM exits
the loop once the minimum count is met, preserving that iteration's captures.
Previously saved alternatives remain available if the continuation fails.
There is no global visited-state cache that could incorrectly merge paths with
different captures or backreferences.

Search invokes the VM at consecutive input offsets, including the end offset.
The first successful path wins. Global enumeration continues after the match,
advancing one unit after an empty match. Every attempt and subprogram receives
the same cumulative instruction count. `MaxSteps` therefore bounds a complete
search/global operation, rather than resetting at each candidate position.

## Tradeoffs

Immutable records make backtracking restoration straightforward, and counted
loops keep bytecode compact. This first implementation prioritizes clear
semantics and testable stages over specialized automata and search prefilters.
It does not include NFA/DFA execution, JIT compilation, prefix acceleration,
capture history, or a process-global compiled-pattern cache. Callers should
reuse `Compile` results.

Instruction budgeting bounds the number of VM dispatches, not elapsed time,
allocation cost, output size, or the cost of M string/list operations. Parsing
and compilation also use immutable lists, and can be more expensive for very
large patterns. M text uses UTF-16 units; comparisons use ordinal text operations
so isolated surrogates do not pass through `Character.ToNumber`, which rejects
them. JSON is used only to force validation and by tests; no serialized AST is
interpreted by the matching loop.
