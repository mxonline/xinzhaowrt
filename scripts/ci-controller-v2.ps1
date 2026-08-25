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
$HardFiles = @('config/required-plugins.txt','config/arthur.config')
$AllowedRepairPrefixes = @('scripts/','.github/workflows/','patches/','files/','package/')
$currentRunId = $RunId

New-Item -ItemType Directory -Force -Path $StateDir, $OutputRoot | Out-Null

function Write-ControllerLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $ControllerLog -Value $line
    Write-Host $line
}

function Set-ControllerState {
    param([string]$Status,[string]$Stage='',[string]$Conclusion='',[long]$CurrentRunId=0,[int]$RepairRound=0,[string]$Message='')
    [ordered]@{
        status=$Status; stage=$Stage; conclusion=$Conclusion; run_id=$CurrentRunId
        repair_round=$RepairRound; branch=$Branch; repository=$Repository
        message=$Message; updated_at=(Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
}

function Invoke-Captured {
    param([string]$FilePath,[string[]]$Arguments,[switch]$AllowFailure)
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $text = (& $FilePath @Arguments 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if (-not $AllowFailure -and $code -ne 0) { throw "$FilePath failed with exit code $code`n$text" }
    [pscustomobject]@{ ExitCode=$code; Output=$text }
}

function Get-CodexExecutable {
    $cmd = Get-Command codex.cmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $codex = Get-Command codex -ErrorAction Stop
    if ($codex.Source -and $codex.Source.EndsWith('.ps1',[System.StringComparison]::OrdinalIgnoreCase)) {
        $shim = Join-Path (Split-Path $codex.Source -Parent) 'codex.cmd'
        if (Test-Path $shim) { return $shim }
    }
    return $codex.Source
}

function Assert-Tools {
    foreach ($tool in @('git','gh','codex')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command not found: $tool" }
    }
    $auth = Invoke-Captured -FilePath 'gh' -Arguments @('auth','status','--hostname','github.com') -AllowFailure
    if ($auth.ExitCode -ne 0) { throw "GitHub CLI is not authenticated.`n$($auth.Output)" }
}

function Assert-CleanRepository {
    $dirty = Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'status','--porcelain')
    if ($dirty.Output) { throw "Repository has uncommitted changes.`n$($dirty.Output)" }
}

function Sync-Branch {
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'fetch','--quiet','origin',$Branch) | Out-Null
    $currentBranch = (Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'branch','--show-current')).Output.Trim()
    if ($currentBranch -eq $Branch) {
        Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'pull','--ff-only','origin',$Branch) | Out-Null
    } else {
        $head = (Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'rev-parse','HEAD')).Output.Trim()
        $remote = (Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'rev-parse',"origin/$Branch")).Output.Trim()
        if ($head -ne $remote) { throw "Detached worktree is not synchronized with origin/$Branch." }
    }
}

function Get-HardFileHashes {
    $hashes=@{}
    foreach ($relative in $HardFiles) {
        $path=Join-Path $RepoRoot $relative
        if (-not (Test-Path $path)) { throw "Hard constraint file missing: $relative" }
        $hashes[$relative]=(Get-FileHash -Algorithm SHA256 -Path $path).Hash
    }
    return $hashes
}

function Test-HardFilesUnchanged {
    param([hashtable]$Before)
    foreach ($relative in $HardFiles) {
        $path=Join-Path $RepoRoot $relative
        if ((Get-FileHash -Algorithm SHA256 -Path $path).Hash -ne $Before[$relative]) {
            Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'restore','--',$relative) -AllowFailure | Out-Null
            throw "BLOCKED: protected file modification attempted: $relative"
        }
    }
}

function Invoke-GhWithBackoff {
    param([string[]]$Arguments)
    $attempt=0
    while ($true) {
        $attempt++
        $result=Invoke-Captured -FilePath 'gh' -Arguments $Arguments -AllowFailure
        if ($result.ExitCode -eq 0) { return $result.Output }
        $msg=$result.Output
        if ($msg -match '(?i)rate limit|HTTP 403') { Write-ControllerLog 'GitHub rate limit; retrying in 600 seconds.'; Start-Sleep 600; continue }
        if ($msg -match '(?i)unexpected EOF|EOF|timeout|timed out|connection|HTTP 5\d\d') { Write-ControllerLog "Transient GitHub error; retrying in 120 seconds: $msg"; Start-Sleep 120; continue }
        throw "gh command failed: $($Arguments -join ' ')`n$msg"
    }
}

