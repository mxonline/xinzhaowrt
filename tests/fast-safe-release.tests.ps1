$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}
function Assert-Equal($Actual,$Expected,[string]$Message) {
    if ([string]$Actual -ne [string]$Expected) { throw "TEST_FAIL: $Message actual='$Actual' expected='$Expected'" }
}
function Assert-Throws([scriptblock]$Action,[string]$Pattern,[string]$Message) {
    $threw = $false
    try { & $Action } catch {
        $threw = $true
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) {
            throw "TEST_FAIL: $Message wrong error='$($_.Exception.Message)' expected-pattern='$Pattern'"
        }
    }
    if (-not $threw) { throw "TEST_FAIL: $Message did not throw" }
}

$policyPath = Join-Path $Root 'production/fast-safe-release-policy.json'
$libPath = Join-Path $Root 'scripts/fast-safe-release-lib.ps1'
Assert-True (Test-Path -LiteralPath $policyPath) 'machine release policy must exist'
Assert-True (Test-Path -LiteralPath $libPath) 'shared fast-safe release library must exist'

. $libPath

$policy = Get-FastSafeReleasePolicy
Assert-Equal $policy.success_terminal_state 'PRODUCTION_RELEASED' 'terminal success state is fixed'
Assert-Equal $policy.recovery_law 'REUSE_RECONCILE_REPAIR_CONTINUE' 'recovery law is fixed'
Assert-True (-not [bool]$policy.allow_new_production_stages) 'new production stages are denied by default'

$state = New-ReleaseTaskState `
    -ReleaseTaskId 'arthur:adh-quickstart:accepted-c4cadd6e' `
    -DeviceId 'jdcloud_re-ss-01' `
    -CurrentStage 'SOURCE_FROZEN'

Assert-Equal $state.schema_version 2 'new release state uses schema v2'
Assert-Equal $state.terminal_state 'ACTIVE' 'new release task is active'
Assert-Equal $state.last_verified_stage 'SOURCE_FROZEN' 'current verified stage is retained'

Assert-Throws {
    Assert-ReleaseStageTransition -State $state -NextStage 'PREVIEW_ACCEPTED'
} 'RELEASE_STAGE_REGRESSION_WITHOUT_INVALIDATION' 'verified checkpoint cannot regress without invalidation evidence'

Add-ReleaseInvalidation `
    -State $state `
    -Checkpoint 'SOURCE_FROZEN' `
    -Reason 'accepted preview bytes changed' `
    -OldFingerprint ('a' * 64) `
    -NewFingerprint ('b' * 64) `
    -MinimumRepeatStage 'PREVIEW_ACCEPTED' | Out-Null

Assert-True (Test-CheckpointValid -State $state -Checkpoint 'SOURCE_FROZEN' -Fingerprint ('a' * 64) -eq $false) 'invalidated checkpoint must not remain valid'
Assert-ReleaseStageTransition -State $state -NextStage 'PREVIEW_ACCEPTED' | Out-Null

Write-Host 'FAST_SAFE_RELEASE_POLICY_CONTRACT=PASS'
Write-Host 'FAST_SAFE_RELEASE_MONOTONIC_STATE_CONTRACT=PASS'
