$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$TargetUser = "$env:COMPUTERNAME\chenz"
$TaskName = 'XinZhaoWrt-Existing-Bridge-Recovery'
$RecoveryRoot = 'C:\ProgramData\XinZhaoWrt\BridgeRecovery'
$InnerScript = Join-Path $RecoveryRoot 'inspect-existing-bridge.ps1'
$PromptPath = Join-Path $RecoveryRoot 'bridge-inspect-prompt.txt'
$ResultPath = Join-Path $RecoveryRoot 'bridge-inspect-result.json'
$LogPath = Join-Path $RecoveryRoot 'bridge-inspect.log'

New-Item -ItemType Directory -Force -Path $RecoveryRoot | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $ResultPath,$LogPath

$prompt = @'
You are inspecting an EXISTING GPT-Codex Bridge runtime for the XinZhaoWrt Arthur firmware project.
Do not redesign, rebuild, upgrade, or replace the Bridge. Do not modify any file. Do not run firmware build, flash, sysupgrade, GitHub workflow, git commit, git push, or release action.

Working repository: C:\Users\chenz\xinzhaowrt
Expected existing runtime: C:\Users\chenz\xinzhaowrt\ai_orchestrator
Expected state directory: C:\Users\chenz\xinzhaowrt\.ai-orchestrator

Read the existing ai_orchestrator code, local non-secret state/handoff files, and any existing project documentation needed to determine how the already-built Bridge/Supervisor was originally launched and resumed.
Do not print, read out, or expose any credential, token, API key, private key, cookie, or secret value.

Return JSON only with this exact shape:
{
  "bridge_present": true,
  "state_present": true,
  "bridge_active": false,
  "supervisor_present": true,
  "resume_entrypoint": "exact existing module/script path or command supported by the code",
  "resume_arguments": "arguments required to resume the existing runtime, or empty string",
  "last_checkpoint": "non-secret current/last durable checkpoint if identifiable",
  "safe_to_resume": true,
  "blocker": "empty if safely resumable; otherwise the concrete blocker"
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
    $inputText = Get-Content -Raw $promptPath
    $output = ($inputText | & $codex exec --sandbox read-only -c 'approval_policy="never"' -o $resultPath - 2>&1 | Out-String)
    "CODEX_EXIT=$LASTEXITCODE" | Add-Content -Path $logPath
    $output | Add-Content -Path $logPath
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if (-not (Test-Path $resultPath)) { throw 'Codex produced no bridge inspection result.' }
    exit 0
} catch {
    "ERROR=$($_.Exception.Message)" | Add-Content -Path $logPath
    exit 1
}
'@
[IO.File]::WriteAllText($InnerScript,$inner,(New-Object Text.UTF8Encoding($false)))

try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$InnerScript`"" -WorkingDirectory $RecoveryRoot
    $principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings -Description 'Temporary minimum recovery inspection of the already-existing GPT-Codex Bridge in its original chenz user context.'
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "BRIDGE_CONTEXT_TASK_REGISTERED user=$TargetUser"
} catch {
    Write-Host "BRIDGE_CONTEXT_RECOVERY=BLOCKED_USER_CONTEXT reason=$($_.Exception.Message)"
    exit 0
}

$deadline = (Get-Date).AddSeconds(150)
while ((Get-Date) -lt $deadline) {
    if (Test-Path $ResultPath) {
        Write-Host 'BRIDGE_CONTEXT_RECOVERY=RESULT_READY'
        $result = Get-Content -Raw $ResultPath
        Write-Host "BRIDGE_CONTEXT_RESULT=$result"
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        exit 0
    }
    $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($taskInfo -and $taskInfo.LastRunTime.Year -gt 2000 -and $taskInfo.LastTaskResult -ne 267009) {
        if (Test-Path $LogPath) {
            $safeLog = (Get-Content -Raw $LogPath) -replace '(?i)(sk-[A-Za-z0-9_-]+|github_pat_[A-Za-z0-9_]+|ghp_[A-Za-z0-9_]+)','[REDACTED]'
            if ($safeLog.Length -gt 6000) { $safeLog = $safeLog.Substring($safeLog.Length-6000) }
            Write-Host "BRIDGE_CONTEXT_LOG=$safeLog"
        }
        Write-Host "BRIDGE_CONTEXT_RECOVERY=FAILED result=$($taskInfo.LastTaskResult)"
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        exit 0
    }
    Start-Sleep -Seconds 5
}

$info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
$state = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Write-Host "BRIDGE_CONTEXT_RECOVERY=WAITING_OR_NO_INTERACTIVE_TOKEN state=$($state.State) last_result=$($info.LastTaskResult) last_run=$($info.LastRunTime) user=$TargetUser"
# Keep the task registered so it can run automatically when the original user context becomes available.
exit 0