function Start-CloudRun {
    $started=[DateTime]::UtcNow
    Invoke-GhWithBackoff -Arguments @('workflow','run',$Workflow,'--repo',$Repository,'--ref',$Branch) | Out-Null
    Write-ControllerLog "Triggered $Workflow on $Branch."
    while ($true) {
        Start-Sleep 5
        $raw=Invoke-GhWithBackoff -Arguments @('run','list','--repo',$Repository,'--workflow',$Workflow,'--branch',$Branch,'--event','workflow_dispatch','--limit','10','--json','databaseId,createdAt,status,headSha')
        $runs=$raw | ConvertFrom-Json
        $candidate=$runs | Where-Object { ([DateTime]$_.createdAt).ToUniversalTime() -ge $started.AddSeconds(-2) } | Sort-Object { [DateTime]$_.createdAt } -Descending | Select-Object -First 1
        if ($candidate) { Write-ControllerLog "New Run ID: $($candidate.databaseId)"; return [long]$candidate.databaseId }
    }
}

function Wait-CloudRun {
    param([long]$Id,[int]$Round)
    while ($true) {
        $raw=Invoke-GhWithBackoff -Arguments @('run','view',[string]$Id,'--repo',$Repository,'--json','status,conclusion,url,headSha,createdAt,updatedAt')
        $run=$raw | ConvertFrom-Json
        $status=[string]$run.status
        $conclusion=if ($run.PSObject.Properties.Name -contains 'conclusion') { [string]$run.conclusion } else { '' }
        Set-ControllerState -Status $status -Stage 'github-actions' -Conclusion $conclusion -CurrentRunId $Id -RepairRound $Round -Message "GitHub Actions $status"
        Write-ControllerLog "Run ${Id}: status=$status conclusion=$conclusion"
        if ($status -eq 'completed') { return $run }
        Start-Sleep $PollSeconds
    }
}

function Download-RunArtifacts {
    param([long]$Id,[switch]$Failure)
    $runDir=Join-Path $OutputRoot ("run-{0}" -f $Id)
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    if ($Failure) {
        $failed=Invoke-Captured -FilePath 'gh' -Arguments @('run','view',[string]$Id,'--repo',$Repository,'--log-failed') -AllowFailure
        $failed.Output | Set-Content -Path (Join-Path $runDir 'failed-steps.log') -Encoding UTF8
    }
    $download=Invoke-Captured -FilePath 'gh' -Arguments @('run','download',[string]$Id,'--repo',$Repository,'--dir',$runDir) -AllowFailure
    if ($download.ExitCode -ne 0) { Write-ControllerLog "Artifact download warning: $($download.Output)" }
    return $runDir
}

function Verify-Firmware {
    param([long]$Id,[string]$RunDir)
    $firmware=Get-ChildItem -Path $RunDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'jdcloud_re-ss-01' -and $_.Length -gt 0 }
    if (-not $firmware) { throw "Build success but no non-empty jdcloud_re-ss-01 firmware found for Run $Id." }
    $pluginReport=Get-ChildItem -Path $RunDir -Recurse -File -Filter 'plugin-verification.txt' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pluginReport) { throw "Build success but plugin-verification.txt is missing for Run $Id." }
    $pluginText=Get-Content -Raw $pluginReport.FullName
    if ($pluginText -notmatch 'PASS: all required LuCI plugins were compiled and are present in the final firmware manifest') {
        throw "Build success but required 22-plugin verification did not pass for Run $Id."
    }
    $checks=foreach ($file in $firmware) { [pscustomobject]@{file=$file.FullName;size=$file.Length;sha256=(Get-FileHash -Algorithm SHA256 -Path $file.FullName).Hash} }
    $checks | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $RunDir 'firmware-verification.json') -Encoding UTF8
    Write-ControllerLog "Firmware and 22-plugin verification passed for Run $Id."
}

function Get-TailText {
    param([string]$Path,[int]$MaxChars=24000)
    if (-not (Test-Path $Path)) { return '' }
    $text=Get-Content -Raw -ErrorAction SilentlyContinue $Path
    if (-not $text) { return '' }
    if ($text.Length -gt $MaxChars) { return $text.Substring($text.Length-$MaxChars) }
    return $text
}

