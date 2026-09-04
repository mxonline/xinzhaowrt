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

Assert-Equal (Get-MinimumInvalidationForImpact -ImpactClass 'DOC_ONLY') 'NONE' 'docs invalidate no release evidence'
Assert-Equal (Get-MinimumInvalidationForImpact -ImpactClass 'CONTROL_PLANE_ONLY') 'CONTROL_EVIDENCE_ONLY' 'control-only edits preserve firmware bytes'
Assert-Equal (Get-MinimumInvalidationForImpact -ImpactClass 'PREVIEW_BYTES') 'PREVIEW_AND_DOWNSTREAM' 'preview byte changes repeat preview and downstream only'
Assert-Equal (Get-MinimumInvalidationForImpact -ImpactClass 'FIRMWARE_INPUT') 'BUILD_AND_DOWNSTREAM' 'firmware input changes repeat build and downstream only'
Assert-Equal (Get-MinimumInvalidationForImpact -ImpactClass 'DEVICE_WRITE_POLICY') 'PREFLASH_AND_DOWNSTREAM' 'write-policy changes repeat preflash safety and downstream only'
Assert-Throws {
    Get-MinimumInvalidationForImpact -ImpactClass 'UNKNOWN'
} 'FAST_SAFE_RELEASE_UNKNOWN_IMPACT_CLASS' 'unknown impact class must fail closed'

$previewRecord = [pscustomobject][ordered]@{
    schema_version = 1
    feature_id = 'arthur-adh-quickstart'
    accepted_preview_source_sha = ('1' * 40)
    accepted_diff_sha256 = ('2' * 64)
    preview_manifest_sha256 = ('3' * 64)
    frozen_files = @(
        [pscustomobject][ordered]@{ remote='/usr/lib/lua/luci/controller/AdGuardHome.lua'; sha256=('4' * 64); mode='0644'; overlay='files/usr/lib/lua/luci/controller/AdGuardHome.lua' },
        [pscustomobject][ordered]@{ remote='/etc/init.d/AdGuardHome'; sha256=('5' * 64); mode='0755'; overlay='files/etc/init.d/AdGuardHome' }
    )
}
$previewRecordWithHandoffNoise = (($previewRecord | ConvertTo-Json -Depth 20) | ConvertFrom-Json -Depth 20)
Add-Member -InputObject $previewRecordWithHandoffNoise -NotePropertyName handoff_text -NotePropertyValue 'changed documentation only'
$fp1 = Get-AcceptedPreviewFingerprint -AcceptedRecord $previewRecord -PreviewPolicyIdentity 'policy-v1'
$fp2 = Get-AcceptedPreviewFingerprint -AcceptedRecord $previewRecordWithHandoffNoise -PreviewPolicyIdentity 'policy-v1'
Assert-Equal $fp1 $fp2 'HANDOFF/docs noise must not alter accepted preview fingerprint'
Assert-True ($fp1 -match '^[0-9a-f]{64}$') 'accepted preview fingerprint must be SHA256'

$matchingHashes = @{
    '/usr/lib/lua/luci/controller/AdGuardHome.lua' = ('4' * 64)
    '/etc/init.d/AdGuardHome' = ('5' * 64)
}
$reuse = Get-PreviewReuseDecision -AcceptedRecord $previewRecord -DeviceHashes $matchingHashes -PreviewPolicyIdentity 'policy-v1'
Assert-Equal $reuse.action 'REUSE_PREVIEW_ACCEPTED' 'matching device hashes reuse accepted preview'
Assert-Equal @($reuse.paths).Count 0 'matching preview requires no file writes'
Assert-True (-not [bool]$reuse.source_discovery_allowed) 'same accepted fingerprint forbids source rediscovery'
Assert-True (-not [bool]$reuse.full_preview_deploy_allowed) 'same accepted fingerprint forbids full preview deployment'

