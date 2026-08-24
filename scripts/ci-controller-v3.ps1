param(
    [ValidateSet('Stabilize','Resume')]
    [string]$Mode = 'Stabilize',
    [long]$RunId = 0,
    [int]$MaxRepairRounds = 3,
    [int]$PollSeconds = 60,
    [int]$CodexTimeoutSeconds = 1800,
    [string]$Repository = 'mxonline/xinzhaowrt',
    [string]$Branch = 'main',
    [string]$Workflow = 'stabilize-v3.yml'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$StateDir = Join-Path $RepoRoot 'state'
$OutputRoot = Join-Path $RepoRoot 'output\controller-v3'
$StateFile = Join-Path $StateDir 'ci-v3-state.json'
$ControllerLog = Join-Path $OutputRoot 'controller-v3.log'
$HardFiles = @('config/required-plugins.txt','config/arthur.config')
$currentRunId = $RunId
$repairRound = 0

New-Item -ItemType Directory -Force -Path $StateDir, $OutputRoot | Out-Null

$mutex = New-Object System.Threading.Mutex($false, 'Local\XinZhaoWrtV3Controller')
if (-not $mutex.WaitOne(0, $false)) {
    throw 'Another XinZhaoWrt v3 controller instance is already running.'
}

function Write-Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $line | Tee-Object -FilePath $ControllerLog -Append
}

