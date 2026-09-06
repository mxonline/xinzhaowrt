$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$HelperPath = Join-Path $Root 'scripts\ensure-arthur-persistent-supervisor.ps1'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
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

Assert-True (Test-Path -LiteralPath $HelperPath -PathType Leaf) 'persistent Supervisor helper must exist'
$source = Get-Content -Raw -LiteralPath $HelperPath

Assert-Contains $source 'GITHUB_ACTIONS' 'detached fallback must be scoped to a GitHub Actions runner context'
Assert-Contains $source 'RUNNER_TRACKING_ID' 'detached child must opt out of self-hosted runner orphan cleanup'
Assert-Contains $source "$env:RUNNER_TRACKING_ID = ''" 'detached child must inherit an empty runner tracking id'
Assert-Contains $source 'Start-Process' 'detached fallback must spawn the same persistent Supervisor outside the job process lifecycle'
Assert-Contains $source 'Get-CimInstance Win32_Process' 'helper must detect an already-running Supervisor before spawning another one'
Assert-Contains $source 'run-supervisor.py' 'detached fallback must launch the existing recovery Supervisor shim'
Assert-Contains $source '--interval' 'detached Supervisor must retain watchdog cadence'
Assert-Contains $source "'30'" 'detached Supervisor must retain the 30-second watchdog cadence'
Assert-Contains $source 'HEADLESS_CODEX_MODEL' 'detached Supervisor must bind the explicit headless Codex model'
Assert-Contains $source 'gpt-5.6-terra' 'detached Supervisor must use the approved model binding'
Assert-Contains $source 'ARTHUR_CONTROL_PLANE_CODE_ROOT' 'detached child must bind clean control-runtime'
Assert-Contains $source 'ARTHUR_CONTROL_PLANE_STATE_DIR' 'detached child must bind the durable state directory'
Assert-Contains $source 'PERSISTENT_SUPERVISOR_DETACHED=REUSE' 'existing detached Supervisor must be reused idempotently'
Assert-Contains $source 'PERSISTENT_SUPERVISOR_DETACHED=PASS' 'new detached Supervisor launch must emit explicit evidence'
Assert-Contains $source 'PERSISTENT_SUPERVISOR_TASK=PASS' 'detached fallback must preserve the existing workflow compatibility marker'
Assert-NotContains $source 'Stop-Process' 'ensure helper must not kill an existing Supervisor process just to replace ownership mode'

$processProbeIndex = $source.IndexOf('Get-CimInstance Win32_Process',[System.StringComparison]::OrdinalIgnoreCase)
$scheduledTaskIndex = $source.IndexOf('$existing = Get-ScheduledTask',[System.StringComparison]::OrdinalIgnoreCase)
$trackingNeedle = '$env:RUNNER_TRACKING_ID = ' + "''"
$trackingIndex = $source.IndexOf($trackingNeedle,[System.StringComparison]::OrdinalIgnoreCase)
$spawnIndex = $source.IndexOf('Start-Process',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($processProbeIndex -ge 0 -and $scheduledTaskIndex -ge 0 -and $processProbeIndex -lt $scheduledTaskIndex) 'real process reuse must be checked before Scheduled Task discovery'
Assert-True ($trackingIndex -ge 0 -and $spawnIndex -ge 0 -and $trackingIndex -lt $spawnIndex) 'RUNNER_TRACKING_ID must be cleared before spawning the detached process'

Write-Host 'ARTHUR_DETACHED_SUPERVISOR_RUNNER_CLEANUP_CONTRACT=PASS'
Write-Host 'ARTHUR_DETACHED_SUPERVISOR_IDEMPOTENT_REUSE_CONTRACT=PASS'
Write-Host 'ARTHUR_DETACHED_SUPERVISOR_NO_ADMIN_REQUIRED_CONTRACT=PASS'
