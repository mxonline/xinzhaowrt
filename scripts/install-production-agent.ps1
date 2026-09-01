param([string]$TaskName='XinZhaoWrt-Arthur-Production-Agent')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Launcher=Join-Path $PSScriptRoot 'start-production-agent.ps1'
if (-not (Test-Path $Launcher)) { throw "Launcher missing: $Launcher" }

foreach ($tool in @('gh.exe','ssh.exe','scp.exe')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command missing: $tool" }
}

# Do not trust `gh auth status` as a machine-auth gate. Exercise the repository API
# with the credential actually available to this Windows account/runner.
$auth = & gh api repos/mxonline/xinzhaowrt --jq .full_name 2>&1
if ($LASTEXITCODE -ne 0 -or (($auth -join "`n") -notmatch 'mxonline/xinzhaowrt')) {
    throw "RECOVERABLE_GITHUB_AUTH: repository API probe failed; persistent automation may retry after machine/App credential recovery.`n$($auth -join "`n")"
}
Write-Host 'PERSISTENT_GITHUB_API_AUTH=PASS'

function Resolve-AgentPowerShell {
    $systemPwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($systemPwsh) {
        Write-Host "PRODUCTION_AGENT_POWERSHELL=SYSTEM path=$($systemPwsh.Source)"
        return $systemPwsh.Source
    }

    $psRoot = Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\PowerShell'
    $current = Join-Path $psRoot 'current'
    $portable = Join-Path $current 'pwsh.exe'
    if (Test-Path $portable) {
        Write-Host "PRODUCTION_AGENT_POWERSHELL=PORTABLE_REUSE path=$portable"
        return $portable
    }

    New-Item -ItemType Directory -Force -Path $psRoot | Out-Null
    Get-ChildItem -Path $psRoot -Filter 'PowerShell-*-win-x64.zip' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Host 'POWERSHELL_PORTABLE_BOOTSTRAP=START'
    & gh release download --repo PowerShell/PowerShell --pattern 'PowerShell-*-win-x64.zip' --dir $psRoot --clobber
    if ($LASTEXITCODE -ne 0) { throw 'Failed to download portable PowerShell from the official PowerShell GitHub release.' }

    $zip = Get-ChildItem -Path $psRoot -Filter 'PowerShell-*-win-x64.zip' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $zip) { throw 'Portable PowerShell archive was not found after download.' }

    if (Test-Path $current) { Remove-Item -Recurse -Force $current }
    New-Item -ItemType Directory -Force -Path $current | Out-Null
    Expand-Archive -Path $zip.FullName -DestinationPath $current -Force
    Remove-Item -Force $zip.FullName

    if (-not (Test-Path $portable)) { throw "Portable PowerShell bootstrap produced no pwsh.exe: $portable" }
    Write-Host "POWERSHELL_PORTABLE_BOOTSTRAP=PASS path=$portable"
    return $portable
}

$Pwsh=Resolve-AgentPowerShell
$CurrentUser="$env:USERDOMAIN\$env:USERNAME"
$Action=New-ScheduledTaskAction -Execute $Pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Launcher`" -Mode Resume" -WorkingDirectory $Root
$LogonTrigger=New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
$Settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$Principal=New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Highest
$Task=New-ScheduledTask -Action $Action -Trigger $LogonTrigger -Settings $Settings -Principal $Principal -Description 'Unattended Arthur firmware production continuation: GitHub artifact -> safety gate -> standard sysupgrade -> real-device verification -> release.'
Register-ScheduledTask -TaskName $TaskName -InputObject $Task -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
$registered=Get-ScheduledTask -TaskName $TaskName
Write-Host "PRODUCTION_AGENT_INSTALL=PASS task=$TaskName state=$($registered.State) user=$CurrentUser pwsh=$Pwsh"
Write-Host 'Routine firmware production no longer requires manual PowerShell continuation.'
