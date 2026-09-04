param(
    [ValidateSet('AcceptPreview','Resume','RunOnce','Status')][string]$Mode='Resume',
    [string]$FeatureId='',
    [string]$AcceptedPreviewSourceSha='',
    [string]$PreviewManifestPath='',
    [string]$PreviewEvidencePath='',
    [switch]$PauseAfterLivePreview,
    [string]$RuntimeRoot='',
    [string]$Repository='mxonline/xinzhaowrt'
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'feature-handoff-lib.ps1')

# Scheduled/Detached Task Scheduler launches do not inherit the interactive
# Codex shell's temporary Git safety configuration. Keep this worktree
# explicitly trusted for this process only; never mutate the user's global
# Git config as part of production recovery.
$env:GIT_CONFIG_COUNT='1'
$env:GIT_CONFIG_KEY_0='safe.directory'
$env:GIT_CONFIG_VALUE_0=$Root

if (-not $RuntimeRoot) { $RuntimeRoot=Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\FeatureHandoff' }
New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
$StatePath=Join-Path $RuntimeRoot 'handoff.json'
$LogPath=Join-Path $RuntimeRoot 'handoff.log'
$LockPath=Join-Path $RuntimeRoot 'handoff.lock'
$ProductionStatePath=Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\ProductionAgent\output\production-agent\state.json'
$ControllerTask='XinZhaoWrt-Arthur-v3-Controller'
$ControllerLauncher=Join-Path $Root 'scripts\start-ci-controller-v3.ps1'
$V3RequestRelative='production\v3-request.json'
$V3RequestGit='production/v3-request.json'
$V3AutoWorkflow='arthur-update-v3-auto.yml'
$V3Workflow='arthur-update-v3.yml'

function Log([string]$Message) {
    $line='{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Message
    Add-Content -LiteralPath $LogPath -Value $line
    Write-Host $line
}

function Invoke-Native([string]$File,[string[]]$Arguments,[switch]$AllowFailure) {
    $old=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $raw=@(& $File @Arguments 2>&1)
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$old }
    $text=($raw | ForEach-Object { [string]$_ }) -join "`n"
    if (-not $AllowFailure -and $code -ne 0) { throw "$File failed ($code): $text" }
    return [pscustomobject]@{ ExitCode=$code; Output=$text.Trim() }
}

function Test-Recoverable([string]$Message) {
    return $Message -match '(?i)timeout|timed out|connection|HTTP 5\d\d|HTTP 409|conflict|rate limit|temporar|EOF|queued|runner|network|could not resolve|TLS|try again|AUTO_TRIGGER_WAIT|CONTROLLER_RESUME_START|dubious ownership|safe\.directory'
}

function Ensure-StateField($State,[string]$Name,$Value) {
    if ($State.PSObject.Properties.Name -notcontains $Name) { Add-Member -InputObject $State -NotePropertyName $Name -NotePropertyValue $Value }
}

function Ensure-RequestStateFields($State) {
    Ensure-StateField $State 'request_id' ''
    Ensure-StateField $State 'source_ref' ''
    Ensure-StateField $State 'request_commit_sha' ''
    Ensure-StateField $State 'auto_trigger_run_id' 0
}

function Get-ResolvedManifestPath([string]$Path) {
    if (-not $Path) { return '' }
    if ([System.IO.Path]::IsPathRooted($Path)) { return (Resolve-Path -LiteralPath $Path).Path }
    return (Resolve-Path -LiteralPath (Join-Path $Root $Path)).Path
}

function Read-PreviewEvidence([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "FEATURE_HANDOFF_PREVIEW_EVIDENCE_MISSING=$Path" }
    try { $e=Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 20 }
    catch { throw "FEATURE_HANDOFF_PREVIEW_EVIDENCE_INVALID: $($_.Exception.Message)" }
    if ([string]$e.LIVE_PREVIEW -ne 'PASS') { throw 'FEATURE_HANDOFF_PREVIEW_NOT_ACCEPTED' }
    if ([string]$e.WIFI -ne 'VERIFIED_FROZEN') { throw 'FEATURE_HANDOFF_WIFI_NOT_FROZEN' }
    if ([string]$e.REAL_DEVICE_VERIFY -ne 'NOT_RUN') { throw 'FEATURE_HANDOFF_PREVIEW_FORMAL_VERIFY_STATE_INVALID' }
    if ($e.RELEASE_ALLOWED -ne $false) { throw 'FEATURE_HANDOFF_PREVIEW_RELEASE_STATE_INVALID' }
    return $e
}

function Get-AcceptanceIdentity {
    if (-not $FeatureId -or -not $AcceptedPreviewSourceSha -or -not $PreviewManifestPath -or -not $PreviewEvidencePath) { throw 'FEATURE_HANDOFF_ACCEPT_PREVIEW_ARGUMENTS_REQUIRED' }
    if ($AcceptedPreviewSourceSha -notmatch '^[0-9a-fA-F]{40}$') { throw 'FEATURE_HANDOFF_INVALID_ACCEPTED_SHA' }
    $evidence=Read-PreviewEvidence $PreviewEvidencePath
    $resolvedManifest=Get-ResolvedManifestPath $PreviewManifestPath
    $identity=Get-PreviewManifestIdentity -RepoRoot $Root -ManifestPath $resolvedManifest
    $diffSha=Get-WorktreeDiffSha256 -RepoRoot $Root
    return [pscustomobject]@{ evidence=$evidence; manifest_path=$resolvedManifest; manifest_sha256=$identity.manifest_sha256; diff_sha256=$diffSha; source_sha=$AcceptedPreviewSourceSha.ToLowerInvariant() }
}

