param(
    [ValidateSet('Resume','RunOnce','Status')][string]$Mode='Resume',
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

if (-not $RuntimeRoot) {
    $RuntimeRoot=Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\FeatureHandoff'
}
New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
$StatePath=Join-Path $RuntimeRoot 'handoff.json'
$LogPath=Join-Path $RuntimeRoot 'handoff.log'
$ProductionStatePath=Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\ProductionAgent\output\production-agent\state.json'
$ControllerTask='XinZhaoWrt-Arthur-v3-Controller'
$HandoffTask='XinZhaoWrt-Arthur-Feature-Handoff'

function Log([string]$Message) {
    $line='{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Message
    Add-Content -LiteralPath $LogPath -Value $line
    Write-Host $line
}

function Invoke-Native([string]$File,[string[]]$Args,[switch]$AllowFailure) {
    $old=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $raw=@(& $File @Args 2>&1)
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$old }
    $text=($raw | ForEach-Object { [string]$_ }) -join "`n"
    if (-not $AllowFailure -and $code -ne 0) { throw "$File failed ($code): $text" }
    [pscustomobject]@{ ExitCode=$code; Output=$text.Trim() }
}

function Test-Recoverable([string]$Message) {
    return $Message -match '(?i)timeout|timed out|connection|HTTP 5\d\d|rate limit|temporar|EOF|queued|runner|network|could not resolve|TLS|try again'
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

function Initialize-StateIfNeeded {
    $existing=Load-FeatureHandoffState -StatePath $StatePath
    if ($existing) {
        if ($FeatureId -and [string]$existing.feature_id -ne $FeatureId -and [string]$existing.current_stage -ne 'PRODUCTION_RELEASED') {
            throw "FEATURE_HANDOFF_ACTIVE_FEATURE_CONFLICT active=$($existing.feature_id) requested=$FeatureId"
        }
        return $existing
    }
    if (-not $FeatureId -or -not $AcceptedPreviewSourceSha -or -not $PreviewManifestPath -or -not $PreviewEvidencePath) {
        return $null
    }
    if ($PauseAfterLivePreview) {
        Write-Host 'FEATURE_HANDOFF=PAUSED_BY_USER'
        return $null
    }
    $evidence=Read-PreviewEvidence $PreviewEvidencePath
    $resolvedManifest=Get-ResolvedManifestPath $PreviewManifestPath
    $identity=Get-PreviewManifestIdentity -RepoRoot $Root -ManifestPath $resolvedManifest
    $diffSha=Get-WorktreeDiffSha256 -RepoRoot $Root
    $state=New-FeatureHandoffState `
        -FeatureId $FeatureId `
        -AcceptedPreviewSourceSha $AcceptedPreviewSourceSha.ToLowerInvariant() `
        -AcceptedDiffSha256 $diffSha `
        -PreviewManifestSha256 $identity.manifest_sha256 `
        -PreviewManifestPath $resolvedManifest `
        -PreviewEvidence $evidence
    Save-FeatureHandoffState -State $state -StatePath $StatePath
    Log "PREVIEW_ACCEPTED feature=$FeatureId source=$AcceptedPreviewSourceSha diff=$diffSha"
    return $state
}

function Capture-LocalChanges($State) {
    $paths=@(Get-FeatureChangedPaths -RepoRoot $Root)
    Assert-FeatureChangedPathsSafe -ChangedPaths $paths | Out-Null
    $currentDiff=Get-WorktreeDiffSha256 -RepoRoot $Root
    if ($currentDiff -ne [string]$State.accepted_diff_sha256) {
        throw "FEATURE_HANDOFF_SOURCE_IDENTITY_CHANGED accepted=$($State.accepted_diff_sha256) current=$currentDiff"
    }
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
        @('pwsh',@('-NoProfile','-File',(Join-Path $Root 'tests/feature-handoff.tests.ps1')))
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

function Get-CurrentBranch {
    $r=Invoke-Native git @('-C',$Root,'branch','--show-current')
    return $r.Output.Trim()
}

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
        if ($merge.ExitCode -ne 0) {
            throw "FEATURE_HANDOFF_SOURCE_RECONCILIATION_BLOCKED: merge conflict preserved for inspection. $($merge.Output)"
        }
    }
    foreach ($path in @($State.changed_paths)) {
        Invoke-Native git @('-C',$Root,'add','--',[string]$path) | Out-Null
    }
    $staged=Invoke-Native git @('-C',$Root,'diff','--cached','--name-only')
    if ($staged.Output) {
        Invoke-Native git @('-C',$Root,'commit','-m',"feat: freeze accepted $($State.feature_id) live preview") | Out-Null
    }
    $State.feature_commit_sha=(Invoke-Native git @('-C',$Root,'rev-parse','HEAD')).Output.Trim()
    Invoke-Native git @('-C',$Root,'push','-u','origin',$branch) | Out-Null
    Log "FEATURE_BRANCH_PUSHED branch=$branch sha=$($State.feature_commit_sha)"
}

