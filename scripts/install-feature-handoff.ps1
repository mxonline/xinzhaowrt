param([string]$TaskName='XinZhaoWrt-Arthur-Feature-Handoff')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Handoff=Join-Path $PSScriptRoot 'feature-handoff.ps1'
if (-not (Test-Path -LiteralPath $Handoff)) { throw "Feature handoff missing: $Handoff" }

function Resolve-HandoffPowerShell {
    $current=Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path $current) { return $current }
    $cmd=Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $portable=Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\PowerShell\current\pwsh.exe'
    if (Test-Path $portable) { return $portable }
    throw 'FEATURE_HANDOFF_POWERSHELL7_REQUIRED'
}

$Pwsh=Resolve-HandoffPowerShell
$CurrentUser="$env:USERDOMAIN\$env:USERNAME"
$Action=New-ScheduledTaskAction -Execute $Pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Handoff`" -Mode Resume" -WorkingDirectory $Root
$LogonTrigger=New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
$Settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 50 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$Principal=New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Highest
$Task=New-ScheduledTask -Action $Action -Trigger $LogonTrigger -Settings $Settings -Principal $Principal -Description 'Resume accepted Arthur LIVE_PREVIEW handoff into the existing v3 production controller until PRODUCTION_RELEASED.'
Register-ScheduledTask -TaskName $TaskName -InputObject $Task -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Milliseconds 500
$registered=Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
Write-Host "FEATURE_HANDOFF_INSTALL=PASS task=$TaskName state=$($registered.State) user=$CurrentUser"