function Accept-PreviewState {
    if ($PauseAfterLivePreview) { Write-Host 'FEATURE_HANDOFF=PAUSED_BY_USER'; return $null }
    $accept=Get-AcceptanceIdentity
    $existing=Load-FeatureHandoffState -StatePath $StatePath
    if ($existing -and [string]$existing.current_stage -ne 'PRODUCTION_RELEASED') {
        Assert-HandoffResumeIdentity -State $existing -FeatureId $FeatureId -AcceptedPreviewSourceSha $accept.source_sha -AcceptedDiffSha256 $accept.diff_sha256 -PreviewManifestSha256 $accept.manifest_sha256 | Out-Null
        Write-Host "FEATURE_HANDOFF_ACCEPTED=EXISTING dispatch_key=$($existing.dispatch_key)"
        return $existing
    }
    if ($existing -and [string]$existing.current_stage -eq 'PRODUCTION_RELEASED') {
        $sameKey=(Get-FeatureHandoffKey -FeatureId $FeatureId -AcceptedPreviewSourceSha $accept.source_sha) -eq [string]$existing.dispatch_key
        if ($sameKey -and [string]$existing.accepted_diff_sha256 -eq $accept.diff_sha256 -and [string]$existing.preview_manifest_sha256 -eq $accept.manifest_sha256) {
            Write-Host "FEATURE_HANDOFF_ACCEPTED=ALREADY_RELEASED dispatch_key=$($existing.dispatch_key)"
            return $existing
        }
        $archive=Join-Path $RuntimeRoot ("handoff.released.$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')).json")
        Copy-Item -LiteralPath $StatePath -Destination $archive -Force
    }
    $state=New-FeatureHandoffState -FeatureId $FeatureId -AcceptedPreviewSourceSha $accept.source_sha -AcceptedDiffSha256 $accept.diff_sha256 -PreviewManifestSha256 $accept.manifest_sha256 -PreviewManifestPath $accept.manifest_path -PreviewEvidence $accept.evidence
    Ensure-RequestStateFields $state
    Save-FeatureHandoffState -State $state -StatePath $StatePath
    Log "PREVIEW_ACCEPTED feature=$FeatureId source=$($accept.source_sha) diff=$($accept.diff_sha256)"
    Write-Host "FEATURE_HANDOFF_ACCEPTED=PASS dispatch_key=$($state.dispatch_key)"
    return $state
}

function Load-OrAcceptState {
    $state=Load-FeatureHandoffState -StatePath $StatePath
    if ($state) {
        Ensure-RequestStateFields $state
        if ($FeatureId -and [string]$state.current_stage -ne 'PRODUCTION_RELEASED') {
            $accept=Get-AcceptanceIdentity
            Assert-HandoffResumeIdentity -State $state -FeatureId $FeatureId -AcceptedPreviewSourceSha $accept.source_sha -AcceptedDiffSha256 $accept.diff_sha256 -PreviewManifestSha256 $accept.manifest_sha256 | Out-Null
        }
        return $state
    }
    if ($FeatureId) { return Accept-PreviewState }
    return $null
}

function Capture-LocalChanges($State) {
    $paths=@(Get-FeatureChangedPaths -RepoRoot $Root)
    Assert-FeatureChangedPathsSafe -ChangedPaths $paths | Out-Null
    $currentDiff=Get-WorktreeDiffSha256 -RepoRoot $Root
    if ($currentDiff -ne [string]$State.accepted_diff_sha256) { throw "FEATURE_HANDOFF_SOURCE_IDENTITY_CHANGED accepted=$($State.accepted_diff_sha256) current=$currentDiff" }
    $State.changed_paths=@($paths)
    Set-FeatureHandoffStage -State $State -Stage 'LOCAL_CHANGES_CAPTURED' -Status 'VERIFIED' | Out-Null
    Save-FeatureHandoffState -State $State -StatePath $StatePath
    Log "LOCAL_CHANGES_CAPTURED count=$($paths.Count)"
}

function Run-StaticChecks($State) {
    $commands=@(
        @('bash',@((Join-Path $Root 'tests/test-live-preview-contract.sh'))),
        @('bash',@((Join-Path $Root 'tests/test-classify-build-scope.sh'))),
        @('bash',@((Join-Path $Root 'scripts/verify-project.sh'))),
        @('pwsh',@('-NoProfile','-File',(Join-Path $Root 'tests/feature-handoff.tests.ps1'))),
        @('pwsh',@('-NoProfile','-File',(Join-Path $Root 'tests/feature-handoff-auto-trigger.tests.ps1')))
    )
    foreach ($entry in $commands) {
        $result=Invoke-Native -File $entry[0] -Args $entry[1] -AllowFailure
        if ($result.ExitCode -ne 0) { throw "FEATURE_HANDOFF_STATIC_CHECK_FAILED command=$($entry[0]) output=$($result.Output)" }
    }
    Set-FeatureHandoffStage -State $State -Stage 'STATIC_VERIFIED' -Status 'VERIFIED' | Out-Null
    Save-FeatureHandoffState -State $State -StatePath $StatePath
    Log 'STATIC_VERIFIED=PASS'
}

