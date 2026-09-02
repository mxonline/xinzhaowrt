$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ScriptPath = Join-Path $Root 'scripts\repair-github-runner.ps1'

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

Assert-True (Test-Path $ScriptPath) 'Windows runner recovery script must exist'
$text = Get-Content -Raw $ScriptPath

foreach ($needle in @(
    'C:\actions-runner',
    '.service',
    'Get-Service',
    'Set-Service',
    'Start-Service',
    'sc.exe',
    'failure',
    'failureflag',
    'git --version',
    'gh --version',
    'codex --version',
    'gh auth status --hostname github.com',
    'RUNNER_SERVICE_RUNNING=PASS',
    'RUNNER_SELF_HEAL=PASS'
)) {
    Assert-Contains $text $needle "runner self-heal contract requires $needle"
}

Assert-Contains $text 'RUNNER_SERVICE_MISSING_RECONFIG_REQUIRED' 'missing Windows runner service must fail closed instead of silently re-registering'
Assert-True (-not $text.Contains('config.cmd remove')) 'self-heal must never remove the registered runner'
Assert-True (-not $text.Contains('--token')) 'self-heal must never embed or request a GitHub runner registration token'
Assert-True (-not $text.Contains('Remove-Service')) 'self-heal must not destroy the existing runner service'

Write-Host 'RUNNER_SELF_HEAL_CONTRACT=PASS'
