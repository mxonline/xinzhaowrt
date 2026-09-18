$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $Root 'scripts\arthur-resume-state.ps1')
. (Join-Path $Root 'scripts\arthur-evidence-index.ps1')

function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ($Actual -ne $Expected) { throw "TEST_FAIL: $Message (actual='$Actual' expected='$Expected')" }
}

# The formally authorized v0.1.5 execution identity already stored in operator-intent.json
# includes the dotted semantic version in its task slug. Existing execution ids without dots
# must remain valid, but validators must not reject this already-authorized identity.
$executionId = 'arthur-v0.1.5-release-e037750-20260918'
$baseline = [pscustomobject]@{ source_sha=('e' * 40); build_date='2026-09-18' }

$resolved = Resolve-ArthurMigrationExecutionId -ExplicitExecutionId $executionId -PreviousResumeState $null -BaselineFirmware $baseline
Assert-Equal $resolved $executionId 'resume-state execution validator must accept the authorized dotted version slug'

$path = Get-ArthurEvidenceIndexPath -Root $Root -ExecutionId $executionId
$leafExecution = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($path))
Assert-Equal $leafExecution $executionId 'evidence index path must preserve the authorized execution id exactly'

Write-Host 'ARTHUR_VERSIONED_EXECUTION_ID=PASS'