function Freeze-AcceptedSource($State) {
    $frozen=@(Freeze-PreviewManifestToOverlay -RepoRoot $Root -ManifestPath ([string]$State.preview_manifest_path))
    $deferred=New-Object System.Collections.Generic.List[string]
    foreach ($name in @('ADGUARD_NETWORK_MUTATION_TEST','ADGUARD_WEB_RUNTIME_TEST')) {
        if ($State.preview_evidence.PSObject.Properties.Name -contains $name) {
            $value=[string]$State.preview_evidence.$name
            if ($value -like 'DEFERRED*') { $deferred.Add("$name=$value") }
        }
    }
    $record=Write-AcceptedPreviewRecord -RepoRoot $Root -State $State -FrozenFiles $frozen -DeferredAcceptance @($deferred)
    $State.frozen_files=@($frozen)
    $recordRel=(Resolve-Path -LiteralPath $record).Path.Substring((Resolve-Path $Root).Path.Length).TrimStart('\','/') -replace '\\','/'
    $paths=New-Object System.Collections.Generic.List[string]
    foreach ($p in @($State.changed_paths)) { if ($p) { $paths.Add([string]$p) } }
    foreach ($f in $frozen) { if (-not $paths.Contains([string]$f.overlay)) { $paths.Add([string]$f.overlay) } }
    if (-not $paths.Contains($recordRel)) { $paths.Add($recordRel) }
    Assert-FeatureChangedPathsSafe -ChangedPaths @($paths) | Out-Null
    $State.changed_paths=@($paths | Sort-Object -Unique)
    Set-FeatureHandoffStage -State $State -Stage 'SOURCE_FROZEN' -Status 'VERIFIED' | Out-Null
    Save-FeatureHandoffState -State $State -StatePath $StatePath
    Log "SOURCE_FROZEN files=$($frozen.Count) record=$recordRel"
}

function Get-CurrentBranch { return (Invoke-Native git @('-C',$Root,'branch','--show-current')).Output.Trim() }

function Ensure-FeatureBranch($State) {
    $branch=Get-CurrentBranch
    if (-not $branch) { throw 'FEATURE_HANDOFF_DETACHED_HEAD_UNSUPPORTED' }
    if ($branch -eq 'main') {
        $short=([string]$State.accepted_preview_source_sha).Substring(0,8)
        $branch="feature/handoff-$($State.feature_id)-$short"
        $r=Invoke-Native git @('-C',$Root,'switch','-c',$branch) -AllowFailure
        if ($r.ExitCode -ne 0) {
            $exists=Invoke-Native git @('-C',$Root,'show-ref','--verify',"refs/heads/$branch") -AllowFailure
            if ($exists.ExitCode -eq 0) { Invoke-Native git @('-C',$Root,'switch',$branch) | Out-Null }
            else { throw "FEATURE_HANDOFF_BRANCH_CREATE_FAILED: $($r.Output)" }
        }
    }
    $State.branch=$branch
    return $branch
}

function Stage-And-Commit($State) {
    $branch=Ensure-FeatureBranch $State
    Invoke-Native git @('-C',$Root,'fetch','origin','main') | Out-Null
    $ancestor=Invoke-Native git @('-C',$Root,'merge-base','--is-ancestor','origin/main','HEAD') -AllowFailure
    if ($ancestor.ExitCode -ne 0) {
        $merge=Invoke-Native git @('-C',$Root,'merge','--no-edit','origin/main') -AllowFailure
        if ($merge.ExitCode -ne 0) { throw "FEATURE_HANDOFF_SOURCE_RECONCILIATION_BLOCKED: merge conflict preserved for inspection. $($merge.Output)" }
    }
    foreach ($path in @($State.changed_paths)) { Invoke-Native git @('-C',$Root,'add','--',[string]$path) | Out-Null }
    $staged=Invoke-Native git @('-C',$Root,'diff','--cached','--name-only')
    if ($staged.Output) { Invoke-Native git @('-C',$Root,'commit','-m',"feat: freeze accepted $($State.feature_id) live preview") | Out-Null }
    $State.feature_commit_sha=(Invoke-Native git @('-C',$Root,'rev-parse','HEAD')).Output.Trim()
    Invoke-Native git @('-C',$Root,'push','-u','origin',$branch) | Out-Null
    Save-FeatureHandoffState -State $State -StatePath $StatePath
    Log "FEATURE_BRANCH_PUSHED branch=$branch sha=$($State.feature_commit_sha)"
}

function Get-OrCreatePr($State) {
    $list=Invoke-Native gh @('pr','list','--repo',$Repository,'--head',[string]$State.branch,'--base','main','--state','all','--limit','20','--json','number,headRefOid,state,mergedAt')
    $prs=@(); if ($list.Output) { $prs=@($list.Output | ConvertFrom-Json) }
    $match=$prs | Where-Object { [string]$_.headRefOid -eq [string]$State.feature_commit_sha } | Sort-Object { [int]$_.number } -Descending | Select-Object -First 1
    if ($match) { return [int]$match.number }
    $create=Invoke-Native gh @('pr','create','--repo',$Repository,'--base','main','--head',[string]$State.branch,'--title',"Arthur: freeze accepted $($State.feature_id) preview",'--body',"Automated Feature Handoff for accepted LIVE_PREVIEW. WIFI=VERIFIED_FROZEN. Production continues through durable v3 request, existing v3 Controller and Production Agent.")
    $m=[regex]::Match($create.Output,'/pull/(\d+)')
    if (-not $m.Success) { throw "FEATURE_HANDOFF_PR_CREATE_UNRESOLVED output=$($create.Output)" }
    return [int]$m.Groups[1].Value
}

function Invoke-PrRepair($State,[int]$PrNumber,[string]$FailureText) {
    $codex=Get-Command codex.cmd -ErrorAction SilentlyContinue
    if (-not $codex) { $codex=Get-Command codex -ErrorAction SilentlyContinue }
    if (-not $codex) { throw "FEATURE_HANDOFF_PR_CHECK_FAILED_NO_CODEX: $FailureText" }
    $prompt=@"
Repair PR #$PrNumber for mxonline/xinzhaowrt after Feature Handoff static/CI failure.
Read AGENTS.md, knowledge/V013-DEVELOPMENT-LOOP.md, and the handoff spec/plan.
Keep WIFI=VERIFIED_FROZEN. Do not modify protected baseline files, force push, reset/clean away work, weaken tests/gates, flash the router, or touch raw storage.
Diagnose the first concrete error below, make the smallest repair in the current branch, run the relevant tests, and stop without git commit/push.
Failure evidence:
$FailureText
"@
    $resultPath=Join-Path $RuntimeRoot 'codex-pr-repair.txt'
    $input=Join-Path $RuntimeRoot 'codex-pr-repair.prompt.txt'
    Set-Content -LiteralPath $input -Value $prompt -Encoding UTF8
    $old=$ErrorActionPreference
    try { $ErrorActionPreference='Continue'; $raw=@(Get-Content -Raw $input | & $codex.Source exec --sandbox workspace-write -c 'approval_policy="never"' -o $resultPath - 2>&1); $code=$LASTEXITCODE }
    finally { $ErrorActionPreference=$old }
    if ($code -ne 0) { throw "FEATURE_HANDOFF_CODEX_REPAIR_FAILED: $($raw -join ' ')" }
    $paths=@(Get-FeatureChangedPaths -RepoRoot $Root)
    Assert-FeatureChangedPathsSafe -ChangedPaths $paths | Out-Null
    Run-StaticChecks $State
    foreach ($path in $paths) { Invoke-Native git @('-C',$Root,'add','--',$path) | Out-Null }
    $staged=Invoke-Native git @('-C',$Root,'diff','--cached','--name-only')
    if ($staged.Output) {
        Invoke-Native git @('-C',$Root,'commit','-m',"fix: repair $($State.feature_id) handoff CI") | Out-Null
        $State.feature_commit_sha=(Invoke-Native git @('-C',$Root,'rev-parse','HEAD')).Output.Trim()
        Invoke-Native git @('-C',$Root,'push','origin',[string]$State.branch) | Out-Null
        Save-FeatureHandoffState -State $State -StatePath $StatePath
    }
}

function Get-PrMergeCommit([int]$PrNumber,[string]$ExpectedHead) {
    for ($i=0; $i -lt 30; $i++) {
        $info=Invoke-Native gh @('pr','view',[string]$PrNumber,'--repo',$Repository,'--json','state,headRefOid,mergeCommit') -AllowFailure
        if ($info.ExitCode -eq 0 -and $info.Output) {
            $pr=$info.Output | ConvertFrom-Json
            if ($ExpectedHead -and [string]$pr.headRefOid -ne $ExpectedHead) { throw "FEATURE_HANDOFF_PR_HEAD_MOVED expected=$ExpectedHead actual=$($pr.headRefOid)" }
            if ([string]$pr.state -eq 'MERGED' -and $pr.mergeCommit -and [string]$pr.mergeCommit.oid -match '^[0-9a-f]{40}$') { return [string]$pr.mergeCommit.oid }
        }
        Start-Sleep -Seconds 2
    }
    throw 'FEATURE_HANDOFF_PR_MERGE_COMMIT_TIMEOUT'
}

function Wait-PrAndMerge($State,[int]$PrNumber) {
    $already=Invoke-Native gh @('pr','view',[string]$PrNumber,'--repo',$Repository,'--json','state,headRefOid,mergeCommit') -AllowFailure
    if ($already.ExitCode -eq 0 -and $already.Output) {
        $p=$already.Output | ConvertFrom-Json
        if ([string]$p.headRefOid -ne [string]$State.feature_commit_sha) { throw "FEATURE_HANDOFF_PR_HEAD_MOVED expected=$($State.feature_commit_sha) actual=$($p.headRefOid)" }
        if ([string]$p.state -eq 'MERGED') { return Get-PrMergeCommit -PrNumber $PrNumber -ExpectedHead ([string]$State.feature_commit_sha) }
    }

    for ($round=0; $round -lt 4; $round++) {
        $checks=Invoke-Native gh @('pr','checks',[string]$PrNumber,'--repo',$Repository,'--watch','--fail-fast=false') -AllowFailure
        if ($checks.ExitCode -eq 0) {
            $info=Invoke-Native gh @('pr','view',[string]$PrNumber,'--repo',$Repository,'--json','headRefOid,state')
            $pr=$info.Output | ConvertFrom-Json
            if ([string]$pr.headRefOid -ne [string]$State.feature_commit_sha) { throw "FEATURE_HANDOFF_PR_HEAD_MOVED expected=$($State.feature_commit_sha) actual=$($pr.headRefOid)" }
            if ([string]$pr.state -ne 'MERGED') {
                $merge=Invoke-Native gh @('pr','merge',[string]$PrNumber,'--repo',$Repository,'--merge','--match-head-commit',[string]$State.feature_commit_sha) -AllowFailure
                if ($merge.ExitCode -ne 0) { throw "FEATURE_HANDOFF_PR_MERGE_FAILED: $($merge.Output)" }
            }
            return Get-PrMergeCommit -PrNumber $PrNumber -ExpectedHead ([string]$State.feature_commit_sha)
        }
        if (Test-Recoverable $checks.Output) { Start-Sleep -Seconds 30; continue }
        Invoke-PrRepair -State $State -PrNumber $PrNumber -FailureText $checks.Output
    }
    throw 'FEATURE_HANDOFF_PR_CHECK_RETRIES_EXHAUSTED'
}

function Verify-FrozenFilesOnMain($State,[string]$ExpectedMergeSha) {
    if ($ExpectedMergeSha -notmatch '^[0-9a-f]{40}$') { throw 'FEATURE_HANDOFF_MERGE_SHA_INVALID' }
    Invoke-Native git @('-C',$Root,'fetch','origin','main') | Out-Null
    $ancestor=Invoke-Native git @('-C',$Root,'merge-base','--is-ancestor',$ExpectedMergeSha,'origin/main') -AllowFailure
    if ($ancestor.ExitCode -ne 0) { throw "FEATURE_HANDOFF_MERGE_NOT_ON_MAIN sha=$ExpectedMergeSha" }
    foreach ($f in @($State.frozen_files)) {
        $featureBlob=(Invoke-Native git @('-C',$Root,'rev-parse',"$($State.feature_commit_sha):$($f.overlay)")).Output.Trim()
        $mergeBlob=Invoke-Native git @('-C',$Root,'rev-parse',"$ExpectedMergeSha`:$($f.overlay)") -AllowFailure
        if ($mergeBlob.ExitCode -ne 0 -or $mergeBlob.Output.Trim() -ne $featureBlob) { throw "FEATURE_HANDOFF_ACCEPTED_SOURCE_NOT_IN_MERGE path=$($f.overlay) merge=$ExpectedMergeSha" }
    }
    $State.merge_sha=$ExpectedMergeSha
    $State.dispatch_source_sha=$ExpectedMergeSha
    Save-FeatureHandoffState -State $State -StatePath $StatePath
}

function Return-WorktreeToMain($State,[string]$ExpectedMergeSha) {
    $dirty=Invoke-Native git @('-C',$Root,'status','--porcelain')
    if ($dirty.Output) { throw "FEATURE_HANDOFF_POST_MERGE_DIRTY_WORKTREE: $($dirty.Output)" }
    Invoke-Native git @('-C',$Root,'fetch','origin','main') | Out-Null
    $branch=Get-CurrentBranch
    if ($branch -ne 'main') { Invoke-Native git @('-C',$Root,'switch','main') | Out-Null }
    Invoke-Native git @('-C',$Root,'pull','--ff-only','origin','main') | Out-Null
    $ancestor=Invoke-Native git @('-C',$Root,'merge-base','--is-ancestor',$ExpectedMergeSha,'HEAD') -AllowFailure
    if ($ancestor.ExitCode -ne 0) { throw "FEATURE_HANDOFF_MAIN_SYNC_LOST_MERGE sha=$ExpectedMergeSha" }
    Log "WORKTREE_MAIN_SYNC=PASS merge=$ExpectedMergeSha head=$((Invoke-Native git @('-C',$Root,'rev-parse','HEAD')).Output.Trim())"
}

function Integrate-Remote($State) {
    if (-not [int]$State.pr_number -or -not [string]$State.feature_commit_sha) {
        Stage-And-Commit $State
        $State.pr_number=Get-OrCreatePr $State
        Save-FeatureHandoffState -State $State -StatePath $StatePath
    }
    $mergeSha=Wait-PrAndMerge -State $State -PrNumber ([int]$State.pr_number)
    Verify-FrozenFilesOnMain -State $State -ExpectedMergeSha $mergeSha
    Return-WorktreeToMain -State $State -ExpectedMergeSha $mergeSha
    Set-FeatureHandoffStage -State $State -Stage 'REMOTE_INTEGRATED' -Status 'VERIFIED' | Out-Null
    Save-FeatureHandoffState -State $State -StatePath $StatePath
    Log "REMOTE_INTEGRATED pr=$($State.pr_number) merge=$mergeSha"
}

function Get-ProductionState {
    if (-not (Test-Path -LiteralPath $ProductionStatePath)) { return $null }
    try { return Get-Content -Raw -LiteralPath $ProductionStatePath | ConvertFrom-Json -Depth 20 } catch { return $null }
}

function Ensure-ControllerRecovery($State) {
    if ($State -and [long]$State.dispatched_run_id -gt 0) {
        $runId=[long]$State.dispatched_run_id
        if (-not (Test-Path -LiteralPath $ControllerLauncher -PathType Leaf)) { throw "FEATURE_HANDOFF_CONTROLLER_LAUNCHER_MISSING=$ControllerLauncher" }
        $matching=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            [string]$_.CommandLine -match '(?i)ci-controller-v3\.ps1' -and
            [string]$_.CommandLine -match '(?i)-Mode\s+Resume(?:\s|$)' -and
            [string]$_.CommandLine -match ("(?i)-RunId\s+" + [regex]::Escape([string]$runId) + '(?:\s|$)')
        }) | Select-Object -First 1
        if ($matching) { return $true }
        if ((Get-CurrentBranch) -ne 'main') { throw 'RECOVERABLE_CONTROLLER_RESUME_START: Feature Handoff must be on main before controller Resume.' }
        $launch=Invoke-Native 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ControllerLauncher,'-Mode','Resume','-UpdateMode',[string]$State.v3_mode,'-RunId',[string]$runId) -AllowFailure
        if ($launch.ExitCode -ne 0) { throw "RECOVERABLE_CONTROLLER_RESUME_START: $($launch.Output)" }
        Log "CONTROLLER_RESUME_STARTED run=$runId mode=$($State.v3_mode)"
        return $true
    }

    $task=Get-ScheduledTask -TaskName $ControllerTask -ErrorAction SilentlyContinue
    if ($task) { Start-ScheduledTask -TaskName $ControllerTask -ErrorAction SilentlyContinue; return $true }
    $deploy=Invoke-Native gh @('workflow','run','production-agent-deploy.yml','--repo',$Repository,'--ref','main') -AllowFailure
    if ($deploy.ExitCode -ne 0 -and -not (Test-Recoverable $deploy.Output)) { throw "FEATURE_HANDOFF_CONTROLLER_RECOVERY_DISPATCH_FAILED: $($deploy.Output)" }
    return $false
}

