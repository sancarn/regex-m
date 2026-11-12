let
    A = Support[Assert], E = Support[Throws],
    rows = {
        A("List formats only matches", () => Regex[List]("before a1 between b2 after", "([a-z])(\d)", "$2:$1;"), "1:a;2:b;"),
        A("List named fields", () => Regex[List]("AB 12; CD 34", "(?<id>[A-Z]+) (?<count>\d+)", "$id,$count\r\n"), "AB,12#(cr)#(lf)CD,34#(cr)#(lf)"),
        A("List whole match", () => Regex[List]("a b", "\w", "[$&/$0]"), "[a/a][b/b]"),
        A("List no matches", () => Regex[List]("abc", "\d", "$&"), ""),
        A("List empty format", () => Regex[List]("aaa", "a", ""), ""),
        A("List absent capture", () => Regex[List]("b", "(a)?b", "[$1]"), "[]"),
        A("List empty matches advance", () => Regex[List]("ab", "", "-"), "---"),
        A("List compiled pattern", () => Regex[List]("a A", Regex[Compile]("a", [IgnoreCase=true]), "$0"), "aA"),
        A("List options", () => Regex[List]("a A", "a", "$0", [IgnoreCase=true]), "aA"),
        A("List escaped dollars", () => Regex[List]("a", "(a)", "\$1 \$name"), "$1 $name"),
        A("List escaped backslash", () => Regex[List]("a", "a", "\\n"), "\n"),
        A("List literal backslash before capture", () => Regex[List]("a", "(a)", "\\$1"), "\a"),
        A("List unknown tokens remain literal", () => Regex[List]("a", "a", "$9 $unknown ${name} \t"), "$9 $unknown ${name} \t"),
        A("List legacy dollar doubling", () => Regex[List]("a", "(a)", "$$1"), "$a"),
        A("List legacy numbered prefix order", () => Regex[List]("abcdefghij", "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)", "$10"), "a0"),
        A("List legacy named prefix order", () => Regex[List]("ab", "(?<ab>a)(?<a>b)", "$ab"), "bb"),
        A("List substitutions inside inserted captures", () => Regex[List]("$2X", "(\$2)(X)", "$1"), "X"),
        A("List whole match expanded before escapes", () => Regex[List]("\n", "\\n", "$&"), "#(lf)"),
        A("List sentinel text preserved", () => Regex[List]("#regex-m-dollar#", ".+", "$0"), "#regex-m-dollar#"),
        A("Test predicate", () => {Regex[Test]("abc", "a"), Regex[Test]("abc", "z")}, {true,false}),
        E("List shares global budget", () => Regex[List](Text.Repeat("a",100), "a", "$0", [MaxSteps=20]), "Regex.Limit"),
        E("List validates even empty format", () => Regex[List]("a", "(", ""), "Regex.Syntax")
    }
in Table.FromRecords(rows)
