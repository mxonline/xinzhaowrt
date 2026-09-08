$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ContractPath = Join-Path $Root 'scripts\arthur-state-contract.ps1'
$ResumePath = Join-Path $Root 'scripts\arthur-resume-state.ps1'
$ControlPlanePath = Join-Path $Root 'scripts\arthur-control-plane.ps1'
$FirmwareResumePath = Join-Path $Root 'scripts\arthur-firmware-resume.ps1'
$ConsistencyPath = Join-Path $Root 'scripts\arthur-state-consistency.ps1'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}
function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ($Actual -ne $Expected) { throw "TEST_FAIL: $Message (actual='$Actual' expected='$Expected')" }
}
function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message (missing '$Needle')"
    }
}

. $ContractPath
. $ResumePath
Assert-True (Test-Path -LiteralPath $ConsistencyPath -PathType Leaf) 'runtime consistency helper must exist'
. $ConsistencyPath

$baseline = [pscustomobject]@{
    active_development_baseline = $true
    firmware = [pscustomobject]@{
        version='0.1.3'; build_id='33462873812'; build_date='2026-09-01';
        source_sha=('a' * 40); github_run_id=100; artifact_id=200; sha256=('b' * 64)
    }
}
$live = [pscustomobject]@{ version='0.1.3'; build_id='33462873812'; git_commit='aaaaaaa' }
$runtime = [pscustomobject]@{ phase='BUILD'; current_stage='BUILD'; next_action='BUILD'; turn_count=1 }
$digest = Get-ArthurRequirementDigest -RequirementText 'gate requirement'
$build = New-ArthurGateRecord -GateId 'BUILD' -RequirementRef 'x#build' -RequirementDigest $digest -Status 'PASS' -Subject @{ source_sha=('c' * 40) } -EvidenceRefs @('e:build')
$artifact = New-ArthurGateRecord -GateId 'ARTIFACT' -RequirementRef 'x#artifact' -RequirementDigest $digest -Status 'RUNNING' -Subject @{ source_sha=('c' * 40) }
$preflash = New-ArthurGateRecord -GateId 'PRE_FLASH' -RequirementRef 'x#preflash' -RequirementDigest $digest -Status 'PENDING' -Subject @{}

