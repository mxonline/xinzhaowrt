#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(rel):
    return (ROOT / rel).read_text(encoding='utf-8')


def write(rel, text):
    (ROOT / rel).write_text(text, encoding='utf-8', newline='\n')


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'PATCH_{label}_EXPECTED_ONCE actual={count}')
    return text.replace(old, new, 1)


# 1) Feature Handoff: bind accepted preview to one durable execution identity.
p = 'scripts/feature-handoff-lib.ps1'
s = read(p)
s = replace_once(s,
"Set-StrictMode -Version Latest\n\n$script:FeatureHandoffStages",
"Set-StrictMode -Version Latest\n\n$stateContractPath = Join-Path $PSScriptRoot 'arthur-state-contract.ps1'\nif (-not (Test-Path -LiteralPath $stateContractPath -PathType Leaf)) { throw 'FEATURE_HANDOFF_STATE_CONTRACT_MISSING' }\n. $stateContractPath\n\n$script:FeatureHandoffStages",
'FEATURE_LIB_LOAD_CONTRACT')
s = replace_once(s,
"        schema_version = 1\n        feature_id = $FeatureId\n        dispatch_key = Get-FeatureHandoffKey -FeatureId $FeatureId -AcceptedPreviewSourceSha $AcceptedPreviewSourceSha\n        accepted_preview_source_sha = $AcceptedPreviewSourceSha\n",
"        schema_version = 1\n        feature_id = $FeatureId\n        execution_id = New-ArthurExecutionId -TaskSlug (($FeatureId.ToLowerInvariant() -replace '[^a-z0-9-]','-').Trim('-')) -AcceptedSourceSha $AcceptedPreviewSourceSha -Date (Get-Date)\n        dispatch_key = Get-FeatureHandoffKey -FeatureId $FeatureId -AcceptedPreviewSourceSha $AcceptedPreviewSourceSha\n        accepted_preview_source_sha = $AcceptedPreviewSourceSha\n",
'FEATURE_LIB_EXECUTION_ID')
s = replace_once(s,
"        preview_manifest_path = $PreviewManifestPath\n        preview_evidence = $PreviewEvidence\n        changed_paths = @()\n",
"        preview_manifest_path = $PreviewManifestPath\n        preview_evidence = $PreviewEvidence\n        preview_observation = [ordered]@{ scope='LIVE_PREVIEW'; result='PASS'; producer='feature-handoff'; evidence=$PreviewEvidence }\n        changed_paths = @()\n",
'FEATURE_LIB_PREVIEW_OBSERVATION')
s = replace_once(s,
"function Normalize-FeatureHandoffState {\n    param([Parameter(Mandatory)]$State)\n    $stage = [string]$State.current_stage\n",
"function Ensure-FeatureHandoffExecutionIdentity {\n    param([Parameter(Mandatory)]$State)\n    if ($State.PSObject.Properties.Name -notcontains 'execution_id' -or [string]::IsNullOrWhiteSpace([string]$State.execution_id)) {\n        $created = Get-Date\n        if ($State.PSObject.Properties.Name -contains 'created_at' -and [string]$State.created_at) {\n            $parsed = [datetime]::MinValue\n            if ([datetime]::TryParse([string]$State.created_at,[ref]$parsed)) { $created = $parsed }\n        }\n        $slug = (([string]$State.feature_id).ToLowerInvariant() -replace '[^a-z0-9-]','-').Trim('-')\n        $id = New-ArthurExecutionId -TaskSlug $slug -AcceptedSourceSha ([string]$State.accepted_preview_source_sha) -Date $created\n        Add-HandoffStateDefault $State 'execution_id' $id\n    }\n    if ($State.PSObject.Properties.Name -notcontains 'preview_observation') {\n        Add-HandoffStateDefault $State 'preview_observation' ([pscustomobject][ordered]@{ scope='LIVE_PREVIEW'; result='PASS'; producer='feature-handoff'; evidence=$State.preview_evidence })\n    }\n    return $State\n}\n\nfunction Normalize-FeatureHandoffState {\n    param([Parameter(Mandatory)]$State)\n    Ensure-FeatureHandoffExecutionIdentity -State $State | Out-Null\n    $stage = [string]$State.current_stage\n",
'FEATURE_LIB_NORMALIZE_EXECUTION')
s = replace_once(s,
"    Add-HandoffStateDefault $State 'dispatch_started_at' ''\n    Add-HandoffStateDefault $State 'dispatch_accepted' $false\n    $State.updated_at = (Get-Date).ToString('o')\n",
"    Add-HandoffStateDefault $State 'dispatch_started_at' ''\n    Add-HandoffStateDefault $State 'dispatch_accepted' $false\n    Ensure-FeatureHandoffExecutionIdentity -State $State | Out-Null\n    $State.updated_at = (Get-Date).ToString('o')\n",
'FEATURE_LIB_SAVE_EXECUTION')
write(p, s)

