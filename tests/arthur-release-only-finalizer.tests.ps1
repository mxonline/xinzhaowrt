$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalizerPath = Join-Path $Root 'scripts\arthur-release-only-state.ps1'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}
function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ($Actual -ne $Expected) { throw "TEST_FAIL: $Message (actual='$Actual' expected='$Expected')" }
}
function New-Gate([string]$Id,[string]$Status) {
    return [pscustomobject][ordered]@{
        gate_id=$Id; status=$Status; requirement_ref="test#$Id"; requirement_digest=('a' * 64);
        subject=[pscustomobject]@{}; evidence_refs=@(); inherited=$false; inherited_from=''; verified_at=''
    }
}

Assert-True (Test-Path -LiteralPath $FinalizerPath -PathType Leaf) 'release-only terminal state helper must exist'
. $FinalizerPath

$gates = [pscustomobject][ordered]@{
    BUILD = New-Gate 'BUILD' 'PASS'
    ARTIFACT = New-Gate 'ARTIFACT' 'PASS'
    PRE_FLASH = New-Gate 'PRE_FLASH' 'PENDING'
    AUTO_FLASH_SAFETY_GATE = New-Gate 'AUTO_FLASH_SAFETY_GATE' 'PENDING'
    FLASH = New-Gate 'FLASH' 'PENDING'
    WAIT_DEVICE = New-Gate 'WAIT_DEVICE' 'PENDING'
    IDENTIFY = New-Gate 'IDENTIFY' 'PENDING'
    LAN_RUNTIME = New-Gate 'LAN_RUNTIME' 'PENDING'
    DHCP = New-Gate 'DHCP' 'PENDING'
    WAN = New-Gate 'WAN' 'PENDING'
    DNS = New-Gate 'DNS' 'PENDING'
    SSH = New-Gate 'SSH' 'PENDING'
    LUCI = New-Gate 'LUCI' 'PENDING'
    PLUGIN_RUNTIME_22 = New-Gate 'PLUGIN_RUNTIME_22' 'PENDING'
    ARGON_KUCAT_RUNTIME = New-Gate 'ARGON_KUCAT_RUNTIME' 'PENDING'
    SYSTEM_HEALTH = New-Gate 'SYSTEM_HEALTH' 'PENDING'
    RELEASE_GATE = New-Gate 'RELEASE_GATE' 'PENDING'
    RELEASE = New-Gate 'RELEASE' 'PENDING'
    PRODUCTION_RELEASED = New-Gate 'PRODUCTION_RELEASED' 'PENDING'
}
$resume = [pscustomobject][ordered]@{
    schema_version=2; execution_id='arthur-release-aaaaaaa-20260915'; status='RESUME_SAFE'; instruction_allowed=$true; release='';
    source=[pscustomobject][ordered]@{ repository_head=('a' * 40); accepted_source_sha=('a' * 40); accepted_release=''; accepted_firmware=''; accepted_firmware_sha256='' };
    production=[pscustomobject][ordered]@{ github_run_id=123; artifact_id=456; release_id=0; release=''; release_url=''; firmware=''; candidate_sha256='' };
    gates=$gates; current_gate='PRE_FLASH'; next_action='PRE_FLASH'; pending=@('PRE_FLASH'); post_release_device_test='';
    checkpoint=[pscustomobject][ordered]@{ current='PRE_FLASH'; next_action='PRE_FLASH'; turn_count=1 }
}
$intent = [pscustomobject][ordered]@{
    schema_version='1.1'; project='Arthur'; intent_type='EXECUTE_FIRMWARE'; authorization_scope='FIRMWARE_RELEASE'; firmware_execution_authorized=$true;
    execution_id='arthur-release-aaaaaaa-20260915';
    firmware_state=[pscustomobject][ordered]@{ current_stage='ARTIFACT'; next_stage='PRE_FLASH'; active_run_id=123; active_source_sha=('a' * 40); active_artifact_id=456; candidate_release_conclusion='success' }
}

$result = Complete-ArthurReleaseOnlyState -ResumeState $resume -OperatorIntent $intent -RunId 777 -ArtifactId 888 -ReleaseTag 'v0.1.5' -SourceSha ('b' * 40) -Firmware 'XinZhaoWrt-Arthur-v0.1.5-20260915-sysupgrade.bin' -FirmwareSha256 ('c' * 64) -FactorySha256 ('d' * 64) -ReleaseId 999 -ReleaseUrl 'https://github.com/mxonline/xinzhaowrt/releases/tag/v0.1.5' -EvidenceId 'release-777' -VerifiedAt '2026-09-15T13:30:00Z'

Assert-Equal $result.resume_state.status 'PRODUCTION_RELEASED' 'release-only finalizer must close production terminal state'
Assert-Equal $result.resume_state.current_gate 'PRODUCTION_RELEASED' 'terminal gate must be PRODUCTION_RELEASED'
Assert-Equal $result.resume_state.next_action 'NONE' 'terminal release must have no next action'
Assert-Equal $result.resume_state.instruction_allowed $false 'terminal release must close firmware instruction authorization'
Assert-Equal $result.resume_state.post_release_device_test 'PENDING_INDEPENDENT' 'post-release device test must remain independent'
Assert-Equal $result.resume_state.production.github_run_id 777 'terminal identity must bind to exact production run'
Assert-Equal $result.resume_state.production.artifact_id 888 'terminal identity must bind to exact artifact'
Assert-Equal $result.resume_state.production.release 'v0.1.5' 'terminal identity must bind to exact release tag'
Assert-Equal $result.resume_state.production.candidate_sha256 ('c' * 64) 'terminal identity must bind to exact firmware hash'
Assert-Equal $result.operator_intent.firmware_execution_authorized $false 'terminal finalizer must close operator execution authorization'
Assert-Equal $result.operator_intent.firmware_state.current_stage 'PRODUCTION_RELEASED' 'operator projection must close at terminal'
Assert-Equal $result.operator_intent.firmware_state.next_stage 'NONE' 'operator projection must have no device stage after release'

foreach ($gateId in @(Get-ArthurReleaseOnlySkippedGates)) {
    $property = $result.resume_state.gates.PSObject.Properties[$gateId]
    if ($property) { Assert-Equal ([string]$property.Value.status) 'SKIPPED' "$gateId must be SKIPPED in RELEASE_ONLY" }
}
foreach ($gateId in @('RELEASE_GATE','RELEASE','PRODUCTION_RELEASED')) {
    $gate = $result.resume_state.gates.PSObject.Properties[$gateId].Value
    Assert-Equal ([string]$gate.status) 'PASS' "$gateId must PASS from GitHub Release evidence"
    Assert-Equal ([string]$gate.evidence_refs[0]) 'evidence:release-777' "$gateId must use durable release evidence"
}

$blocked = $false
$badResume = $resume | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$badResume.gates.BUILD.status = 'FAIL'
try {
    Complete-ArthurReleaseOnlyState -ResumeState $badResume -OperatorIntent $intent -RunId 777 -ArtifactId 888 -ReleaseTag 'v0.1.5' -SourceSha ('b' * 40) -Firmware 'firmware.bin' -FirmwareSha256 ('c' * 64) -ReleaseId 999 -ReleaseUrl 'https://example.invalid' -EvidenceId 'release-777' | Out-Null
} catch { $blocked = ($_.Exception.Message -eq 'ARTHUR_RELEASE_ONLY_BUILD_NOT_PASS') }
Assert-True $blocked 'release-only finalizer must fail closed when BUILD is not PASS'

Write-Host 'ARTHUR_RELEASE_ONLY_FINALIZER_STATE=PASS'