function Get-OrCreatePr($State) {
    $list=Invoke-Native gh @('pr','list','--repo',$Repository,'--head',[string]$State.branch,'--base','main','--state','open','--json','number,headRefOid')
    $prs=@()
    if ($list.Output) { $prs=@($list.Output | ConvertFrom-Json) }
    if ($prs.Count -gt 0) { return [int]$prs[0].number }
    $create=Invoke-Native gh @('pr','create','--repo',$Repository,'--base','main','--head',[string]$State.branch,'--title',"Arthur: freeze accepted $($State.feature_id) preview",'--body',"Automated Feature Handoff for accepted LIVE_PREVIEW. WIFI=VERIFIED_FROZEN. Production continues through existing v3 Controller and Production Agent.")
    $m=[regex]::Match($create.Output,'/pull/(\d+)')
    if (-not $m.Success) { throw "FEATURE_HANDOFF_PR_CREATE_UNRESOLVED output=$($create.Output)" }
    return [int]$m.Groups[1].Value
}

function Invoke-PrRepair($State,[int]$PrNumber,[string]$FailureText) {
    $codex=(Get-Command codex.cmd -ErrorAction SilentlyContinue)
    if (-not $codex) { $codex=Get-Command codex -ErrorAction SilentlyContinue }
    if (-not $codex) { throw "FEATURE_HANDOFF_PR_CHECK_FAILED_NO_CODEX: $FailureText" }
    $prompt=@"
Repair PR #$PrNumber for mxonline/xinzhaowrt after Feature Handoff static/CI failure.
Read AGENTS.md, knowledge/V013-DEVELOPMENT-LOOP.md, and the handoff spec/plan.
Keep WIFI=VERIFIED_FROZEN. Do not modify config/required-plugins.txt, config/arthur.config, config/arthur-known-good.lock, production/known-good.json, VERSION, or build.env.
Do not force push, reset/clean away work, remove required plugins, weaken tests/gates, flash the router, or touch raw storage.
Diagnose the first concrete error below, make the smallest repair in the current branch, run the relevant tests, and stop without git commit/push.
Failure evidence:
$FailureText
"@
    $resultPath=Join-Path $RuntimeRoot 'codex-pr-repair.txt'
    $input=Join-Path $RuntimeRoot 'codex-pr-repair.prompt.txt'
    Set-Content -LiteralPath $input -Value $prompt -Encoding UTF8
    $old=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $raw=@(Get-Content -Raw $input | & $codex.Source exec --sandbox workspace-write -c 'approval_policy="never"' -o $resultPath - 2>&1)
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$old }
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
    }
}

function Wait-PrAndMerge($State,[int]$PrNumber) {
    for ($round=0; $round -lt 4; $round++) {
        $checks=Invoke-Native gh @('pr','checks',[string]$PrNumber,'--repo',$Repository,'--watch','--fail-fast=false') -AllowFailure
        if ($checks.ExitCode -eq 0) {
            $info=Invoke-Native gh @('pr','view',[string]$PrNumber,'--repo',$Repository,'--json','headRefOid,state,mergeStateStatus')
            $pr=$info.Output | ConvertFrom-Json
            if ([string]$pr.headRefOid -ne [string]$State.feature_commit_sha) {
                throw "FEATURE_HANDOFF_PR_HEAD_MOVED expected=$($State.feature_commit_sha) actual=$($pr.headRefOid)"
            }
            $merge=Invoke-Native gh @('pr','merge',[string]$PrNumber,'--repo',$Repository,'--merge','--match-head-commit',[string]$State.feature_commit_sha) -AllowFailure
            if ($merge.ExitCode -ne 0) { throw "FEATURE_HANDOFF_PR_MERGE_FAILED: $($merge.Output)" }
            return
        }
        if (Test-Recoverable $checks.Output) { Start-Sleep -Seconds 30; continue }
        Invoke-PrRepair -State $State -PrNumber $PrNumber -FailureText $checks.Output
    }
    throw 'FEATURE_HANDOFF_PR_CHECK_RETRIES_EXHAUSTED'
}

function Verify-FrozenFilesOnMain($State) {
    Invoke-Native git @('-C',$Root,'fetch','origin','main') | Out-Null
    $mainSha=(Invoke-Native git @('-C',$Root,'rev-parse','origin/main')).Output.Trim()
    foreach ($f in @($State.frozen_files)) {
        $featureBlob=(Invoke-Native git @('-C',$Root,'rev-parse',"$($State.feature_commit_sha):$($f.overlay)")).Output.Trim()
        $mainBlob=(Invoke-Native git @('-C',$Root,'rev-parse',"origin/main:$($f.overlay)") -AllowFailure)
        if ($mainBlob.ExitCode -ne 0 -or $mainBlob.Output.Trim() -ne $featureBlob) {
            throw "FEATURE_HANDOFF_ACCEPTED_SOURCE_NOT_ON_MAIN path=$($f.overlay)"
        }
    }
    $State.merge_sha=$mainSha
    $State.dispatch_source_sha=$mainSha
    return $mainSha
}