p = 'scripts/feature-handoff.ps1'
s = read(p)
s = replace_once(s,
"    return ([string]$r.request_id -eq [string]$State.request_id -and [string]$r.mode -eq [string]$State.v3_mode -and [string]$r.source_ref -eq [string]$State.source_ref -and [string]$r.source_sha -eq [string]$State.merge_sha -and [string]$r.accepted_diff_sha256 -eq [string]$State.accepted_diff_sha256)\n",
"    return ([string]$r.request_id -eq [string]$State.request_id -and [string]$r.execution_id -eq [string]$State.execution_id -and [string]$r.mode -eq [string]$State.v3_mode -and [string]$r.source_ref -eq [string]$State.source_ref -and [string]$r.source_sha -eq [string]$State.merge_sha -and [string]$r.accepted_diff_sha256 -eq [string]$State.accepted_diff_sha256)\n",
'FEATURE_REQUEST_MATCH_EXECUTION')
s = replace_once(s,
"        request_id=[string]$State.request_id\n        mode=[string]$State.v3_mode\n",
"        request_id=[string]$State.request_id\n        execution_id=[string]$State.execution_id\n        mode=[string]$State.v3_mode\n",
'FEATURE_REQUEST_EXECUTION')
s = replace_once(s,
"    Write-Host \"REQUEST_ID=$($state.request_id)\"\n    Write-Host \"SOURCE_REF=$($state.source_ref)\"\n",
"    Write-Host \"REQUEST_ID=$($state.request_id)\"\n    Write-Host \"EXECUTION_ID=$($state.execution_id)\"\n    Write-Host \"SOURCE_REF=$($state.source_ref)\"\n",
'FEATURE_STATUS_EXECUTION')
write(p, s)

# 2) Legacy verified display becomes a projection of valid Gate state only.
p = 'scripts/arthur-resume-state.ps1'
s = read(p)
marker = "function Resolve-ArthurResumeState {\n"
helper = """function Get-ArthurLegacyVerifiedValue {
    param([object]$GateMap,[string]$GateId,[string]$PassValue)
    $gate = Get-ArthurResumeMember $GateMap $GateId
    if ($null -eq $gate -or [string](Get-ArthurResumeMember $gate 'status') -ne 'PASS') { return 'REVERIFY_REQUIRED' }
    return $PassValue
}

"""
if helper not in s:
    s = replace_once(s, marker, helper + marker, 'RESUME_LEGACY_HELPER')
s = replace_once(s,
"        verified = [ordered]@{\n            real_device_baseline = $(if ($safe) { 'MATCHED' } else { 'RECONCILE_REQUIRED' })\n            wifi = 'VERIFIED_FROZEN'\n            luci_chinese = 'VERIFIED_FROZEN'\n            adguard_full_manager = 'LIVE_BROWSER_VERIFIED'\n            quickstart = 'AUTHENTICATED_RENDER_VERIFIED'\n        }\n",
"        verified = [ordered]@{\n            real_device_baseline = $(if ($safe) { 'MATCHED' } else { 'RECONCILE_REQUIRED' })\n            wifi = Get-ArthurLegacyVerifiedValue -GateMap $gateMap -GateId 'WIFI' -PassValue 'VERIFIED_FROZEN'\n            luci_chinese = Get-ArthurLegacyVerifiedValue -GateMap $gateMap -GateId 'LUCI_CHINESE' -PassValue 'VERIFIED_FROZEN'\n            adguard_full_manager = Get-ArthurLegacyVerifiedValue -GateMap $gateMap -GateId 'ADGUARD_FULL_MANAGER' -PassValue 'LIVE_BROWSER_VERIFIED'\n            quickstart = Get-ArthurLegacyVerifiedValue -GateMap $gateMap -GateId 'QUICKSTART' -PassValue 'AUTHENTICATED_RENDER_VERIFIED'\n        }\n",
'RESUME_VERIFIED_PROJECTION')
write(p, s)

