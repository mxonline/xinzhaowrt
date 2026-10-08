$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$workflowPath = Join-Path $projectRoot '.github\workflows\known-good-fastlane.yml'
$workflowText = Get-Content -Raw -LiteralPath $workflowPath
$lines = $workflowText -split "`r?`n"
$permissionIndex = [Array]::IndexOf($lines,'permissions:')
if ($permissionIndex -lt 0) { throw 'TEST_FAIL: known-good fastlane workflow permissions boundary is missing.' }
$triggerText = ($lines[0..($permissionIndex - 1)] -join "`n")
if ($triggerText -notmatch '(?m)^  workflow_dispatch:\s*$') {
    throw 'TEST_FAIL: known-good fastlane must remain manually dispatchable.'
}
if ($triggerText -match '(?m)^  push:\s*$') {
    throw 'TEST_FAIL: source synchronization must not start a second firmware build automatically.'
}
if (-not $workflowText.Contains('Build frozen Arthur baseline') -or -not $workflowText.Contains('./scripts/build.sh')) {
    throw 'TEST_FAIL: known-good manual build lane was removed instead of preserving its explicit dispatch path.'
}
Write-Output 'KNOWN_GOOD_FASTLANE_SINGLE_BUILD_BOUNDARY=PASS'
