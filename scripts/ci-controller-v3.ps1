param(
    [ValidateSet('Watch','Rebuild','Update','Resume')]
    [string]$Mode = 'Watch',

    [ValidateSet('rebuild_known_good','update_immortalwrt','update_feeds','update_plugins','update_all')]
    [string]$UpdateMode = 'update_immortalwrt',

    [long]$RunId = 0,
    [int]$MaxRepairRounds = 3,
    [int]$PollSeconds = 60,
    [int]$CodexTimeoutSeconds = 1800,
    [string]$Repository = 'mxonline/xinzhaowrt',
    [string]$Branch = 'main',
    [string]$Workflow = 'arthur-update-v3.yml'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$StateDir = Join-Path $RepoRoot 'state'
$OutputRoot = Join-Path $RepoRoot 'output\controller-v3'
$StateFile = Join-Path $StateDir 'ci-v3-state.json'
$ControllerLog = Join-Path $OutputRoot 'controller.log'
$RequestFile = Join-Path $RepoRoot 'production\v3-request.json'
$RequiredFile = Join-Path $RepoRoot 'config\required-plugins.txt'
$KnownGoodFile = Join-Path $RepoRoot 'production\known-good.json'
$KnownGoodLock = Join-Path $RepoRoot 'config\arthur-known-good.lock'

$HardFiles = @(
    'config/required-plugins.txt',
    'config/arthur.config',
    'config/arthur-known-good.lock',
    'production/known-good.json',
    'production/status.json',
    'VERSION',
    'build.env'
)

$AllowedRepairPrefixes = @(
    'scripts/',
    '.github/workflows/',
    'patches/',
    'files/',
    'package/'
)

New-Item -ItemType Directory -Force -Path $StateDir, $OutputRoot | Out-Null

function Write-ControllerLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $ControllerLog -Value $line
    Write-Host $line
}

function Set-ControllerState {
    param(
        [string]$Status,
        [string]$Stage = '',
        [string]$Conclusion = '',
        [long]$CurrentRunId = 0,
        [int]$RepairRound = 0,
        [string]$CurrentUpdateMode = '',
        [string]$CandidateTag = '',
        [string]$Message = ''
    )

    [ordered]@{
        schema_version = '3.0'
        controller = 'XinZhaoWrt Arthur v3 persistent auto-repair controller'
        status = $Status
        stage = $Stage
        conclusion = $Conclusion
        run_id = $CurrentRunId
        repair_round = $RepairRound
        max_repair_rounds = $MaxRepairRounds
        update_mode = $CurrentUpdateMode
        candidate_tag = $CandidateTag
        branch = $Branch
        repository = $Repository
        message = $Message
        updated_at = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $StateFile -Encoding UTF8
}

function Get-ControllerState {
    if (-not (Test-Path $StateFile)) { return $null }
    try { return (Get-Content -Raw -Path $StateFile | ConvertFrom-Json) }
    catch { return $null }
}

function Invoke-Captured {
    param([string]$FilePath,[string[]]$Arguments,[switch]$AllowFailure)
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $text = (& $FilePath @Arguments 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if (-not $AllowFailure -and $code -ne 0) {
        throw "$FilePath failed with exit code $code`n$text"
    }

    [pscustomobject]@{ ExitCode = $code; Output = $text }
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
        throw "Repository has uncommitted changes. Refusing automatic repair.`n$($dirty.Output)"
    }
}

function Sync-Branch {
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'fetch','--quiet','origin',$Branch) | Out-Null
    $currentBranch = (Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'branch','--show-current')).Output.Trim()
    if ($currentBranch -ne $Branch) {
        throw "Controller requires local branch '$Branch'; current branch is '$currentBranch'."
    }
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'pull','--ff-only','origin',$Branch) | Out-Null
}

function Get-ProtectedHashes {
    $hashes = @{}
    foreach ($relative in $HardFiles) {
        $path = Join-Path $RepoRoot $relative
        if (-not (Test-Path $path)) { throw "Protected file missing: $relative" }
        $hashes[$relative] = (Get-FileHash -Algorithm SHA256 -Path $path).Hash
    }
    return $hashes
}

