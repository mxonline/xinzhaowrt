$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ResumePath = Join-Path $Root 'scripts\arthur-resume-state.ps1'
$ContractPath = Join-Path $Root 'scripts\arthur-state-contract.ps1'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}

function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ($Actual -ne $Expected) { throw "TEST_FAIL: $Message (actual='$Actual' expected='$Expected')" }
}

Assert-True (Test-Path $ResumePath) 'resume-state helper must exist'
Assert-True (Test-Path $ContractPath) 'state-contract helper must exist'
. $ContractPath
. $ResumePath

$baseline = [pscustomobject]@{
    active_development_baseline = $true
    firmware = [pscustomobject]@{
        version = '0.1.3'
        build_id = '33462873812'
        build_date = '2026-09-01'
        source_sha = 'e27bafac2d4a3ecf0f7a0e4cf2f7b34cf77571c9'
        github_run_id = 33462873812
        artifact_id = 9784138318
        sha256 = ('b' * 64)
    }
}
$live = [pscustomobject]@{
    version = '0.1.3'
    build_id = '33462873812'
    git_commit = 'e27bafa'
}
$runtime = [pscustomobject]@{
    phase = 'ARTIFACT'
    current_stage = 'ARTIFACT'
    next_action = 'ARTIFACT'
    turn_count = 6
}

$v2 = Resolve-ArthurResumeState -RepositoryHead ('a' * 40) -RealDeviceBaseline $baseline -LiveDevice $live -RuntimeState $runtime
Assert-Equal $v2.schema_version 2 'resume-state must emit schema v2'
Assert-Equal $v2.execution_id 'arthur-migrated-e27bafa-20260901' 'legacy migration must derive deterministic execution identity from accepted baseline date/source'
Assert-Equal $v2.source.repository_head ('a' * 40) 'schema v2 source must contain repository head'
Assert-Equal $v2.repository_head $v2.source.repository_head 'compatibility repository_head must match schema v2 source'
Assert-Equal $v2.device.build_id '33462873812' 'schema v2 device identity must be present'
Assert-Equal $v2.real_device.build_id $v2.device.build_id 'compatibility real_device must mirror schema v2 device'
Assert-Equal $v2.production.github_run_id 33462873812 'schema v2 production identity must carry baseline run during migration fallback'
Assert-Equal $v2.production.artifact_id 9784138318 'schema v2 production identity must carry baseline artifact during migration fallback'
Assert-Equal $v2.current_gate 'ARTIFACT' 'schema v2 current gate must reflect runtime phase during migration'
Assert-Equal $v2.next_action 'ARTIFACT' 'existing runtime next_action must remain compatible before Control Plane gate arbitration lands'
Assert-True (-not $v2.gates.PSObject.Properties['WIFI']) 'legacy fixed verified strings must not manufacture a WIFI Gate PASS'

$previousV2 = [pscustomobject]@{
    schema_version = 2
    execution_id = 'arthur-adh-cn-e27bafa-20260908'
    status = 'RESUME_SAFE'
    checkpoint = [pscustomobject]@{ current = 'ARTIFACT'; next_action = 'ARTIFACT' }
}
$reused = Resolve-ArthurResumeState -RepositoryHead ('a' * 40) -RealDeviceBaseline $baseline -LiveDevice $live -RuntimeState $runtime -PreviousResumeState $previousV2
Assert-Equal $reused.execution_id 'arthur-adh-cn-e27bafa-20260908' 'existing schema-v2 execution identity must survive resume'

$artifactDigest = Get-ArthurRequirementDigest -RequirementText 'artifact requirement v1'
$wifiDigest = Get-ArthurRequirementDigest -RequirementText 'wifi requirement v1'
$artifactGate = New-ArthurGateRecord `
    -GateId 'ARTIFACT' `
    -RequirementRef 'production/release-policy.md#Candidate' `
    -RequirementDigest $artifactDigest `
    -Status 'PASS' `
    -Subject @{ source_sha = ('e' * 40); candidate_sha256 = ('c' * 64) } `
    -EvidenceRefs @('evidence:artifact')
