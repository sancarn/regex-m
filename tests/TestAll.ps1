<# MGIS-style Test*.m discovery and assertion rows, evaluated by real Power Query.
   Prefer the result-returning powershell-mashup host. A built-in JSON adapter
   also supports standalone checkouts without that optional module. #>
[CmdletBinding()]
param(
    [string]$TestsDirectory = $PSScriptRoot,
    [string]$LibraryPath,
    [string]$EnginePath,
    [string]$MashupModulePath,
    [string]$ResultsPath,
    [switch]$UseMinimalHost
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -eq 'Core') {
    $arguments = @('-NoProfile', '-File', $PSCommandPath)
    foreach ($key in $PSBoundParameters.Keys) {
        if ($PSBoundParameters[$key] -is [switch]) {
            if ($PSBoundParameters[$key]) { $arguments += "-$key" }
        } else { $arguments += @("-$key", [string]$PSBoundParameters[$key]) }
    }
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" @arguments
    exit $LASTEXITCODE
}
$TestsDirectory = (Resolve-Path -LiteralPath $TestsDirectory).Path
if (-not $LibraryPath) { $LibraryPath = Join-Path (Split-Path $TestsDirectory -Parent) 'Regex.m' }
$definitions = @{
    Regex = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $LibraryPath).Path)
    Support = [IO.File]::ReadAllText((Join-Path $TestsDirectory 'Support.m'))
}
if (-not $MashupModulePath -and $env:MASHUP_MODULE_PATH) { $MashupModulePath = $env:MASHUP_MODULE_PATH }
if (-not $MashupModulePath) {
    $sibling = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'powershell-mashup/src/PowerShellMashup.psd1'
    if (Test-Path -LiteralPath $sibling) { $MashupModulePath = $sibling }
}
if ($MashupModulePath -and -not $UseMinimalHost) {
    Import-Module $MashupModulePath -Force
    $runtime = Get-MashupRuntime -EnginePath $EnginePath | Select-Object -First 1
    Write-Host "Host: powershell-mashup; engine $($runtime.Version)"
    function Invoke-TestQuery([string]$source) {
        Invoke-Mashup -Query $source -Definitions $definitions -EnginePath $runtime.Path
    }
} else {
    if (-not $EnginePath) { $EnginePath = $env:MASHUP_ENGINE_PATH }
    if (-not $EnginePath) {
        $candidates = foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ($root) {
                Join-Path $root 'Microsoft Office/root/Office16/ADDINS/Microsoft Power Query for Excel Integrated/bin/Microsoft.MashupEngine.dll'
                Join-Path $root 'Microsoft Power BI Desktop/bin/Microsoft.MashupEngine.dll'
            }
        }
        $EnginePath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $EnginePath) { throw 'Mashup runtime not found. Supply -EnginePath or MASHUP_ENGINE_PATH.' }
    [void][Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $EnginePath).Path)
    $engine = [Microsoft.Mashup.Engine1.Engine]::Instance
    $hostApi = [Microsoft.Mashup.Evaluator.MinimalEngineHost]::Instance
    $library = [Microsoft.Mashup.Engine.Interface.IEngine].GetMethod('GetLibrary').Invoke($engine, @($hostApi, $null))
    Write-Host "Host: MGIS-style minimal host with JSON results; engine $((Get-Item $EnginePath).VersionInfo.FileVersion)"
    function Invoke-TestQuery([string]$source) {
        $query = 'let Regex = (' + $definitions.Regex + "`n), Support = (" + $definitions.Support + "`n), result = (" + $source + "`n) in Text.FromBinary(Json.FromValue(result), TextEncoding.Utf8)"
        $value = [Microsoft.Mashup.Engine1.Language.LanguageLibrary]::Evaluate($query, $library)
        $decoded = $value.ToString() | ConvertFrom-Json
        foreach ($item in $decoded) { Write-Output $item }
    }
}
$tests = @(Get-ChildItem -LiteralPath $TestsDirectory -Filter 'Test*.m' -File | Sort-Object Name)
if ($tests.Count -eq 0) { throw 'No Test*.m suites found.' }
$all = [Collections.Generic.List[object]]::new()
$suiteFailures = 0
foreach ($test in $tests) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $rows = @(Invoke-TestQuery ([IO.File]::ReadAllText($test.FullName)))
        if ($rows.Count -eq 0) { throw 'Suite returned no assertions.' }
        foreach ($row in $rows) {
            if ($null -eq $row.PSObject.Properties['passed'] -or $row.passed -isnot [bool]) { throw 'Invalid assertion row: passed must be a Boolean.' }
            $all.Add([pscustomobject]@{ suite=$test.Name; description=$row.description; passed=$row.passed; expected=$row.expected; actual=$row.actual; error=$row.error })
            if (-not $row.passed) { Write-Host "  FAIL $($row.description): expected $($row.expected); actual $($row.actual); $($row.error)" }
        }
        $failed = @($rows | Where-Object { -not $_.passed }).Count
        if ($failed) { $suiteFailures++ }
        Write-Host "$($test.Name): $($rows.Count - $failed)/$($rows.Count) passed ($($watch.ElapsedMilliseconds) ms)"
    } catch {
        $suiteFailures++
        $failure = $_.Exception
        while ($failure.InnerException) { $failure = $failure.InnerException }
        Write-Host "$($test.Name): ERROR - $($failure.Message)"
        $all.Add([pscustomobject]@{suite=$test.Name; description='Suite evaluation'; passed=$false; expected='successful evaluation'; actual=$null; error=$failure.Message})
    }
}
$passed = @($all | Where-Object passed).Count
Write-Host "$passed/$($all.Count) assertions passed; $($tests.Count - $suiteFailures)/$($tests.Count) suites passed."
if ($ResultsPath) {
    [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsPath), (ConvertTo-Json -InputObject $all.ToArray() -Depth 30), [Text.UTF8Encoding]::new($false))
}
if ($suiteFailures) { exit 1 }