function Assert-ProtectedFilesUnchanged {
    param([hashtable]$Before)
    foreach ($relative in $HardFiles) {
        $path = Join-Path $RepoRoot $relative
        if (-not (Test-Path $path)) { throw "BLOCKED: protected file deleted: $relative" }
        $after = (Get-FileHash -Algorithm SHA256 -Path $path).Hash
        if ($after -ne $Before[$relative]) {
            throw "BLOCKED: protected file modification attempted: $relative"
        }
    }
}

function Assert-KnownGoodBaseline {
    if (-not (Test-Path $KnownGoodFile)) { throw 'production/known-good.json is missing.' }
    if (-not (Test-Path $KnownGoodLock)) { throw 'config/arthur-known-good.lock is missing.' }
    if (-not (Test-Path $RequiredFile)) { throw 'config/required-plugins.txt is missing.' }

    $known = Get-Content -Raw $KnownGoodFile | ConvertFrom-Json
    if ($known.verified -ne $true -or [string]$known.status -ne 'verified') {
        throw 'BLOCKED: production/known-good.json is not verified.'
    }
    if ([string]$known.device -ne 'jdcloud_re-ss-01') {
        throw 'BLOCKED: Known-Good device is not jdcloud_re-ss-01.'
    }

    $required = @(Get-Content $RequiredFile | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() })
    if ($required.Count -ne 22) {
        throw "BLOCKED: required plugin count is $($required.Count), expected 22."
    }

    $lockRefs = @(Get-Content $KnownGoodLock | Where-Object { $_ -match '^[A-Z0-9_]+_REF="[0-9a-f]{40}"$' })
    if ($lockRefs.Count -ne 14) {
        throw "BLOCKED: Known-Good lock contains $($lockRefs.Count) pinned refs, expected 14."
    }

    return [pscustomobject]@{
        StableTag = [string]$known.stable_tag
        CandidateTag = [string]$known.candidate_tag
        RequiredPlugins = $required
        LockSha256 = (Get-FileHash -Algorithm SHA256 -Path $KnownGoodLock).Hash.ToLowerInvariant()
    }
}

function Invoke-GhWithBackoff {
    param([string[]]$Arguments)
    while ($true) {
        $result = Invoke-Captured -FilePath 'gh' -Arguments $Arguments -AllowFailure
        if ($result.ExitCode -eq 0) { return $result.Output }

        $msg = $result.Output
        if ($msg -match '(?i)rate limit|HTTP 403') {
            Write-ControllerLog 'GitHub API rate limit encountered; retrying in 600 seconds.'
            Start-Sleep 600
            continue
        }
        if ($msg -match '(?i)unexpected EOF|timeout|timed out|connection reset|connection refused|HTTP 5\d\d') {
            Write-ControllerLog "Transient GitHub error; retrying in 120 seconds: $msg"
            Start-Sleep 120
            continue
        }
        throw "gh command failed: $($Arguments -join ' ')`n$msg"
    }
}

function Get-RequestUpdateMode {
    param([string]$Fallback)
    if (Test-Path $RequestFile) {
        try {
            $request = Get-Content -Raw $RequestFile | ConvertFrom-Json
            $modeValue = [string]$request.mode
            if ($modeValue -in @('rebuild_known_good','update_immortalwrt','update_feeds','update_plugins','update_all')) {
                return $modeValue
            }
        }
        catch {
            Write-ControllerLog "Could not parse production/v3-request.json: $($_.Exception.Message)"
        }
    }
    return $Fallback
}

function Start-V3Run {
    param([string]$RequestedMode)

    $head = (Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'rev-parse','HEAD')).Output.Trim()
    $started = [DateTime]::UtcNow

    Invoke-GhWithBackoff -Arguments @(
        'workflow','run',$Workflow,
        '--repo',$Repository,
        '--ref',$Branch,
        '-f',"mode=$RequestedMode"
    ) | Out-Null

    Write-ControllerLog "Triggered $Workflow mode=$RequestedMode at project commit $head."

    while ($true) {
        Start-Sleep 5
        $raw = Invoke-GhWithBackoff -Arguments @(
            'run','list','--repo',$Repository,'--workflow',$Workflow,'--branch',$Branch,
            '--event','workflow_dispatch','--limit','10',
            '--json','databaseId,createdAt,status,headSha,event'
        )
        $runs = @($raw | ConvertFrom-Json)
        $candidate = $runs |
            Where-Object {
                ([DateTime]$_.createdAt).ToUniversalTime() -ge $started.AddSeconds(-3) -and
                [string]$_.headSha -eq $head
            } |
            Sort-Object { [DateTime]$_.createdAt } -Descending |
            Select-Object -First 1

        if ($candidate) {
            Write-ControllerLog "New Arthur v3 Run ID: $($candidate.databaseId)"
            return [long]$candidate.databaseId
        }
    }
}