$gateDriven = Resolve-ArthurResumeState `
    -RepositoryHead ('c' * 40) `
    -RealDeviceBaseline $baseline `
    -LiveDevice $live `
    -RuntimeState $runtime `
    -ExecutionId 'arthur-release-aaaaaaa-20260908' `
    -GateRecords @($build,$artifact,$preflash) `
    -CurrentSubjects @{ BUILD=@{source_sha=('c'*40)}; ARTIFACT=@{source_sha=('c'*40)}; PRE_FLASH=@{} }
Assert-Equal $gateDriven.current_gate 'ARTIFACT' 'first incomplete Gate must replace legacy runtime phase as current_gate'
Assert-Equal $gateDriven.next_action 'ARTIFACT' 'next_action must come from first incomplete Gate'
Assert-Equal $gateDriven.checkpoint.next_action 'ARTIFACT' 'compatibility checkpoint must mirror Gate arbitration'
Assert-Equal @($gateDriven.pending)[0] 'ARTIFACT' 'pending must expose Gate-driven next action'

$wifi = New-ArthurGateRecord -GateId 'WIFI' -RequirementRef 'x#wifi' -RequirementDigest $digest -Status 'PASS' -Subject @{ source_sha=('c'*40) } -Inherited $true -InheritedFrom 'production/wifi-frozen-baseline.json'
$currentSubjects = Get-ArthurCurrentSubjectsForRepositoryHead -GateRecords @($build,$wifi) -RepositoryHead ('d' * 40)
Assert-Equal $currentSubjects.BUILD.source_sha ('d' * 40) 'non-inherited source-bound Gate must track current repository head'
Assert-Equal $currentSubjects.WIFI.source_sha ('c' * 40) 'inherited frozen Gate must retain accepted subject until change-impact explicitly invalidates it'

$previousState = [pscustomobject]@{ gates=[pscustomobject]@{ BUILD=$build; WIFI=$wifi } }
$extracted = @(Get-ArthurGateRecordsFromResumeState -ResumeState $previousState)
Assert-Equal $extracted.Count 2 'schema-v2 gate map must round-trip into gate records'

# Runtime consistency must bind state, Gate order, evidence index, and the latest execution-aware ledger event.
$executionId = 'arthur-release-aaaaaaa-20260908'
$consistencyBuild = New-ArthurGateRecord -GateId 'BUILD' -RequirementRef 'x#build' -RequirementDigest $digest -Status 'RUNNING' -Subject @{ source_sha=('c' * 40); github_run_id=12 } -EvidenceRefs @('evidence:build-run-12')
$consistencyArtifact = New-ArthurGateRecord -GateId 'ARTIFACT' -RequirementRef 'x#artifact' -RequirementDigest $digest -Status 'PENDING' -Subject @{ source_sha=('c' * 40); github_run_id=12 }
$consistencyState = [pscustomobject]@{
    schema_version = 2
    execution_id = $executionId
    current_gate = 'BUILD'
    next_action = 'BUILD'
    gates = [pscustomobject]@{ BUILD=$consistencyBuild; ARTIFACT=$consistencyArtifact }
}
$consistencyEvidence = [pscustomobject]@{
    schema_version = 1
    execution_id = $executionId
    evidence = @([pscustomobject]@{ evidence_id='build-run-12'; gate_id='BUILD'; result='RUNNING' })
}
$consistencyEvents = @([pscustomobject]@{
    event='GATE_STARTED'; stage='BUILD'; data=[pscustomobject]@{ execution_id=$executionId; gate_id='BUILD' }
})
$consistent = Test-ArthurRuntimeStateConsistency -ResumeState $consistencyState -Events $consistencyEvents -EvidenceIndex $consistencyEvidence
Assert-True $consistent.consistent 'matching execution state, evidence, and ledger must be consistent'
Assert-Equal $consistent.expected_gate 'BUILD' 'consistency gate must derive expected current Gate from Gate status, not legacy verified/checkpoint strings'

$wrongEvidence = [pscustomobject]@{ schema_version=1; execution_id='arthur-other-aaaaaaa-20260908'; evidence=@() }
$wrongEvidenceResult = Test-ArthurRuntimeStateConsistency -ResumeState $consistencyState -Events $consistencyEvents -EvidenceIndex $wrongEvidence
Assert-True (-not $wrongEvidenceResult.consistent) 'evidence from another execution must fail closed'
Assert-True (@($wrongEvidenceResult.conflicts) -contains 'EVIDENCE_EXECUTION_ID_MISMATCH') 'execution mismatch must be explicit'

$missingEvidence = [pscustomobject]@{ schema_version=1; execution_id=$executionId; evidence=@() }
$missingEvidenceResult = Test-ArthurRuntimeStateConsistency -ResumeState $consistencyState -Events $consistencyEvents -EvidenceIndex $missingEvidence
Assert-True (-not $missingEvidenceResult.consistent) 'Gate evidence ref missing from durable index must fail closed'
Assert-True (@($missingEvidenceResult.conflicts) -contains 'GATE_EVIDENCE_REF_MISSING:BUILD:build-run-12') 'missing evidence id must identify the affected Gate'

$wrongLedgerEvents = @([pscustomobject]@{
    event='GATE_STARTED'; stage='BUILD'; data=[pscustomobject]@{ execution_id='arthur-other-aaaaaaa-20260908'; gate_id='BUILD' }
})
$wrongLedger = Test-ArthurRuntimeStateConsistency -ResumeState $consistencyState -Events $wrongLedgerEvents -EvidenceIndex $consistencyEvidence
Assert-True (-not $wrongLedger.consistent) 'latest execution-aware ledger event from another execution must fail closed'
Assert-True (@($wrongLedger.conflicts) -contains 'LEDGER_LATEST_EXECUTION_ID_MISMATCH') 'ledger execution mismatch must be explicit'

$wrongGateState = [pscustomobject]@{
    schema_version=2; execution_id=$executionId; current_gate='ARTIFACT'; next_action='ARTIFACT';
    gates=[pscustomobject]@{ BUILD=$consistencyBuild; ARTIFACT=$consistencyArtifact }
}
$wrongGate = Test-ArthurRuntimeStateConsistency -ResumeState $wrongGateState -Events $consistencyEvents -EvidenceIndex $consistencyEvidence
Assert-True (-not $wrongGate.consistent) 'current_gate may not contradict first incomplete Gate'
Assert-True (@($wrongGate.conflicts) -contains 'CURRENT_GATE_MISMATCH:ARTIFACT:BUILD') 'Gate mismatch must name claimed and expected Gates'

# PR #73 behavior is frozen: stale REAL_DEVICE_VERIFY canonical checkpoints normalize to ADH_MANAGEMENT.
$stale73 = [pscustomobject]@{
    production_task='arthur-adh-quickstart'
    checkpoint=[pscustomobject]@{ current='REAL_DEVICE_VERIFY'; next_action='REAL_DEVICE_VERIFY'; status='BLOCKED_BUILD_INFO_PROVENANCE' }
}
$frozen73 = Resolve-ArthurControlPlaneCheckpoint -ExistingCanonical $stale73
Assert-Equal $frozen73.current 'ADH_MANAGEMENT' '#73 stale checkpoint normalization must remain unchanged'
Assert-Equal $frozen73.next_action 'ADH_MANAGEMENT' '#73 next action must remain ADH_MANAGEMENT'

$controlPlane = Get-Content -Raw $ControlPlanePath
Assert-Contains $controlPlane 'arthur-evidence-index.ps1' 'Control Plane must load evidence-index helper'
Assert-Contains $controlPlane 'Get-ArthurGateRecordsFromResumeState' 'Control Plane must reconcile previous Gate records'
Assert-Contains $controlPlane 'Get-ArthurCurrentSubjectsForRepositoryHead' 'Control Plane must refresh source-bound Gate subjects before arbitration'
Assert-Contains $controlPlane 'production/evidence/**' 'Control Plane non-state HEAD must exclude durable evidence-index commits'
Assert-Contains $controlPlane 'GATE_STALE' 'Control Plane must append explicit Gate staleness events'
Assert-Contains $controlPlane 'GATE_PASSED' 'Control Plane must append explicit Gate PASS events'

$firmwareResume = Get-Content -Raw $FirmwareResumePath
Assert-Contains $firmwareResume 'production/evidence/**' 'resume gate effective HEAD must ignore evidence-index-only commits'
Assert-Contains $firmwareResume 'resume.source.repository_head' 'resume gate must prefer schema-v2 nested source identity'
Assert-Contains $firmwareResume 'execution_id' 'resume gate output must expose execution identity'
Assert-Contains $firmwareResume 'gates' 'resume gate output must expose reconciled Gate state'
Assert-Contains $firmwareResume 'arthur-state-consistency.ps1' 'resume gate must load runtime consistency helper'
Assert-Contains $firmwareResume 'Test-ArthurRuntimeStateConsistency' 'resume gate must fail closed on cross-store state inconsistency'

Write-Host 'ARTHUR_CONTROL_PLANE_GATES=PASS'
