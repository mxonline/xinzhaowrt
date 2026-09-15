$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$HelperPath = Join-Path $Root 'scripts\production-agent-release-mode.ps1'
$AgentPath = Join-Path $Root 'scripts\production-agent.ps1'
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

Assert-True (Test-Path -LiteralPath $PolicyPath -PathType Leaf) 'release-mode policy must exist'
Assert-True (Test-Path -LiteralPath $HelperPath -PathType Leaf) 'production-agent release-mode helper must exist'
Assert-True (Test-Path -LiteralPath $AgentPath -PathType Leaf) 'production-agent implementation must exist'

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

$legacy = @(Get-ArthurProductionAgentStages -ReleaseMode 'FLASH_AND_VERIFY')
foreach ($stage in @('REAL_DEVICE_BASELINE_GATE','AUTO_FLASH_SAFETY_GATE','FLASH_STARTED','WAIT_DEVICE','REAL_DEVICE_VERIFY','RELEASE_GATE','PRODUCTION_RELEASED')) {
    Assert-True ($legacy -contains $stage) "FLASH_AND_VERIFY compatibility must preserve $stage"
}

$threw = $false
try { Get-ArthurProductionAgentStages -ReleaseMode 'UNKNOWN' | Out-Null } catch { $threw = $true }
Assert-True $threw 'unknown release mode must fail closed'

$agent = Get-Content -Raw -LiteralPath $AgentPath
Assert-Contains $agent 'production-agent-release-mode.ps1' 'production agent must source the release-mode helper'
Assert-Contains $agent 'Get-ArthurProductionReleaseModePolicy' 'production agent must load machine release policy'
Assert-Contains $agent 'Get-ArthurProductionAgentStages' 'production agent must select an effective stage registry by mode'
Assert-Contains $agent "if (`$ReleaseMode -eq 'RELEASE_ONLY')" 'production agent must have an explicit RELEASE_ONLY execution branch'
Assert-Contains $agent "Save-State `$state 'RELEASE_GATE'" 'RELEASE_ONLY must advance Candidate directly to RELEASE_GATE'
Assert-Contains $agent 'POST_RELEASE_DEVICE_TEST=PENDING_INDEPENDENT' 'release-only terminal must explicitly leave post-release device testing pending and independent'

$releaseBranch = $agent.IndexOf("if (`$ReleaseMode -eq 'RELEASE_ONLY')",[System.StringComparison]::OrdinalIgnoreCase)
$firstRollbackExecution = $agent.IndexOf('Ensure-Rollback $state',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($releaseBranch -ge 0 -and $firstRollbackExecution -ge 0 -and $releaseBranch -lt $firstRollbackExecution) 'RELEASE_ONLY decision must be evaluated before any rollback/device/flash execution path'

Write-Host 'ARTHUR_PRODUCTION_AGENT_RELEASE_ONLY=PASS'