function Get-HandoffRequestIdentity($State) {
    Ensure-RequestStateFields $State
    if (-not [string]$State.merge_sha -or [string]$State.merge_sha -notmatch '^[0-9a-f]{40}$') { throw 'FEATURE_HANDOFF_MERGE_SHA_REQUIRED_FOR_REQUEST' }
    $safe=(([string]$State.feature_id).ToLowerInvariant() -replace '[^a-z0-9._-]','-').Trim('-')
    $mergeShort=([string]$State.merge_sha).Substring(0,12)
    $diffShort=([string]$State.accepted_diff_sha256).Substring(0,12)
    $requestId="handoff-$safe-$mergeShort-$diffShort"
    $sourceRef="handoff-source-$safe-$mergeShort-$diffShort"
    if (-not [string]$State.request_id) { $State.request_id=$requestId }
    elseif ([string]$State.request_id -ne $requestId) { throw "FEATURE_HANDOFF_REQUEST_ID_MISMATCH expected=$requestId actual=$($State.request_id)" }
    if (-not [string]$State.source_ref) { $State.source_ref=$sourceRef }
    elseif ([string]$State.source_ref -ne $sourceRef) { throw "FEATURE_HANDOFF_SOURCE_REF_MISMATCH expected=$sourceRef actual=$($State.source_ref)" }
    Save-FeatureHandoffState -State $State -StatePath $StatePath
    return [pscustomobject]@{ request_id=$requestId; source_ref=$sourceRef }
}