# 3) Control Plane loads evidence, ignores state/evidence commits, reconciles Gates and emits Gate events.
p = 'scripts/arthur-control-plane.ps1'
s = read(p)
s = replace_once(s,
"    . $resumeHelperPath\n    $eventLedgerHelperPath = Join-Path $codeRoot 'scripts\\arthur-firmware-event-ledger.ps1'\n",
"    . $resumeHelperPath\n    $evidenceIndexHelperPath = Join-Path $codeRoot 'scripts\\arthur-evidence-index.ps1'\n    if (-not (Test-Path -LiteralPath $evidenceIndexHelperPath -PathType Leaf)) { Fail 'CONTROL_PLANE_EVIDENCE_HELPER_MISSING' }\n    . $evidenceIndexHelperPath\n    $eventLedgerHelperPath = Join-Path $codeRoot 'scripts\\arthur-firmware-event-ledger.ps1'\n",
'CONTROL_LOAD_EVIDENCE')
s = replace_once(s,
"            & git add -- 'production/resume-state.json' 'production/firmware-events.jsonl'\n",
"            & git add -- 'production/resume-state.json' 'production/firmware-events.jsonl'\n            & git add -- 'production/evidence/*/index.json' 2>$null\n",
'CONTROL_PUBLISH_EVIDENCE')
s = replace_once(s,
"        Save-Json $ResumeStatePath $ResumeState\n\n        if ([string]$env:GITHUB_REF_NAME -ne 'main') {\n",
"        if ($ResumeState.gates) {\n            foreach ($gateProperty in @($ResumeState.gates.PSObject.Properties)) {\n                $gateId = [string]$gateProperty.Name\n                $newGate = $gateProperty.Value\n                $newStatus = [string]$newGate.status\n                $oldStatus = ''\n                if ($existingPublished -and $existingPublished.gates -and $existingPublished.gates.PSObject.Properties[$gateId]) { $oldStatus = [string]$existingPublished.gates.PSObject.Properties[$gateId].Value.status }\n                $gateEvent = if ($newStatus -eq 'PASS' -and $oldStatus -ne 'PASS') { 'GATE_PASSED' } elseif ($newStatus -eq 'STALE' -and $oldStatus -ne 'STALE') { 'GATE_STALE' } else { '' }\n                if ($gateEvent) {\n                    $null = Add-ArthurFirmwareEvent -Path $eventLedgerPath -Event $gateEvent -Stage $gateId -Source 'ARTHUR_CONTROL_PLANE' -Timestamp $evidenceTime -Data ([ordered]@{ execution_id=[string]$ResumeState.execution_id; gate_id=$gateId; previous_status=$oldStatus; status=$newStatus; evidence_refs=@($newGate.evidence_refs) })\n                    Log \"FIRMWARE_GATE_EVENT=PASS event=$gateEvent gate=$gateId execution=$($ResumeState.execution_id)\"\n                }\n            }\n        }\n        Save-Json $ResumeStatePath $ResumeState\n\n        if ([string]$env:GITHUB_REF_NAME -ne 'main') {\n",
'CONTROL_GATE_EVENTS')
s = replace_once(s,
"        $repositoryHead = (& git log -1 --format=%H -- . ':(exclude)production/resume-state.json' ':(exclude)production/firmware-events.jsonl' | Out-String).Trim()\n",
"        $repositoryHead = (& git log -1 --format=%H -- . ':(exclude)production/resume-state.json' ':(exclude)production/firmware-events.jsonl' ':(exclude)production/evidence/**' | Out-String).Trim()\n",
'CONTROL_HEAD_EVIDENCE_EXCLUDE')
s = replace_once(s,
"    $runtimeBefore = Get-Content -Raw -LiteralPath $runtimeStatePath | ConvertFrom-Json\n    $resumeState = Resolve-ArthurResumeState -RepositoryHead $repositoryHead -RealDeviceBaseline $realDeviceBaseline -LiveDevice $device.live_build_info -RuntimeState $runtimeBefore -PreviousResumeState $previousResumeState\n",
"    $runtimeBefore = Get-Content -Raw -LiteralPath $runtimeStatePath | ConvertFrom-Json\n    $previousGateRecords = @(Get-ArthurGateRecordsFromResumeState -ResumeState $previousResumeState)\n    $currentSubjects = Get-ArthurCurrentSubjectsForRepositoryHead -GateRecords $previousGateRecords -RepositoryHead $repositoryHead\n    $activeExecutionId = if ($previousResumeState -and $previousResumeState.PSObject.Properties['execution_id']) { [string]$previousResumeState.execution_id } else { '' }\n    $v3RequestPath = Join-Path $codeRoot 'production\\v3-request.json'\n    if (-not $activeExecutionId -and (Test-Path -LiteralPath $v3RequestPath -PathType Leaf)) {\n        try { $v3Request = Get-Content -Raw -LiteralPath $v3RequestPath | ConvertFrom-Json; if ($v3Request.PSObject.Properties['execution_id']) { $activeExecutionId = [string]$v3Request.execution_id } } catch {}\n    }\n    $resumeState = Resolve-ArthurResumeState -RepositoryHead $repositoryHead -RealDeviceBaseline $realDeviceBaseline -LiveDevice $device.live_build_info -RuntimeState $runtimeBefore -PreviousResumeState $previousResumeState -ExecutionId $activeExecutionId -GateRecords $previousGateRecords -CurrentSubjects $currentSubjects\n",
'CONTROL_GATE_RECONCILE')
write(p, s)

