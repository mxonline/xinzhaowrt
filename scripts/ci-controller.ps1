param(
    [ValidateSet('UpdateBuild','Rebuild','Resume')]
    [string]$Mode = 'UpdateBuild',
    [long]$RunId = 0,
    [int]$MaxRepairRounds = 3,
    [int]$PollSeconds = 60,
    [int]$CodexTimeoutSeconds = 1800,
    [string]$Repository = 'mxonline/xinzhaowrt',
    [string]$Branch = 'main',
    [string]$Workflow = 'build.yml'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$StateDir = Join-Path $RepoRoot 'state'
$OutputRoot = Join-Path $RepoRoot 'output\controller'
$StateFile = Join-Path $StateDir 'ci-state.json'
$ControllerLog = Join-Path $OutputRoot 'controller.log'
$HardFiles = @(
    'config/required-plugins.txt',
    'config/arthur.config'
)
$currentRunId = $RunId

New-Item -ItemType Directory -Force -Path $StateDir, $OutputRoot | Out-Null

function Write-ControllerLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $line | Tee-Object -FilePath $ControllerLog -Append
}

function Set-ControllerState {
    param(
        [string]$Status,
        [string]$Stage = '',
        [string]$Conclusion = '',
        [long]$CurrentRunId = 0,
        [int]$RepairRound = 0,
        [string]$Message = ''
    )
    $state = [ordered]@{
        status       = $Status
        stage        = $Stage
        conclusion   = $Conclusion
        run_id       = $CurrentRunId
        repair_round = $RepairRound
        branch       = $Branch
        repository   = $Repository
        message      = $Message
        updated_at   = (Get-Date).ToString('o')
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
}

function Invoke-Captured {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [switch]$AllowFailure
    )
    $text = (& $FilePath @Arguments 2>&1 | Out-String).Trim()
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) {
        throw "$FilePath failed with exit code $code`n$text"
    }
    [pscustomobject]@{ ExitCode = $code; Output = $text }
}

function Assert-Tools {
    foreach ($tool in @('git','gh','codex')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "Required command not found: $tool"
        }
    }
    $auth = Invoke-Captured -FilePath 'gh' -Arguments @('auth','status','--hostname','github.com') -AllowFailure
    if ($auth.ExitCode -ne 0) {
        throw "GitHub CLI is not authenticated.`n$($auth.Output)"
    }
}

function Assert-CleanRepository {
    $dirty = Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'status','--porcelain')
    if ($dirty.Output) {
        throw "Repository has uncommitted changes. Persistent controller refuses to overwrite them.`n$($dirty.Output)"
    }
}

function Sync-Main {
    # 中文说明：静默 Git 的正常远程进度输出，避免 PowerShell 将 stderr 进度误当作失败信息。
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'fetch','--quiet','origin',$Branch) | Out-Null
    $currentBranch = (Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'branch','--show-current')).Output.Trim()
    if ($currentBranch -eq $Branch) {
        Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'pull','--ff-only','origin',$Branch) | Out-Null
    } else {
        # 中文说明：允许控制器运行在 detached worktree；main 可能被另一工作树占用。
        $head = ''
        $remoteHead = ''
        $head = (Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'rev-parse','HEAD')).Output.Trim()
        $remoteHead = (Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'rev-parse',"origin/$Branch")).Output.Trim()
        if ($head -ne $remoteHead) {
            throw "Detached worktree is not synchronized with origin/$Branch. Refusing to overwrite local worktree."
        }
    }
}

function Get-HardFileHashes {
    $result = @{}
    foreach ($relative in $HardFiles) {
        $path = Join-Path $RepoRoot $relative
        if (-not (Test-Path $path)) { throw "Hard constraint file missing: $relative" }
        $result[$relative] = (Get-FileHash -Algorithm SHA256 -Path $path).Hash
    }
    return $result
}