function Integrate-Remote($State) {
    Stage-And-Commit $State
    $pr=Get-OrCreatePr $State
    $State.pr_number=$pr
    Save-FeatureHandoffState -State $State -StatePath $StatePath
    Wait-PrAndMerge -State $State -PrNumber $pr
    Verify-FrozenFilesOnMain $State | Out-Null
    Set-FeatureHandoffStage -State $State -Stage 'REMOTE_INTEGRATED' -Status 'VERIFIED' | Out-Null
    Save-FeatureHandoffState -State $State -StatePath $StatePath
    Log "REMOTE_INTEGRATED pr=$pr main=$($State.merge_sha)"
}

function Get-ProductionState {
    if (-not (Test-Path -LiteralPath $ProductionStatePath)) { return $null }
    try { return Get-Content -Raw -LiteralPath $ProductionStatePath | ConvertFrom-Json -Depth 20 }
    catch { return $null }
}

function Ensure-ControllerRecovery {
    $task=Get-ScheduledTask -TaskName $ControllerTask -ErrorAction SilentlyContinue
    if ($task) {
        Start-ScheduledTask -TaskName $ControllerTask -ErrorAction SilentlyContinue
        return $true
    }
    $deploy=Invoke-Native gh @('workflow','run','production-agent-deploy.yml','--repo',$Repository,'--ref','main') -AllowFailure
    if ($deploy.ExitCode -ne 0 -and -not (Test-Recoverable $deploy.Output)) {
        throw "FEATURE_HANDOFF_CONTROLLER_RECOVERY_DISPATCH_FAILED: $($deploy.Output)"
    }
    return $false
}

function Discover-V3Run([string]$SourceSha,[datetime]$StartedAt) {
    for ($i=0; $i -lt 24; $i++) {
        $list=Invoke-Native gh @('run','list','--repo',$Repository,'--workflow','arthur-update-v3.yml','--branch','main','--event','workflow_dispatch','--limit','20','--json','databaseId,createdAt,status,conclusion,headSha') -AllowFailure
        if ($list.ExitCode -eq 0 -and $list.Output) {
            $runs=@($list.Output | ConvertFrom-Json)
            $run=$runs | Where-Object {
                [string]$_.headSha -eq $SourceSha -and ([datetime]$_.createdAt).ToUniversalTime() -ge $StartedAt.ToUniversalTime().AddSeconds(-3)
            } | Sort-Object { [datetime]$_.createdAt } -Descending | Select-Object -First 1
            if ($run) { return [long]$run.databaseId }
        }
        Start-Sleep -Seconds 5
    }
    throw 'FEATURE_HANDOFF_V3_RUN_DISCOVERY_TIMEOUT'
}

function Dispatch-BuildOnce($State) {
    $prod=Get-ProductionState
    if ($prod -and [long]$State.dispatched_run_id -gt 0 -and [long]$prod.run_id -eq [long]$State.dispatched_run_id) {
        $updated=Reconcile-ProductionState -HandoffState $State -ProductionState $prod
        foreach ($p in $updated.PSObject.Properties) { $State.($p.Name)=$p.Value }
        Save-FeatureHandoffState -State $State -StatePath $StatePath
        return
    }
    if ([long]$State.dispatched_run_id -gt 0 -or $State.suppress_dispatch -eq $true) { return }
    $lockChanged=@($State.changed_paths) -contains 'config/arthur-known-good.lock'
    $plan=Select-HandoffBuildPlan -ChangedPaths @($State.changed_paths) -KnownGoodLockChanged:$lockChanged
    $State.selected_build_lane=$plan.selected_build_lane
    $State.v3_mode=$plan.v3_mode
    $started=Get-Date
    Invoke-Native gh @('workflow','run','arthur-update-v3.yml','--repo',$Repository,'--ref','main','-f',"mode=$($plan.v3_mode)") | Out-Null
    $runId=Discover-V3Run -SourceSha ([string]$State.dispatch_source_sha) -StartedAt $started
    $State.dispatched_run_id=$runId
    Set-FeatureHandoffStage -State $State -Stage 'BUILD_DISPATCHED' -Status 'LIVE' | Out-Null
    Save-FeatureHandoffState -State $State -StatePath $StatePath
    Ensure-ControllerRecovery | Out-Null
    Log "BUILD_DISPATCHED run=$runId mode=$($State.v3_mode)"
}