function Get-RepairEvidence {
    param([string]$RunDir)
    $names=@('failure-report.txt','error-summary.txt','error-context.txt','feed-error.txt','feed-check.log','failed-steps.log','build.log','failure-fingerprint.json','repair-regression.json')
    $parts=New-Object System.Collections.Generic.List[string]
    foreach ($name in $names) {
        $file=Get-ChildItem -Path $RunDir -Recurse -File -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($file) {
            $text=Get-TailText -Path $file.FullName
            if ($text) { $parts.Add("===== $name =====`n$text") }
        }
    }
    $joined=$parts -join "`n`n"
    $joined=$joined -replace '(?i)(authorization:\s*(?:basic|bearer)\s+)[^\s]+','$1[REDACTED]'
    $joined=$joined -replace '(?i)(github_pat_|ghp_)[A-Za-z0-9_]+','[REDACTED_TOKEN]'
    if ($joined.Length -gt 120000) { $joined=$joined.Substring($joined.Length-120000) }
    return $joined
}

function Invoke-CodexNoTool {
    param([string]$Prompt,[string]$OutputPath)
    $promptPath="$OutputPath.prompt.txt"
    [System.IO.File]::WriteAllText($promptPath,$Prompt,(New-Object System.Text.UTF8Encoding($false)))
    $exe=Get-CodexExecutable
    $job=Start-Job -ScriptBlock {
        param($Exe,$PromptFile,$OutFile)
        $ErrorActionPreference='Continue'
        $inputText=Get-Content -Raw $PromptFile
        $output=($inputText | & $Exe exec --sandbox read-only -c 'approval_policy="never"' -o $OutFile - 2>&1 | Out-String)
        [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=$output}
    } -ArgumentList $exe,$promptPath,$OutputPath
    $done=Wait-Job $job -Timeout $CodexTimeoutSeconds
    if (-not $done) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue; throw "BLOCKED: Codex reasoning timed out after $CodexTimeoutSeconds seconds." }
    $result=Receive-Job $job
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    $result.Output | Set-Content -Path "$OutputPath.exec.log" -Encoding UTF8
    if ($result.ExitCode -ne 0) { throw "BLOCKED: Codex reasoning failed with exit code $($result.ExitCode)." }
    if (-not (Test-Path $OutputPath)) { throw 'BLOCKED: Codex produced no final response.' }
    return (Get-Content -Raw $OutputPath)
}

function ConvertFrom-CodexJson {
    param([string]$Text)
    $clean=$Text.Trim()
    $clean=$clean -replace '^```(?:json)?\s*','' -replace '\s*```$',''
    $first=$clean.IndexOf('{'); $last=$clean.LastIndexOf('}')
    if ($first -lt 0 -or $last -le $first) { throw 'BLOCKED: Codex plan was not valid JSON.' }
    return ($clean.Substring($first,$last-$first+1) | ConvertFrom-Json)
}

function Test-RepairPath {
    param([string]$Path,[switch]$MustExist)
    $p=($Path -replace '\\','/').TrimStart('./')
    if (-not $p -or $p.StartsWith('/') -or $p -match '^[A-Za-z]:' -or $p -match '(^|/)\.\.(/|$)') { return $false }
    if ($HardFiles -contains $p) { return $false }
    $prefixOK=$false
    foreach ($prefix in $AllowedRepairPrefixes) { if ($p.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)) { $prefixOK=$true; break } }
    if (-not $prefixOK) { return $false }
    if ($MustExist -and -not (Test-Path (Join-Path $RepoRoot $p))) { return $false }
    return $true
}

function Extract-UnifiedDiff {
    param([string]$Text)
    $m=[regex]::Match($Text,'(?s)```diff\s*(.*?)\s*```')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    $idx=$Text.IndexOf('diff --git ')
    if ($idx -ge 0) { return $Text.Substring($idx).Trim() }
    throw 'BLOCKED: Codex did not return a unified diff.'
}