function Ensure-HandoffSourceTag($State) {
    $id=Get-HandoffRequestIdentity $State
    $refPath="repos/$Repository/git/ref/tags/$($id.source_ref)"
    $existing=Invoke-Native gh @('api',$refPath,'--jq','.object.sha') -AllowFailure
    if ($existing.ExitCode -eq 0 -and $existing.Output) {
        if ($existing.Output.Trim() -ne [string]$State.merge_sha) { throw "FEATURE_HANDOFF_SOURCE_TAG_CONFLICT ref=$($id.source_ref) expected=$($State.merge_sha) actual=$($existing.Output.Trim())" }
        Log "SOURCE_TAG=EXISTING ref=$($id.source_ref) sha=$($State.merge_sha)"
        return $id.source_ref
    }
    $created=Invoke-Native gh @('api','--method','POST',"repos/$Repository/git/refs",'-f',"ref=refs/tags/$($id.source_ref)",'-f',"sha=$($State.merge_sha)") -AllowFailure
    if ($created.ExitCode -ne 0) {
        $recheck=Invoke-Native gh @('api',$refPath,'--jq','.object.sha') -AllowFailure
        if ($recheck.ExitCode -ne 0 -or $recheck.Output.Trim() -ne [string]$State.merge_sha) { throw "FEATURE_HANDOFF_SOURCE_TAG_CREATE_FAILED: $($created.Output)" }
    }
    Log "SOURCE_TAG=PASS ref=$($id.source_ref) sha=$($State.merge_sha)"
    return $id.source_ref
}

