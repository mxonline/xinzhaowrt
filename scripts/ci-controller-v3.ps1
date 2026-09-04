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

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Core = Join-Path $PSScriptRoot 'ci-controller-v3-core.ps1'
$Resolver = Join-Path $PSScriptRoot 'resolve-candidate-dedup.sh'
$DecisionPath = Join-Path $Root 'state\build-dedup-state.json'
New-Item -ItemType Directory -Force -Path (Split-Path $DecisionPath -Parent) | Out-Null

function Invoke-CoreController {
    param([string]$EffectiveMode,[long]$EffectiveRunId)
    & $Core `
        -Mode $EffectiveMode `
        -UpdateMode $UpdateMode `
        -RunId $EffectiveRunId `
        -MaxRepairRounds $MaxRepairRounds `
        -PollSeconds $PollSeconds `
        -CodexTimeoutSeconds $CodexTimeoutSeconds `
        -Repository $Repository `
        -Branch $Branch `
        -Workflow $Workflow
    exit $LASTEXITCODE
}

function Save-DedupDecision {
    param([hashtable]$Values)
    [ordered]@{
        schema_version = '1.0'
        repository = $Repository
        branch = $Branch
        workflow = $Workflow
        requested_mode = $Mode
        update_mode = $UpdateMode
        action = [string]$Values.ACTION
        active_run_id = if ($Values.RUN_ID) { [long]$Values.RUN_ID } else { 0 }
        build_fingerprint = [string]$Values.BUILD_FINGERPRINT
        source_sha = [string]$Values.SOURCE_SHA
        source_impact = [string]$Values.SOURCE_IMPACT
        updated_at = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $DecisionPath
}

if (-not (Test-Path $Core)) { throw "BLOCKED: preserved v3 controller core is missing: $Core" }
if (-not (Test-Path $Resolver)) { throw "BLOCKED: Candidate dedup resolver is missing: $Resolver" }

# Explicit Run IDs are immutable resume requests. Watch is read-only. Neither path may
# dispatch a replacement Candidate, so they bypass source-impact resolution safely.
if ($Mode -eq 'Watch' -or ($Mode -eq 'Resume' -and $RunId -gt 0)) {
    Invoke-CoreController -EffectiveMode $Mode -EffectiveRunId $RunId
}

$head = (& git -C $Root rev-parse HEAD 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') {
    throw "RECOVERABLE_GIT_HEAD: unable to resolve current source SHA: $head"
}

$raw = (& bash $Resolver $Repository $Workflow $head 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "RECOVERABLE_BUILD_DEDUP_GATE: resolver failed: $raw"
}

$decision = @{}
foreach ($line in ($raw -split "`r?`n")) {
    if ($line -match '^([A-Z_]+)=(.*)$') { $decision[$matches[1]] = $matches[2] }
}
if (-not $decision.ACTION) { throw "BLOCKED: Candidate dedup resolver returned no ACTION: $raw" }
Save-DedupDecision -Values $decision

switch ([string]$decision.ACTION) {
    'WATCH_EXISTING_RUN' {
        $reuseRun = [long]$decision.RUN_ID
        Write-Host "BUILD_DEDUP=WATCH_EXISTING_RUN run_id=$reuseRun fingerprint=$($decision.BUILD_FINGERPRINT)"
        Invoke-CoreController -EffectiveMode 'Resume' -EffectiveRunId $reuseRun
    }
    'REUSE_ARTIFACT' {
        $reuseRun = [long]$decision.RUN_ID
        Write-Host "BUILD_DEDUP=REUSE_ARTIFACT run_id=$reuseRun fingerprint=$($decision.BUILD_FINGERPRINT)"
        Invoke-CoreController -EffectiveMode 'Resume' -EffectiveRunId $reuseRun
    }
    'NO_NEW_CANDIDATE' {
        Write-Host "BUILD_DEDUP=NO_NEW_CANDIDATE fingerprint=$($decision.BUILD_FINGERPRINT) impact=$($decision.SOURCE_IMPACT)"
        Write-Host 'NEXT_ACTION=WAIT_FOR_EXISTING_CANDIDATE_OR_FIRMWARE_INPUT_CHANGE'
        exit 0
    }
    'NEW_CANDIDATE' {
        Write-Host "BUILD_DEDUP=NEW_CANDIDATE_ALLOWED fingerprint=$($decision.BUILD_FINGERPRINT) impact=$($decision.SOURCE_IMPACT)"
        Invoke-CoreController -EffectiveMode $Mode -EffectiveRunId $RunId
    }
    default {
        throw "BLOCKED: unsupported Candidate dedup action: $($decision.ACTION)"
    }
}
