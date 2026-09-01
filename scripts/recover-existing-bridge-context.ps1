$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$TargetUser = "$env:COMPUTERNAME\chenz"
$TaskName = 'XinZhaoWrt-Existing-Bridge-Recovery'
$RecoveryRoot = 'C:\ProgramData\XinZhaoWrt\BridgeRecovery'
$InnerScript = Join-Path $RecoveryRoot 'inspect-existing-bridge.ps1'
$PromptPath = Join-Path $RecoveryRoot 'bridge-inspect-prompt.txt'
$ResultPath = Join-Path $RecoveryRoot 'bridge-inspect-result.json'
$LogPath = Join-Path $RecoveryRoot 'bridge-inspect.log'
$CommonStartup = [Environment]::GetFolderPath('CommonStartup')
$StartupWrapper = if ($CommonStartup) { Join-Path $CommonStartup 'XinZhaoWrt-Existing-Bridge-Recovery.cmd' } else { '' }

New-Item -ItemType Directory -Force -Path $RecoveryRoot | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $ResultPath,$LogPath

$prompt = @'
You are recovering the EXISTING GPT-Codex Bridge runtime for the XinZhaoWrt Arthur firmware project.
Do not redesign, rebuild, upgrade, replace, or create a new Bridge. Do not create or replace credentials. Do not expose any credential, token, API key, private key, cookie, or secret value.
Do not run firmware build, flash, sysupgrade, GitHub workflow, git commit, git push, or release action.

Working repository: C:\Users\chenz\xinzhaowrt
Expected existing runtime: C:\Users\chenz\xinzhaowrt\ai_orchestrator
Expected state directory: C:\Users\chenz\xinzhaowrt\.ai-orchestrator

Read the existing ai_orchestrator code, non-secret durable state/HANDOFF, and project documentation. Determine the exact already-existing resume/start entrypoint and the last valid checkpoint. If the existing Bridge/Supervisor is present, inactive, and can be safely resumed using its existing code and existing credential storage, resume it from the last valid checkpoint. Do not modify source files. Do not re-run completed firmware stages. After attempting resume, verify whether the existing Bridge/Supervisor is actually alive and whether it can continue GPT -> Codex dispatch.

Return JSON only with this exact shape:
{
  "bridge_present": true,
  "state_present": true,
  "bridge_was_active": false,
  "supervisor_present": true,
  "resume_entrypoint": "existing entrypoint used or identified",
  "last_checkpoint": "non-secret durable checkpoint",
  "resume_attempted": true,
  "resume_success": true,
  "bridge_active_after": true,
  "safe_to_continue": true,
  "blocker": "empty if recovered; otherwise the concrete blocker"
}
'@
[IO.File]::WriteAllText($PromptPath,$prompt,(New-Object Text.UTF8Encoding($false)))

$inner = @'
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest
$repo = 'C:\Users\chenz\xinzhaowrt'
$codex = 'C:\Users\chenz\AppData\Roaming\Python\Python314\site-packages\codex_cli_bin\bin\codex.exe'
$promptPath = 'C:\ProgramData\XinZhaoWrt\BridgeRecovery\bridge-inspect-prompt.txt'
$resultPath = 'C:\ProgramData\XinZhaoWrt\BridgeRecovery\bridge-inspect-result.json'
$logPath = 'C:\ProgramData\XinZhaoWrt\BridgeRecovery\bridge-inspect.log'
try {
    "CONTEXT=$(whoami)" | Set-Content -Path $logPath -Encoding UTF8
    "REPO_EXISTS=$(Test-Path $repo)" | Add-Content -Path $logPath
    "ORCHESTRATOR_EXISTS=$(Test-Path (Join-Path $repo 'ai_orchestrator'))" | Add-Content -Path $logPath
    "STATE_EXISTS=$(Test-Path (Join-Path $repo '.ai-orchestrator'))" | Add-Content -Path $logPath
    "CODEX_EXISTS=$(Test-Path $codex)" | Add-Content -Path $logPath
    if (-not (Test-Path $repo)) { throw 'Original repository is not available in chenz context.' }
    if (-not (Test-Path $codex)) { throw 'Existing Codex executable is not available in chenz context.' }
    Set-Location $repo
    $before = (& git status --porcelain 2>&1 | Out-String)
    $inputText = Get-Content -Raw $promptPath
    $output = ($inputText | & $codex exec --sandbox workspace-write -c 'approval_policy="never"' -o $resultPath - 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    "CODEX_EXIT=$exitCode" | Add-Content -Path $logPath
    $output | Add-Content -Path $logPath
    $after = (& git status --porcelain 2>&1 | Out-String)
    if ($after -ne $before) {
        "SOURCE_CHANGE_DETECTED=YES" | Add-Content -Path $logPath
        throw 'Existing Bridge recovery attempted to change repository files; source changes are not accepted during recovery.'
    }
    if ($exitCode -ne 0) { exit $exitCode }
    if (-not (Test-Path $resultPath)) { throw 'Codex produced no bridge recovery result.' }
    exit 0
} catch {
    "ERROR=$($_.Exception.Message)" | Add-Content -Path $logPath
    exit 1
}
'@
[IO.File]::WriteAllText($InnerScript,$inner,(New-Object Text.UTF8Encoding($false)))

$registered = $false
try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$InnerScript`"" -WorkingDirectory $RecoveryRoot
    $principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings -Description 'Temporary minimum recovery of the already-existing GPT-Codex Bridge in its original chenz user context.'
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Write-Host "BRIDGE_CONTEXT_TASK_REGISTERED user=$TargetUser"
    $registered = $true
} catch {
    Write-Host "BRIDGE_CONTEXT_TASK_UNAVAILABLE reason=$($_.Exception.Message)"
}

if (-not $registered) {
    if (-not $StartupWrapper) {
        Write-Host 'BRIDGE_CONTEXT_RECOVERY=BLOCKED_NO_COMMON_STARTUP'
        exit 0
    }
    try {
        $wrapper = @"
@echo off
if /I not "%USERNAME%"=="chenz" exit /b 0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$InnerScript"
if exist "$ResultPath" del /f /q "%~f0" >nul 2>&1
exit /b 0
"@
        [IO.File]::WriteAllText($StartupWrapper,$wrapper,(New-Object Text.ASCIIEncoding))
        Write-Host "BRIDGE_CONTEXT_RECOVERY=STAGED_FOR_CHENZ_LOGON path=$StartupWrapper"
    } catch {
        Write-Host "BRIDGE_CONTEXT_RECOVERY=BLOCKED_STARTUP_WRITE reason=$($_.Exception.Message)"
    }
    exit 0
}

$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    if (Test-Path $ResultPath) {
        Write-Host 'BRIDGE_CONTEXT_RECOVERY=RESULT_READY'
        Write-Host "BRIDGE_CONTEXT_RESULT=$(Get-Content -Raw $ResultPath)"
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        exit 0
    }
    Start-Sleep -Seconds 5
}

Write-Host "BRIDGE_CONTEXT_RECOVERY=WAITING_FOR_ORIGINAL_USER_CONTEXT user=$TargetUser"
exit 0
