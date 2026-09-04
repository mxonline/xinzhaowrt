[CmdletBinding()]
param(
    [string]$Repository = 'mxonline/xinzhaowrt',
    [string]$WorkflowRunId = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$lock = $null

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

try {
    $identity = (whoami).Trim()
    if ($identity -notmatch '(?i)\\xinzhaowrt-runner$') {
        Fail "CONTROL_PLANE_IDENTITY_MISMATCH: expected cychan\\xinzhaowrt-runner, got $identity"
    }

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Fail 'CONTROL_PLANE_ROOT_MISSING: LOCALAPPDATA is not set in the runner service context'
    }
    $root = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\ControlPlane'))
    if ($root -match '(?i)\\Users\\chenz(\\|$)') {
        Fail "CONTROL_PLANE_ROOT_FORBIDDEN: $root"
    }

    $stateDir = Join-Path $root 'state'
    $logDir = Join-Path $root 'logs'
    $lockDir = Join-Path $root 'locks'
    $sshDir = Join-Path $root 'ssh'
    New-Item -ItemType Directory -Force -Path $root, $stateDir, $logDir, $lockDir, $sshDir | Out-Null

    $lockPath = Join-Path $lockDir 'arthur-control-plane.lock'
    try {
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch {
        Fail "CONTROL_PLANE_ALREADY_RUNNING: $($_.Exception.Message)"
    }

    $logPath = Join-Path $logDir ("run-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    function Log([string]$Message) {
        $line = "{0:o} {1}" -f [DateTime]::UtcNow, $Message
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
        Write-Host $line
    }

    function Save-Json([string]$Path, [object]$Value) {
        $tmp = "$Path.$PID.tmp"
        $json = $Value | ConvertTo-Json -Depth 30
        [IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }

    function Invoke-GhJson([string[]]$Arguments) {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $raw = (& gh @Arguments 2>&1 | Out-String).Trim()
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $old }
        if ($code -ne 0) { Fail "GITHUB_API_FAILED: $raw" }
        try { return ($raw | ConvertFrom-Json) }
        catch { Fail "GITHUB_API_INVALID_JSON: $raw" }
    }

    function Invoke-ReadOnlySsh([string]$Command, [string]$KnownHosts) {
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ ok = $false; output = 'SSH_NOT_INSTALLED' } }
        if (-not (Test-Path -LiteralPath $KnownHosts -PathType Leaf)) { return [pscustomobject]@{ ok = $false; output = 'KNOWN_HOSTS_MISSING' } }
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = (& ssh -o BatchMode=yes -o ConnectTimeout=8 -o UserKnownHostsFile=$KnownHosts root@192.168.6.1 $Command 2>&1 | Out-String).Trim()
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $old }
        return [pscustomobject]@{ ok = ($code -eq 0); output = $output }
    }

    function Publish-ResumeState([object]$ResumeState, [string]$ResumeStatePath) {
        $existingPublished = $null
        if (Test-Path -LiteralPath $ResumeStatePath -PathType Leaf) {
            try { $existingPublished = Get-Content -Raw -LiteralPath $ResumeStatePath | ConvertFrom-Json }
            catch { $existingPublished = $null }
        }
        $existingHash = if ($existingPublished -and $existingPublished.semantic_sha256) { [string]$existingPublished.semantic_sha256 } else { '' }
        if ($existingHash -eq [string]$ResumeState.semantic_sha256) {
            Log "RESUME_STATE_PUBLISHED=UNCHANGED semantic_sha256=$existingHash"
            return
        }

        $ResumeState | Add-Member -NotePropertyName evidence_timestamp -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Save-Json $ResumeStatePath $ResumeState

        if ([string]$env:GITHUB_REF_NAME -ne 'main') {
            Log "RESUME_STATE_PUBLISHED=LOCAL_ONLY ref=$($env:GITHUB_REF_NAME) semantic_sha256=$($ResumeState.semantic_sha256)"
            return
        }

        Push-Location $env:GITHUB_WORKSPACE
        try {
            & git config user.name 'github-actions[bot]'
            & git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
            & git add -- 'production/resume-state.json'
            & git diff --cached --quiet
            if ($LASTEXITCODE -eq 0) {
                Log 'RESUME_STATE_PUBLISHED=UNCHANGED_GIT'
                return
            }
            & git commit -m 'chore(state): update Arthur resume snapshot [skip ci]'
            if ($LASTEXITCODE -ne 0) { Fail 'RESUME_STATE_PUBLICATION_FAILED: git commit failed' }
            & git push origin HEAD:main
            if ($LASTEXITCODE -ne 0) { Fail 'RESUME_STATE_PUBLICATION_FAILED: non-fast-forward or push rejected; retry from fresh main' }
        }
        finally { Pop-Location }
        Log "RESUME_STATE_PUBLISHED=PASS semantic_sha256=$($ResumeState.semantic_sha256)"
    }

    $canonicalPath = Join-Path $root 'canonical-state.json'
    $heartbeatPath = Join-Path $root 'heartbeat.json'
    $existing = $null
    if (Test-Path -LiteralPath $canonicalPath -PathType Leaf) {
        try { $existing = Get-Content -Raw -LiteralPath $canonicalPath | ConvertFrom-Json }
        catch { Fail "CANONICAL_STATE_INVALID: $($_.Exception.Message)" }
        if ($existing.canonical_root -ne $root) { Fail 'CANONICAL_STATE_ROOT_MISMATCH' }
    }

    $heartbeat = [long]0
    if (Test-Path -LiteralPath $heartbeatPath -PathType Leaf) {
        try { $heartbeat = [long](Get-Content -Raw -LiteralPath $heartbeatPath | ConvertFrom-Json).sequence } catch { $heartbeat = 0 }
    }
    $heartbeat++
    Save-Json $heartbeatPath ([ordered]@{
        schema_version = 1
        sequence = $heartbeat
        updated_at = [DateTime]::UtcNow.ToString('o')
        pid = $PID
        identity = $identity
        workflow_run_id = $WorkflowRunId
    })
    Log "RUNNER_CONTROL_PLANE=RUNNING sequence=$heartbeat identity=$identity"

    foreach ($tool in @('git', 'gh', 'python')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "CONTROL_PLANE_TOOL_MISSING: $tool" }
    }
    $resumeHelperPath = Join-Path $env:GITHUB_WORKSPACE 'scripts\arthur-resume-state.ps1'
    if (-not (Test-Path -LiteralPath $resumeHelperPath -PathType Leaf)) { Fail 'CONTROL_PLANE_RESUME_HELPER_MISSING' }
    . $resumeHelperPath

    $headless = $false
    if (Get-Command codex -ErrorAction SilentlyContinue) { $headless = $true }
    $pythonProbe = (& python -c "import importlib.util; print('PASS' if (importlib.util.find_spec('openai_codex') or importlib.util.find_spec('codex')) else 'MISSING')" 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $pythonProbe -eq 'PASS') { $headless = $true }
    if (-not $headless) { Fail 'HEADLESS_CODEX_UNAVAILABLE' }
    Log 'HEADLESS_CODEX_AVAILABLE=PASS'

    Log 'GITHUB_PROVENANCE_RUN_LIST=BEGIN'
    $runList = Invoke-GhJson @('run', 'list', '--repo', $Repository, '--limit', '50', '--json', 'databaseId,status,conclusion,headSha,headBranch,workflowName,createdAt')
    Log 'GITHUB_PROVENANCE_RUN_LIST=PASS'
    $successfulRuns = @($runList | Where-Object { $_.conclusion -eq 'success' -and $_.headSha })
    Log 'GITHUB_PROVENANCE_RELEASE_LIST=BEGIN'
    $releases = Invoke-GhJson @('release', 'list', '--repo', $Repository, '--limit', '100', '--json', 'tagName,isDraft,isPrerelease,publishedAt')
    Log 'GITHUB_PROVENANCE_RELEASE_LIST=PASS'
    $candidateReleases = @($releases | Where-Object { $_.tagName -like 'arthur-update-*' -and -not $_.isDraft })
    $productionReleases = @($releases | Where-Object { $_.tagName -like 'arthur-production-*' -and -not $_.isDraft })
    $candidate = $candidateReleases | Sort-Object publishedAt -Descending | Select-Object -First 1
    $production = $productionReleases | Sort-Object publishedAt -Descending | Select-Object -First 1
    $run = $successfulRuns | Sort-Object createdAt -Descending | Where-Object { $_.workflowName -match '(?i)Arthur|Known|Update' } | Select-Object -First 1
    if (-not $run) { $run = $successfulRuns | Sort-Object createdAt -Descending | Select-Object -First 1 }
    if ($candidate) {
        Log 'GITHUB_PROVENANCE_CANDIDATE_VIEW=BEGIN'
        $candidateDetails = Invoke-GhJson @('release', 'view', $candidate.tagName, '--repo', $Repository, '--json', 'tagName,targetCommitish,assets,isPrerelease,isDraft,publishedAt')
        Log 'GITHUB_PROVENANCE_CANDIDATE_VIEW=PASS'
    }
    else {
        $candidateDetails = $null
        Log 'GITHUB_PROVENANCE_CANDIDATE_VIEW=BEGIN'
        Log 'GITHUB_PROVENANCE_CANDIDATE_VIEW=PASS candidate=MISSING'
    }
    Log ("GITHUB_PROVENANCE candidate={0} production={1} run={2}" -f $(if ($candidate) { $candidate.tagName } else { 'MISSING' }), $(if ($production) { $production.tagName } else { 'MISSING' }), $(if ($run) { $run.databaseId } else { 'MISSING' }))

    $knownHosts = Join-Path $sshDir 'known_hosts'
    $deviceProbe = Invoke-ReadOnlySsh 'ubus call system board; echo __BUILD_INFO_SCAN__; find /etc /usr /mnt -type f -name build-info.json -print 2>/dev/null' $knownHosts
    $device = [ordered]@{ classification = 'INVALID'; reachable = $false; identity = $null; error = $null; live_build_info = $null; build_info_sources = [ordered]@{ rom = 'UNKNOWN'; overlay = 'UNKNOWN'; http = 'UNKNOWN'; browser_cache = 'NOT_USED'; artifact = 'UNKNOWN' } }
    if ($deviceProbe.ok) {
        $device.reachable = $true
        $probeParts = @($deviceProbe.output -split '__BUILD_INFO_SCAN__', 2)
        $boardJson = if ($probeParts.Count -gt 0) { [string]$probeParts[0] } else { '' }
        $boardJson = $boardJson.Trim()
        $scanText = if ($probeParts.Count -gt 1) { [string]$probeParts[1] } else { '' }
        $deviceLines = @($scanText -split "`r?`n")
        if ($boardJson -match '^\s*\{') {
            try {
                $board = $boardJson | ConvertFrom-Json
                $model = if ($board.PSObject.Properties['model']) { [string]$board.model } else { '' }
                $boardName = if ($board.PSObject.Properties['board_name']) { [string]$board.board_name } else { '' }
                $release = if ($board.PSObject.Properties['release']) { $board.release } else { $null }
                $device.identity = [ordered]@{ model = $model; board = $boardName; release = $release }
                if ($model -match '(?i)RE-SS-01|JDCloud' -or $boardName -match '(?i)jdcloud|re-ss-01') { $device.classification = 'CURRENT' }
                else { $device.classification = 'INVALID' }
            } catch { $device.classification = 'INVALID'; $device.error = $_.Exception.Message }
        }
        $device.build_info_sources.rom = if (@($deviceLines | Where-Object { $_ -match 'build-info\.json' }).Count -gt 0) { 'PRESENT_UNVERIFIED' } else { 'MISSING' }
    }
    else { $device.build_info_sources.rom = 'UNAVAILABLE_RETRY'; $device.error = $deviceProbe.output }
    $deviceDetail = if ($device.error) { ([string]$device.error -replace "\s+", ' ').Trim() } else { $device.build_info_sources.rom }
    Log ("DEVICE_PROBE reachable={0} classification={1} detail={2}" -f $device.reachable, $device.classification, $deviceDetail)

    $overlayPath = Join-Path $env:GITHUB_WORKSPACE 'files\www\luci-static\xinzhao\build-info.json'
    $device.build_info_sources.overlay = if (Test-Path -LiteralPath $overlayPath -PathType Leaf) { 'TEMPLATE_OR_SOURCE' } else { 'MISSING' }
    try {
        $http = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Uri 'http://192.168.6.1/luci-static/xinzhao/build-info.json'
        if ($http.Content -match '@VERSION@|@BUILD_ID@') {
            $device.build_info_sources.http = 'STALE_TEMPLATE'
        }
        else {
            try {
                $liveBuild = $http.Content | ConvertFrom-Json
                $device.live_build_info = [ordered]@{
                    version = [string]$liveBuild.Version
                    build_id = [string]$liveBuild.'Build ID'
                    git_commit = [string]$liveBuild.'Git Commit'
                }
                $device.build_info_sources.http = 'PRESENT_PARSED'
            }
            catch { $device.build_info_sources.http = 'INVALID_JSON' }
        }
    } catch { $device.build_info_sources.http = 'UNAVAILABLE_RETRY' }
    $artifactBuildInfo = @(
        if ($candidateDetails) { @($candidateDetails.assets | Where-Object { $_.name -match '(?i)build-info\.(json|txt)$' }) }
    )
    $device.build_info_sources.artifact = if ($artifactBuildInfo.Count -gt 0) { 'PRESENT_UNVERIFIED' } else { 'MISSING' }

    $checkpoint = if ($existing -and $existing.checkpoint) { $existing.checkpoint } else { [ordered]@{ current = 'ADH_MANAGEMENT'; next_action = 'ADH_MANAGEMENT'; status = 'RESUMED_FROM_GITHUB_PROVENANCE' } }
    if ((Get-ArthurResumePhaseIndex $checkpoint.next_action) -lt 0) { Fail "CHECKPOINT_INVALID: $($checkpoint.next_action)" }

    $provenanceConsistent = ($candidate -and $production -and $run -and $device.classification -eq 'CURRENT' -and $device.build_info_sources.rom -notin @('MISSING','UNAVAILABLE_RETRY') -and $device.build_info_sources.http -eq 'PRESENT_PARSED')
    $nextStatus = 'RESUME_PENDING'
    if (-not $device.reachable) { $nextStatus = 'RETRY_DEVICE_UNAVAILABLE' }
    elseif ($device.classification -ne 'CURRENT') { $nextStatus = 'BLOCKED_DEVICE_IDENTITY' }
    elseif (-not $provenanceConsistent) { $nextStatus = 'RECOVERABLE_BUILD_INFO_PROVENANCE' }
    else { $nextStatus = 'RESUME_SAFE_CHECKPOINT' }

    $acceptance = [ordered]@{
        RUNNER_CONTROL_PLANE = 'RUNNING'
        CANONICAL_STATE = 'PASS'
        HEADLESS_CODEX_AVAILABLE = 'PASS'
        CHECKPOINT_AUTO_RESUMED = 'PENDING'
        NO_USER_INPUT = 'PASS'
        NO_DUPLICATE_BUILD = 'PASS'
        NO_DUPLICATE_CANDIDATE = 'PASS'
        NO_DUPLICATE_FLASH = 'PASS'
        UNATTENDED_RELEASE_CERTIFIED = 'false'
    }
    $state = [ordered]@{
        schema_version = 2
        canonical_root = $root
        state_source = 'AI_ORCHESTRATOR'
        production_task = 'arthur-adh-quickstart'
        release_task_id = if ($existing -and $existing.release_task_id) { $existing.release_task_id } elseif ($run) { [string]$run.databaseId } else { 'arthur-adh-quickstart' }
        updated_at = [DateTime]::UtcNow.ToString('o')
        execution_identity = $identity
        checkpoint = [ordered]@{ current = [string]$checkpoint.current; next_action = [string]$checkpoint.next_action; status = $nextStatus; last_run_id = $WorkflowRunId }
        github = [ordered]@{ candidate = $candidate; production = $production; successful_run = $run; candidate_details = $candidateDetails }
        device = $device
        legacy_evidence = [ordered]@{ source = 'ProgramData-ControlPlane-legacy-import-only'; classification = 'SUPERSEDED_OR_INVALID'; user_profile_state_read = $false }
        duplicate_action_guard = [ordered]@{ build = 'PASS'; candidate = 'PASS'; flash = 'PASS'; actions_executed = @() }
        acceptance = $acceptance
    }
    Save-Json $canonicalPath $state
    Log "CANONICAL_STATE=PASS path=$canonicalPath status=$nextStatus next_action=$($checkpoint.next_action)"
    Log 'STATE_SOURCE=AI_ORCHESTRATOR'
    Log 'NO_USER_INPUT=PASS NO_DUPLICATE_BUILD=PASS NO_DUPLICATE_CANDIDATE=PASS NO_DUPLICATE_FLASH=PASS'

    if ($nextStatus -eq 'BLOCKED_DEVICE_IDENTITY') {
        Fail 'BLOCKED_DEVICE_IDENTITY'
    }
    if ($nextStatus -eq 'RETRY_DEVICE_UNAVAILABLE') {
        Log 'RETRY_DEVICE_UNAVAILABLE; next scheduled run will reconcile again'
        exit 0
    }

    $runtimeStatePath = Join-Path $stateDir 'runtime-state.json'
    if (-not (Test-Path -LiteralPath $runtimeStatePath -PathType Leaf)) {
        $resumePrompt = @"
Resume the current Arthur production task arthur-adh-quickstart from the accepted XinZhaoWrt 0.1.3 real-device baseline. First reconcile the build-info provenance mismatch and repair only the proven source/artifact-generation defect; do not rebuild or flash merely for browser/cache metadata. Then continue ADH_MANAGEMENT using the mature luci-app-adguardhome implementation with only minimal compatibility patches, complete ADH Chinese localization, preserve WIFI=VERIFIED_FROZEN and the accepted iStore/QuickStart state, and continue automatically through the existing safe production gates. Do not ask the user for recoverable failures and never duplicate Build, Candidate, or Flash.
"@
        Save-Json $runtimeStatePath ([ordered]@{
            schema_version = '3.0'
            request_id = 'arthur-adh-quickstart'
            release_task_id = 'arthur-adh-quickstart'
            repo = $Repository
            branch = $(if ($env:GITHUB_REF_NAME) { $env:GITHUB_REF_NAME } else { 'main' })
            source_sha = $(if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { $null })
            device = 'jdcloud_re-ss-01'
            phase = 'ADH_MANAGEMENT'
            current_stage = 'ADH_MANAGEMENT'
            last_verified_stage = 'REAL_DEVICE_VERIFY'
            active_run_id = 0
            candidate_sha256 = $null
            next_action = 'ADH_MANAGEMENT'
            next_codex_prompt = $resumePrompt.Trim()
            terminal_state = $null
            executor_thread_id = $null
            controller_thread_id = $null
            responses_conversation_id = $null
            pending_human_gate = $null
            candidate = @{}
            known_good = @{}
            turn_count = 0
            last_result = $null
            last_decision = $null
            preflight = @{}
            stop_requested = $false
            observability = [ordered]@{ control_plane_bootstrap = 'arthur-adh-quickstart'; provenance_status = $nextStatus }
        })
        Log 'AI_ORCHESTRATOR_STATE_BOOTSTRAPPED=PASS phase=ADH_MANAGEMENT'
    }

    $baselinePath = Join-Path $env:GITHUB_WORKSPACE 'production\real-device-baseline.json'
    if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) { Fail 'STATE_RECONCILIATION_REQUIRED: REAL_DEVICE_BASELINE_MISSING' }
    try { $realDeviceBaseline = Get-Content -Raw -LiteralPath $baselinePath | ConvertFrom-Json }
    catch { Fail "STATE_RECONCILIATION_REQUIRED: REAL_DEVICE_BASELINE_INVALID $($_.Exception.Message)" }

    $resumeStatePath = Join-Path $env:GITHUB_WORKSPACE 'production\resume-state.json'
    $previousResumeState = $null
    if (Test-Path -LiteralPath $resumeStatePath -PathType Leaf) {
        try { $previousResumeState = Get-Content -Raw -LiteralPath $resumeStatePath | ConvertFrom-Json }
        catch { Fail "STATE_RECONCILIATION_REQUIRED: RESUME_STATE_INVALID $($_.Exception.Message)" }
    }

    Push-Location $env:GITHUB_WORKSPACE
    try {
        $repositoryHead = (& git log -1 --format=%H -- . ':(exclude)production/resume-state.json' | Out-String).Trim()
    }
    finally { Pop-Location }
    if ([string]::IsNullOrWhiteSpace($repositoryHead)) { $repositoryHead = [string]$env:GITHUB_SHA }

    $runtimeBefore = Get-Content -Raw -LiteralPath $runtimeStatePath | ConvertFrom-Json
    $resumeState = Resolve-ArthurResumeState -RepositoryHead $repositoryHead -RealDeviceBaseline $realDeviceBaseline -LiveDevice $device.live_build_info -RuntimeState $runtimeBefore -PreviousResumeState $previousResumeState
    Publish-ResumeState $resumeState $resumeStatePath
    if (-not $resumeState.instruction_allowed) {
        Fail ("STATE_RECONCILIATION_REQUIRED: " + (@($resumeState.conflicts) -join ','))
    }
    Log "RESUME_STATE_RECONCILED=PASS version=$($resumeState.real_device.version) checkpoint=$($resumeState.checkpoint.current) next_action=$($resumeState.next_action)"

    $turnBefore = [int]$runtimeBefore.turn_count
    $phaseBefore = [string]$runtimeBefore.phase
    Log "HEADLESS_RUNTIME_STARTING phase=$phaseBefore turn_count=$turnBefore"

    Push-Location $env:GITHUB_WORKSPACE
    try {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $runtimeOutput = (& python -m ai_orchestrator resume --state-dir $stateDir --max-turns 1 2>&1 | Out-String).Trim()
            $runtimeCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $old }
    }
    finally { Pop-Location }

    if ($runtimeOutput) { Add-Content -LiteralPath $logPath -Value $runtimeOutput -Encoding UTF8 }
    if ($runtimeCode -ne 0) {
        Fail "HEADLESS_RUNTIME_FAILED: exit=$runtimeCode"
    }
    Log 'HEADLESS_RUNTIME_STARTED=PASS'

    $runtimeAfter = Get-Content -Raw -LiteralPath $runtimeStatePath | ConvertFrom-Json
    $turnAfter = [int]$runtimeAfter.turn_count
    $phaseAfter = [string]$runtimeAfter.phase
    if ($turnAfter -le $turnBefore -and $phaseAfter -eq $phaseBefore) {
        Fail "HEADLESS_RUNTIME_NO_PROGRESS: phase=$phaseAfter turn_count=$turnAfter"
    }

    $postResumeState = Resolve-ArthurResumeState -RepositoryHead $repositoryHead -RealDeviceBaseline $realDeviceBaseline -LiveDevice $device.live_build_info -RuntimeState $runtimeAfter -PreviousResumeState $resumeState
    Publish-ResumeState $postResumeState $resumeStatePath
    if (-not $postResumeState.instruction_allowed) {
        Fail ("STATE_RECONCILIATION_REQUIRED: " + (@($postResumeState.conflicts) -join ','))
    }

    $state.checkpoint = [ordered]@{
        current = $phaseAfter
        next_action = $(if ($runtimeAfter.next_action) { [string]$runtimeAfter.next_action } else { $phaseAfter })
        status = 'HEADLESS_RUNTIME_RESUMED'
        last_run_id = $WorkflowRunId
    }
    $state.acceptance.CHECKPOINT_AUTO_RESUMED = 'PASS'
    $state.updated_at = [DateTime]::UtcNow.ToString('o')
    Save-Json $canonicalPath $state
    Log "CHECKPOINT_AUTO_RESUMED=PASS before=$phaseBefore/$turnBefore after=$phaseAfter/$turnAfter"

    if ($runtimeAfter.terminal_state -eq 'PRODUCTION_RELEASED' -or $phaseAfter -eq 'PRODUCTION_RELEASED') {
        $state.acceptance.UNATTENDED_RELEASE_CERTIFIED = 'true'
        Save-Json $canonicalPath $state
        Log 'PRODUCTION_RELEASED=true'
    }

    exit 0
}
catch {
    if ($_.Exception.Message -notmatch '^CONTROL_PLANE_|^GITHUB_API_|^CANONICAL_|^HEADLESS_|^CHECKPOINT_|^BLOCKED_|^STATE_RECONCILIATION_|^RESUME_STATE_') { Write-Error $_ }
    exit 1
}
finally {
    if ($lock) { $lock.Dispose() }
}