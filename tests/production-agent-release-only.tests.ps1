$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$HelperPath = Join-Path $Root 'scripts\production-agent-release-mode.ps1'
$AgentPath = Join-Path $Root 'scripts\production-agent.ps1'
$ReleaseOnlyPath = Join-Path $Root 'scripts\production-agent-release-only.ps1'
$LegacyPath = Join-Path $Root 'scripts\production-agent-flash-legacy.ps1'
$PolicyPath = Join-Path $Root 'production\release-mode.json'

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
function Assert-NotContains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "TEST_FAIL: $Message (unexpected '$Needle')"
    }
}

foreach ($path in @($PolicyPath,$HelperPath,$AgentPath,$ReleaseOnlyPath,$LegacyPath)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "required release-only production file must exist: $path"
}

. $HelperPath
$policy = Get-ArthurProductionReleaseModePolicy -Path $PolicyPath
Assert-Equal ([string]$policy.mode) 'RELEASE_ONLY' 'new production default must be RELEASE_ONLY'
Assert-True ([bool]$policy.unattended_release) 'RELEASE_ONLY must permit unattended GitHub release'
Assert-True (-not [bool]$policy.automatic_flash) 'RELEASE_ONLY must forbid automatic router flash'
Assert-Equal ([string]$policy.post_release_device_test) 'INDEPENDENT' 'post-release device test must remain independent'

$releaseOnly = @(Get-ArthurProductionAgentStages -ReleaseMode 'RELEASE_ONLY')
foreach ($stage in @('REQUESTED','CANDIDATE_VERIFIED','RELEASE_GATE','PRODUCTION_RELEASED')) {
    Assert-True ($releaseOnly -contains $stage) "RELEASE_ONLY must include $stage"
}
foreach ($stage in @('REAL_DEVICE_BASELINE_GATE','AUTO_FLASH_SAFETY_GATE','FLASH_STARTED','WAIT_DEVICE','REAL_DEVICE_VERIFY')) {
    Assert-True ($releaseOnly -notcontains $stage) "RELEASE_ONLY must never select $stage"
}

$legacyStages = @(Get-ArthurProductionAgentStages -ReleaseMode 'FLASH_AND_VERIFY')
foreach ($stage in @('REAL_DEVICE_BASELINE_GATE','AUTO_FLASH_SAFETY_GATE','FLASH_STARTED','WAIT_DEVICE','REAL_DEVICE_VERIFY','RELEASE_GATE','PRODUCTION_RELEASED')) {
    Assert-True ($legacyStages -contains $stage) "FLASH_AND_VERIFY compatibility must preserve $stage"
}

$threw = $false
try { Get-ArthurProductionAgentStages -ReleaseMode 'UNKNOWN' | Out-Null } catch { $threw = $true }
Assert-True $threw 'unknown release mode must fail closed'

$agent = Get-Content -Raw -LiteralPath $AgentPath
Assert-Contains $agent 'production-agent-release-mode.ps1' 'production agent must source the release-mode helper'
Assert-Contains $agent 'Get-ArthurProductionReleaseModePolicy' 'production agent must load machine release policy'
Assert-Contains $agent "if (`$ReleaseMode -eq 'RELEASE_ONLY')" 'production agent must explicitly select RELEASE_ONLY'
Assert-Contains $agent 'production-agent-release-only.ps1' 'RELEASE_ONLY must route to the no-flash runtime'
Assert-Contains $agent 'production-agent-flash-legacy.ps1' 'legacy flash implementation must have an explicit compatibility route'
$releaseBranch = $agent.IndexOf("if (`$ReleaseMode -eq 'RELEASE_ONLY')",[System.StringComparison]::OrdinalIgnoreCase)
$legacyBranch = $agent.IndexOf("if (`$ReleaseMode -eq 'FLASH_AND_VERIFY')",[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($releaseBranch -ge 0 -and $legacyBranch -gt $releaseBranch) 'RELEASE_ONLY route must be evaluated before legacy flash compatibility'

$releaseRuntime = Get-Content -Raw -LiteralPath $ReleaseOnlyPath
Assert-Contains $releaseRuntime 'RELEASE_ONLY_CLOUD_FINALIZER_OWNS_RELEASE=YES' 'release-only runtime must hand off to the cloud finalizer'
Assert-Contains $releaseRuntime 'POST_RELEASE_DEVICE_TEST=PENDING_INDEPENDENT' 'post-release device testing must remain explicitly independent'
foreach ($forbidden in @('Ensure-Rollback','Get-DeviceTarget','ssh.exe','scp.exe','sysupgrade','auto-flash-safety-gate.ps1','real-device-verify-v3.ps1','Invoke-VerifiedSysupgrade','Upload-Candidate')) {
    Assert-NotContains $releaseRuntime $forbidden "release-only runtime must not contain router write primitive $forbidden"
}

$legacyRuntime = Get-Content -Raw -LiteralPath $LegacyPath
Assert-Contains $legacyRuntime 'Invoke-VerifiedSysupgrade' 'legacy compatibility runtime must preserve historical sysupgrade implementation'
Assert-Contains $legacyRuntime 'AUTO_FLASH_SAFETY_GATE' 'legacy compatibility runtime must preserve flash safety gate'

Write-Host 'ARTHUR_PRODUCTION_AGENT_RELEASE_ONLY=PASS'