function Get-CurrentV3RequestRaw {
    return Invoke-Native gh @('api',"repos/$Repository/contents/$V3RequestGit`?ref=main",'-H','Accept: application/vnd.github.raw+json') -AllowFailure
}

function Test-CurrentV3RequestMatches($State,[string]$Raw) {
    if (-not $Raw) { return $false }
    try { $r=$Raw | ConvertFrom-Json -Depth 20 } catch { return $false }
    return ([string]$r.request_id -eq [string]$State.request_id -and [string]$r.mode -eq [string]$State.v3_mode -and [string]$r.source_ref -eq [string]$State.source_ref -and [string]$r.source_sha -eq [string]$State.merge_sha -and [string]$r.accepted_diff_sha256 -eq [string]$State.accepted_diff_sha256)
}

function Get-LatestV3RequestCommit {
    $r=Invoke-Native gh @('api',"repos/$Repository/commits?path=$V3RequestGit&sha=main&per_page=1",'--jq','.[0].sha')
    if ($r.Output -notmatch '^[0-9a-f]{40}$') { throw "FEATURE_HANDOFF_REQUEST_COMMIT_UNRESOLVED output=$($r.Output)" }
    return $r.Output.Trim()
}

function Write-HandoffV3Request($State) {
    Ensure-RequestStateFields $State
    if (-not [string]$State.v3_mode) {
        $lockChanged=@($State.changed_paths) -contains 'config/arthur-known-good.lock'
        $plan=Select-HandoffBuildPlan -ChangedPaths @($State.changed_paths) -KnownGoodLockChanged:$lockChanged
        $State.selected_build_lane=$plan.selected_build_lane
        $State.v3_mode=$plan.v3_mode
    }
    Ensure-HandoffSourceTag $State | Out-Null
    $known=Get-Content -Raw (Join-Path $Root 'production\known-good.json') | ConvertFrom-Json -Depth 20
    $request=[ordered]@{
        schema_version='1.0'
        request_id=[string]$State.request_id
        mode=[string]$State.v3_mode
        base_stable=[string]$known.stable_tag
        device='jdcloud_re-ss-01'
        source_ref=[string]$State.source_ref
        source_sha=[string]$State.merge_sha
        feature_id=[string]$State.feature_id
        accepted_preview_source_sha=[string]$State.accepted_preview_source_sha
        accepted_diff_sha256=[string]$State.accepted_diff_sha256
        preview_manifest_sha256=[string]$State.preview_manifest_sha256
        reason="Build the immutable accepted LIVE_PREVIEW source for $($State.feature_id); WIFI=VERIFIED_FROZEN; deferred runtime acceptance remains for formal REAL_DEVICE_VERIFY."
        requested_at=[string]$State.created_at
    }
    $json=($request | ConvertTo-Json -Depth 20) + "`n"

    for ($attempt=0; $attempt -lt 5; $attempt++) {
        $current=Get-CurrentV3RequestRaw
        if ($current.ExitCode -eq 0 -and (Test-CurrentV3RequestMatches -State $State -Raw $current.Output)) {
            $State.request_commit_sha=Get-LatestV3RequestCommit
            Save-FeatureHandoffState -State $State -StatePath $StatePath
            Log "V3_REQUEST=EXISTING request_id=$($State.request_id) commit=$($State.request_commit_sha) source_ref=$($State.source_ref)"
            return
        }
        $meta=Invoke-Native gh @('api',"repos/$Repository/contents/$V3RequestGit`?ref=main",'--jq','.sha') -AllowFailure
        if ($meta.ExitCode -ne 0 -or -not $meta.Output) { throw "FEATURE_HANDOFF_REQUEST_BLOB_LOOKUP_FAILED: $($meta.Output)" }
        $base64=[Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
        $put=Invoke-Native gh @('api','--method','PUT',"repos/$Repository/contents/$V3RequestGit",'-f',"message=chore: dispatch $($State.request_id)",'-f',"content=$base64",'-f',"sha=$($meta.Output.Trim())",'-f','branch=main','--jq','.commit.sha') -AllowFailure
        if ($put.ExitCode -eq 0 -and $put.Output -match '^[0-9a-f]{40}$') {
            $State.request_commit_sha=$put.Output.Trim()
            Save-FeatureHandoffState -State $State -StatePath $StatePath
            Log "V3_REQUEST=PASS request_id=$($State.request_id) commit=$($State.request_commit_sha) source_ref=$($State.source_ref)"
            return
        }
        Start-Sleep -Seconds 3
    }
    $final=Get-CurrentV3RequestRaw
    if ($final.ExitCode -eq 0 -and (Test-CurrentV3RequestMatches -State $State -Raw $final.Output)) {
        $State.request_commit_sha=Get-LatestV3RequestCommit
        Save-FeatureHandoffState -State $State -StatePath $StatePath
        return
    }
    throw 'FEATURE_HANDOFF_V3_REQUEST_WRITE_RETRIES_EXHAUSTED'
}

function Find-HandoffAutoTriggerRun($State) {
    if (-not [string]$State.request_commit_sha) { return $null }
    $list=Invoke-Native gh @('run','list','--repo',$Repository,'--workflow',$V3AutoWorkflow,'--branch','main','--event','push','--limit','40','--json','databaseId,headSha,status,conclusion,createdAt') -AllowFailure
    if ($list.ExitCode -ne 0 -or -not $list.Output) { return $null }
    $runs=@($list.Output | ConvertFrom-Json)
    return $runs | Where-Object { [string]$_.headSha -eq [string]$State.request_commit_sha } | Sort-Object { [long]$_.databaseId } | Select-Object -First 1
}

function Find-HandoffV3Run($State) {
    if (-not [string]$State.source_ref) { return $null }
    $list=Invoke-Native gh @('run','list','--repo',$Repository,'--workflow',$V3Workflow,'--event','workflow_dispatch','--limit','100','--json','databaseId,headBranch,headSha,status,conclusion,createdAt') -AllowFailure
    if ($list.ExitCode -ne 0 -or -not $list.Output) { return $null }
    $runs=@($list.Output | ConvertFrom-Json)
    return $runs | Where-Object { [string]$_.headBranch -eq [string]$State.source_ref -and [string]$_.headSha -eq [string]$State.merge_sha } | Sort-Object { [long]$_.databaseId } | Select-Object -First 1
}

function Wait-DurableV3Dispatch($State) {
    for ($round=0; $round -lt 120; $round++) {
        $v3=Find-HandoffV3Run $State
        if ($v3) {
            $State.dispatched_run_id=[long]$v3.databaseId
            $State.dispatch_accepted=$true
            Set-FeatureHandoffStage -State $State -Stage 'BUILD_DISPATCHED' -Status 'LIVE' | Out-Null
            Save-FeatureHandoffState -State $State -StatePath $StatePath
            Ensure-ControllerRecovery -State $State | Out-Null
            Log "BUILD_DISPATCHED run=$($State.dispatched_run_id) request_id=$($State.request_id) source_ref=$($State.source_ref)"
            return
        }

        $auto=Find-HandoffAutoTriggerRun $State
        if ($auto) {
            $State.auto_trigger_run_id=[long]$auto.databaseId
            Save-FeatureHandoffState -State $State -StatePath $StatePath
            if ([string]$auto.status -eq 'completed' -and [string]$auto.conclusion -notin @('success','')) {
                $rerunArgs=@('run','rerun',[string]$auto.databaseId,'--repo',$Repository)
                if ([string]$auto.conclusion -eq 'failure') { $rerunArgs += '--failed' }
                $rerun=Invoke-Native gh $rerunArgs -AllowFailure
                if ($rerun.ExitCode -ne 0 -and -not (Test-Recoverable $rerun.Output)) { throw "FEATURE_HANDOFF_AUTO_TRIGGER_RERUN_FAILED: $($rerun.Output)" }
                Log "AUTO_TRIGGER_RERUN_REQUESTED run=$($auto.databaseId) conclusion=$($auto.conclusion)"
            }
        }
        Start-Sleep -Seconds 5
    }
    throw 'FEATURE_HANDOFF_AUTO_TRIGGER_WAIT_TIMEOUT'
}

function Dispatch-BuildOnce($State) {
    Ensure-RequestStateFields $State
    if ([long]$State.dispatched_run_id -gt 0) { Ensure-ControllerRecovery -State $State | Out-Null; return }
    $prod=Get-ProductionState
    if ($prod -and [long]$State.dispatched_run_id -gt 0 -and [long]$prod.run_id -eq [long]$State.dispatched_run_id) {
        $updated=Reconcile-ProductionState -HandoffState $State -ProductionState $prod
        foreach ($p in $updated.PSObject.Properties) { $State.($p.Name)=$p.Value }
        Save-FeatureHandoffState -State $State -StatePath $StatePath
        return
    }
    Write-HandoffV3Request $State
    Wait-DurableV3Dispatch $State
}

function Monitor-Production($State,[switch]$OneShot) {
    while ($true) {
        $prod=Get-ProductionState
        if ($prod -and ([long]$State.dispatched_run_id -eq 0 -or [long]$prod.run_id -eq [long]$State.dispatched_run_id)) {
            $updated=Reconcile-ProductionState -HandoffState $State -ProductionState $prod
            foreach ($p in $updated.PSObject.Properties) { $State.($p.Name)=$p.Value }
            Save-FeatureHandoffState -State $State -StatePath $StatePath
            if ([string]$State.current_stage -eq 'PRODUCTION_RELEASED') { Log "PRODUCTION_RELEASED run=$($State.dispatched_run_id)"; Write-Host 'PRODUCTION_RELEASED=YES'; return }
            if ($prod.PSObject.Properties.Name -contains 'human_gate' -and [string]$prod.human_gate) {
                $gate=[string]$prod.human_gate
                if ($gate -in @('NO_SAFE_ROLLBACK','DEVICE_IDENTITY_MISMATCH','SSH_HOST_IDENTITY_MISMATCH','REAL_DEVICE_BASELINE_GATE_FAILED','AUTO_FLASH_SAFETY_GATE_FAILED')) {
                    $State.stage_status='BLOCKED'; $State.last_error="PRODUCTION_SAFETY_BLOCK=$gate"; Save-FeatureHandoffState -State $State -StatePath $StatePath; throw $State.last_error
                }
            }
        }
        Ensure-ControllerRecovery -State $State | Out-Null
        if ($OneShot) { return }
        Start-Sleep -Seconds 30
    }
}

function Invoke-OneStage($State,[switch]$OneShot) {
    switch ([string]$State.current_stage) {
        'PREVIEW_ACCEPTED' { Capture-LocalChanges $State; return }
        'LOCAL_CHANGES_CAPTURED' { Run-StaticChecks $State; return }
        'STATIC_VERIFIED' { Freeze-AcceptedSource $State; return }
        'SOURCE_FROZEN' { Integrate-Remote $State; return }
        'REMOTE_INTEGRATED' { Dispatch-BuildOnce $State; return }
        'BUILD_DISPATCHED' { Ensure-ControllerRecovery -State $State | Out-Null; Set-FeatureHandoffStage -State $State -Stage 'CONTROLLER_ATTACHED' -Status 'LIVE' | Out-Null; Save-FeatureHandoffState -State $State -StatePath $StatePath; return }
        'CONTROLLER_ATTACHED' { Monitor-Production -State $State -OneShot:$OneShot; return }
        'PRODUCTION_RUNNING' { Monitor-Production -State $State -OneShot:$OneShot; return }
        'PRODUCTION_RELEASED' { Write-Host 'PRODUCTION_RELEASED=YES'; return }
        default { throw "FEATURE_HANDOFF_UNKNOWN_STAGE=$($State.current_stage)" }
    }
}

if ($Mode -eq 'Status') {
    $state=Load-FeatureHandoffState -StatePath $StatePath
    if (-not $state) { Write-Host 'FEATURE_HANDOFF=IDLE'; exit 0 }
    Ensure-RequestStateFields $state
    Write-Host "FEATURE_HANDOFF_STAGE=$($state.current_stage)"
    Write-Host "FEATURE_HANDOFF_STATUS=$($state.stage_status)"
    Write-Host "FEATURE_ID=$($state.feature_id)"
    Write-Host "ACCEPTED_SOURCE_SHA=$($state.accepted_preview_source_sha)"
    Write-Host "REQUEST_ID=$($state.request_id)"
    Write-Host "SOURCE_REF=$($state.source_ref)"
    Write-Host "RUN_ID=$($state.dispatched_run_id)"
    Write-Host "PRODUCTION_STAGE=$($state.production_stage)"
    exit 0
}

$lockStream=$null
try {
    try { $lockStream=[System.IO.File]::Open($LockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None) }
    catch {
        if ($Mode -eq 'AcceptPreview') { throw 'FEATURE_HANDOFF_ACCEPT_PREVIEW_LOCKED_BY_ACTIVE_RUNTIME' }
        Write-Host 'FEATURE_HANDOFF_ALREADY_RUNNING=YES'; exit 0
    }

    if ($Mode -eq 'AcceptPreview') {
        $state=Accept-PreviewState
        if (-not $state) { exit 0 }
        Write-Host "FEATURE_HANDOFF_STAGE=$($state.current_stage)"
        exit 0
    }

    $state=Load-OrAcceptState
    if (-not $state) { Write-Host 'FEATURE_HANDOFF=IDLE'; exit 0 }
    Ensure-RequestStateFields $state
    if ($Mode -eq 'RunOnce') { Invoke-OneStage $state -OneShot; exit 0 }

    while ($true) {
        try {
            if ([string]$state.current_stage -eq 'PRODUCTION_RELEASED') { Write-Host 'PRODUCTION_RELEASED=YES'; exit 0 }
            Invoke-OneStage $state
            $state=Load-FeatureHandoffState -StatePath $StatePath
            Ensure-RequestStateFields $state
        } catch {
            $message=$_.Exception.Message
            $state=Load-FeatureHandoffState -StatePath $StatePath
            if ($state) {
                Ensure-RequestStateFields $state
                $state.last_error=$message
                $state.retry_count=[int]$state.retry_count + 1
                if (Test-Recoverable $message) {
                    $state.stage_status='RETRYING'; Save-FeatureHandoffState -State $state -StatePath $StatePath
                    Log "RETRYING stage=$($state.current_stage) error=$message"; Start-Sleep -Seconds 30; continue
                }
                $state.stage_status='BLOCKED'; Save-FeatureHandoffState -State $state -StatePath $StatePath
            }
            Log "BLOCKED error=$message"
            throw
        }
    }
} finally {
    if ($lockStream) { $lockStream.Dispose() }
}