function Test-HardFilesUnchanged {
    param([hashtable]$Before)
    foreach ($relative in $HardFiles) {
        $path = Join-Path $RepoRoot $relative
        $after = (Get-FileHash -Algorithm SHA256 -Path $path).Hash
        if ($after -ne $Before[$relative]) {
            Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'restore','--',$relative) -AllowFailure | Out-Null
            throw "BLOCKED: automatic repair attempted to modify protected file $relative. Change was restored."
        }
    }
}

function Invoke-GhWithBackoff {
    param([string[]]$Arguments)
    $attempt = 0
    while ($true) {
        $attempt++
        $result = Invoke-Captured -FilePath 'gh' -Arguments $Arguments -AllowFailure
        if ($result.ExitCode -eq 0) { return $result.Output }

        $msg = $result.Output
        if ($msg -match '(?i)rate limit|HTTP 403') {
            Write-ControllerLog 'GitHub API rate limit reached. Keeping the current Run and backing off for 600 seconds.'
            Start-Sleep -Seconds 600
            continue
        }
        if ($msg -match '(?i)unexpected EOF|EOF|timeout|timed out|connection|HTTP 5\d\d') {
            Write-ControllerLog "Transient GitHub/API error (attempt $attempt). Retrying in 120 seconds: $msg"
            Start-Sleep -Seconds 120
            continue
        }
        throw "gh command failed:`n$($Arguments -join ' ')`n$msg"
    }
}

function Start-CloudRun {
    $started = [DateTime]::UtcNow
    Invoke-GhWithBackoff -Arguments @('workflow','run',$Workflow,'--repo',$Repository,'--ref',$Branch) | Out-Null
    Write-ControllerLog "Triggered GitHub Actions workflow $Workflow on $Branch."

    while ($true) {
        Start-Sleep -Seconds 5
        $raw = Invoke-GhWithBackoff -Arguments @('run','list','--repo',$Repository,'--workflow',$Workflow,'--branch',$Branch,'--event','workflow_dispatch','--limit','10','--json','databaseId,createdAt,status,headSha')
        $runs = $raw | ConvertFrom-Json
        $candidate = $runs | Where-Object { ([DateTime]$_.createdAt).ToUniversalTime() -ge $started.AddSeconds(-2) } | Sort-Object { [DateTime]$_.createdAt } -Descending | Select-Object -First 1
        if ($candidate) {
            Write-ControllerLog "New Run ID: $($candidate.databaseId)"
            return [long]$candidate.databaseId
        }
    }
}

function Get-CloudRunState {
    param([long]$Id)
    $raw = Invoke-GhWithBackoff -Arguments @('run','view',[string]$Id,'--repo',$Repository,'--json','status,conclusion,url,headSha,createdAt,updatedAt')
    return ($raw | ConvertFrom-Json)
}

function Wait-CloudRun {
    param([long]$Id,[int]$Round)
    while ($true) {
        $run = Get-CloudRunState -Id $Id
        $status = [string]$run.status
        $conclusion = if ($run.PSObject.Properties.Name -contains 'conclusion') { [string]$run.conclusion } else { '' }
        Set-ControllerState -Status $status -Stage 'github-actions' -Conclusion $conclusion -CurrentRunId $Id -RepairRound $Round -Message "GitHub Actions $status"
        Write-ControllerLog "Run ${Id}: status=$status conclusion=$conclusion"
        if ($status -eq 'completed') { return $run }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Download-RunArtifacts {
    param([long]$Id,[switch]$Failure)
    $runDir = Join-Path $OutputRoot ("run-{0}" -f $Id)
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null

    if ($Failure) {
        $failedLog = Join-Path $runDir 'failed-steps.log'
        $logResult = Invoke-Captured -FilePath 'gh' -Arguments @('run','view',[string]$Id,'--repo',$Repository,'--log-failed') -AllowFailure
        $logResult.Output | Set-Content -Path $failedLog -Encoding UTF8
    }

    $download = Invoke-Captured -FilePath 'gh' -Arguments @('run','download',[string]$Id,'--repo',$Repository,'--dir',$runDir) -AllowFailure
    if ($download.ExitCode -ne 0) {
        Write-ControllerLog "Artifact download returned exit code $($download.ExitCode): $($download.Output)"
    }
    return $runDir
}

function Verify-Firmware {
    param([long]$Id,[string]$RunDir)
    $firmware = Get-ChildItem -Path $RunDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'jdcloud_re-ss-01' -and $_.Length -gt 0 }
    if (-not $firmware) {
        throw "Build reported success but no non-empty jdcloud_re-ss-01 firmware was found in artifacts for Run $Id."
    }
    $checks = foreach ($file in $firmware) {
        [pscustomobject]@{
            file = $file.FullName
            size = $file.Length
            sha256 = (Get-FileHash -Algorithm SHA256 -Path $file.FullName).Hash
        }
    }
    $checks | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $RunDir 'firmware-verification.json') -Encoding UTF8
    Write-ControllerLog "Firmware verification passed for Run $Id ($($firmware.Count) matching files)."
}

