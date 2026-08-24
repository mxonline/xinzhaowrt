param(
    [ValidateSet('UpdateBuild','Rebuild','Resume')]
    [string]$Mode = 'UpdateBuild',
    [long]$RunId = 0,
    [int]$MaxRepairRounds = 3,
    [int]$PollSeconds = 60
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Controller = Join-Path $PSScriptRoot 'ci-controller.ps1'
$OutputDir = Join-Path $RepoRoot 'output\controller'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$taskName = 'XinZhaoWrt-CI-Controller'
$args = @(
    '-NoProfile',
    '-ExecutionPolicy','Bypass',
    '-File',('"{0}"' -f $Controller),
    '-Mode',$Mode,
    '-MaxRepairRounds',[string]$MaxRepairRounds,
    '-PollSeconds',[string]$PollSeconds
)
if ($Mode -eq 'Resume') {
    if ($RunId -le 0) { throw 'Resume mode requires -RunId.' }
    $args += @('-RunId',[string]$RunId)
}
$argumentLine = $args -join ' '

try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argumentLine -WorkingDirectory $RepoRoot
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Write-Host "Persistent controller started as Windows Scheduled Task: $taskName"
    Write-Host "Mode: $Mode"
    if ($RunId -gt 0) { Write-Host "Run ID: $RunId" }
    Write-Host "State: $RepoRoot\state\ci-state.json"
    Write-Host "Log:   $RepoRoot\output\controller\controller.log"
}
catch {
    Write-Warning "Task Scheduler launch failed: $($_.Exception.Message)"
    Write-Warning 'Falling back to a detached PowerShell process.'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -WorkingDirectory $RepoRoot -WindowStyle Hidden
    Write-Host 'Persistent controller started as detached PowerShell process.'
    Write-Host "State: $RepoRoot\state\ci-state.json"
    Write-Host "Log:   $RepoRoot\output\controller\controller.log"
}
