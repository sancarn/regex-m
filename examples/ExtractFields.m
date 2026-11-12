// Requires a query named Regex containing Regex.m.
let
    Pattern = Regex[Compile]("(?<name>[A-Za-z]+)=(?<value>\d+)"),
    Found = Regex[Matches]("width=120 height=80", Pattern),
    Result = Table.FromRecords(List.Transform(Found, each [
        Name = [NamedGroups][name][Value],
        Value = Number.FromText([NamedGroups][value][Value])
    ]))
in Result
