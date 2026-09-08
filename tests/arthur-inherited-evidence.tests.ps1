$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $Root 'scripts\arthur-state-contract.ps1')
. (Join-Path $Root 'scripts\arthur-resume-state.ps1')

function Assert-Equal { param($Actual,$Expected,[string]$Message) if ($Actual -ne $Expected) { throw "TEST_FAIL: $Message (actual='$Actual' expected='$Expected')" } }
function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw "TEST_FAIL: $Message" } }

$baseline = [pscustomobject]@{
    active_development_baseline = $true
    firmware = [pscustomobject]@{ version='0.1.3'; build_id='33462873812'; build_date='2026-09-01'; source_sha=('a'*40); github_run_id=100; artifact_id=200; sha256=('b'*64) }
}
$live = [pscustomobject]@{ version='0.1.3'; build_id='33462873812'; git_commit='aaaaaaa' }
$runtime = [pscustomobject]@{ phase='BUILD'; current_stage='BUILD'; next_action='BUILD'; turn_count=1 }
$digest = Get-ArthurRequirementDigest -RequirementText 'Wi-Fi accepted frozen baseline'

$legacyOnly = Resolve-ArthurResumeState -RepositoryHead ('c'*40) -RealDeviceBaseline $baseline -LiveDevice $live -RuntimeState $runtime -ExecutionId 'arthur-release-aaaaaaa-20260908'
Assert-Equal ([string]$legacyOnly.verified.wifi) 'REVERIFY_REQUIRED' 'legacy fixed strings must not manufacture Wi-Fi PASS'
Assert-Equal ([string]$legacyOnly.verified.luci_chinese) 'REVERIFY_REQUIRED' 'legacy fixed strings must not manufacture LuCI Chinese PASS'
Assert-Equal ([string]$legacyOnly.verified.adguard_full_manager) 'REVERIFY_REQUIRED' 'legacy fixed strings must not manufacture ADH PASS'
Assert-Equal ([string]$legacyOnly.verified.quickstart) 'REVERIFY_REQUIRED' 'legacy fixed strings must not manufacture QuickStart PASS'

$wifi = New-ArthurGateRecord -GateId 'WIFI' -RequirementRef 'production/ARTHUR_PRODUCT_TARGETS.md#wifi' -RequirementDigest $digest -Status 'PASS' -Subject @{ source_sha=('a'*40); device_build_id='33462873812' } -Inherited $true -InheritedFrom 'production/real-device-baseline.json'
$withWifi = Resolve-ArthurResumeState -RepositoryHead ('c'*40) -RealDeviceBaseline $baseline -LiveDevice $live -RuntimeState $runtime -ExecutionId 'arthur-release-aaaaaaa-20260908' -GateRecords @($wifi) -CurrentSubjects @{ WIFI=@{ source_sha=('a'*40); device_build_id='33462873812' } } -RequirementDigests @{ WIFI=$digest }
Assert-Equal ([string]$withWifi.gates.WIFI.status) 'PASS' 'explicit inherited provenance may retain Wi-Fi PASS when subject is unchanged'
Assert-Equal ([string]$withWifi.verified.wifi) 'VERIFIED_FROZEN' 'legacy summary may display frozen only when Gate is valid PASS'

$changedDigest = Get-ArthurRequirementDigest -RequirementText 'Wi-Fi acceptance changed'
$stale = Resolve-ArthurResumeState -RepositoryHead ('c'*40) -RealDeviceBaseline $baseline -LiveDevice $live -RuntimeState $runtime -ExecutionId 'arthur-release-aaaaaaa-20260908' -GateRecords @($wifi) -CurrentSubjects @{ WIFI=@{ source_sha=('a'*40); device_build_id='33462873812' } } -RequirementDigests @{ WIFI=$changedDigest }
Assert-Equal ([string]$stale.gates.WIFI.status) 'STALE' 'requirement digest change must stale inherited evidence'
Assert-Equal ([string]$stale.verified.wifi) 'REVERIFY_REQUIRED' 'stale inherited evidence cannot display as verified'

Write-Host 'ARTHUR_INHERITED_EVIDENCE_CONTRACT=PASS'