# 4) Production Agent submits durable observations while preserving at-most-once flash semantics.
p = 'scripts/production-agent.ps1'
s = read(p)
s = replace_once(s,
". (Join-Path $PSScriptRoot 'real-device-baseline-lib.ps1')\n$Out = Join-Path $Root 'output\\production-agent'\n",
". (Join-Path $PSScriptRoot 'real-device-baseline-lib.ps1')\n. (Join-Path $PSScriptRoot 'arthur-state-contract.ps1')\n. (Join-Path $PSScriptRoot 'arthur-evidence-index.ps1')\n$script:ProductionEvidenceTypes = @('ARTIFACT_MANIFEST','FLASH_SAFETY_REPORT','FLASH_EVENT','REAL_DEVICE_REPORT','GITHUB_RELEASE')\n$Out = Join-Path $Root 'output\\production-agent'\n",
'AGENT_LOAD_EVIDENCE')
s = replace_once(s,
"        schema_version='1.1'; stage='REQUESTED'; status='LIVE'; run_id=$RequestedRunId;\n        artifact_id=[long]0; artifact_name=''; source_sha=''; candidate_sha256=''; candidate_path='';\n",
"        schema_version='1.2'; stage='REQUESTED'; status='LIVE'; run_id=$RequestedRunId; execution_id='';\n        artifact_id=[long]0; artifact_name=''; source_sha=''; candidate_sha256=''; candidate_path='';\n",
'AGENT_STATE_EXECUTION')
insert_after = "function At-Or-After($State,[string]$Stage) { return (Stage-Index ([string]$State.stage)) -ge (Stage-Index $Stage) }\n\n"
helper = """function Ensure-ProductionExecutionId($State) {
    if ($State.PSObject.Properties.Name -notcontains 'execution_id') { $State | Add-Member -NotePropertyName execution_id -NotePropertyValue '' }
    if ([string]$State.execution_id) { return [string]$State.execution_id }
    foreach ($candidatePath in @((Join-Path $Root 'production\\v3-request.json'),(Join-Path $Root 'production\\resume-state.json'))) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            try {
                $candidate = Get-Content -Raw -LiteralPath $candidatePath | ConvertFrom-Json
                if ($candidate.PSObject.Properties['execution_id'] -and [string]$candidate.execution_id) { $State.execution_id=[string]$candidate.execution_id; return [string]$State.execution_id }
            } catch {}
        }
    }
    if ([string]$State.source_sha -match '^[0-9a-fA-F]{40}$') {
        $State.execution_id = New-ArthurExecutionId -TaskSlug 'production' -AcceptedSourceSha ([string]$State.source_sha).ToLowerInvariant() -Date (Get-Date)
        return [string]$State.execution_id
    }
    return ''
}

function Write-ProductionEvidence($State,[string]$GateId,[string]$Type,[string]$EvidenceId,[string]$Ref,[string]$Result,[string]$ContentSha='',[string]$DeviceBuildId='') {
    $executionId = Ensure-ProductionExecutionId $State
    if (-not $executionId) { throw 'PRODUCTION_EVIDENCE_EXECUTION_ID_UNRESOLVED' }
    $path = Get-ArthurEvidenceIndexPath -Root $Root -ExecutionId $executionId
    $record = [ordered]@{
        evidence_id=$EvidenceId; gate_id=$GateId; type=$Type; producer='scripts/production-agent.ps1';
        source_sha=[string]$State.source_sha; github_run_id=[long]$State.run_id; artifact_id=[long]$State.artifact_id;
        candidate_sha256=[string]$State.candidate_sha256; device_build_id=$DeviceBuildId; ref=$Ref; sha256=$ContentSha;
        observed_at=[DateTimeOffset]::UtcNow.ToString('o'); result=$Result
    }
    Add-ArthurEvidenceRecord -Path $path -Record $record | Out-Null
    Save-State $State ([string]$State.stage) ([string]$State.status)
    Log "EVIDENCE_RECORDED execution=$executionId gate=$GateId type=$Type result=$Result"
}

"""
if helper not in s:
    s = replace_once(s, insert_after, insert_after + helper, 'AGENT_EVIDENCE_HELPER')