$wifiGate = New-ArthurGateRecord `
    -GateId 'WIFI' `
    -RequirementRef 'production/ARTHUR_PRODUCT_TARGETS.md#Required-Wi-Fi-target' `
    -RequirementDigest $wifiDigest `
    -Status 'PASS' `
    -Subject @{ source_sha = ('e' * 40) } `
    -Inherited $true `
    -InheritedFrom 'production/wifi-frozen-baseline.json'

$subjects = @{
    ARTIFACT = @{ source_sha = ('e' * 40); candidate_sha256 = ('d' * 64) }
    WIFI = @{ source_sha = ('e' * 40) }
}
$digests = @{
    ARTIFACT = $artifactDigest
    WIFI = $wifiDigest
}
$staleCandidate = Resolve-ArthurResumeState `
    -RepositoryHead ('a' * 40) `
    -RealDeviceBaseline $baseline `
    -LiveDevice $live `
    -RuntimeState $runtime `
    -ExecutionId 'arthur-adh-cn-e27bafa-20260908' `
    -GateRecords @($artifactGate,$wifiGate) `
    -CurrentSubjects $subjects `
    -RequirementDigests $digests
Assert-Equal $staleCandidate.gates.ARTIFACT.status 'STALE' 'candidate identity change must stale candidate-bound Gate'
Assert-Equal $staleCandidate.gates.WIFI.status 'PASS' 'candidate change must not stale unrelated inherited Wi-Fi evidence'

$changedWifiDigests = @{
    ARTIFACT = $artifactDigest
    WIFI = (Get-ArthurRequirementDigest -RequirementText 'wifi requirement v2')
}
$staleRequirement = Resolve-ArthurResumeState `
    -RepositoryHead ('a' * 40) `
    -RealDeviceBaseline $baseline `
    -LiveDevice $live `
    -RuntimeState $runtime `
    -ExecutionId 'arthur-adh-cn-e27bafa-20260908' `
    -GateRecords @($wifiGate) `
    -CurrentSubjects $subjects `
    -RequirementDigests $changedWifiDigests
Assert-Equal $staleRequirement.gates.WIFI.status 'STALE' 'requirement digest change must stale inherited historical PASS'

$legacy = Get-Content -Raw (Join-Path $Root 'tests\fixtures\arthur-v015-terminal-schema1.json') | ConvertFrom-Json
Assert-Equal $legacy.schema_version 1 'v0.1.5 fixture must preserve the original terminal schema'
if ([int]$legacy.schema_version -eq 1) {
    $status = Get-Content -Raw (Join-Path $Root 'production\status.json') | ConvertFrom-Json
    $knownGood = Get-Content -Raw (Join-Path $Root 'production\known-good.json') | ConvertFrom-Json
    $productGoalVerification = Get-Content -Raw (Join-Path $Root 'production\product-goal-verification.json') | ConvertFrom-Json
    $wifiBaseline = Get-Content -Raw (Join-Path $Root 'production\wifi-frozen-baseline.json') | ConvertFrom-Json
    $migrated = Convert-ArthurLegacyTerminalResumeState -Legacy $legacy -Status $status -ProductGoalVerification $productGoalVerification -KnownGood $knownGood -WifiBaseline $wifiBaseline -RepositoryRoot $Root -RepositoryHead ('a' * 40)
    Assert-Equal $migrated.schema_version 2 'legacy terminal snapshot must migrate to schema v2'
    Assert-Equal $migrated.status 'PRODUCTION_RELEASED' 'legacy terminal must remain terminal'
    Assert-Equal $migrated.instruction_allowed $false 'legacy terminal must not authorize execution'
    Assert-Equal $migrated.source.accepted_source_sha $status.source_commit 'migration must preserve exact latest Stable source'
    Assert-Equal $migrated.production.github_run_id $status.run_id 'migration must preserve exact latest Stable build'
    Assert-Equal $migrated.production.candidate_sha256 $status.sysupgrade_sha256 'migration must preserve exact latest Stable image hash'
    Assert-Equal $knownGood.source_commit '236abeaaea06442aa0f8f34efd0b4464b35c5061' 'migration must leave the historical rollback Known-Good source intact'
    Assert-Equal $migrated.verified.wifi 'VERIFIED_FROZEN' 'migration must preserve separately hash-verified frozen Wi-Fi baseline status'
    Assert-Equal @($migrated.gates.PSObject.Properties).Count 0 'legacy string gate summaries must not become fabricated Gate PASS records'
    $badWifiBaseline = $wifiBaseline | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $badWifiBaseline.source_git_blob_sha = ('f' * 40)
    $wifiConflict = $false
    try { $null = Convert-ArthurLegacyTerminalResumeState -Legacy $legacy -Status $status -ProductGoalVerification $productGoalVerification -KnownGood $knownGood -WifiBaseline $badWifiBaseline -RepositoryRoot $Root -RepositoryHead ('a' * 40) }
    catch { $wifiConflict = $true }
    Assert-True $wifiConflict 'mismatched frozen Wi-Fi source hash must block migration'
    $knownGoodConflict = $false
    $badKnownGood = $knownGood | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $badKnownGood.target = 'ipq40xx'
    try { $null = Convert-ArthurLegacyTerminalResumeState -Legacy $legacy -Status $status -ProductGoalVerification $productGoalVerification -KnownGood $badKnownGood -WifiBaseline $wifiBaseline -RepositoryRoot $Root -RepositoryHead ('a' * 40) }
    catch { $knownGoodConflict = $true }
    Assert-True $knownGoodConflict 'Known-Good must independently identify the Arthur qualcommax/ipq60xx device'
    $conflict = $false
    $badProductGoalVerification = $productGoalVerification | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $badProductGoalVerification.sysupgrade_sha256 = ('f' * 64)
    try { $null = Convert-ArthurLegacyTerminalResumeState -Legacy $legacy -Status $status -ProductGoalVerification $badProductGoalVerification -KnownGood $knownGood -WifiBaseline $wifiBaseline -RepositoryRoot $Root -RepositoryHead ('a' * 40) }
    catch { $conflict = $true }
    Assert-True $conflict 'mismatched latest production image hash must block migration'
}

Write-Host 'ARTHUR_RESUME_STATE_V2=PASS'
