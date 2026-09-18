[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$StateDir,
    [Parameter(Mandatory=$true)][string]$ControlRoot,
    [Parameter(Mandatory=$true)][string]$Repository
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-JsonSafe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json) }
    catch { throw "FRESH_RUNTIME_SUPERSESSION_INVALID_JSON=$Path $($_.Exception.Message)" }
}

function Get-Value($Object,[string]$Name,$Default=$null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Write-JsonAtomic([string]$Path,$Value) {
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp,($Value | ConvertTo-Json -Depth 40) + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

$statePath = [IO.Path]::GetFullPath($StateDir)
$controlPath = [IO.Path]::GetFullPath($ControlRoot)
$runtimePath = Join-Path $statePath 'runtime-state.json'
$resumePath = Join-Path $controlPath 'production\resume-state.json'
$intentPath = Join-Path $controlPath 'production\operator-intent.json'
$modePath = Join-Path $controlPath 'production\release-mode.json'

$runtime = Read-JsonSafe $runtimePath
$resume = Read-JsonSafe $resumePath
$intent = Read-JsonSafe $intentPath
$releaseMode = Read-JsonSafe $modePath

if ($null -eq $runtime -or $null -eq $resume -or $null -eq $intent -or $null -eq $releaseMode) {
    Write-Host 'FRESH_EXECUTION_RUNTIME_SUPERSESSION=NOT_APPLICABLE reason=required_state_missing'
    exit 0
}

$phase = [string](Get-Value $runtime 'phase' '')
if ([string]::IsNullOrWhiteSpace($phase)) { $phase = [string](Get-Value $runtime 'current_stage' '') }
$humanGate = ''
foreach ($gateName in @('human_gate','humanGate','pending_human_gate','pendingHumanGate')) {
    $candidate = [string](Get-Value $runtime $gateName '')
    if (-not [string]::IsNullOrWhiteSpace($candidate)) { $humanGate = $candidate; break }
}

$executionId = ([string](Get-Value $resume 'execution_id' '')).Trim()
$intentExecutionId = ([string](Get-Value $intent 'execution_id' '')).Trim()
$runtimeTaskId = ([string](Get-Value $runtime 'release_task_id' '')).Trim()
$runtimeRequestId = ([string](Get-Value $runtime 'request_id' '')).Trim()
$runtimeSource = ([string](Get-Value $runtime 'source_sha' '')).Trim().ToLowerInvariant()
$acceptedSource = ''
if ($resume.PSObject.Properties['source'] -and $resume.source) {
    $acceptedSource = ([string](Get-Value $resume.source 'accepted_source_sha' '')).Trim().ToLowerInvariant()
}
$productionRun = 0L
$artifactId = 0L
if ($resume.PSObject.Properties['production'] -and $resume.production) {
    [void][long]::TryParse([string](Get-Value $resume.production 'github_run_id' '0'),[ref]$productionRun)
    [void][long]::TryParse([string](Get-Value $resume.production 'artifact_id' '0'),[ref]$artifactId)
}

$authorizationSafe = (
    [string](Get-Value $intent 'intent_type' '') -eq 'EXECUTE_FIRMWARE' -and
    [string](Get-Value $intent 'authorization_scope' '') -eq 'FIRMWARE_RELEASE' -and
    (Get-Value $intent 'firmware_execution_authorized' $false) -eq $true -and
    [string](Get-Value $intent 'release_mode' '') -eq 'RELEASE_ONLY' -and
    (Get-Value $intent 'device_write_authorized' $true) -eq $false -and
    [string](Get-Value $releaseMode 'mode' '') -eq 'RELEASE_ONLY' -and
    (Get-Value $releaseMode 'automatic_flash' $true) -eq $false -and
    $intent.PSObject.Properties['guardrails'] -and
    $intent.guardrails -and
    (Get-Value $intent.guardrails 'release_only' $false) -eq $true -and
    (Get-Value $intent.guardrails 'automatic_flash' $true) -eq $false -and
    (Get-Value $intent.guardrails 'sysupgrade_forbidden' $false) -eq $true
)

$freshResume = (
    -not [string]::IsNullOrWhiteSpace($executionId) -and
    $executionId -eq $intentExecutionId -and
    [string](Get-Value $resume 'status' '') -eq 'RESUME_SAFE' -and
    (Get-Value $resume 'instruction_allowed' $false) -eq $true -and
    [string](Get-Value $resume 'current_gate' '') -eq 'CHANGE_IMPACT' -and
    [string](Get-Value $resume 'next_action' '') -eq 'CHANGE_IMPACT' -and
    $productionRun -eq 0 -and
    $artifactId -eq 0
)

$runtimeBelongsToFreshExecution = (
    $runtimeTaskId -eq $executionId -or
    $runtimeRequestId -eq $executionId
)
$runtimeSourceMatchesFresh = (
    -not [string]::IsNullOrWhiteSpace($runtimeSource) -and
    -not [string]::IsNullOrWhiteSpace($acceptedSource) -and
    $runtimeSource -eq $acceptedSource
)

$eligible = (
    $authorizationSafe -and
    $freshResume -and
    $phase -eq 'ARTIFACT' -and
    [string]::IsNullOrWhiteSpace($humanGate) -and
    -not $runtimeBelongsToFreshExecution -and
    -not $runtimeSourceMatchesFresh
)

if (-not $eligible) {
    Write-Host "FRESH_EXECUTION_RUNTIME_SUPERSESSION=NOT_APPLICABLE phase=$phase execution=$executionId runtime_task=$runtimeTaskId"
    exit 0
}

# This is a local executor handoff only. It never touches the router, never runs
# sysupgrade, and never changes production/known-good.json.
if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $command = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($command)) { continue }
        if ($command.IndexOf($statePath,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($command -match '(?i)run-supervisor\.py' -or ($command -match '(?i)ai_orchestrator' -and $command -match '(?i)\bresume\b')) {
            try {
                Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
                Write-Host "FRESH_RUNTIME_OLD_PROCESS_STOPPED=PASS pid=$($process.ProcessId)"
            }
            catch {
                throw "FRESH_RUNTIME_OLD_PROCESS_STOP_FAILED pid=$($process.ProcessId) $($_.Exception.Message)"
            }
        }
    }
}

$taskName = 'XinZhaoWrt-Arthur-Persistent-Supervisor'
if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task -and [string]$task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
        Write-Host "FRESH_RUNTIME_OLD_TASK_STOPPED=PASS task=$taskName"
    }
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$archiveRoot = Join-Path $statePath (Join-Path 'superseded-runtime' $stamp)
New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
foreach ($name in @(
    'runtime-state.json',
    'runtime-status.json',
    'supervisor-status.json',
    'supervisor-state.json',
    'repair-status.json',
    'supervisor.lock',
    'executor-lease.json',
    'approval.json',
    'STOP',
    'events.jsonl'
)) {
    $source = Join-Path $statePath $name
    if (Test-Path -LiteralPath $source) {
        Move-Item -LiteralPath $source -Destination (Join-Path $archiveRoot $name) -Force
    }
}

