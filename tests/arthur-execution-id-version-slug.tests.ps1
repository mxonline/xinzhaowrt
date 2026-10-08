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

# Schema-2 migration must still load the terminal execution id produced by the
# original v0.1.5 release workflow, so its historical evidence index can be read.
$historicalExecutionId = 'arthur-v015-software-source-repair-36764137044'
Assert-Equal (Test-ArthurExecutionId -ExecutionId $historicalExecutionId) $true 'historical v015 release execution id must remain readable'
$historicalPath = Get-ArthurEvidenceIndexPath -Root $Root -ExecutionId $historicalExecutionId
$historicalLeaf = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($historicalPath))
Assert-Equal $historicalLeaf $historicalExecutionId 'historical execution id must map to its original evidence directory'
Assert-Equal (Test-ArthurExecutionId -ExecutionId 'arthur-v015-..-36764137044') $false 'path traversal tokens must remain invalid in historical ids'

Write-Host 'ARTHUR_VERSIONED_EXECUTION_ID=PASS'