function Set-State {
    param(
        [string]$Status,
        [string]$Stage = '',
        [string]$Conclusion = '',
        [string]$Message = ''
    )
    [ordered]@{
        pipeline     = 'OpenWrt-v3'
        status       = $Status
        stage        = $Stage
        conclusion   = $Conclusion
        run_id       = $currentRunId
        repair_round = $repairRound
        workflow     = $Workflow
        branch       = $Branch
        repository   = $Repository
        message      = $Message
        updated_at   = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
}

function Invoke-Captured {
    param([string]$FilePath,[string[]]$Arguments,[switch]$AllowFailure)
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
    $auth = Invoke-Captured 'gh' @('auth','status','--hostname','github.com') -AllowFailure
    if ($auth.ExitCode -ne 0) { throw "GitHub CLI is not authenticated.`n$($auth.Output)" }
}

function Assert-CleanRepo {
    $dirty = Invoke-Captured 'git' @('-C',$RepoRoot,'status','--porcelain')
    if ($dirty.Output) { throw "Repository has uncommitted changes.`n$($dirty.Output)" }
}

function Sync-Branch {
    Invoke-Captured 'git' @('-C',$RepoRoot,'fetch','--quiet','origin',$Branch) | Out-Null
    $current = (Invoke-Captured 'git' @('-C',$RepoRoot,'branch','--show-current')).Output.Trim()
    if ($current -eq $Branch) {
        Invoke-Captured 'git' @('-C',$RepoRoot,'pull','--ff-only','origin',$Branch) | Out-Null
        return
    }
    $head = (Invoke-Captured 'git' @('-C',$RepoRoot,'rev-parse','HEAD')).Output.Trim()
    $remote = (Invoke-Captured 'git' @('-C',$RepoRoot,'rev-parse',"origin/$Branch")).Output.Trim()
    if ($head -ne $remote) {
        throw "Current worktree is not synchronized with origin/$Branch."
    }
}

function Invoke-Gh {
    param([string[]]$Arguments)
    while ($true) {
        $result = Invoke-Captured 'gh' $Arguments -AllowFailure
        if ($result.ExitCode -eq 0) { return $result.Output }
        if ($result.Output -match '(?i)rate limit|HTTP 403') {
            Write-Log 'GitHub API rate limit reached; waiting 600 seconds without restarting the Run.'
            Start-Sleep 600
            continue
        }
        if ($result.Output -match '(?i)unexpected EOF|timed out|timeout|connection|HTTP 5\d\d') {
            Write-Log 'Transient GitHub/API failure; retrying in 120 seconds.'
            Start-Sleep 120
            continue
        }
        throw "gh command failed: $($Arguments -join ' ')`n$($result.Output)"
    }
}

function Start-V3Run {
    $started = [DateTime]::UtcNow
    Invoke-Gh @('workflow','run',$Workflow,'--repo',$Repository,'--ref',$Branch) | Out-Null
    Write-Log "Triggered $Workflow on $Branch."
    while ($true) {
        Start-Sleep 5
        $raw = Invoke-Gh @('run','list','--repo',$Repository,'--workflow',$Workflow,'--branch',$Branch,'--event','workflow_dispatch','--limit','10','--json','databaseId,createdAt,status,headSha')
        $runs = $raw | ConvertFrom-Json
        $candidate = $runs | Where-Object { ([DateTime]$_.createdAt).ToUniversalTime() -ge $started.AddSeconds(-2) } | Sort-Object { [DateTime]$_.createdAt } -Descending | Select-Object -First 1
        if ($candidate) { return [long]$candidate.databaseId }
    }
}

function Get-RunState {
    param([long]$Id)
    (Invoke-Gh @('run','view',[string]$Id,'--repo',$Repository,'--json','status,conclusion,url,headSha,createdAt,updatedAt') | ConvertFrom-Json)
}

function Wait-V3Run {
    param([long]$Id)
    while ($true) {
        $run = Get-RunState $Id
        $status = [string]$run.status
        $conclusion = if ($run.PSObject.Properties.Name -contains 'conclusion') { [string]$run.conclusion } else { '' }
        Set-State $status 'github-actions' $conclusion "v3 workflow $status"
        Write-Log "Run ${Id}: status=$status conclusion=$conclusion"
        if ($status -eq 'completed') { return $run }
        Start-Sleep $PollSeconds
    }
}

function Download-V3Artifacts {
    param([long]$Id,[switch]$Failure)
    $runDir = Join-Path $OutputRoot ("run-{0}" -f $Id)
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    if ($Failure) {
        $failed = Invoke-Captured 'gh' @('run','view',[string]$Id,'--repo',$Repository,'--log-failed') -AllowFailure
        $failed.Output | Set-Content (Join-Path $runDir 'failed-steps.log') -Encoding UTF8
    }
    $download = Invoke-Captured 'gh' @('run','download',[string]$Id,'--repo',$Repository,'--dir',$runDir) -AllowFailure
    if ($download.ExitCode -ne 0) { Write-Log "Artifact download warning: $($download.Output)" }
    return $runDir
}

function Verify-KnownGoodCandidate {
    param([long]$Id,[string]$RunDir)
    $manifest = Get-ChildItem $RunDir -Recurse -File -Filter manifest.txt -ErrorAction SilentlyContinue | Select-Object -First 1
    $lock = Get-ChildItem $RunDir -Recurse -File -Filter sources.lock -ErrorAction SilentlyContinue | Select-Object -First 1
    $fullConfig = Get-ChildItem $RunDir -Recurse -File -Filter full.config -ErrorAction SilentlyContinue | Select-Object -First 1
    $profiles = Get-ChildItem $RunDir -Recurse -File -Filter profiles.json -ErrorAction SilentlyContinue | Select-Object -First 1
    $firmware = Get-ChildItem $RunDir -Recurse -File -Filter '*.bin' -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 1024 }
    foreach ($item in @($manifest,$lock,$fullConfig,$profiles)) {
        if (-not $item) { throw "Run $Id succeeded but known-good metadata is incomplete." }
    }
    if (-not $firmware) { throw "Run $Id succeeded but no non-empty firmware image was found." }
    $manifestText = Get-Content -Raw $manifest.FullName
    if ($manifestText -notmatch '(?m)^status=known-good-candidate$') { throw 'Known-good manifest status is missing.' }
    if ($manifestText -notmatch '(?m)^required_plugins=22$') { throw 'Known-good manifest does not certify 22 required plugins.' }
    $required = Get-Content (Join-Path $RepoRoot 'config\required-plugins.txt') | Where-Object { $_ -and -not $_.StartsWith('#') }
    $configText = Get-Content -Raw $fullConfig.FullName
    foreach ($pkg in $required) {
        if ($configText -notmatch "(?m)^CONFIG_PACKAGE_$([regex]::Escape($pkg))=y$") {
            throw "Required plugin missing from known-good full.config: $pkg"
        }
    }
    [ordered]@{
        run_id = $Id
        firmware_count = @($firmware).Count
        verified_plugins = $required.Count
        verified_at = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content (Join-Path $RunDir 'known-good-verification.json') -Encoding UTF8
    Write-Log "Known-good candidate verified: Run $Id, firmware=$(@($firmware).Count), plugins=$($required.Count)."
}

function Get-HardHashes {
    $h = @{}
    foreach ($relative in $HardFiles) {
        $path = Join-Path $RepoRoot $relative
        $h[$relative] = (Get-FileHash -Algorithm SHA256 $path).Hash
    }
    return $h
}

function Assert-HardFilesUnchanged {
    param([hashtable]$Before)
    foreach ($relative in $HardFiles) {
        $path = Join-Path $RepoRoot $relative
        if ((Get-FileHash -Algorithm SHA256 $path).Hash -ne $Before[$relative]) {
            Invoke-Captured 'git' @('-C',$RepoRoot,'restore','--',$relative) -AllowFailure | Out-Null
            throw "BLOCKED: automatic repair attempted to modify protected file $relative."
        }
    }
}

function Assert-SourceLockImmutableRefs {
    $lockPath = Join-Path $RepoRoot 'config\sources.lock'
    if (-not (Test-Path $lockPath)) { throw 'BLOCKED: config/sources.lock is missing.' }
    foreach ($line in Get-Content $lockPath) {
        if ($line -match '^([A-Z0-9_]+_COMMIT)=(.+)$') {
            if ($Matches[2] -notmatch '^[0-9a-f]{40}$') {
                throw "BLOCKED: source lock $($Matches[1]) is not an immutable commit SHA."
            }
        }
    }
}

function Invoke-V3CodexRepair {
    param([long]$Id,[string]$RunDir,[int]$Round)
    Assert-CleanRepo
    $before = Get-HardHashes
    $promptPath = Join-Path $RunDir 'codex-v3-repair-prompt.txt'
    $lastMessage = Join-Path $RunDir 'codex-v3-last-message.txt'
    @"
Repair mxonline/xinzhaowrt OpenWrt v3.0 stabilization after GitHub Actions Run $Id failed.

Repository: $RepoRoot
Diagnostics: $RunDir
Repair round: $Round of $MaxRepairRounds

This is the v3.0 stabilization pipeline. Inspect ALL available smoke logs and failed-step logs, not only the first generic exit code. Determine every independently confirmed failing phase among:
- Phase 1 QuickStart + iStore
- Phase 2 OpenAppFilter
- Phase 3 OpenClash + MosDNS
- Phase 4 EasyTier + DiskMan + Lucky + QuickFile
- Phase 5 standard LuCI applications
- Full Build / known-good verification

Make one minimal coherent repair pass for all confirmed root causes that can be fixed safely together. Do not start another full local OpenWrt build.

Hard rules:
1. Do not modify config/required-plugins.txt or remove/disable/bypass any of its 22 plugins.
2. Do not modify config/arthur.config or change qualcommax/ipq60xx/jdcloud_re-ss-01.
3. config/sources.lock may only change to another explicit 40-character commit SHA when diagnostics prove the pinned revision itself is incompatible; never replace a lock with main/master/tag/floating refs.
4. Do not perform flashing, eMMC partition, bootloader, or device operations.
5. Do not commit, push, trigger Actions, or manipulate GitHub. The controller owns those operations.
6. Prefer package/source/workflow compatibility fixes over suppressing checks.
7. Keep the Compatibility Gate and 22/22 verification intact.
8. Run lightweight static checks only.
9. If a required plugin cannot be made compatible without a product decision or removal, make no protected change and end with a line beginning BLOCKED.
10. Finish with repository changes implementing the repair, or BLOCKED.
"@ | Set-Content $promptPath -Encoding UTF8

    Set-State 'repairing' 'codex-v3' '' 'Codex is analyzing all failed v3 phases.'
    $codexPath = (Get-Command codex).Source
    $job = Start-Job -ScriptBlock {
        param($Exe,$Root,$PromptFile,$LastMessage)
        $inputText = Get-Content -Raw $PromptFile
        $output = ($inputText | & $Exe exec --sandbox workspace-write -c 'approval_policy="never"' -C $Root -o $LastMessage - 2>&1 | Out-String)
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } -ArgumentList $codexPath,$RepoRoot,$promptPath,$lastMessage

    $done = Wait-Job $job -Timeout $CodexTimeoutSeconds
    if (-not $done) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        throw "BLOCKED: codex exec exceeded $CodexTimeoutSeconds seconds."
    }
    $result = Receive-Job $job
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    $result.Output | Set-Content (Join-Path $RunDir 'codex-v3-exec.log') -Encoding UTF8
    if ($result.ExitCode -ne 0) { throw "BLOCKED: codex exec failed with exit code $($result.ExitCode)." }

    Assert-HardFilesUnchanged $before
    Assert-SourceLockImmutableRefs
    $diff = Invoke-Captured 'git' @('-C',$RepoRoot,'diff','--check') -AllowFailure
    if ($diff.ExitCode -ne 0) { throw "BLOCKED: git diff --check failed.`n$($diff.Output)" }
    $changes = Invoke-Captured 'git' @('-C',$RepoRoot,'status','--porcelain')
    if (-not $changes.Output) { throw 'BLOCKED: Codex produced no repository changes.' }
    if ((Test-Path $lastMessage) -and ((Get-Content -Raw $lastMessage) -match '(?im)^\s*BLOCKED\b')) {
        throw "BLOCKED: Codex requires a protected/user decision. See $lastMessage"
    }
    Write-Log "v3 repair produced changes:`n$($changes.Output)"
}