function Invoke-StructuredCodexRepair {
    param([long]$Id,[string]$RunDir,[int]$Round)
    Assert-CleanRepository
    $before=Get-HardFileHashes
    $evidence=Get-RepairEvidence -RunDir $RunDir
    if (-not $evidence) { throw 'BLOCKED: diagnostics contain no usable repair evidence.' }

    $repoMap=(Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'ls-files','scripts','.github/workflows','patches','files','package')).Output
    if ($repoMap.Length -gt 20000) { $repoMap=$repoMap.Substring(0,20000) }

    $planPrompt=@"
You are the reasoning stage of an automated OpenWrt CI repair controller.
DO NOT use shell, filesystem, network, or any tool. Analyze only the text supplied below.
The controller, not you, will read and modify files.
Target must remain qualcommax/ipq60xx/jdcloud_re-ss-01 and all 22 required LuCI plugins must remain enabled.
Protected files config/required-plugins.txt and config/arthur.config can never be changed.
Choose at most 6 EXISTING repository files from the repository map that are genuinely needed to implement the smallest safe repair.
Return ONLY JSON with exactly these keys:
{"status":"repairable|blocked","root_cause":"...","error_signature":"...","repair_strategy":"...","files_needed":["..."]}
If evidence is insufficient or a protected/product decision is required, return status blocked.

FAILED RUN: $Id
REPAIR ROUND: $Round of $MaxRepairRounds

REPOSITORY MAP:
$repoMap

DIAGNOSTICS:
$evidence
"@
    Set-ControllerState -Status 'repairing' -Stage 'codex-plan' -CurrentRunId $Id -RepairRound $Round -Message 'Codex is reasoning over controller-supplied diagnostics only.'
    $planText=Invoke-CodexNoTool -Prompt $planPrompt -OutputPath (Join-Path $RunDir 'codex-plan.json')
    $plan=ConvertFrom-CodexJson $planText
    $plan | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $RunDir 'codex-plan-normalized.json') -Encoding UTF8
    if ([string]$plan.status -ne 'repairable') { throw "BLOCKED: Codex classified failure as blocked: $($plan.root_cause)" }

    $files=@($plan.files_needed)
    if ($files.Count -eq 0 -or $files.Count -gt 6) { throw 'BLOCKED: Codex requested an invalid number of source files.' }
    $normalized=New-Object System.Collections.Generic.List[string]
    $sourceParts=New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        $p=([string]$f -replace '\\','/').TrimStart('./')
        if (-not (Test-RepairPath -Path $p -MustExist)) { throw "BLOCKED: Codex requested unsafe or unavailable path: $p" }
        if (-not $normalized.Contains($p)) { $normalized.Add($p) }
        $text=Get-Content -Raw (Join-Path $RepoRoot $p)
        if ($text.Length -gt 50000) { throw "BLOCKED: requested repair file is too large for safe structured repair: $p" }
        $sourceParts.Add("===== FILE: $p =====`n$text")
    }
    $sources=$sourceParts -join "`n`n"

    $patchPrompt=@"
You are the patch-generation stage of an automated OpenWrt CI repair controller.
DO NOT use shell, filesystem, network, or any tool. Use only the diagnostics, repair plan, and exact source files supplied below.
Generate the smallest safe repair for the confirmed root cause.
You may modify ONLY these existing files:
$($normalized -join "`n")
Never modify config/required-plugins.txt or config/arthur.config, never remove any required plugin, and never change the device target.
Do not include explanation. Return ONLY a standard git unified diff beginning with 'diff --git'. Do not invent files that were not supplied.

PLAN:
$($plan | ConvertTo-Json -Depth 6)

DIAGNOSTICS:
$evidence

