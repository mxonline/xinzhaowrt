param(
    [ValidateSet('Watch','Rebuild','Update','Resume')]
    [string]$Mode = 'Watch',

    [ValidateSet('rebuild_known_good','update_immortalwrt','update_feeds','update_plugins','update_all')]
    [string]$UpdateMode = 'update_immortalwrt',

    [long]$RunId = 0,
    [int]$MaxRepairRounds = 3,
    [int]$PollSeconds = 60
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Controller = Join-Path $PSScriptRoot 'ci-controller-v3.ps1'
$OutputDir = Join-Path $RepoRoot 'output\controller-v3'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

if (-not (Test-Path $Controller)) {
    throw "Controller not found: $Controller"
}

if ($Mode -eq 'Resume' -and $RunId -le 0) {
    throw 'Resume mode requires -RunId.'
}

$taskName = if ($Mode -eq 'Watch') { 'XinZhaoWrt-CI-v3-Watch' } else { 'XinZhaoWrt-CI-v3-Controller' }
$args = @(
    '-NoProfile',
    '-ExecutionPolicy','Bypass',
    '-File',('"{0}"' -f $Controller),
    '-Mode',$Mode,
    '-UpdateMode',$UpdateMode,
    '-MaxRepairRounds',[string]$MaxRepairRounds,
    '-PollSeconds',[string]$PollSeconds
)

if ($Mode -eq 'Resume') {
    $args += @('-RunId',[string]$RunId)
}

$argumentLine = $args -join ' '
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argumentLine -WorkingDirectory $RepoRoot
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited

    if ($Mode -eq 'Watch') {
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    }
    else {
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
    }

    Start-ScheduledTask -TaskName $taskName
    Write-Host "Arthur v3 persistent controller started: $taskName"
    Write-Host "Mode: $Mode"
    Write-Host "Update mode: $UpdateMode"
    if ($RunId -gt 0) { Write-Host "Run ID: $RunId" }
    if ($Mode -eq 'Watch') { Write-Host 'Watch mode is also registered to start automatically at Windows logon.' }
    Write-Host "State: $RepoRoot\state\ci-v3-state.json"
    Write-Host "Log:   $RepoRoot\output\controller-v3\controller.log"
}
catch {
    Write-Warning "Task Scheduler launch failed: $($_.Exception.Message)"
    Write-Warning 'Falling back to a detached PowerShell process for this session.'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -WorkingDirectory $RepoRoot -WindowStyle Hidden
    Write-Host 'Arthur v3 controller started as a detached PowerShell process.'
    Write-Host "State: $RepoRoot\state\ci-v3-state.json"
    Write-Host "Log:   $RepoRoot\output\controller-v3\controller.log"
}
