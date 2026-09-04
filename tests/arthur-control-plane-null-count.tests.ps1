$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ScriptPath = Join-Path $Root 'scripts\arthur-control-plane.ps1'
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw 'TEST_FAIL: Arthur Control Plane script is missing'
}

$script = Get-Content -Raw -LiteralPath $ScriptPath
$unsafe = "if ((`$deviceLines | Where-Object { `$_ -match 'build-info\.json' }).Count -gt 0)"
$safe = "if (@(`$deviceLines | Where-Object { `$_ -match 'build-info\.json' }).Count -gt 0)"

if ($script.IndexOf($unsafe,[System.StringComparison]::Ordinal) -ge 0) {
    throw 'TEST_FAIL: empty build-info scan must not dereference .Count on a null/scalar pipeline result'
}
if ($script.IndexOf($safe,[System.StringComparison]::Ordinal) -lt 0) {
    throw 'TEST_FAIL: build-info scan must wrap Where-Object output in @() before Count'
}

$deviceLines = @('no build info here')
$count = @($deviceLines | Where-Object { $_ -match 'build-info\.json' }).Count
if ($count -ne 0) { throw "TEST_FAIL: expected zero safe matches, got $count" }

Write-Host 'ARTHUR_CONTROL_PLANE_NULL_COUNT_CONTRACT=PASS'
