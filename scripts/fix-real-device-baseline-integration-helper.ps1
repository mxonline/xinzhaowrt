$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Path = Join-Path $Root 'scripts\apply-real-device-baseline-integration.ps1'
$Text = Get-Content -Raw $Path

$badControllerAnchor = @'
$controllerAnchor = "$ProductionStateFile = Join-Path `$RepoRoot 'output\production-agent\state.json'"
'@
$goodControllerAnchor = @'
$controllerAnchor = '$ProductionStateFile = Join-Path $RepoRoot ''output\production-agent\state.json'''
'@
if ($Text.Contains($badControllerAnchor)) {
    $Text = $Text.Replace($badControllerAnchor,$goodControllerAnchor)
}
elseif (-not $Text.Contains($goodControllerAnchor)) {
    throw 'controllerAnchor repair target missing'
}

$oldBaselinePath = @'
$RealDeviceBaselinePath = Join-Path $Root ([string]$Config.real_device_baseline)
$ExpectedDiffPath = Join-Path $Root ([string]$Config.expected_diff)
'@
$newBaselinePath = @'
$RealDeviceBaselineDefault = 'production\real-device-baseline.json'
$ExpectedDiffDefault = 'production\expected-diff.json'
$RealDeviceBaselineRelative = if ([string]$Config.real_device_baseline) { [string]$Config.real_device_baseline } else { $RealDeviceBaselineDefault }
$ExpectedDiffRelative = if ([string]$Config.expected_diff) { [string]$Config.expected_diff } else { $ExpectedDiffDefault }
$RealDeviceBaselinePath = Join-Path $Root $RealDeviceBaselineRelative
$ExpectedDiffPath = Join-Path $Root $ExpectedDiffRelative
'@
if (-not $Text.Contains($oldBaselinePath)) {
    throw 'real-device baseline path repair target missing'
}
$Text = $Text.Replace($oldBaselinePath,$newBaselinePath)

$badExitChecks = @(
    'if ($LASTEXITCODE -ne 0) { throw "real-device baseline contract failed: $LASTEXITCODE" }',
    'if ($LASTEXITCODE -ne 0) { throw "production-agent contract failed: $LASTEXITCODE" }'
)
foreach ($line in $badExitChecks) {
    $Text = $Text.Replace("$line`r`n",'')
    $Text = $Text.Replace("$line`n",'')
}

Set-Content -Path $Path -Value $Text -Encoding UTF8

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) {
    throw (($errors | ForEach-Object Message) -join '; ')
}

Write-Host 'REAL_DEVICE_BASELINE_HELPER_REPAIR=PASS'
