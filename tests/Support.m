// MGIS assertion row contract, with eager JSON serialization inside try.
let
    Encode = (value) => Text.FromBinary(Json.FromValue(value), TextEncoding.Utf8),
    Assert = (description as text, action as function, expected as any, optional tags as nullable list) as record =>
        let observed = try Encode(action()), wanted = Encode(expected)
        in [parent = "Regex", description = description, tags = if tags = null then {} else tags,
            passed = if observed[HasError] then false else observed[Value] = wanted,
            expected = wanted, actual = if observed[HasError] then null else observed[Value],
            error = if observed[HasError] then observed[Error][Message] else null],
    Throws = (description as text, action as function, reason as text) as record =>
        let observed = try Encode(action())
        in [parent = "Regex", description = description, tags = {"errors"},
            passed = if observed[HasError] then observed[Error][Reason] = reason else false,
            expected = reason, actual = if observed[HasError] then observed[Error][Reason] else observed[Value],
            error = if observed[HasError] then observed[Error][Message] else null]
in [Assert = Assert, Throws = Throws]