$driftedHashes = @{
    '/usr/lib/lua/luci/controller/AdGuardHome.lua' = ('0' * 64)
    '/etc/init.d/AdGuardHome' = ('5' * 64)
}
$restore = Get-PreviewReuseDecision -AcceptedRecord $previewRecord -DeviceHashes $driftedHashes -PreviewPolicyIdentity 'policy-v1'
Assert-Equal $restore.action 'RESTORE_DRIFTED_PREVIEW_FILES' 'one drifted file triggers minimum restore only'
Assert-Equal @($restore.paths).Count 1 'one drifted file must not redeploy the full bundle'
Assert-Equal $restore.paths[0] '/usr/lib/lua/luci/controller/AdGuardHome.lua' 'restore identifies only the drifted target'
Assert-True (-not [bool]$restore.source_discovery_allowed) 'drift repair still forbids source rediscovery'
Assert-True (-not [bool]$restore.full_preview_deploy_allowed) 'drift repair still forbids full preview deployment'

. (Join-Path $Root 'scripts/feature-handoff-lib.ps1')
$handoffState = New-FeatureHandoffState `
    -FeatureId 'arthur-adh-quickstart' `
    -AcceptedPreviewSourceSha ('6' * 40) `
    -AcceptedDiffSha256 ('7' * 64) `
    -PreviewManifestSha256 ('8' * 64) `
    -PreviewManifestPath 'manifest.json' `
    -PreviewEvidence @{ LIVE_PREVIEW='PASS'; WIFI='VERIFIED_FROZEN' }
Assert-Equal $handoffState.schema_version 2 'new Feature Handoff state must use durable release schema v2'
Assert-Equal $handoffState.terminal_state 'ACTIVE' 'Feature Handoff release remains active until production release'
Assert-Equal $handoffState.last_verified_stage 'PREVIEW_ACCEPTED' 'accepted preview is retained as verified checkpoint'
Assert-True ([string]$handoffState.release_task_id -like 'arthur:arthur-adh-quickstart:*') 'Feature Handoff state must own durable release task identity'
Assert-True ($handoffState.PSObject.Properties.Name -contains 'accepted_preview_fingerprint') 'Feature Handoff state must persist preview fingerprint slot'
Assert-True ($handoffState.PSObject.Properties.Name -contains 'build_fingerprint') 'Feature Handoff state must persist build fingerprint slot'
Assert-True ($handoffState.PSObject.Properties.Name -contains 'executor_state') 'Feature Handoff state must separate executor state from release state'

$buildIdentity = [pscustomobject][ordered]@{
    target = 'qualcommax'
    subtarget = 'ipq60xx'
    profile = 'jdcloud_re-ss-01'
    source_lock_sha256 = ('9' * 64)
    toolchain_identity = 'arthur-sdk-known-good-v1'
    config_sha256 = ('a' * 64)
    required_plugins_sha256 = ('b' * 64)
    files_identity = ('c' * 64)
    build_scripts_identity = ('d' * 64)
    package_inputs_identity = ('e' * 64)
    theme_identity = ('f' * 64)
}
$buildIdentityWithControlNoise = (($buildIdentity | ConvertTo-Json -Depth 20) | ConvertFrom-Json -Depth 20)
Add-Member -InputObject $buildIdentityWithControlNoise -NotePropertyName handoff_text -NotePropertyValue 'docs changed'
Add-Member -InputObject $buildIdentityWithControlNoise -NotePropertyName controller_text -NotePropertyValue 'controller path fixed'
$buildFp1 = Get-BuildFingerprint -InputIdentity $buildIdentity
$buildFp2 = Get-BuildFingerprint -InputIdentity $buildIdentityWithControlNoise
Assert-Equal $buildFp1 $buildFp2 'HANDOFF/controller-only noise must not alter build fingerprint'
Assert-True ($buildFp1 -match '^[0-9a-f]{64}$') 'build fingerprint must be SHA256'

