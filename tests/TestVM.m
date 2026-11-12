let
    A = Support[Assert],
    rows = {
        A("parser exposes AST", () => Regex[Parse]("a|b")[Ast][Kind], "Alternation"),
        A("compiler emits choices", () => List.Contains(List.Transform(Regex[Compile]("a|b")[Program][Code], each [Op]), "Split"), true),
        A("counted repetition stays compact", () => List.Count(Regex[Compile]("a{1000000}")[Program][Code]), 5),
        A("VM never reads AST", () => let p = Record.RemoveFields(Regex[Compile]("a+"), {"Ast"}) in Regex[Match]("aaa", p)[Value], "aaa"),
        A("VM matches long consuming loop", () => Regex[Match](Text.Repeat("a", 5000), "^a+$")[Length], 5000),
        A("VM exact count", () => Regex[Match](Text.Repeat("a", 2000), "^a{2000}$")[Length], 2000),
        A("many global matches", () => List.Count(Regex[Matches](Text.Repeat("a", 500), "a")), 500),
        A("empty input all matches", () => List.Count(Regex[Matches]("", "")), 1),
        A("lookbehind zero width", () => Regex[Match]("a", "(?<=)a")[Value], "a")
    }
in Table.FromRecords(rows)