function Get-LatestV3Run {
    $raw = Invoke-GhWithBackoff -Arguments @(
        'run','list','--repo',$Repository,'--workflow',$Workflow,'--branch',$Branch,
        '--event','workflow_dispatch','--limit','10',
        '--json','databaseId,createdAt,status,conclusion,headSha,event'
    )
    $runs = @($raw | ConvertFrom-Json)
    if (-not $runs) { return $null }

    $active = $runs |
        Where-Object { [string]$_.status -in @('queued','in_progress','waiting','requested','pending') } |
        Sort-Object { [DateTime]$_.createdAt } -Descending |
        Select-Object -First 1
    if ($active) { return $active }

    $cutoff = [DateTime]::UtcNow.AddHours(-12)
    return ($runs |
        Where-Object { ([DateTime]$_.createdAt).ToUniversalTime() -ge $cutoff } |
        Sort-Object { [DateTime]$_.createdAt } -Descending |
        Select-Object -First 1)
}

function Wait-V3Run {
    param([long]$Id,[int]$RepairRound,[string]$RequestedMode)

    while ($true) {
        $raw = Invoke-GhWithBackoff -Arguments @(
            'run','view',[string]$Id,'--repo',$Repository,
            '--json','status,conclusion,url,headSha,createdAt,updatedAt'
        )
        $run = $raw | ConvertFrom-Json
        $status = [string]$run.status
        $conclusion = if ($run.PSObject.Properties.Name -contains 'conclusion') { [string]$run.conclusion } else { '' }

        Set-ControllerState -Status $status -Stage 'github-actions' -Conclusion $conclusion `
            -CurrentRunId $Id -RepairRound $RepairRound -CurrentUpdateMode $RequestedMode `
            -Message "Arthur v3 GitHub Actions $status"
        Write-ControllerLog "Run ${Id}: status=$status conclusion=$conclusion repair_round=$RepairRound"

        if ($status -eq 'completed') { return $run }
        Start-Sleep $PollSeconds
    }
}

function Download-RunEvidence {
    param([long]$Id,[switch]$Failure)

    $runDir = Join-Path $OutputRoot ("run-{0}" -f $Id)
    if (Test-Path $runDir) { Remove-Item -Recurse -Force $runDir }
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null

    if ($Failure) {
        $failed = Invoke-Captured -FilePath 'gh' -Arguments @('run','view',[string]$Id,'--repo',$Repository,'--log-failed') -AllowFailure
        $failed.Output | Set-Content -Path (Join-Path $runDir 'failed-steps.log') -Encoding UTF8
    }

    $download = Invoke-Captured -FilePath 'gh' -Arguments @('run','download',[string]$Id,'--repo',$Repository,'--dir',$runDir) -AllowFailure
    if ($download.ExitCode -ne 0) {
        Write-ControllerLog "Artifact download warning for Run ${Id}: $($download.Output)"
    }

    return $runDir
}

function Get-TailText {
    param([string]$Path,[int]$MaxChars = 24000)
    if (-not (Test-Path $Path)) { return '' }
    $text = Get-Content -Raw -ErrorAction SilentlyContinue $Path
    if (-not $text) { return '' }
    if ($text.Length -gt $MaxChars) { return $text.Substring($text.Length - $MaxChars) }
    return $text
}

function Get-RepairEvidence {
    param([string]$RunDir)

    $names = @(
        'failure-report.txt',
        'error-summary.txt',
        'error-context.txt',
        'failed-steps.log',
        'build-diagnostic.log',
        'build.log',
        'plugin-verification.txt',
        'update-lock.diff',
        'update-metadata.json'
    )

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in $names) {
        $file = Get-ChildItem -Path $RunDir -Recurse -File -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($file) {
            $text = Get-TailText -Path $file.FullName
            if ($text) { $parts.Add("===== $name =====`n$text") }
        }
    }

    $joined = $parts -join "`n`n"
    $joined = $joined -replace '(?i)(authorization:\s*(?:basic|bearer)\s+)[^\s]+','$1[REDACTED]'
    $joined = $joined -replace '(?i)(github_pat_|ghp_)[A-Za-z0-9_]+','[REDACTED_TOKEN]'
    if ($joined.Length -gt 120000) { $joined = $joined.Substring($joined.Length - 120000) }
    return $joined
}