s = replace_once(s,
"    $State.source_sha = [string]$manifest.source_sha\n    Save-State $State 'CANDIDATE_VERIFIED' 'VERIFIED'\n",
"    $State.source_sha = [string]$manifest.source_sha\n    Save-State $State 'CANDIDATE_VERIFIED' 'VERIFIED'\n    Write-ProductionEvidence $State 'ARTIFACT' 'ARTIFACT_MANIFEST' (\"artifact-$($State.run_id)-$($State.artifact_id)\") (\"github-artifact:$($State.artifact_id)\") 'PASS' ([string]$State.candidate_sha256)\n",
'AGENT_ARTIFACT_EVIDENCE')
s = replace_once(s,
"    Write-Host 'AUTO_FLASH_SAFETY_GATE=PASS'\n    Save-State $State 'AUTO_FLASH_SAFETY_GATE' 'VERIFIED'\n",
"    Write-Host 'AUTO_FLASH_SAFETY_GATE=PASS'\n    Save-State $State 'AUTO_FLASH_SAFETY_GATE' 'VERIFIED'\n    $safetyLog = Join-Path $Out 'auto-flash-safety-gate.log'\n    $safetyHash = if (Test-Path $safetyLog) { (Get-FileHash -Algorithm SHA256 $safetyLog).Hash.ToLowerInvariant() } else { '' }\n    Write-ProductionEvidence $State 'AUTO_FLASH_SAFETY_GATE' 'FLASH_SAFETY_REPORT' (\"flash-safety-$($State.run_id)\") 'output/production-agent/auto-flash-safety-gate.log' 'PASS' $safetyHash\n",
'AGENT_SAFETY_EVIDENCE')
s = replace_once(s,
"    $args = ([string]$Profile.argument_template).Replace('{remote_candidate}',$Remote)\n    $command = \"$( [string]$Profile.remote_upgrade_binary ) $args\"\n    Save-State $State 'FLASH_STARTED' 'LIVE'\n",
"    $args = ([string]$Profile.argument_template).Replace('{remote_candidate}',$Remote)\n    $command = \"$( [string]$Profile.remote_upgrade_binary ) $args\"\n    Write-ProductionEvidence $State 'FLASH' 'FLASH_EVENT' (\"flash-start-$($State.run_id)\") (\"target:$Target\") 'STARTED'\n    Save-State $State 'FLASH_STARTED' 'LIVE'\n",
'AGENT_FLASH_EVIDENCE')
s = replace_once(s,
"    $State.repair_controller_started = $false\n    Save-State $State 'RELEASE_GATE' 'VERIFIED'\n",
"    $State.repair_controller_started = $false\n    $reportHash = (Get-FileHash -Algorithm SHA256 $report).Hash.ToLowerInvariant()\n    $deviceBuildId = if ($result.PSObject.Properties['build_id']) { [string]$result.build_id } elseif ($result.PSObject.Properties['device_build_id']) { [string]$result.device_build_id } else { '' }\n    Write-ProductionEvidence $State 'REAL_DEVICE_VERIFY' 'REAL_DEVICE_REPORT' (\"real-device-$($State.run_id)\") 'output/real-device/real-device-verification.json' 'PASS' $reportHash $deviceBuildId\n    Save-State $State 'RELEASE_GATE' 'VERIFIED'\n",
'AGENT_DEVICE_EVIDENCE')
s = replace_once(s,
"    Save-State $State 'PRODUCTION_RELEASED' 'VERIFIED'\n    Write-Host 'PRODUCTION_RELEASED=YES'\n",
"    Write-ProductionEvidence $State 'RELEASE' 'GITHUB_RELEASE' (\"release-$($State.run_id)\") (\"github-release:$tag\") 'PASS'\n    Save-State $State 'PRODUCTION_RELEASED' 'VERIFIED'\n    Write-Host 'PRODUCTION_RELEASED=YES'\n",
'AGENT_RELEASE_EVIDENCE')
write(p, s)

print('UNIFIED_STATE_PATCH=PASS')
