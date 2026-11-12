<# Independent oracle for the documented common subset. .NET Regex is used
   only here to generate expectations; Regex.m executes every actual match. #>
[CmdletBinding()]
param([string]$EnginePath, [string]$MashupModulePath, [string]$ResultsPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -eq 'Core') { throw 'Run with Windows PowerShell 5.1 (powershell.exe).' }
if (-not $MashupModulePath) { $MashupModulePath = $env:MASHUP_MODULE_PATH }
if (-not $MashupModulePath) {
    $MashupModulePath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'powershell-mashup/src/PowerShellMashup.psd1'
}
Import-Module $MashupModulePath -Force
$patterns = [Collections.Generic.List[string]]::new()
@('', 'a', 'ab', '^a$', 'a|ab', '(a|ab)b', '(a)?b', '(a|b)+', '(a(b)?)+', '(a*)*',
  '(a?)*', '(a?)+', '(a*)+', '(a*?)*', '(a*?)+', '(?:|a)*', '^(?:|a)*b$',
  '^(?:[ab]*?)*b', '((a|ab){1,3})b', '(a+)\1', '(a|b)\1', '(a)?\1', '()\1',
  '(a|(b))*', '(?=(a+))\1', '(?!(a)b)a', '(?<=a)b', '(?<!a)b', '(?<=a|b)a',
  '(?>a|ab)b', '(?>a*)a', '\ba\b', '\Ba\B', '^.*$', '[^a]+', '\d+', '\w+', '\s+',
  '\A[ab]*\z', '(a{0,2}){2,3}', '((a)?b?)*', '(a|aa)+b', '(a|aa)*?b',
  '(){3}', '(){3,}', '(?:a|){2,3}b', '(?:|a){2,3}b', '(?=(a|ab))\1b',
  '(?<word>a+)\k<word>', '(?<=((ab)))a') | ForEach-Object { $patterns.Add($_) }
$atoms = @('a', '[ab]', '(a|b)', '(?:ab|a)', '(a?)', '(?:a*?)')
$quantifiers = @('*', '+', '?', '{0}', '{2}', '{1,3}', '{2,}', '*?', '+?', '??', '{0,3}?')
foreach ($atom in $atoms) {
    foreach ($quantifier in $quantifiers) {
        $patterns.Add($atom + $quantifier)
        $patterns.Add('^' + $atom + $quantifier + 'b$')
    }
}
$inputs = [Collections.Generic.List[string]]::new()
$inputs.Add('')
$level = @('')
for ($length = 1; $length -le 4; $length++) {
    $next = foreach ($prefix in $level) { $prefix + 'a'; $prefix + 'b' }
    foreach ($value in $next) { $inputs.Add($value) }
    $level = @($next)
}
@('aaabbb', 'ababab', 'a1 b2', '123', ' a ', "a`nb", "a`n", "`t") | ForEach-Object { $inputs.Add($_) }
$fixtures = foreach ($pattern in $patterns) {
    $reference = [regex]::new($pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1))
    $cases = foreach ($inputText in $inputs) {
        $match = $reference.Match($inputText)
        $expected = if ($match.Success) {
            $groups = @(foreach ($group in $match.Groups) {
                if ($group.Success) { ,@($group.Index, $group.Length, $group.Value) }
                else { ,@(-1, 0, $null) }
            })
            ,@($groups)
        } else { $null }
        [pscustomobject]@{ input=$inputText; expected=$expected }
    }
    [pscustomobject]@{ pattern=$pattern; cases=@($cases) }
}
$json = ConvertTo-Json -InputObject @($fixtures) -Depth 20 -Compress
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
$definitions = @{
    Regex = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'Regex.m'))
    Fixtures = 'Json.Document(Binary.FromText("' + $encoded + '", BinaryEncoding.Base64))'
}
$query = @'
let
    rows = List.Combine(List.Transform(Fixtures, (fixture) =>
        let compiled = Regex[Compile](fixture[pattern]) in
        List.Transform(fixture[cases], (case) =>
            let
                result = try Text.FromBinary(Json.FromValue(
                    let m = Regex[Match](case[input], compiled)
                    in if m = null then null else List.Transform(m[Groups], each {[Index], [Length], [Value]}))),
                expected = Text.FromBinary(Json.FromValue(case[expected]))
            in [pattern = fixture[pattern], input = case[input],
                passed = if result[HasError] then false else result[Value] = expected,
                expected = expected,
                actual = if result[HasError] then result[Error][Message] else result[Value]])))
in Table.FromRecords(rows)
'@
$watch = [Diagnostics.Stopwatch]::StartNew()
$failures = [Collections.Generic.List[object]]::new()
$count = 0
Invoke-Mashup -Query $query -Definitions $definitions -EnginePath $EnginePath | ForEach-Object {
    $count++
    if (-not $_.passed) {
        $failures.Add($_)
        if ($failures.Count -le 20) { Write-Host (ConvertTo-Json -InputObject $_ -Compress) }
    }
}
$summary = [pscustomobject]@{ total=$count; passed=$count-$failures.Count; failed=$failures.Count; patterns=$patterns.Count; inputs=$inputs.Count; milliseconds=$watch.ElapsedMilliseconds; failures=$failures.ToArray() }
Write-Host "$($summary.passed)/$count differential cases passed ($($summary.patterns) patterns, $($summary.inputs) inputs; $($summary.milliseconds) ms)."
if ($ResultsPath) {
    [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsPath), (ConvertTo-Json -InputObject $summary -Depth 30), [Text.UTF8Encoding]::new($false))
}
if ($count -ne $patterns.Count * $inputs.Count) { throw 'Differential run returned an incomplete result set.' }
if ($failures.Count) { exit 1 }