$runningDecision = Get-BuildReuseDecision -BuildFingerprint $buildFp1 `
    -Runs @([pscustomobject]@{ id=123; fingerprint=$buildFp1; status='in_progress'; conclusion='' }) `
    -Artifacts @()
Assert-Equal $runningDecision.action 'WATCH_EXISTING_RUN' 'matching active Candidate is watched instead of redispatched'
Assert-Equal $runningDecision.run_id 123 'watch decision preserves existing run id'

$artifactDecision = Get-BuildReuseDecision -BuildFingerprint $buildFp1 -Runs @() `
    -Artifacts @([pscustomobject]@{ fingerprint=$buildFp1; sha256=('1' * 64); immutable=$true; acceptance='PASS'; identity='Arthur-v3-Candidate-123' })
Assert-Equal $artifactDecision.action 'REUSE_ARTIFACT' 'matching successful immutable Candidate is reused'
Assert-Equal $artifactDecision.artifact_sha256 ('1' * 64) 'artifact reuse preserves Candidate sha256'

$revalidateDecision = Get-BuildReuseDecision -BuildFingerprint $buildFp1 -Runs @() `
    -Artifacts @([pscustomobject]@{ fingerprint=$buildFp1; sha256=('2' * 64); immutable=$true; acceptance='CONTROL_ONLY_FAIL'; identity='Arthur-v3-Candidate-124' })
Assert-Equal $revalidateDecision.action 'REVALIDATE_QUARANTINE_CANDIDATE' 'control-only acceptance failure reuses Candidate bytes'

$changedIdentity = (($buildIdentity | ConvertTo-Json -Depth 20) | ConvertFrom-Json -Depth 20)
$changedIdentity.files_identity = ('0' * 64)
$changedFp = Get-BuildFingerprint -InputIdentity $changedIdentity
Assert-True ($changedFp -ne $buildFp1) 'firmware byte input change must change build fingerprint'
$newDecision = Get-BuildReuseDecision -BuildFingerprint $changedFp -Runs @() -Artifacts @()
Assert-Equal $newDecision.action 'START_NEW_CANDIDATE' 'changed firmware fingerprint permits exactly one new Candidate'

$tempQuarantine = Join-Path ([System.IO.Path]::GetTempPath()) "xinzhao-quarantine-$PID-$([Guid]::NewGuid().ToString('N')).json"
try {
    Write-CandidateQuarantineRecord -Path $tempQuarantine -Record ([pscustomobject]@{
        build_fingerprint=$buildFp1; run_id=123; source_sha=('3' * 40); artifact_name='Arthur-v3-Candidate-123';
        artifact_sha256=('4' * 64); target='qualcomax/ipq60xx'; profile='jdcloud_re-ss-01'; acceptance_class='PENDING'
    }) | Out-Null
    $quarantine = Get-CandidateQuarantineRecord -Path $tempQuarantine
    Assert-Equal $quarantine.build_fingerprint $buildFp1 'quarantine retains build fingerprint'
    Assert-Equal $quarantine.run_id 123 'quarantine retains run id'
    Assert-Equal $quarantine.acceptance_class 'PENDING' 'quarantine exists before later acceptance result'
} finally { Remove-Item -Force -ErrorAction SilentlyContinue $tempQuarantine }

Write-Host 'FAST_SAFE_RELEASE_POLICY_CONTRACT=PASS'
Write-Host 'FAST_SAFE_RELEASE_MONOTONIC_STATE_CONTRACT=PASS'
Write-Host 'FAST_SAFE_RELEASE_V1_MIGRATION_CONTRACT=PASS'
Write-Host 'FAST_SAFE_RELEASE_MINIMUM_INVALIDATION_CONTRACT=PASS'
Write-Host 'FAST_SAFE_RELEASE_PREVIEW_REUSE_CONTRACT=PASS'
Write-Host 'FAST_SAFE_RELEASE_HANDOFF_V2_CONTRACT=PASS'
Write-Host 'FAST_SAFE_RELEASE_BUILD_REUSE_CONTRACT=PASS'