$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$installer=Get-Content -Raw (Join-Path $Root 'scripts/install-feature-handoff.ps1')

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}
function Assert-Contains([string]$Text,[string]$Needle,[string]$Message) {
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message missing='$Needle'"
    }
}

# Feature Handoff performs Git/gh/PowerShell orchestration only. It must be
# registerable by the same non-admin interactive user that ran Codex/LIVE_PREVIEW.
Assert-Contains $installer '-RunLevel Limited' 'Feature Handoff Scheduled Task must not require elevation'
Assert-True ($installer -notmatch '(?i)-RunLevel\s+Highest') 'Feature Handoff installer must not force Highest privilege'
Assert-Contains $installer 'FEATURE_HANDOFF_INSTALL=PASS' 'installer must retain explicit success evidence'
Assert-Contains $installer 'Start-ScheduledTask' 'installer must immediately hand ownership to Task Scheduler'
Assert-Contains $installer 'UnauthorizedAccessException' 'installer must classify task registration access denial as an elevation-retry condition'
Assert-Contains $installer 'RunAs' 'installer must retry task registration through the existing Windows elevation mechanism'
Assert-Contains $installer 'FEATURE_HANDOFF_ELEVATION_REQUIRED' 'installer must expose a recoverable elevation handoff instead of silently stopping'

Write-Host 'FEATURE_HANDOFF_NONADMIN_TASK_CONTRACT=PASS'