function ConvertFrom-CodexJson {
    param([string]$Text)
    $clean = $Text.Trim()
    $clean = $clean -replace '^```(?:json)?\s*','' -replace '\s*```$',''
    $first = $clean.IndexOf('{')
    $last = $clean.LastIndexOf('}')
    if ($first -lt 0 -or $last -le $first) {
        throw 'BLOCKED: Codex did not return valid JSON.'
    }
    return ($clean.Substring($first,$last-$first+1) | ConvertFrom-Json)
}

function Invoke-CodexRepair {
    param([long]$Id,[string]$RunDir,[int]$Round,[string]$RequestedMode)

    $evidence = Get-RepairEvidence -RunDir $RunDir
    if (-not $evidence) {
        throw 'BLOCKED: diagnostics contain no usable repair evidence.'
    }

    $resultPath = Join-Path $RunDir ("codex-repair-round-{0}.json" -f $Round)
    $promptPath = "$resultPath.prompt.txt"
    $execLog = "$resultPath.exec.log"

    $prompt = @"
You are repairing the XinZhaoWrt Arthur OpenWrt automatic compilation v3 pipeline.

Repository: $Repository
Failed GitHub Actions Run: $Id
Update mode: $RequestedMode
Repair round: $Round of $MaxRepairRounds
Target: qualcommax/ipq60xx/jdcloud_re-ss-01
Mandatory LuCI plugins: exactly 22; every one must remain enabled, compile successfully, and appear in the final firmware manifest.

Read and obey AGENTS.md and docs/OPENWRT_CI_V3.md before editing.
Inspect the failure evidence below and the current repository. Identify the FIRST concrete root cause.

You may modify ONLY these path families when a code repair is justified:
- scripts/
- .github/workflows/
- patches/
- files/
- package/

You MUST NOT modify:
- config/required-plugins.txt
- config/arthur.config
- config/arthur-known-good.lock
- production/known-good.json
- production/status.json
- VERSION
- build.env

You MUST NOT:
- remove, disable, rename, or bypass any of the 22 mandatory plugins;
- change the device target;
- weaken acceptance gates;
- promote Stable or alter Known-Good;
- run sysupgrade, mtd, dd, U-Boot, eMMC/partition writes, or access the router;
- git commit, git push, create Releases, or trigger GitHub Actions.

Work directly in the current workspace if and only if a minimal deterministic repair is supported by evidence.
If the failure is clearly transient infrastructure/network and no source change is justified, make NO file changes and choose decision=retry.
If the evidence is insufficient, the required fix needs a protected file/product decision, or safe automatic repair is not possible, make NO file changes and choose decision=blocked.

After any edit, inspect git diff and keep the change minimal.
Return JSON only in this exact shape:
{
  "decision": "repaired|retry|blocked",
  "first_error": "first concrete failure",
  "summary": "short explanation",
  "changed_files": ["path1", "path2"]
}

Failure evidence:
$evidence
"@

    [System.IO.File]::WriteAllText($promptPath,$prompt,(New-Object System.Text.UTF8Encoding($false)))
    $exe = Get-CodexExecutable

    $job = Start-Job -ScriptBlock {
        param($Exe,$PromptFile,$OutFile,$LogFile,$WorkingDirectory)
        $ErrorActionPreference = 'Continue'
        Set-Location $WorkingDirectory
        $inputText = Get-Content -Raw $PromptFile
        $output = ($inputText | & $Exe exec --sandbox workspace-write -c 'approval_policy="never"' -o $OutFile - 2>&1 | Out-String)
        $output | Set-Content -Path $LogFile -Encoding UTF8
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } -ArgumentList $exe,$promptPath,$resultPath,$execLog,$RepoRoot

    $done = Wait-Job $job -Timeout $CodexTimeoutSeconds
    if (-not $done) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        throw "BLOCKED: Codex repair timed out after $CodexTimeoutSeconds seconds."
    }

    $jobResult = Receive-Job $job
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    if ($jobResult.ExitCode -ne 0) {
        throw "BLOCKED: Codex repair failed with exit code $($jobResult.ExitCode)."
    }
    if (-not (Test-Path $resultPath)) {
        throw 'BLOCKED: Codex produced no repair decision.'
    }

    return (ConvertFrom-CodexJson -Text (Get-Content -Raw $resultPath))
}