function Commit-Repair {
    param([long]$FailedId,[int]$Round)
    Invoke-Captured 'git' @('-C',$RepoRoot,'add','-A') | Out-Null
    Invoke-Captured 'git' @('-C',$RepoRoot,'commit','-m',"fix(ci-v3): repair run $FailedId round $Round") | Out-Null
    Invoke-Captured 'git' @('-C',$RepoRoot,'push','origin',$Branch) | Out-Null
    $sha = (Invoke-Captured 'git' @('-C',$RepoRoot,'rev-parse','HEAD')).Output.Trim()
    Write-Log "Repair pushed: $sha"
}

try {
    Assert-Tools
    Set-Location $RepoRoot
    Sync-Branch
    Assert-CleanRepo
    Assert-SourceLockImmutableRefs

    if ($Mode -eq 'Resume') {
        if ($RunId -le 0) { throw 'Resume mode requires -RunId.' }
        $currentRunId = $RunId
    } else {
        $currentRunId = Start-V3Run
    }

    while ($true) {
        $run = Wait-V3Run $currentRunId
        $conclusion = if ($run.PSObject.Properties.Name -contains 'conclusion') { [string]$run.conclusion } else { '' }
        if ($conclusion -eq 'success') {
            Set-State 'verifying' 'known-good' $conclusion 'Downloading and verifying known-good candidate.'
            $runDir = Download-V3Artifacts $currentRunId
            Verify-KnownGoodCandidate $currentRunId $runDir
            Set-State 'success' 'known-good' 'success' 'First known-good candidate is verified.'
            Write-Log "SUCCESS: v3 Run $currentRunId produced a verified known-good candidate."
            exit 0
        }

        $repairRound++
        $runDir = Download-V3Artifacts $currentRunId -Failure
        Set-State 'failed' 'diagnostics' $conclusion "Diagnostics downloaded to $runDir"
        if ($repairRound -gt $MaxRepairRounds) {
            throw "BLOCKED: maximum v3 repair rounds ($MaxRepairRounds) exceeded."
        }
        Invoke-V3CodexRepair $currentRunId $runDir $repairRound
        Commit-Repair $currentRunId $repairRound
        $currentRunId = Start-V3Run
    }
}
catch {
    $message = $_.Exception.Message
    Write-Log "STOPPED: $message"
    Set-State 'blocked' 'controller-v3' '' $message
    exit 1
}
finally {
    if ($mutex) {
        try { $mutex.ReleaseMutex() | Out-Null } catch {}
        $mutex.Dispose()
    }
}
