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

$checkpointValid = Test-CheckpointValid -State $state -Checkpoint 'SOURCE_FROZEN' -Fingerprint ('a' * 64)
Assert-True (-not $checkpointValid) 'invalidated checkpoint must not remain valid'
Assert-ReleaseStageTransition -State $state -NextStage 'PREVIEW_ACCEPTED' | Out-Null

$v1 = [pscustomobject][ordered]@{
    schema_version = 1
    feature_id = 'arthur-adh-quickstart'
    accepted_preview_source_sha = ('c' * 40)
    accepted_diff_sha256 = ('d' * 64)
    preview_manifest_sha256 = ('e' * 64)
    preview_manifest_path = 'manifest.json'
    current_stage = 'BUILD_DISPATCHED'
    stage_status = 'LIVE'
    dispatched_run_id = 12345
    suppress_dispatch = $false
    last_error = ''
    retry_count = 0
}
$migrated = ConvertTo-ReleaseTaskStateV2 -State $v1 -DeviceId 'jdcloud_re-ss-01'
Assert-Equal $migrated.schema_version 2 'schema v1 upgrades to v2'
Assert-Equal $migrated.feature_id 'arthur-adh-quickstart' 'migration preserves feature id'
Assert-Equal $migrated.accepted_preview_source_sha ('c' * 40) 'migration preserves accepted source identity'
Assert-Equal $migrated.dispatched_run_id 12345 'migration preserves active run id'
Assert-Equal $migrated.current_stage 'BUILD_DISPATCHED' 'migration preserves current stage'
Assert-True ([string]$migrated.release_task_id -like 'arthur:arthur-adh-quickstart:*') 'migration creates durable release task id'

Write-Host 'FAST_SAFE_RELEASE_POLICY_CONTRACT=PASS'
Write-Host 'FAST_SAFE_RELEASE_MONOTONIC_STATE_CONTRACT=PASS'
Write-Host 'FAST_SAFE_RELEASE_V1_MIGRATION_CONTRACT=PASS'