function Monitor-Production($State,[switch]$OneShot) {
    while ($true) {
        $prod=Get-ProductionState
        if ($prod -and ([long]$State.dispatched_run_id -eq 0 -or [long]$prod.run_id -eq [long]$State.dispatched_run_id)) {
            $updated=Reconcile-ProductionState -HandoffState $State -ProductionState $prod
            foreach ($p in $updated.PSObject.Properties) { $State.($p.Name)=$p.Value }
            Save-FeatureHandoffState -State $State -StatePath $StatePath
            if ([string]$State.current_stage -eq 'PRODUCTION_RELEASED') {
                Log "PRODUCTION_RELEASED run=$($State.dispatched_run_id)"
                Write-Host 'PRODUCTION_RELEASED=YES'
                return
            }
            if ($prod.PSObject.Properties.Name -contains 'human_gate' -and [string]$prod.human_gate) {
                $gate=[string]$prod.human_gate
                if ($gate -in @('NO_SAFE_ROLLBACK','DEVICE_IDENTITY_MISMATCH','SSH_HOST_IDENTITY_MISMATCH','REAL_DEVICE_BASELINE_GATE_FAILED','AUTO_FLASH_SAFETY_GATE_FAILED')) {
                    $State.stage_status='BLOCKED'
                    $State.last_error="PRODUCTION_SAFETY_BLOCK=$gate"
                    Save-FeatureHandoffState -State $State -StatePath $StatePath
                    throw $State.last_error
                }
            }
        }
        Ensure-ControllerRecovery | Out-Null
        if ($OneShot) { return }
        Start-Sleep -Seconds 30
    }
}

function Invoke-OneStage($State) {
    switch ([string]$State.current_stage) {
        'PREVIEW_ACCEPTED' { Capture-LocalChanges $State; return }
        'LOCAL_CHANGES_CAPTURED' { Run-StaticChecks $State; return }
        'STATIC_VERIFIED' { Freeze-AcceptedSource $State; return }
        'SOURCE_FROZEN' { Integrate-Remote $State; return }
        'REMOTE_INTEGRATED' { Dispatch-BuildOnce $State; return }
        'BUILD_DISPATCHED' {
            Ensure-ControllerRecovery | Out-Null
            Set-FeatureHandoffStage -State $State -Stage 'CONTROLLER_ATTACHED' -Status 'LIVE' | Out-Null
            Save-FeatureHandoffState -State $State -StatePath $StatePath
            return
        }
        'CONTROLLER_ATTACHED' { Monitor-Production -State $State -OneShot; return }
        'PRODUCTION_RUNNING' { Monitor-Production -State $State -OneShot; return }
        'PRODUCTION_RELEASED' { Write-Host 'PRODUCTION_RELEASED=YES'; return }
        default { throw "FEATURE_HANDOFF_UNKNOWN_STAGE=$($State.current_stage)" }
    }
}

if ($Mode -eq 'Status') {
    $state=Load-FeatureHandoffState -StatePath $StatePath
    if (-not $state) { Write-Host 'FEATURE_HANDOFF=IDLE'; exit 0 }
    Write-Host "FEATURE_HANDOFF_STAGE=$($state.current_stage)"
    Write-Host "FEATURE_HANDOFF_STATUS=$($state.stage_status)"
    Write-Host "FEATURE_ID=$($state.feature_id)"
    Write-Host "ACCEPTED_SOURCE_SHA=$($state.accepted_preview_source_sha)"
    Write-Host "RUN_ID=$($state.dispatched_run_id)"
    Write-Host "PRODUCTION_STAGE=$($state.production_stage)"
    exit 0
}

$state=Initialize-StateIfNeeded
if (-not $state) { Write-Host 'FEATURE_HANDOFF=IDLE'; exit 0 }

if ($Mode -eq 'RunOnce') {
    Invoke-OneStage $state
    exit 0
}

while ($true) {
    try {
        if ([string]$state.current_stage -eq 'PRODUCTION_RELEASED') { Write-Host 'PRODUCTION_RELEASED=YES'; exit 0 }
        Invoke-OneStage $state
        $state=Load-FeatureHandoffState -StatePath $StatePath
    }
    catch {
        $message=$_.Exception.Message
        $state=Load-FeatureHandoffState -StatePath $StatePath
        if ($state) {
            $state.last_error=$message
            $state.retry_count=[int]$state.retry_count + 1
            if (Test-Recoverable $message) {
                $state.stage_status='RETRYING'
                Save-FeatureHandoffState -State $state -StatePath $StatePath
                Log "RETRYING stage=$($state.current_stage) error=$message"
                Start-Sleep -Seconds 30
                continue
            }
            $state.stage_status='BLOCKED'
            Save-FeatureHandoffState -State $state -StatePath $StatePath
        }
        Log "BLOCKED error=$message"
        throw
    }
}
