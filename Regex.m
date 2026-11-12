// Pure Power Query M. Paste this expression into a query named Regex.
let
    Fail = (reason as text, message as text, detail as any) as any =>
        error Error.Record(reason, message, detail),
    Syntax = (message as text, position as number) as any =>
        Fail("Regex.Syntax", message, [Position = position]),
    Int = (value as any, name as text, minimum as number) as number =>
        if not Value.Is(value, type number) then Fail("Regex.Options", name & " must be an integer.", value)
        else if Number.IsNaN(value) or value = #infinity or value = -#infinity then Fail("Regex.Options", name & " must be finite.", value)
        else if value < minimum or value <> Number.RoundDown(value) or value > 2147483647 then Fail("Regex.Options", name & " is out of range.", value)
        else value,
    Options = (options as nullable record) as record =>
        let
            defaults = [IgnoreCase = false, Multiline = false, DotAll = false,
                MaxSteps = 1000000, MaxPatternLength = 10000, MaxDepth = 64, MaxProgramSize = 20000],
            supplied = if options = null then [] else options,
            unknown = List.Difference(Record.FieldNames(supplied), Record.FieldNames(defaults)),
            merged = defaults & supplied,
            flags = List.Transform({"IgnoreCase", "Multiline", "DotAll"}, (key) =>
                if Value.Is(Record.Field(merged, key), type logical) then Record.Field(merged, key)
                else Fail("Regex.Options", key & " must be logical.", Record.Field(merged, key))),
            limits = List.Transform({"MaxSteps", "MaxPatternLength", "MaxDepth", "MaxProgramSize"},
                (key) => Int(Record.Field(merged, key), key, 1)),
            checked = Record.FromList(flags & limits, Record.FieldNames(defaults))
        in
            if not List.IsEmpty(unknown) then Fail("Regex.Options", "Unknown option.", unknown)
            else if List.Count(List.Select(Record.FieldValues(checked), each _ <> null)) = 7 then checked
            else Fail("Regex.Options", "Invalid options.", supplied),
    Ch = (s as text, p as number) as text => if p < 0 or p >= Text.Length(s) then "" else Text.Middle(s, p, 1),
    // Character.FromNumber rejects standalone surrogates; take the appropriate
    // UTF-16 unit from a valid supplementary scalar for \uD800..\uDFFF.
    FromUnit = (n as number) as text =>
        if n >= 55296 and n <= 56319 then Ch(Character.FromNumber(65536 + (n - 55296) * 1024), 0)
        else if n >= 56320 and n <= 57343 then Ch(Character.FromNumber(65536 + n - 56320), 1)
        else Character.FromNumber(n),
    Digit = (c as text) as logical => c <> "" and Text.Contains("0123456789", c, Comparer.Ordinal),
    Word = (c as text) as logical => c <> "" and Text.Contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_", c, Comparer.Ordinal),
    Key = (n as number) as text => Number.ToText(n, "0", "en-US"),
    Put = (r as record, key as text, value as any) as record => Record.AddField(Record.RemoveFields(r, {key}, MissingField.Ignore), key, value),
    Seq = (nodes as list) as record => [Kind = "Sequence", Children = nodes],

    ParseCore = (pattern as text, opt as record) as record =>
        let
            length = Text.Length(pattern),
            At = (p) => Ch(pattern, p),
            // Every parse result carries its next offset and capture symbol table.
            Result = (node, p, groups, names) => [Node = node, P = p, Groups = groups, Names = names],
            NameAt = (p as number) as record =>
                let end = p + Text.PositionOf(Text.Range(pattern, p), ">"), name = Text.Middle(pattern, p, end - p)
                in if end < p then Syntax("Expected '>'.", p)
                   else if name = "" or Digit(Ch(name, 0)) or not List.AllTrue(List.Transform(Text.ToList(name), Word)) then Syntax("Invalid capture name.", p)
                   else [Name = name, P = end + 1],
            DigitsAt = (p as number) as record =>
                let chars = List.Generate(() => p, each Digit(At(_)), each _ + 1, each At(_)),
                    value = if List.IsEmpty(chars) then Syntax("Expected a decimal integer.", p) else Number.FromText(Text.Combine(chars), "en-US")
                in [Value = if value > 1000000 then Syntax("Repeat count or reference exceeds 1000000.", p) else value, P = p + List.Count(chars)],
            EscapeAt = (p as number, inClass as logical) as record =>
                let
                    c = At(p + 1),
                    simple = [n = "#(lf)", r = "#(cr)", t = "#(tab)", f = Character.FromNumber(12), v = Character.FromNumber(11), #"0" = Character.FromNumber(0)],
                    hexLength = if c = "x" then 2 else 4,
                    hex = Text.Middle(pattern, p + 2, hexLength),
                    hexDigits = Text.ToList(Text.Upper(hex)),
                    hexValue = List.Accumulate(hexDigits, 0, (s, d) => s * 16 + Text.PositionOf("0123456789ABCDEF", d)),
                    number = if Digit(c) and c <> "0" then DigitsAt(p + 1) else null,
                    named = if c = "k" and At(p + 2) = "<" then NameAt(p + 3) else null
                in
                    if c = "" then Syntax("Trailing backslash.", p)
                    else if List.Contains({"d", "D", "w", "W", "s", "S"}, c) then [Node = [Kind = "Set", Class = c], P = p + 2]
                    else if c = "b" and inClass then [Node = [Kind = "Literal", Value = Character.FromNumber(8)], P = p + 2]
                    else if List.Contains({"b", "B", "A", "z", "Z"}, c) and not inClass then [Node = [Kind = "Anchor", Value = c], P = p + 2]
                    else if Record.HasFields(simple, c) then
                        if c = "0" and Digit(At(p + 2)) then Syntax("Octal escapes are not supported.", p)
                        else [Node = [Kind = "Literal", Value = Record.Field(simple, c)], P = p + 2]
                    else if c = "x" or c = "u" then
                        if Text.Length(hex) <> hexLength or not List.AllTrue(List.Transform(hexDigits, each Text.Contains("0123456789ABCDEF", _))) then Syntax("Invalid hexadecimal escape.", p)
                        else [Node = [Kind = "Literal", Value = FromUnit(hexValue)], P = p + 2 + hexLength]
                    else if number <> null and not inClass then [Node = [Kind = "Backref", Ref = number[Value], Position = p], P = number[P]]
                    else if named <> null and not inClass then [Node = [Kind = "Backref", Ref = named[Name], Position = p], P = named[P]]
                    else if List.Contains(Text.ToList("\.^$|?*+()[]{}-/"), c) then [Node = [Kind = "Literal", Value = c], P = p + 2]
                    else Syntax("Unsupported escape '\" & c & "'.", p),
            ClassAt = (p as number) as record =>
                let
                    negative = At(p + 1) = "^",
                    start = p + (if negative then 2 else 1),
                    Item = (q) => if At(q) = "\" then EscapeAt(q, true) else [Node = [Kind = "Literal", Value = At(q)], P = q + 1],
                    Next = (s) =>
                        if s[P] >= length then Syntax("Unclosed character class.", p)
                        else if At(s[P]) = "]" then s & [Done = true, P = s[P] + 1]
                        else let
                            a = Item(s[P]),
                            range = At(a[P]) = "-" and At(a[P] + 1) <> "]" and At(a[P] + 1) <> "",
                            b = if range then Item(a[P] + 1) else null,
                            node = if not range then a[Node]
                                else if a[Node][Kind] <> "Literal" or b[Node][Kind] <> "Literal" then Syntax("Range endpoints must be characters.", s[P])
                                else if Comparer.Ordinal(a[Node][Value], b[Node][Value]) > 0 then Syntax("Reversed character range.", s[P])
                                else [Kind = "Range", Low = a[Node][Value], High = b[Node][Value]]
                        in [P = if range then b[P] else a[P], Items = s[Items] & {node}, Done = false],
                    states = List.Generate(() => [P = start, Items = {}, Done = false], each _ <> null, each if [Done] then null else Next(_)),
                    last = List.Last(states)
                in [Node = [Kind = "Class", Negate = negative, Items = last[Items]], P = last[P]],
            Atom = (p as number, groups as number, names as record, depth as number) as record =>
                let c = At(p) in
                if c = "(" then
                    if depth >= opt[MaxDepth] then Fail("Regex.Limit", "Pattern nesting limit exceeded.", [Position = p])
                    else let
                        special = At(p + 1) = "?", mark = At(p + 2),
                        behind = special and mark = "<" and List.Contains({"=", "!"}, At(p + 3)),
                        named = special and mark = "<" and not behind,
                        name = if named then NameAt(p + 3) else null,
                        capture = not special or named,
                        kind = if not special or named or mark = ":" then "Group"
                            else if mark = ">" then "Atomic"
                            else if behind or List.Contains({"=", "!"}, mark) then "Look"
                            else Syntax("Unsupported group prefix (inline flags, recursion, and conditionals are not supported).", p),
                        newGroups = groups + (if capture then 1 else 0),
                        newNames = if not named then names else if Record.HasFields(names, name[Name]) then Syntax("Duplicate capture name.", p) else Record.AddField(names, name[Name], newGroups),
                        begin = if not special then p + 1 else if named then name[P] else if behind then p + 4 else p + 3,
                        body = Expression(begin, newGroups, newNames, depth + 1),
                        node = if kind = "Group" then if capture then [Kind = "Capture", Index = newGroups, Child = body[Node]] else body[Node]
                            else if kind = "Atomic" then [Kind = "Atomic", Child = body[Node]]
                            else [Kind = "Look", Positive = (if behind then At(p + 3) else mark) = "=", Behind = behind, Child = body[Node], Position = p]
                    in if At(body[P]) <> ")" then Syntax("Unclosed group.", p) else Result(node, body[P] + 1, body[Groups], body[Names])
                else if c = "[" then let a = ClassAt(p) in Result(a[Node], a[P], groups, names)
                else if c = "\" then let a = EscapeAt(p, false) in Result(a[Node], a[P], groups, names)
                else if c = "." then Result([Kind = "Any"], p + 1, groups, names)
                else if c = "^" or c = "$" then Result([Kind = "Anchor", Value = c], p + 1, groups, names)
                else if List.Contains({"*", "+", "?", "{", "}", "]"}, c) then Syntax("Unexpected metacharacter; escape it for a literal.", p)
                else Result([Kind = "Literal", Value = c], p + 1, groups, names),
            Piece = (p, groups, names, depth) =>
                let
                    a = Atom(p, groups, names, depth), q = At(a[P]),
                    quantified = List.Contains({"*", "+", "?", "{"}, q),
                    first = if q = "{" then DigitsAt(a[P] + 1) else null,
                    comma = if q = "{" then At(first[P]) = "," else false,
                    second = if comma and At(first[P] + 1) <> "}" then DigitsAt(first[P] + 1) else null,
                    close = if q <> "{" then a[P] else if not comma then first[P] else if second = null then first[P] + 1 else second[P],
                    low = if q = "+" then 1 else if q = "{" then first[Value] else 0,
                    high = if q = "?" then 1 else if q <> "{" then null else if not comma then low else if second = null then null else second[Value],
                    after = if q = "{" then close + 1 else a[P] + 1,
                    modifier = At(after),
                    repeat = [Kind = "Repeat", Min = low, Max = high, Lazy = modifier = "?", Child = a[Node]],
                    node = if modifier = "+" then [Kind = "Atomic", Child = repeat] else repeat
                in if not quantified then a
                   else if List.Contains({"Anchor", "Look"}, a[Node][Kind]) then Syntax("Cannot quantify an assertion.", a[P])
                   else if q = "{" and At(close) <> "}" then Syntax("Unclosed repeat count.", a[P])
                   else if high <> null and high < low then Syntax("Repeat maximum is smaller than minimum.", a[P])
                   else Result(node, after + (if modifier = "?" or modifier = "+" then 1 else 0), a[Groups], a[Names]),
            Sequence = (p, groups, names, depth) =>
                let
                    states = List.Generate(() => [P = p, Groups = groups, Names = names, Nodes = {}, Done = false],
                        each _ <> null,
                        each if [Done] then null
                            else if [P] >= length or List.Contains({"|", ")"}, At([P])) then _ & [Done = true]
                            else let a = Piece([P], [Groups], [Names], depth) in [P = a[P], Groups = a[Groups], Names = a[Names], Nodes = [Nodes] & {a[Node]}, Done = false]),
                    last = List.Last(states)
                in Result(Seq(last[Nodes]), last[P], last[Groups], last[Names]),
            Expression = (p, groups, names, depth) =>
                let
                    initial = Sequence(p, groups, names, depth),
                    states = List.Generate(() => initial & [Nodes = {initial[Node]}, Done = false], each _ <> null,
                        each if [Done] then null
                            else if At([P]) <> "|" then _ & [Done = true]
                            else let a = Sequence([P] + 1, [Groups], [Names], depth) in a & [Nodes = [Nodes] & {a[Node]}, Done = false]),
                    last = List.Last(states)
                in Result(if List.Count(last[Nodes]) = 1 then last[Nodes]{0} else [Kind = "Alternation", Children = last[Nodes]], last[P], last[Groups], last[Names]),
            parsed = if length > opt[MaxPatternLength] then Fail("Regex.Limit", "Pattern length limit exceeded.", length) else Expression(0, 0, [], 0),
            // Resolve references only after the complete symbol table is available.
            Resolve = (node as record) as record =>
                if node[Kind] = "Backref" then
                    let ref = node[Ref], index = if Value.Is(ref, type number) then ref else Record.FieldOrDefault(parsed[Names], ref, -1)
                    in if index < 1 or index > parsed[Groups] then Syntax("Backreference refers to an unknown group.", node[Position]) else node & [Index = index]
                else if Record.HasFields(node, "Children") then node & [Children = List.Transform(node[Children], each @Resolve(_))]
                else if Record.HasFields(node, "Child") then node & [Child = @Resolve(node[Child])]
                else node,
            ast = Resolve(parsed[Node]),
            // Deep forcing prevents errors in unused alternatives from hiding until matching.
            forced = Binary.Length(Json.FromValue(ast))
        in if parsed[P] <> length then Syntax("Unexpected ')'.", parsed[P])
           else if forced >= 0 then [Pattern = pattern, Ast = ast, GroupCount = parsed[Groups], Names = parsed[Names], Options = opt]
           else error "Unreachable",
    Parse = (pattern as text, optional options as nullable record) as record => ParseCore(pattern, Options(options)),

    Width = (node as record) as nullable number =>
        let kind = node[Kind] in
        if List.Contains({"Literal", "Any", "Set", "Class"}, kind) then 1
        else if List.Contains({"Anchor", "Look"}, kind) then 0
        else if kind = "Backref" then null
        else if kind = "Capture" or kind = "Atomic" then @Width(node[Child])
        else if kind = "Repeat" then
            let w = @Width(node[Child]) in if node[Max] = node[Min] and w <> null then w * node[Min] else if w = 0 then 0 else null
        else let widths = List.Transform(node[Children], each @Width(_)) in
            if List.Contains(widths, null) then null
            else if kind = "Sequence" then List.Sum({0} & widths)
            else if List.Count(List.Distinct(widths)) = 1 then widths{0} else null,
    Build = (ast as record, opt as record) as record =>
        let
            Emit = (code, instruction) =>
                if List.Count(code) >= opt[MaxProgramSize] then Fail("Regex.Limit", "Program size limit exceeded.", opt[MaxProgramSize])
                else [Code = code & {instruction}, Entry = List.Count(code)],
            Lower = (node as record, next as number, code as list) as record =>
                let kind = node[Kind] in
                if kind = "Sequence" then List.Accumulate(List.Reverse(node[Children]), [Code = code, Entry = next], (s, child) => @Lower(child, s[Entry], s[Code]))
                else if kind = "Alternation" then
                    let branches = List.Accumulate(List.Reverse(node[Children]), [Code = code, Entry = null], (s, child) =>
                        let b = @Lower(child, next, s[Code]) in if s[Entry] = null then b else Emit(b[Code], [Op = "Split", X = b[Entry], Y = s[Entry]]))
                    in branches
                else if kind = "Capture" then
                    let end = Emit(code, [Op = "Save", Slot = 2 * node[Index] + 1, Next = next]),
                        body = @Lower(node[Child], end[Entry], end[Code])
                    in Emit(body[Code], [Op = "Save", Slot = 2 * node[Index], Next = body[Entry]])
                else if kind = "Repeat" then
                    let
                        head = Emit(code, [Op = "Reserved"]), id = head[Entry],
                        tail = Emit(head[Code], [Op = "RepeatEnd", Id = id, Next = next, Min = node[Min]]),
                        body = @Lower(node[Child], tail[Entry], tail[Code]),
                        instruction = [Op = "Repeat", Id = id, Body = body[Entry], Next = next, Min = node[Min], Max = node[Max], Lazy = node[Lazy]],
                        patched = List.ReplaceRange(body[Code], id, 1, {instruction})
                    in Emit(patched, [Op = "RepeatInit", Id = id, Next = id])
                else if kind = "Look" or kind = "Atomic" then
                    let w = if kind = "Look" and node[Behind] then Width(node[Child]) else 0,
                        sub = @Build(node[Child], opt)
                    in if w = null then Syntax("Lookbehind must have a fixed width.", node[Position])
                       else Emit(code, [Op = kind, Program = sub, Width = w,
                           Positive = Record.FieldOrDefault(node, "Positive", true), Behind = Record.FieldOrDefault(node, "Behind", false), Next = next])
                else Emit(code, [Op = kind, Arg = node, Next = next]),
            built = Lower(ast, 0, {[Op = "Match"]})
        in [Code = List.Buffer(built[Code]), Entry = built[Entry]],
    Compile = (pattern as text, optional options as nullable record) as record =>
        let parsed = Parse(pattern, options), program = Build(parsed[Ast], parsed[Options]), forced = Binary.Length(Json.FromValue(program))
        in if forced >= 0 then parsed & [Version = 1, Program = program] else error "Unreachable",
    Prepared = (pattern as any, options as nullable record) as record =>
        if Value.Is(pattern, type text) then Compile(pattern, options)
        else if not Value.Is(pattern, type record) then Fail("Regex.Argument", "Expected pattern text or a compiled pattern.", null)
        else if options <> null then Fail("Regex.Argument", "Set options when compiling; do not pass options with a compiled pattern.", null)
        else if not Record.HasFields(pattern, {"Version", "Program", "Options", "GroupCount", "Names"}) then Fail("Regex.Argument", "Invalid compiled pattern.", null)
        else if pattern[Version] <> 1 then Fail("Regex.Argument", "Unsupported compiled pattern version.", pattern[Version])
        else pattern,
    EqualText = (a as text, b as text, opt as record) as logical =>
        (if opt[IgnoreCase] then Comparer.OrdinalIgnoreCase(a, b) else Comparer.Ordinal(a, b)) = 0,
    SetContains = (name as text, c as text) as logical =>
        let lower = Text.Lower(name), hit = if lower = "d" then Digit(c) else if lower = "w" then Word(c)
            else List.Contains({" ", "#(tab)", "#(cr)", "#(lf)", Character.FromNumber(11), Character.FromNumber(12)}, c)
        in c <> "" and (if name = lower then hit else not hit),
    ClassContains = (item as record, c as text, opt as record) as logical =>
        if item[Kind] = "Literal" then EqualText(item[Value], c, opt)
        else if item[Kind] = "Set" then SetContains(item[Class], c)
        else let
            candidates = if opt[IgnoreCase] then {c, Text.Lower(c, "en-US"), Text.Upper(c, "en-US")} else {c}
        in List.AnyTrue(List.Transform(candidates, each Comparer.Ordinal(_, item[Low]) >= 0 and Comparer.Ordinal(_, item[High]) <= 0)),

    // Each choice saves PC, input position, capture slots and repeat counters.
    // Only lookaround/atomic subprogram calls recurse; consuming loops use List.Generate.
    Run = (program as record, input as text, start as number, captures as record, opt as record,
           used as number, requiredEnd as nullable number, depth as number) as record =>
        let
            code = program[Code], size = Text.Length(input),
            Frame = (pc, pos, caps, repeats) => [PC = pc, Pos = pos, Caps = caps, Repeats = repeats],
            initial = [Current = Frame(program[Entry], start, captures, []), Stack = {}, Steps = used, Done = false, Found = null],
            Step = (state as record) as record =>
                if state[Steps] >= opt[MaxSteps] then Fail("Regex.Limit", "VM instruction budget exceeded.", [MaxSteps = opt[MaxSteps], Position = state[Current][Pos]])
                else let
                    f = state[Current], pc = f[PC], pos = f[Pos], caps = f[Caps], repeats = f[Repeats],
                    instruction = code{pc}, op = instruction[Op], steps = state[Steps] + 1,
                    Continue = (frame) => state & [Current = frame, Steps = steps],
                    Advance = (newPos) => Continue(f & [PC = instruction[Next], Pos = newPos]),
                    Reject = () => if List.IsEmpty(state[Stack]) then state & [Steps = steps, Done = true]
                        else state & [Current = state[Stack]{0}, Stack = List.Skip(state[Stack]), Steps = steps],
                    Choice = (first, second) => state & [Current = first, Stack = {second} & state[Stack], Steps = steps],
                    c = Ch(input, pos), arg = Record.FieldOrDefault(instruction, "Arg", null)
                in
                    if op = "Match" then if requiredEnd <> null and pos <> requiredEnd then Reject()
                        else state & [Steps = steps, Done = true, Found = f]
                    else if op = "Split" then Choice(f & [PC = instruction[X]], f & [PC = instruction[Y]])
                    else if op = "Save" then Continue(f & [PC = instruction[Next], Caps = Put(caps, Key(instruction[Slot]), pos)])
                    else if op = "RepeatInit" then Continue(f & [PC = instruction[Next], Repeats = Put(repeats, Key(instruction[Id]), [Count = 0, Start = pos])])
                    else if op = "Repeat" then
                        let r = Record.Field(repeats, Key(instruction[Id])),
                            body = f & [PC = instruction[Body], Repeats = Put(repeats, Key(instruction[Id]), r & [Start = pos])],
                            exit = f & [PC = instruction[Next]]
                        in if r[Count] < instruction[Min] then Continue(body)
                            else if instruction[Max] <> null and r[Count] >= instruction[Max] then Continue(exit)
                            else if instruction[Lazy] then Choice(exit, body) else Choice(body, exit)
                    else if op = "RepeatEnd" then
                        let id = Key(instruction[Id]), r = Record.Field(repeats, id), count = r[Count] + 1,
                            target = if pos = r[Start] and count >= instruction[Min] then instruction[Next] else instruction[Id]
                        in Continue(f & [PC = target, Repeats = Put(repeats, id, r & [Count = count])])
                    else if op = "Look" or op = "Atomic" then
                        let
                            begin = pos - instruction[Width],
                            sub = if begin < 0 then [Found = null, Steps = steps]
                                else if depth >= opt[MaxDepth] then Fail("Regex.Limit", "VM call depth exceeded.", depth)
                                else @Run(instruction[Program], input, begin, caps, opt, steps, if instruction[Behind] then pos else null, depth + 1),
                            matched = sub[Found] <> null,
                            accepted = if op = "Atomic" or instruction[Positive] then matched else not matched,
                            result = if not accepted then Reject()
                                else Continue(f & [PC = instruction[Next],
                                    Pos = if op = "Atomic" then sub[Found][Pos] else pos,
                                    Caps = if matched and instruction[Positive] then sub[Found][Caps] else caps])
                        in result & [Steps = sub[Steps]]
                    else if op = "Anchor" then
                        let anchor = arg[Value], hit =
                            if anchor = "A" then pos = 0
                            else if anchor = "z" then pos = size
                            else if anchor = "^" then pos = 0 or (opt[Multiline] and Ch(input, pos - 1) = "#(lf)")
                            else if anchor = "$" or anchor = "Z" then pos = size or (c = "#(lf)" and (pos = size - 1 or (anchor = "$" and opt[Multiline])))
                            else let boundary = Word(Ch(input, pos - 1)) <> Word(c) in if anchor = "b" then boundary else not boundary
                        in if hit then Advance(pos) else Reject()
                    else if op = "Backref" then
                        let a = Record.FieldOrDefault(caps, Key(2 * arg[Index]), null), b = Record.FieldOrDefault(caps, Key(2 * arg[Index] + 1), null),
                            count = if a = null or b = null then -1 else b - a
                        in if count < 0 then Reject()
                           else if pos + count <= size and EqualText(Text.Middle(input, a, count), Text.Middle(input, pos, count), opt) then Advance(pos + count) else Reject()
                    else if c = "" then Reject()
                    else if op = "Literal" then if EqualText(arg[Value], c, opt) then Advance(pos + 1) else Reject()
                    else if op = "Any" then if opt[DotAll] or (c <> "#(lf)" and c <> "#(cr)") then Advance(pos + 1) else Reject()
                    else if op = "Set" then if SetContains(arg[Class], c) then Advance(pos + 1) else Reject()
                    else if op = "Class" then
                        let hit = List.AnyTrue(List.Transform(arg[Items], each ClassContains(_, c, opt)))
                        in if hit <> arg[Negate] then Advance(pos + 1) else Reject()
                    else Fail("Regex.Program", "Unknown opcode.", op),
            states = List.Generate(() => initial, each _ <> null, each if [Done] then null else Step(_)),
            final = List.Last(states)
        in [Found = final[Found], Steps = final[Steps]],
    MatchRecord = (compiled as record, input as text, start as number, frame as record) as record =>
        let
            Capture = (index) =>
                let a = if index = 0 then start else Record.FieldOrDefault(frame[Caps], Key(2 * index), null),
                    b = if index = 0 then frame[Pos] else Record.FieldOrDefault(frame[Caps], Key(2 * index + 1), null),
                    success = a <> null and b <> null and b >= a
                in [Success = success, Index = if success then a else -1, Length = if success then b - a else 0, Value = if success then Text.Middle(input, a, b - a) else null],
            groups = List.Transform({0..compiled[GroupCount]}, Capture),
            named = Record.FromList(List.Transform(Record.FieldValues(compiled[Names]), each groups{_}), Record.FieldNames(compiled[Names]))
        in groups{0} & [Groups = groups, NamedGroups = named],
    Find = (compiled as record, input as text, start as number, used as number) as record =>
        let
            size = Text.Length(input),
            states = List.Generate(() => [P = start, Steps = used, Match = null, Done = start > size], each _ <> null,
                each if [Done] then null else
                    let result = Run(compiled[Program], input, [P], [], compiled[Options], [Steps], null, 0),
                        hit = if result[Found] = null then null else MatchRecord(compiled, input, [P], result[Found])
                    in [P = [P] + 1, Steps = result[Steps], Match = hit, Done = hit <> null or [P] >= size]),
            last = List.Last(states)
        in [Match = last[Match], Steps = last[Steps]],
    Match = (input as text, pattern as any, optional options as nullable record, optional startAt as nullable number) as nullable record =>
        let compiled = Prepared(pattern, options), start = if startAt = null then 0 else Int(startAt, "startAt", 0)
        in if compiled[Version] = 1 then Find(compiled, input, start, 0)[Match] else error "Unreachable",
    Test = (input as text, pattern as any, optional options as nullable record) as logical => Match(input, pattern, options) <> null,
    All = (compiled as record, input as text) as list =>
        List.Generate(() => Find(compiled, input, 0, 0), each [Match] <> null,
            each Find(compiled, input, [Match][Index] + List.Max({1, [Match][Length]}), [Steps]), each [Match]),
    Matches = (input as text, pattern as any, optional options as nullable record) as list => All(Prepared(pattern, options), input),
    // stdRegex.List's legacy format is deliberately separate from Replace's
    // token syntax: substitutions run in order, including inside inserted text.
    ListMatches = (input as text, pattern as any, format as text, optional options as nullable record) as text =>
        let
            compiled = Prepared(pattern, options),
            names = List.Sort(Record.FieldNames(compiled[Names]), (a, b) =>
                if Text.Length(a) <> Text.Length(b) then Value.Compare(Text.Length(a), Text.Length(b)) else Comparer.Ordinal(a, b)),
            // Pick escape sentinels absent from both the format and all captures.
            Marker = (seed) => List.Last(List.Generate(() => seed, each _ <> null,
                each if Text.Contains(input, _) or Text.Contains(format, _) then _ & "_" else null)),
            slash = Marker("#regex-m-backslash#"), dollar = Marker("#regex-m-dollar#"),
            FormatMatch = (m) =>
                let
                    Value = (g) => if g[Success] then g[Value] else "",
                    whole = Text.Replace(format, "$&", m[Value]),
                    escapes = Text.Replace(Text.Replace(Text.Replace(Text.Replace(whole,
                        "\\", slash), "\$", dollar), "\r", "#(cr)"), "\n", "#(lf)"),
                    restoredSlash = Text.Replace(escapes, slash, "\"),
                    numbered = List.Accumulate({0..compiled[GroupCount]}, restoredSlash,
                        (s, i) => Text.Replace(s, "$" & Key(i), Value(m[Groups]{i}))),
                    named = List.Accumulate(names, numbered,
                        (s, name) => Text.Replace(s, "$" & name, Value(Record.Field(m[NamedGroups], name))))
                in Text.Replace(named, dollar, "$" )
        in Text.Combine(List.Transform(All(compiled, input), FormatMatch)),
    Expand = (replacement as text, match as record) as text =>
        let
            size = Text.Length(replacement),
            Part = (p as number) as record =>
                let c = Ch(replacement, p), next = Ch(replacement, p + 1),
                    digits = if c = "$" and Digit(next) then List.Generate(() => p + 1, each Digit(Ch(replacement, _)), each _ + 1, each Ch(replacement, _)) else {},
                    end = if c = "$" and next = "{" then Text.PositionOf(Text.Range(replacement, p + 2), "}") else -1,
                    name = if end >= 0 then Text.Middle(replacement, p + 2, end) else "",
                    group = if not List.IsEmpty(digits) then
                        let index = Number.FromText(Text.Combine(digits), "en-US") in if index < List.Count(match[Groups]) then match[Groups]{index} else Fail("Regex.Replacement", "Unknown group number.", index)
                        else if c = "$" and next = "{" then
                            if end < 0 then Fail("Regex.Replacement", "Unclosed group name.", p)
                            else if Record.HasFields(match[NamedGroups], name) then Record.Field(match[NamedGroups], name)
                            else Fail("Regex.Replacement", "Unknown group name.", name)
                        else null
                in if c <> "$" then [Text = c, Next = p + 1]
                   else if next = "$" then [Text = "$", Next = p + 2]
                   else if next = "&" then [Text = match[Value], Next = p + 2]
                   else if group <> null then [Text = if group[Success] then group[Value] else "", Next = if next = "{" then p + end + 3 else p + List.Count(digits) + 1]
                   else [Text = "$", Next = p + 1],
            parts = List.Generate(() => [P = 0, Part = null], each [P] <= size,
                each if [P] = size then [P = size + 1, Part = null] else let v = Part([P]) in [P = v[Next], Part = v[Text]], each [Part])
        in Text.Combine(List.RemoveNulls(parts)),
    Replace = (input as text, pattern as any, replacement as any, optional options as nullable record) as text =>
        let
            valid = Value.Is(replacement, type text) or Value.Is(replacement, type function),
            matches = if valid then Matches(input, pattern, options) else Fail("Regex.Argument", "Replacement must be text or a function.", null),
            result = List.Accumulate(matches, [P = 0, Parts = {}], (s, m) =>
                let value = if Value.Is(replacement, type function) then replacement(m) else Expand(replacement, m)
                in if not Value.Is(value, type text) then Fail("Regex.Replacement", "Replacement callback must return text.", null)
                   else [P = m[Index] + m[Length], Parts = s[Parts] & {Text.Middle(input, s[P], m[Index] - s[P]), value}])
        in Text.Combine(result[Parts] & {Text.Range(input, result[P])}),
    Split = (input as text, pattern as any, optional options as nullable record) as list =>
        let result = List.Accumulate(Matches(input, pattern, options), [P = 0, Parts = {}],
            (s, m) => [P = m[Index] + m[Length], Parts = s[Parts] & {Text.Middle(input, s[P], m[Index] - s[P])}])
        in result[Parts] & {Text.Range(input, result[P])},
    Escape = (input as text) as text => Text.Combine(List.Transform(Text.ToList(input), each if List.Contains(Text.ToList("\.^$|?*+()[]{}"), _) then "\" & _ else _)),
    Validate = (pattern as text, optional options as nullable record) as record =>
        let result = try Binary.Length(Json.FromValue(Compile(pattern, options)))
        in if result[HasError] then [Valid = false, Error = result[Error]] else [Valid = true, Error = null]
in
    [Parse = Parse, Compile = Compile, Match = Match, Matches = Matches, Test = Test, List = ListMatches,
     Replace = Replace, Split = Split, Escape = Escape, Validate = Validate]
