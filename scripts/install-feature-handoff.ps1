param(
    [string]$TaskName='XinZhaoWrt-Arthur-Feature-Handoff',
    [switch]$ElevatedRetry
)
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
# Feature Handoff only performs user-level Git/gh/PowerShell orchestration. Requiring
# Highest makes registration fail for the normal non-admin Codex/LIVE_PREVIEW user.
$Principal=New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Limited
$Task=New-ScheduledTask -Action $Action -Trigger $LogonTrigger -Settings $Settings -Principal $Principal -Description 'Resume accepted Arthur LIVE_PREVIEW handoff into the existing v3 production controller until PRODUCTION_RELEASED.'
try {
    Register-ScheduledTask -TaskName $TaskName -InputObject $Task -Force | Out-Null
}
catch {
    $accessDenied = ($_.Exception -is [System.UnauthorizedAccessException]) -or ($_.Exception.Message -match '(?i)access is denied|拒绝访问')
    if (-not $accessDenied -or $ElevatedRetry) { throw }

    # Standard users can prepare the Limited principal, but some Windows
    # installations require an elevated broker to register a task in the
    # Task Scheduler root. Re-run this same installer once through UAC; the
    # task action and principal remain unchanged and the child owns startup.
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -TaskName `"$TaskName`" -ElevatedRetry"
    try {
        $elevated = Start-Process -FilePath $Pwsh -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    }
    catch {
        throw "FEATURE_HANDOFF_ELEVATION_REQUIRED: $($_.Exception.Message)"
    }
    if ($elevated.ExitCode -ne 0) {
        throw "FEATURE_HANDOFF_ELEVATED_REGISTRATION_FAILED exit=$($elevated.ExitCode)"
    }
    Write-Host "FEATURE_HANDOFF_ELEVATED_REGISTRATION=PASS task=$TaskName"
    exit 0
}
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Milliseconds 500
$registered=Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
Write-Host "FEATURE_HANDOFF_INSTALL=PASS task=$TaskName state=$($registered.State) user=$CurrentUser runlevel=Limited"
