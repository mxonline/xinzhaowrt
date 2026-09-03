param([string]$TaskName='XinZhaoWrt-Arthur-Production-Agent')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Launcher=Join-Path $PSScriptRoot 'start-production-agent.ps1'
$FeatureHandoffInstaller=Join-Path $PSScriptRoot 'install-feature-handoff.ps1'
if (-not (Test-Path $Launcher)) { throw "Launcher missing: $Launcher" }
if (-not (Test-Path $FeatureHandoffInstaller)) { throw "Feature handoff installer missing: $FeatureHandoffInstaller" }

foreach ($tool in @('gh.exe','ssh.exe','scp.exe')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command missing: $tool" }
}

# Installation must not stop the unattended chain merely because the GitHub
# Actions host process cannot see the persistent machine/App credential. Probe
# it for evidence, then let the persistent agent retry/recover credentials in
# its own long-lived user context.
$previousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $auth = & gh api repos/mxonline/xinzhaowrt --jq .full_name 2>&1
    $authExit = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousPreference
}
if ($authExit -eq 0 -and (($auth -join "`n") -match 'mxonline/xinzhaowrt')) {
    Write-Host 'PERSISTENT_GITHUB_API_AUTH=PASS'
} else {
    Write-Warning "PERSISTENT_GITHUB_API_AUTH=DEFERRED; persistent agent will retry automatically. $($auth -join ' ')"
}

function Stop-LegacyArthurRebuildControllers {
    $controllerPattern = '(?i)ci-controller-v3\.ps1'
    $rebuildPattern = '(?i)-Mode\s+Rebuild(?:\s|$)'

    $legacy = @(
        Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object {
                [int]$_.ProcessId -ne [int]$PID -and
                [string]$_.CommandLine -match $controllerPattern -and
                [string]$_.CommandLine -match $rebuildPattern
            }
    )

    foreach ($entry in $legacy) {
        $processId = [int]$entry.ProcessId
        if ($processId -le 0) { continue }
        Write-Host "LEGACY_REBUILD_CONTROLLER_STOPPING pid=$processId"
        Stop-Process -Id $processId -Force -ErrorAction Stop
    }

    if ($legacy.Count -gt 0) { Start-Sleep -Seconds 1 }

    $remaining = @(
        Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object {
                [int]$_.ProcessId -ne [int]$PID -and
                [string]$_.CommandLine -match $controllerPattern -and
                [string]$_.CommandLine -match $rebuildPattern
            }
    )
    if ($remaining.Count -gt 0) {
        $remainingIds = ($remaining | ForEach-Object { [string]$_.ProcessId }) -join ','
        throw "Legacy Arthur Rebuild controller cleanup failed; remaining process ids: $remainingIds"
    }

    Write-Host "LEGACY_REBUILD_CONTROLLER_QUIESCED=PASS stopped=$($legacy.Count)"
}

# PR #45 prevents new Rebuild-mode children. Drain only the legacy writers
# created before that fix, before the deploy later starts the persistent Watch controller.
Stop-LegacyArthurRebuildControllers

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

# The Feature Handoff task is installed from the same persistent runtime so a
# successful LIVE_PREVIEW survives Codex/terminal exit and Windows restart.
& $Pwsh -NoProfile -ExecutionPolicy Bypass -File $FeatureHandoffInstaller
if ($LASTEXITCODE -ne 0) { throw "Feature Handoff installer failed: $LASTEXITCODE" }
Write-Host 'FEATURE_HANDOFF_PERSISTENT_RUNTIME=PASS'
Write-Host 'Routine firmware production no longer requires manual PowerShell continuation.'