function Get-ChangedPaths {
    $raw = (Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'status','--porcelain')).Output
    if (-not $raw) { return @() }

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line -or $line.Length -lt 4) { continue }
        $path = $line.Substring(3).Trim()
        if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
        $path = $path.Trim('"') -replace '\\','/'
        if ($path) { $paths.Add($path) }
    }
    return @($paths | Sort-Object -Unique)
}

function Test-AllowedRepairPath {
    param([string]$Path)
    $normalized = ($Path -replace '\\','/').TrimStart('./')
    if (-not $normalized -or $normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:' -or $normalized -match '(^|/)\.\.(/|$)') {
        return $false
    }
    if ($HardFiles -contains $normalized) { return $false }
    foreach ($prefix in $AllowedRepairPrefixes) {
        if ($normalized.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Reset-RepairChanges {
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'reset','--hard','HEAD') -AllowFailure | Out-Null
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'clean','-fd','-e','output/','-e','state/') -AllowFailure | Out-Null
}

function Assert-PowerShellSyntax {
    param([string[]]$ChangedPaths)
    foreach ($relative in $ChangedPaths) {
        if (-not $relative.EndsWith('.ps1',[System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $full = Join-Path $RepoRoot $relative
        if (-not (Test-Path $full)) { continue }
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($full,[ref]$tokens,[ref]$errors) | Out-Null
        if ($errors -and $errors.Count -gt 0) {
            $messages = ($errors | ForEach-Object { $_.Message }) -join '; '
            throw "BLOCKED: PowerShell parser errors in ${relative}: $messages"
        }
    }
}

function Assert-RepairSafe {
    param([hashtable]$ProtectedBefore,[object]$BaselineBefore)

    Assert-ProtectedFilesUnchanged -Before $ProtectedBefore

    $changed = @(Get-ChangedPaths)
    if ($changed.Count -eq 0) {
        throw 'BLOCKED: Codex reported a repair but produced no file changes.'
    }

    foreach ($path in $changed) {
        if (-not (Test-AllowedRepairPath -Path $path)) {
            throw "BLOCKED: automatic repair changed a disallowed path: $path"
        }
    }

    $required = @(Get-Content $RequiredFile | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() })
    if ($required.Count -ne 22) { throw 'BLOCKED: mandatory plugin count changed.' }

    $configText = Get-Content -Raw (Join-Path $RepoRoot 'config\arthur.config')
    foreach ($plugin in $required) {
        if ($configText -notmatch "(?m)^CONFIG_PACKAGE_$([regex]::Escape($plugin))=y$") {
            throw "BLOCKED: mandatory plugin is no longer enabled in config/arthur.config: $plugin"
        }
    }

    $known = Get-Content -Raw $KnownGoodFile | ConvertFrom-Json
    if ($known.verified -ne $true -or [string]$known.status -ne 'verified' -or [string]$known.stable_tag -ne $BaselineBefore.StableTag) {
        throw 'BLOCKED: verified Known-Good baseline changed during repair.'
    }

    $lockHash = (Get-FileHash -Algorithm SHA256 -Path $KnownGoodLock).Hash.ToLowerInvariant()
    if ($lockHash -ne $BaselineBefore.LockSha256) {
        throw 'BLOCKED: official Known-Good lock changed during repair.'
    }

    $diffCheck = Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'diff','--check') -AllowFailure
    if ($diffCheck.ExitCode -ne 0) {
        throw "BLOCKED: git diff --check failed.`n$($diffCheck.Output)"
    }

    Assert-PowerShellSyntax -ChangedPaths $changed
    return $changed
}

function Commit-And-PushRepair {
    param([string[]]$ChangedPaths,[int]$Round,[long]$FailedRunId)

    foreach ($path in $ChangedPaths) {
        Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'add','--',$path) | Out-Null
    }

    $cached = (Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'diff','--cached','--name-only')).Output
    if (-not $cached) { throw 'BLOCKED: no safe repair changes were staged.' }

    $message = "fix: auto-repair Arthur v3 build round $Round"
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'commit','-m',$message) | Out-Null
    Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'push','origin',"HEAD:$Branch") | Out-Null

    $sha = (Invoke-Captured -FilePath 'git' -Arguments @('-C',$RepoRoot,'rev-parse','HEAD')).Output.Trim()
    Write-ControllerLog "Committed and pushed automatic repair for failed Run ${FailedRunId}: $sha"
    return $sha
}

