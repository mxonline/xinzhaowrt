$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ContractPath = Join-Path $Root 'scripts\arthur-state-contract.ps1'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}

function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ($Actual -ne $Expected) { throw "TEST_FAIL: $Message (actual='$Actual' expected='$Expected')" }
}

function Assert-Throws {
    param([scriptblock]$Action,[string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "TEST_FAIL: $Message" }
}

Assert-True (Test-Path -LiteralPath $ContractPath -PathType Leaf) 'Arthur state-contract helper must exist'
. $ContractPath

$id = New-ArthurExecutionId -TaskSlug 'adh-cn' -AcceptedSourceSha ('a' * 40) -Date ([datetime]'2026-09-08')
Assert-Equal $id 'arthur-adh-cn-aaaaaaa-20260908' 'execution id must be deterministic'

$d1 = Get-ArthurRequirementDigest -RequirementText 'Default language: zh_cn'
$d2 = Get-ArthurRequirementDigest -RequirementText 'Default language: zh_cn'
$d3 = Get-ArthurRequirementDigest -RequirementText 'Default language: en'
Assert-Equal $d1 $d2 'same requirement must hash identically'
Assert-True ($d1 -ne $d3) 'changed requirement must produce a different digest'
Assert-True ($d1 -match '^[0-9a-f]{64}$') 'requirement digest must be lowercase SHA256'

$gate = New-ArthurGateRecord `
    -GateId 'ARTIFACT' `
    -RequirementRef 'production/release-policy.md#Candidate' `
    -RequirementDigest $d1 `
    -Status 'PASS' `
    -Subject @{
        source_sha = ('b' * 40)
        github_run_id = 12
        artifact_id = 34
        candidate_sha256 = ('c' * 64)
    } `
    -EvidenceRefs @('production/evidence/x/index.json#artifact')

Assert-Equal $gate.status 'PASS' 'evidence-backed gate may be PASS'
Assert-Equal $gate.gate_id 'ARTIFACT' 'gate id must be retained'
Assert-Equal $gate.requirement_digest $d1 'gate must bind requirement digest'

Assert-Throws {
    New-ArthurGateRecord `
        -GateId 'ARTIFACT' `
        -RequirementRef 'x' `
        -RequirementDigest $d1 `
        -Status 'PASS' `
        -Subject @{} `
        -EvidenceRefs @()
} 'PASS without evidence must fail closed'

$inherited = New-ArthurGateRecord `
    -GateId 'WIFI' `
    -RequirementRef 'production/ARTHUR_PRODUCT_TARGETS.md#Required-Wi-Fi-target' `
    -RequirementDigest $d1 `
    -Status 'PASS' `
    -Subject @{ source_sha = ('b' * 40) } `
    -EvidenceRefs @() `
    -Inherited $true `
    -InheritedFrom 'production/wifi-frozen-baseline.json'
Assert-Equal $inherited.status 'PASS' 'explicit inherited provenance may support PASS without a direct evidence ref'

$currentChangedSource = @{
    source_sha = ('d' * 40)
    github_run_id = 12
    artifact_id = 34
    candidate_sha256 = ('c' * 64)
}
Assert-Equal (Resolve-ArthurGateStatus -Gate $gate -CurrentSubject $currentChangedSource) 'STALE' 'source change must stale source-bound artifact evidence'

$currentSameSubject = @{
    source_sha = ('b' * 40)
    github_run_id = 12
    artifact_id = 34
    candidate_sha256 = ('c' * 64)
}
Assert-Equal (Resolve-ArthurGateStatus -Gate $gate -CurrentSubject $currentSameSubject) 'PASS' 'matching subject must preserve PASS'
Assert-Equal (Resolve-ArthurGateStatus -Gate $gate -CurrentSubject $currentSameSubject -CurrentRequirementDigest $d3) 'STALE' 'changed requirement digest must stale old PASS'

$pending = New-ArthurGateRecord -GateId 'BUILD' -RequirementRef 'x' -RequirementDigest $d1 -Status 'PENDING' -Subject @{}
$running = New-ArthurGateRecord -GateId 'ARTIFACT' -RequirementRef 'x' -RequirementDigest $d1 -Status 'RUNNING' -Subject @{}
$passed = New-ArthurGateRecord -GateId 'PRE_FLASH' -RequirementRef 'x' -RequirementDigest $d1 -Status 'PASS' -Subject @{} -EvidenceRefs @('evidence:preflash')
$next = Get-ArthurNextRequiredGate -Gates @($passed,$running,$pending) -GateOrder @('BUILD','ARTIFACT','PRE_FLASH')
Assert-Equal $next.gate_id 'BUILD' 'next Gate must be the earliest required non-PASS/non-SKIPPED gate'

$skipped = New-ArthurGateRecord -GateId 'BUILD' -RequirementRef 'x' -RequirementDigest $d1 -Status 'SKIPPED' -Subject @{}
$nextAfterSkip = Get-ArthurNextRequiredGate -Gates @($skipped,$passed) -GateOrder @('BUILD','PRE_FLASH')
Assert-True ($null -eq $nextAfterSkip) 'all PASS/SKIPPED gates must yield no next Gate'

Write-Host 'ARTHUR_STATE_CONTRACT=PASS'