SOURCE FILES:
$sources
"@
    Set-ControllerState -Status 'repairing' -Stage 'codex-patch' -CurrentRunId $Id -RepairRound $Round -Message 'Codex is generating a patch from controller-supplied source text.'
    $patchText=Invoke-CodexNoTool -Prompt $patchPrompt -OutputPath (Join-Path $RunDir 'codex-patch.txt')
    $patch=Extract-UnifiedDiff $patchText

    $changed=[regex]::Matches($patch,'(?m)^diff --git a/(.+?) b/(.+?)$')
    if ($changed.Count -eq 0) { throw 'BLOCKED: generated patch contains no changed files.' }
    foreach ($match in $changed) {
        $a=$match.Groups[1].Value.Trim(); $b=$match.Groups[2].Value.Trim()
        if ($a -ne $b) { throw 'BLOCKED: rename/new-file patches are not allowed in automatic repair.' }
        if (-not $normalized.Contains($a)) { throw "BLOCKED: patch attempted a file outside supplied context: $a" }
        if (-not (Test-RepairPath -Path $a -MustExist)) { throw "BLOCKED: unsafe patch path: $a" }
    }

    $patchFile=Join-Path $RunDir 'codex-repair.patch'
    [System.IO.File]::WriteAllText($patchFile,$patch,(New-Object System.Text.UTF8Encoding($false)))
    $check=Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'apply','--check',$patchFile) -AllowFailure
    if ($check.ExitCode -ne 0) { throw "BLOCKED: Codex patch failed git apply --check.`n$($check.Output)" }
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'apply','--whitespace=fix',$patchFile) | Out-Null
    Test-HardFilesUnchanged -Before $before
    $diffCheck=Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'diff','--check') -AllowFailure
    if ($diffCheck.ExitCode -ne 0) { Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'reset','--hard','HEAD') -AllowFailure | Out-Null; throw "BLOCKED: git diff --check failed after patch.`n$($diffCheck.Output)" }
    $changes=Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'status','--porcelain')
    if (-not $changes.Output) { throw 'BLOCKED: structured Codex patch produced no repository changes.' }
    Write-ControllerLog "Structured Codex repair produced changes:`n$($changes.Output)"
}

function Commit-And-PushRepair {
    param([long]$FailedRunId,[int]$Round)
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'add','-A') | Out-Null
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'commit','-m',"fix(ci): auto-repair run $FailedRunId round $Round") | Out-Null
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'push','origin',$Branch) | Out-Null
    $sha=(Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'rev-parse','HEAD')).Output.Trim()
    Write-ControllerLog "Repair committed and pushed: $sha"
}

try {
    Assert-Tools
    Set-Location $RepoRoot
    Sync-Branch
    Assert-CleanRepository
    $repairRound=0
    if ($Mode -eq 'Resume') {
        if ($RunId -le 0) { throw 'Resume mode requires -RunId.' }
        $currentRunId=$RunId
    } else { $currentRunId=Start-CloudRun }

    while ($true) {
        $run=Wait-CloudRun -Id $currentRunId -Round $repairRound
        $conclusion=if ($run.PSObject.Properties.Name -contains 'conclusion') { [string]$run.conclusion } else { '' }
        if ($conclusion -eq 'success') {
            Set-ControllerState -Status 'verifying' -Stage 'artifact' -Conclusion $conclusion -CurrentRunId $currentRunId -RepairRound $repairRound -Message 'Downloading and verifying firmware and required plugins.'
            $runDir=Download-RunArtifacts -Id $currentRunId
            Verify-Firmware -Id $currentRunId -RunDir $runDir
            Set-ControllerState -Status 'success' -Stage 'complete' -Conclusion 'success' -CurrentRunId $currentRunId -RepairRound $repairRound -Message 'Cloud build, firmware, SHA256, and 22-plugin verification succeeded.'
            Write-ControllerLog "SUCCESS: Run $currentRunId passed all acceptance gates."
            exit 0
        }

        $repairRound++
        $runDir=Download-RunArtifacts -Id $currentRunId -Failure
        Set-ControllerState -Status 'failed' -Stage 'diagnostics' -Conclusion $conclusion -CurrentRunId $currentRunId -RepairRound $repairRound -Message "Run failed; diagnostics downloaded to $runDir"
        Write-ControllerLog "Run $currentRunId failed with conclusion=$conclusion. Diagnostics: $runDir"
        if ($repairRound -gt $MaxRepairRounds) { throw "BLOCKED: maximum automatic repair rounds ($MaxRepairRounds) exceeded. Last failed Run: $currentRunId" }

        Invoke-StructuredCodexRepair -Id $currentRunId -RunDir $runDir -Round $repairRound
        Commit-And-PushRepair -FailedRunId $currentRunId -Round $repairRound
        $currentRunId=Start-CloudRun
    }
} catch {
    $message=$_.Exception.Message
    Write-ControllerLog "STOPPED: $message"
    Set-ControllerState -Status 'blocked' -Stage 'controller' -CurrentRunId $currentRunId -Message $message
    exit 1
}