$prompt = @"
Continue the authorized Arthur $($resume.release) RELEASE_ONLY production execution $executionId from CHANGE_IMPACT. Use GitHub durable state as authority. Preserve WIFI, LuCI Simplified Chinese, official iStoreOS QuickStart, the 22 mandatory LuCI plugins, and target qualcommax/ipq60xx/jdcloud_re-ss-01. Continue CHANGE_IMPACT -> BASELINE_INHERITANCE -> EXPECTED_DIFF -> BUILD -> ARTIFACT -> RELEASE_GATE -> RELEASE -> PRODUCTION_RELEASED. Do not flash, do not run sysupgrade, do not write the router, and do not promote known-good before the independent post-release device test.
"@.Trim()

$newRuntime = [ordered]@{
    schema_version = '3.0'
    request_id = $executionId
    release_task_id = $executionId
    repo = $Repository
    branch = 'main'
    source_sha = $acceptedSource
    device = 'jdcloud_re-ss-01'
    phase = 'CHANGE_IMPACT'
    current_stage = 'CHANGE_IMPACT'
    last_verified_stage = 'FRESH_EXECUTION_BOOTSTRAP'
    active_run_id = 0
    candidate_sha256 = $null
    next_action = 'CHANGE_IMPACT'
    next_codex_prompt = $prompt
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
    observability = [ordered]@{
        fresh_execution_runtime_supersession = [ordered]@{
            previous_phase = $phase
            previous_release_task_id = $runtimeTaskId
            previous_request_id = $runtimeRequestId
            previous_source_sha = $runtimeSource
            execution_id = $executionId
            accepted_source_sha = $acceptedSource
            archive = $archiveRoot
            release_only = $true
            automatic_flash = $false
            device_write_authorized = $false
        }
    }
}
Write-JsonAtomic -Path $runtimePath -Value $newRuntime

Write-Host "FRESH_EXECUTION_RUNTIME_SUPERSESSION=APPLIED execution=$executionId from_phase=$phase to_phase=CHANGE_IMPACT archive=$archiveRoot"
exit 0