function Test-Sha256File {
    param([string]$ChecksumPath,[string]$SearchRoot)

    $verified = 0
    foreach ($line in Get-Content $ChecksumPath) {
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') { continue }
        $expected = $Matches[1].ToLowerInvariant()
        $name = $Matches[2].Trim()
        $file = Get-ChildItem -Path $SearchRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq [System.IO.Path]::GetFileName($name) } |
            Select-Object -First 1
        if (-not $file) { continue }
        $actual = (Get-FileHash -Algorithm SHA256 -Path $file.FullName).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "SHA256 mismatch for $($file.Name): expected $expected, got $actual"
        }
        $verified++
    }
    if ($verified -lt 1) { throw 'No checksum entries could be verified locally.' }
}

function Verify-SuccessfulCandidate {
    param([long]$Id,[string]$RunDir,[string]$RequestedMode,[object]$Baseline)

    $firmware = Get-ChildItem -Path $RunDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Arthur.*sysupgrade\.bin$' -and $_.Length -gt 0 } |
        Select-Object -First 1
    if (-not $firmware) { throw "Run $Id completed successfully but no non-empty Arthur sysupgrade firmware was downloaded." }

    $pluginReport = Get-ChildItem -Path $RunDir -Recurse -File -Filter 'plugin-verification.txt' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pluginReport) { throw "Run $Id completed successfully but plugin-verification.txt is missing." }
    $pluginText = Get-Content -Raw $pluginReport.FullName
    if ($pluginText -notmatch 'PASS: all required LuCI plugins were compiled and are present in the final firmware manifest') {
        throw "Run $Id is missing the final 22-plugin PASS marker."
    }
    foreach ($plugin in $Baseline.RequiredPlugins) {
        $pattern = "(?m)^PASS:\s+$([regex]::Escape($plugin))\s+\|"
        if ($pluginText -notmatch $pattern) {
            throw "Run $Id plugin verification is missing PASS for $plugin."
        }
    }

    $checksum = Get-ChildItem -Path $RunDir -Recurse -File -Filter 'SHA256SUMS.local' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $checksum) { throw "Run $Id is missing SHA256SUMS.local." }
    Test-Sha256File -ChecksumPath $checksum.FullName -SearchRoot $RunDir

    $candidateLock = Get-ChildItem -Path $RunDir -Recurse -File -Filter 'arthur-known-good.lock' -ErrorAction SilentlyContinue | Select-Object -First 1
    $metadataFile = Get-ChildItem -Path $RunDir -Recurse -File -Filter 'update-metadata.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $candidateLock -or -not $metadataFile) { throw "Run $Id is missing Candidate lock or update metadata." }

    $metadata = Get-Content -Raw $metadataFile.FullName | ConvertFrom-Json
    $lockHash = (Get-FileHash -Algorithm SHA256 -Path $candidateLock.FullName).Hash.ToLowerInvariant()
    if ([string]$metadata.candidate_lock_sha256 -ne $lockHash) {
        throw "Run $Id Candidate lock hash does not match update-metadata.json."
    }
    if ([string]$metadata.mode -ne $RequestedMode) {
        throw "Run $Id update mode mismatch: metadata=$($metadata.mode), controller=$RequestedMode"
    }
    if ($RequestedMode -eq 'rebuild_known_good' -and $lockHash -ne $Baseline.LockSha256) {
        throw 'rebuild_known_good moved the official Known-Good source lock unexpectedly.'
    }

    $tag = "arthur-update-$Id"
    $releaseRaw = Invoke-Captured -FilePath 'gh' -Arguments @('release','view',$tag,'--repo',$Repository,'--json','tagName,isPrerelease,url,targetCommitish') -AllowFailure
    if ($releaseRaw.ExitCode -ne 0) { throw "Run $Id succeeded but Candidate Release $tag is missing." }
    $release = $releaseRaw.Output | ConvertFrom-Json
    if ($release.isPrerelease -ne $true) { throw "Candidate Release $tag is not marked prerelease." }

    $firmwareSha = (Get-FileHash -Algorithm SHA256 -Path $firmware.FullName).Hash.ToLowerInvariant()
    [ordered]@{
        run_id = $Id
        candidate_tag = $tag
        update_mode = $RequestedMode
        firmware = $firmware.Name
        firmware_sha256 = $firmwareSha
        candidate_lock_sha256 = $lockHash
        plugin_count = 22
        plugin_verification = 'PASS'
        release_url = [string]$release.url
        verified_at = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $runDir 'candidate-verification.json') -Encoding UTF8

    Write-ControllerLog "Run $Id Candidate verification PASS. Release: $tag"
    return $tag
}