function Invoke-CodexRepair {
    param([long]$Id,[string]$RunDir,[int]$Round)

    Assert-CleanRepository
    $beforeHashes = Get-HardFileHashes
    $lastMessage = Join-Path $RunDir 'codex-last-message.txt'
    $promptPath = Join-Path $RunDir 'codex-repair-prompt.txt'

    $prompt = @"
You are repairing the mxonline/xinzhaowrt OpenWrt CI build after GitHub Actions Run $Id failed.

Repository root: $RepoRoot
Diagnostics directory: $RunDir
Automatic repair round: $Round of $MaxRepairRounds

Work directly in the repository and inspect all available diagnostics, especially failed-steps.log and any downloaded failure-report.txt, error-summary.txt, error-context.txt, feed-error.txt, feed-check.log, or build.log.

Rules:
1. Identify the first real root cause. Do not treat generic exit code 1 or unrelated warnings as the root cause.
2. Make the smallest safe code/feed/workflow/script compatibility fix that addresses the confirmed root cause.
3. Do NOT modify config/required-plugins.txt.
4. Do NOT modify config/arthur.config.
5. Do NOT remove, disable, comment out, or bypass any of the 22 required LuCI plugins.
6. Do NOT change the target away from qualcommax/ipq60xx/jdcloud_re-ss-01.
7. Do NOT perform flashing, partition, bootloader, or device operations.
8. Do NOT run a full local OpenWrt compilation.
9. Do NOT commit, push, trigger GitHub Actions, or manipulate GitHub remotely. The persistent controller owns those actions.
10. Run only lightweight/static checks that are available locally.
11. If the repair genuinely requires changing a protected plugin list, target config, device behavior, or another product decision, make no protected change and clearly state BLOCKED in your final message.
12. Finish the task only after the working tree contains the minimal repair, or after determining it is BLOCKED.
"@
    $prompt | Set-Content -Path $promptPath -Encoding UTF8

    $codexPath = (Get-Command codex).Source
    Write-ControllerLog "Starting non-interactive Codex repair for Run $Id, round $Round."
    Set-ControllerState -Status 'repairing' -Stage 'codex-exec' -CurrentRunId $Id -RepairRound $Round -Message 'Codex is analyzing diagnostics and preparing a minimal repair.'

    $job = Start-Job -ScriptBlock {
        param($Exe,$Root,$PromptFile,$LastMessage)
        $inputText = Get-Content -Raw -Path $PromptFile
        $output = ($inputText | & $Exe exec --sandbox workspace-write -c 'approval_policy="never"' -C $Root -o $LastMessage - 2>&1 | Out-String)
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } -ArgumentList $codexPath,$RepoRoot,$promptPath,$lastMessage

    $done = Wait-Job -Job $job -Timeout $CodexTimeoutSeconds
    if (-not $done) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        throw "BLOCKED: codex exec exceeded timeout of $CodexTimeoutSeconds seconds."
    }
    $result = Receive-Job $job
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    $result.Output | Set-Content -Path (Join-Path $RunDir 'codex-exec.log') -Encoding UTF8
    if ($result.ExitCode -ne 0) {
        throw "BLOCKED: codex exec failed with exit code $($result.ExitCode). See $RunDir\codex-exec.log"
    }

    Test-HardFilesUnchanged -Before $beforeHashes

    $diffCheck = Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'diff','--check') -AllowFailure
    if ($diffCheck.ExitCode -ne 0) {
        throw "BLOCKED: git diff --check failed after Codex repair.`n$($diffCheck.Output)"
    }

    $changes = Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'status','--porcelain')
    if (-not $changes.Output) {
        $final = if (Test-Path $lastMessage) { Get-Content -Raw $lastMessage } else { '' }
        throw "BLOCKED: Codex produced no repository changes. $final"
    }

    if ((Test-Path $lastMessage) -and ((Get-Content -Raw $lastMessage) -match '(?im)^\s*BLOCKED\b')) {
        throw "BLOCKED: Codex determined that the failure requires a protected/user decision. See $lastMessage"
    }

    Write-ControllerLog "Codex repair produced changes:`n$($changes.Output)"
}

