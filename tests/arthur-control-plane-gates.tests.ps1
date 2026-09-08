$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ContractPath = Join-Path $Root 'scripts\arthur-state-contract.ps1'
$ResumePath = Join-Path $Root 'scripts\arthur-resume-state.ps1'
$ControlPlanePath = Join-Path $Root 'scripts\arthur-control-plane.ps1'
$FirmwareResumePath = Join-Path $Root 'scripts\arthur-firmware-resume.ps1'

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

Write-Host 'ARTHUR_CONTROL_PLANE_GATES=PASS'