function Process-V3Run {
    param([long]$InitialRunId,[string]$RequestedMode,[int]$InitialRepairRound = 0)

    $currentRunId = $InitialRunId
    $round = $InitialRepairRound

    while ($true) {
        $baseline = Assert-KnownGoodBaseline
        $run = Wait-V3Run -Id $currentRunId -RepairRound $round -RequestedMode $RequestedMode
        $conclusion = [string]$run.conclusion

        if ($conclusion -eq 'success') {
            Set-ControllerState -Status 'verifying' -Stage 'candidate-verification' -Conclusion 'success' `
                -CurrentRunId $currentRunId -RepairRound $round -CurrentUpdateMode $RequestedMode `
                -Message 'GitHub build succeeded; verifying firmware, 22/22 plugins, SHA256, Candidate lock and Release.'

            $runDir = Download-RunEvidence -Id $currentRunId
            $tag = Verify-SuccessfulCandidate -Id $currentRunId -RunDir $runDir -RequestedMode $RequestedMode -Baseline $baseline

            Set-ControllerState -Status 'success' -Stage 'candidate_published' -Conclusion 'success' `
                -CurrentRunId $currentRunId -RepairRound $round -CurrentUpdateMode $RequestedMode -CandidateTag $tag `
                -Message 'v3 Candidate build verified. Next automatic gate is AUTO_FLASH_SAFETY_GATE, followed by standard sysupgrade and real-device verification.'
            return
        }

        if ($conclusion -in @('cancelled','skipped','stale')) {
            Set-ControllerState -Status 'blocked' -Stage 'github-actions' -Conclusion $conclusion `
                -CurrentRunId $currentRunId -RepairRound $round -CurrentUpdateMode $RequestedMode `
                -Message "Run ended with conclusion=$conclusion; automatic source repair is not appropriate."
            return
        }

        if ($round -ge $MaxRepairRounds) {
            Set-ControllerState -Status 'blocked' -Stage 'repair-limit' -Conclusion $conclusion `
                -CurrentRunId $currentRunId -RepairRound $round -CurrentUpdateMode $RequestedMode `
                -Message "Automatic repair limit reached ($MaxRepairRounds rounds)."
            return
        }

        $runDir = Download-RunEvidence -Id $currentRunId -Failure
        $round++

        Set-ControllerState -Status 'repairing' -Stage 'codex-auto-repair' -Conclusion $conclusion `
            -CurrentRunId $currentRunId -RepairRound $round -CurrentUpdateMode $RequestedMode `
            -Message "Build failed; Codex is diagnosing and attempting safe repair round $round/$MaxRepairRounds."

        Sync-Branch
        Assert-CleanRepository
        $baselineBefore = Assert-KnownGoodBaseline
        $protectedBefore = Get-ProtectedHashes

        try {
            $decision = Invoke-CodexRepair -Id $currentRunId -RunDir $runDir -Round $round -RequestedMode $RequestedMode
            $action = [string]$decision.decision
            Write-ControllerLog "Codex decision for Run ${currentRunId}: $action | $($decision.first_error) | $($decision.summary)"

            if ($action -eq 'blocked') {
                Reset-RepairChanges
                Set-ControllerState -Status 'blocked' -Stage 'codex-auto-repair' -Conclusion $conclusion `
                    -CurrentRunId $currentRunId -RepairRound $round -CurrentUpdateMode $RequestedMode `
                    -Message "Codex blocked automatic repair: $($decision.first_error) - $($decision.summary)"
                return
            }

            if ($action -eq 'retry') {
                $changes = @(Get-ChangedPaths)
                if ($changes.Count -gt 0) {
                    Reset-RepairChanges
                    throw 'BLOCKED: Codex chose retry but modified repository files.'
                }
                Assert-ProtectedFilesUnchanged -Before $protectedBefore
                Write-ControllerLog 'Failure classified as transient; re-running the same v3 mode without source changes.'
            }
            elseif ($action -eq 'repaired') {
                $changed = @(Assert-RepairSafe -ProtectedBefore $protectedBefore -BaselineBefore $baselineBefore)
                Commit-And-PushRepair -ChangedPaths $changed -Round $round -FailedRunId $currentRunId | Out-Null
                Sync-Branch
            }
            else {
                Reset-RepairChanges
                throw "BLOCKED: unsupported Codex decision: $action"
            }
        }
        catch {
            Reset-RepairChanges
            Set-ControllerState -Status 'blocked' -Stage 'codex-auto-repair' -Conclusion $conclusion `
                -CurrentRunId $currentRunId -RepairRound $round -CurrentUpdateMode $RequestedMode `
                -Message $_.Exception.Message
            Write-ControllerLog $_.Exception.Message
            return
        }

        Set-ControllerState -Status 'retrying' -Stage 'trigger-next-run' -Conclusion '' `
            -CurrentRunId $currentRunId -RepairRound $round -CurrentUpdateMode $RequestedMode `
            -Message 'Safe repair/retry decision accepted; triggering next Arthur v3 build.'

        $currentRunId = Start-V3Run -RequestedMode $RequestedMode
    }
}

