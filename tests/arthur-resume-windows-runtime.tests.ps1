$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ResumePath = Join-Path $Root 'scripts\arthur-firmware-resume.ps1'
$ResumeStatePath = Join-Path $Root 'production\resume-state.json'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}

$resumeState = Get-Content -Raw -LiteralPath $ResumeStatePath | ConvertFrom-Json
$rawHead = [string]$resumeState.PSObject.Properties['repository_head'].Value
Assert-True ($rawHead -match '^[0-9a-fA-F]{40}$') 'fixture resume repository_head must be a valid 40-hex SHA before runtime gate invocation'

$oldError = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $raw = (& $ResumePath -SkipExternal -AllowRepositoryHeadDriftForReconciliation 2>&1 | Out-String).Trim()
    $exitCode = $LASTEXITCODE
}
finally { $ErrorActionPreference = $oldError }

Assert-True (-not [string]::IsNullOrWhiteSpace($raw)) 'runtime Resume Gate must emit JSON evidence'
$result = $raw | ConvertFrom-Json
Assert-True (-not (@($result.conflicts) -contains 'RESUME_REPOSITORY_HEAD_INVALID')) 'Windows PowerShell runtime must not reject the valid durable repository_head'
Assert-True ([string]$result.resume_state.repository_head -eq $rawHead.ToLowerInvariant()) 'runtime Resume Gate must preserve the canonical durable resume SHA'
Assert-True ($exitCode -eq 0) 'reconciliation-only head drift must not hard-fail the Windows runtime Resume Gate'

Write-Host 'ARTHUR_WINDOWS_RESUME_HEAD_RUNTIME_CONTRACT=PASS'
