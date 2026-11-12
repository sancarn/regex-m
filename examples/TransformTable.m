// Compile once; each row reuses the same immutable bytecode program.
let
    Source = #table({"Code"}, {{"AB-123"}, {"xy-8"}, {"invalid"}, {null}}),
    Pattern = Regex[Compile]("\A(?<prefix>[a-z]+)-(?<number>\d+)\z", [IgnoreCase = true]),
    WithMatch = Table.AddColumn(Source, "Match", each
        if [Code] = null then null else Regex[Match]([Code], Pattern)),
    WithNumber = Table.AddColumn(WithMatch, "Number", each
        if [Match] = null then null else Number.FromText([Match][NamedGroups][number][Value]), type nullable number)
in Table.RemoveColumns(WithNumber, {"Match"})