try {
    Write-ControllerLog "Starting Arthur v3 controller. Mode=$Mode UpdateMode=$UpdateMode MaxRepairRounds=$MaxRepairRounds"
    Assert-Tools
    Sync-Branch
    Assert-CleanRepository
    Assert-KnownGoodBaseline | Out-Null

    if ($Mode -eq 'Rebuild') {
        $UpdateMode = 'rebuild_known_good'
        $newRun = Start-V3Run -RequestedMode $UpdateMode
        Process-V3Run -InitialRunId $newRun -RequestedMode $UpdateMode
        exit 0
    }

    if ($Mode -eq 'Update') {
        if ($UpdateMode -eq 'rebuild_known_good') {
            throw 'Update mode requires update_immortalwrt, update_feeds, update_plugins, or update_all. Use -Mode Rebuild for rebuild_known_good.'
        }
        $newRun = Start-V3Run -RequestedMode $UpdateMode
        Process-V3Run -InitialRunId $newRun -RequestedMode $UpdateMode
        exit 0
    }

    if ($Mode -eq 'Resume') {
        if ($RunId -le 0) { throw 'Resume mode requires -RunId.' }
        $resumeMode = Get-RequestUpdateMode -Fallback $UpdateMode
        Process-V3Run -InitialRunId $RunId -RequestedMode $resumeMode
        exit 0
    }

    Set-ControllerState -Status 'watching' -Stage 'watch' -CurrentUpdateMode (Get-RequestUpdateMode -Fallback $UpdateMode) `
        -Message 'Persistent v3 watcher is active and will attach to new Arthur v3 workflow runs.'

    while ($true) {
        Sync-Branch
        $latest = Get-LatestV3Run
        if (-not $latest) {
            Start-Sleep $PollSeconds
            continue
        }

        $latestId = [long]$latest.databaseId
        $state = Get-ControllerState
        if ($state -and [long]$state.run_id -eq $latestId -and [string]$state.status -in @('success','blocked')) {
            Start-Sleep $PollSeconds
            continue
        }

        $watchMode = Get-RequestUpdateMode -Fallback $UpdateMode
        Write-ControllerLog "Watcher attaching to Arthur v3 Run $latestId with mode=$watchMode."
        Process-V3Run -InitialRunId $latestId -RequestedMode $watchMode
        Start-Sleep $PollSeconds
    }
}
catch {
    $message = $_.Exception.Message
    Write-ControllerLog "CONTROLLER BLOCKED: $message"
    Set-ControllerState -Status 'blocked' -Stage 'controller' -Conclusion 'failure' -CurrentRunId $RunId `
        -RepairRound 0 -CurrentUpdateMode $UpdateMode -Message $message
    exit 1
}
