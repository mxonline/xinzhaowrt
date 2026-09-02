param(
    [string]$RunnerRoot = 'C:\actions-runner'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$Code,[string]$Message) {
    Write-Error "$Code $Message"
    exit 61
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][scriptblock]$Command
    )
    $output = @(& $Command 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Fail 'RUNNER_PREREQUISITE_FAILED' "$Name failed: $($output -join ' ')"
    }
    Write-Host "RUNNER_PREREQUISITE=PASS name=$Name detail=$($output -join ' ')"
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'RUNNER_ADMIN_REQUIRED' 'Open PowerShell as Administrator and run this repair script again.'
}

if (-not (Test-Path $RunnerRoot)) {
    Fail 'RUNNER_ROOT_MISSING' "Runner root does not exist: $RunnerRoot"
}

$runnerConfig = Join-Path $RunnerRoot '.runner'
if (-not (Test-Path $runnerConfig)) {
    Fail 'RUNNER_CONFIG_MISSING_RECONFIG_REQUIRED' "Runner registration metadata is missing at $runnerConfig. Reconfigure the existing runner through GitHub instead of creating a new identity here."
}

$serviceFile = Join-Path $RunnerRoot '.service'
$serviceName = $null
if (Test-Path $serviceFile) {
    $serviceName = (Get-Content -Raw $serviceFile).Trim()
}

if (-not $serviceName) {
    $candidate = Get-Service 'actions.runner.*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '(?i)mxonline|xinzhaowrt|GitHub Actions Runner' } |
        Select-Object -First 1
    if ($candidate) { $serviceName = [string]$candidate.Name }
}

if (-not $serviceName) {
    Fail 'RUNNER_SERVICE_MISSING_RECONFIG_REQUIRED' 'No configured GitHub Actions Runner Windows service was found. GitHub requires reconfiguration when a Windows runner was not originally configured as a service.'
}

$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if (-not $service) {
    Fail 'RUNNER_SERVICE_MISSING_RECONFIG_REQUIRED' "Registered runner service '$serviceName' does not exist. Preserve the existing runner identity and reconfigure it as a Windows service through GitHub."
}

Write-Host "RUNNER_SERVICE_FOUND=PASS name=$serviceName status=$($service.Status) root=$RunnerRoot"

Set-Service -Name $serviceName -StartupType Automatic

$scFailure = @(& sc.exe failure $serviceName 'reset=' '86400' 'actions=' 'restart/60000/restart/60000/restart/300000' 2>&1)
if ($LASTEXITCODE -ne 0) {
    Fail 'RUNNER_SERVICE_RECOVERY_CONFIG_FAILED' "sc.exe failure failed for ${serviceName}: $($scFailure -join ' ')"
}
$scFailureFlag = @(& sc.exe failureflag $serviceName '1' 2>&1)
if ($LASTEXITCODE -ne 0) {
    Fail 'RUNNER_SERVICE_RECOVERY_CONFIG_FAILED' "sc.exe failureflag failed for ${serviceName}: $($scFailureFlag -join ' ')"
}
Write-Host 'RUNNER_SERVICE_RECOVERY_POLICY=PASS first=60s second=60s third=300s reset=86400s'

$service.Refresh()
if ($service.Status -ne 'Running') {
    Start-Service -Name $serviceName
}

$deadline = (Get-Date).AddSeconds(30)
do {
    Start-Sleep -Seconds 1
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    if ($service.Status -eq 'Running') { break }
} while ((Get-Date) -lt $deadline)

if ($service.Status -ne 'Running') {
    Fail 'RUNNER_SERVICE_START_FAILED' "Runner service did not reach Running state: $serviceName status=$($service.Status)"
}
Write-Host "RUNNER_SERVICE_RUNNING=PASS name=$serviceName"

# Keep these commands explicit because production/RUNNER_GATE.md defines them as the local machine gate.
Invoke-Checked 'git' { git --version }
Invoke-Checked 'gh' { gh --version }
Invoke-Checked 'codex' { codex --version }
Invoke-Checked 'github-auth' { gh auth status --hostname github.com }

$repoProbe = @(& gh api repos/mxonline/xinzhaowrt --jq .full_name 2>&1)
if ($LASTEXITCODE -ne 0 -or (($repoProbe -join "`n") -notmatch '^mxonline/xinzhaowrt$')) {
    Fail 'RUNNER_GITHUB_AUTH_FAILED' "GitHub repository probe failed: $($repoProbe -join ' ')"
}
Write-Host 'RUNNER_GITHUB_AUTH=PASS repo=mxonline/xinzhaowrt'

Write-Host 'RUNNER_SELF_HEAL=PASS'
