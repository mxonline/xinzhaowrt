param([string]$TaskName='XinZhaoWrt-Arthur-Production-Agent')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Launcher=Join-Path $PSScriptRoot 'start-production-agent.ps1'
if (-not (Test-Path $Launcher)) { throw "Launcher missing: $Launcher" }
foreach ($tool in @('pwsh.exe','gh.exe','ssh.exe','scp.exe')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command missing: $tool" }
}
$auth=& gh auth status --hostname github.com 2>&1
if ($LASTEXITCODE -ne 0) { throw "NEW_CREDENTIAL_PROVISIONING: GitHub CLI auth is required once before installation.`n$($auth -join "`n")" }
$CurrentUser="$env:USERDOMAIN\$env:USERNAME"
$Action=New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Launcher`" -Mode Resume" -WorkingDirectory $Root
$LogonTrigger=New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
$Settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$Principal=New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Highest
$Task=New-ScheduledTask -Action $Action -Trigger $LogonTrigger -Settings $Settings -Principal $Principal -Description 'Unattended Arthur firmware production continuation: GitHub artifact -> safety gate -> standard sysupgrade -> real-device verification -> release.'
Register-ScheduledTask -TaskName $TaskName -InputObject $Task -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
$registered=Get-ScheduledTask -TaskName $TaskName
Write-Host "PRODUCTION_AGENT_INSTALL=PASS task=$TaskName state=$($registered.State) user=$CurrentUser"
Write-Host 'Routine firmware production no longer requires manual PowerShell continuation.'