function Commit-And-PushRepair {
    param([long]$FailedRunId,[int]$Round)
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'add','-A') | Out-Null
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'commit','-m',"fix(ci): auto-repair run $FailedRunId round $Round") | Out-Null
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'push','origin',$Branch) | Out-Null
    $sha = (Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'rev-parse','HEAD')).Output
    Write-ControllerLog "Repair committed and pushed: $sha"
    return $sha
}

try {
    Assert-Tools
    Set-Location $RepoRoot
    Sync-Main
    Assert-CleanRepository

    $repairRound = 0
    if ($Mode -eq 'Resume') {
        if ($RunId -le 0) { throw 'Resume mode requires -RunId.' }
        $currentRunId = $RunId
    } else {
        # The current build scripts intentionally track the configured upstream refs (for example main/master),
        # so UpdateBuild naturally consumes their latest revisions in GitHub Actions. Rebuild uses the same
        # repository state but does not make an extra source-update commit locally.
        $currentRunId = Start-CloudRun
    }

    while ($true) {
        $run = Wait-CloudRun -Id $currentRunId -Round $repairRound
        $conclusion = if ($run.PSObject.Properties.Name -contains 'conclusion') { [string]$run.conclusion } else { '' }

        if ($conclusion -eq 'success') {
            Set-ControllerState -Status 'verifying' -Stage 'artifact' -Conclusion $conclusion -CurrentRunId $currentRunId -RepairRound $repairRound -Message 'Downloading and verifying firmware artifacts.'
            $runDir = Download-RunArtifacts -Id $currentRunId
            Verify-Firmware -Id $currentRunId -RunDir $runDir
            Set-ControllerState -Status 'success' -Stage 'complete' -Conclusion 'success' -CurrentRunId $currentRunId -RepairRound $repairRound -Message 'Cloud build and firmware verification succeeded.'
            Write-ControllerLog "SUCCESS: Run $currentRunId completed and firmware verification passed."
            exit 0
        }

        $repairRound++
        $runDir = Download-RunArtifacts -Id $currentRunId -Failure
        Set-ControllerState -Status 'failed' -Stage 'diagnostics' -Conclusion $conclusion -CurrentRunId $currentRunId -RepairRound $repairRound -Message "Run failed; diagnostics downloaded to $runDir"
        Write-ControllerLog "Run $currentRunId failed with conclusion=$conclusion. Diagnostics: $runDir"

        if ($repairRound -gt $MaxRepairRounds) {
            throw "BLOCKED: maximum automatic repair rounds ($MaxRepairRounds) exceeded. Last failed Run: $currentRunId"
        }

        Invoke-CodexRepair -Id $currentRunId -RunDir $runDir -Round $repairRound
        Commit-And-PushRepair -FailedRunId $currentRunId -Round $repairRound | Out-Null
        $currentRunId = Start-CloudRun
    }
}
catch {
    $message = $_.Exception.Message
    Write-ControllerLog "STOPPED: $message"
    Set-ControllerState -Status 'blocked' -Stage 'controller' -CurrentRunId $currentRunId -Message $message
    exit 1
}
