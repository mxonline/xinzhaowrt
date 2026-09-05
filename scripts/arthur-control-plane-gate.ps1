[CmdletBinding()]
param(
    [string]$Repository = 'mxonline/xinzhaowrt',
    [string]$WorkflowRunId = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$intentHelperPath = Join-Path $root 'scripts\arthur-operator-intent.ps1'
$intentPath = Join-Path $root 'production\operator-intent.json'
$requestPath = Join-Path $root 'production\v3-request.json'
$resumeGatePath = Join-Path $root 'scripts\arthur-firmware-resume.ps1'
$failureRecoveryPath = Join-Path $root 'scripts\arthur-candidate-failure-recovery.ps1'
$controlPlanePath = Join-Path $root 'scripts\arthur-control-plane.ps1'

if (-not (Test-Path -LiteralPath $intentHelperPath -PathType Leaf)) {
    Write-Error 'OPERATOR_INTENT_HELPER_MISSING'
    exit 1
}
if (-not (Test-Path -LiteralPath $resumeGatePath -PathType Leaf)) {
    Write-Error 'UNIFIED_RESUME_GATE_MISSING'
    exit 1
}
if (-not (Test-Path -LiteralPath $failureRecoveryPath -PathType Leaf)) {
    Write-Error 'CANDIDATE_FAILURE_RECOVERY_HELPER_MISSING'
    exit 1
}
if (-not (Test-Path -LiteralPath $controlPlanePath -PathType Leaf)) {
    Write-Error 'CONTROL_PLANE_MISSING'
    exit 1
}

. $intentHelperPath
$operatorIntent = Read-ArthurOperatorIntent -Path $intentPath
$decision = Get-ArthurFirmwareExecutionPermission -OperatorIntent $operatorIntent

$firmwareState = $operatorIntent.firmware_state
$currentStage = if ($firmwareState) { [string]$firmwareState.current_stage } else { '' }
$nextStage = if ($firmwareState) { [string]$firmwareState.next_stage } else { '' }
Write-Host "OPERATOR_INTENT=PASS intent_type=$($decision.intent_type) scope=$($decision.authorization_scope) current_stage=$currentStage next_stage=$nextStage"

if (-not $decision.allowed) {
    Write-Host "FIRMWARE_EXECUTION_NOT_AUTHORIZED=PASS reason=$($decision.reason)"
    Write-Host 'CONTROL_PLANE_MUTATION_SKIPPED=PASS'
    exit 0
}

Write-Host 'FIRMWARE_EXECUTION_AUTHORIZED=PASS'

# The durable final-release request supersedes stale pre-build AI runtime phases.
# Migrate only forward to the existing BUILD phase; never rewrite a terminal,
# BUILD-or-later, flash, or release checkpoint. This is state reconciliation,
# not a new pipeline stage and not authorization for an extra Candidate/Flash.
if ($currentStage -eq 'BUILD' -and (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
    try { $finalRequest = Get-Content -Raw -LiteralPath $requestPath | ConvertFrom-Json }
    catch {
        Write-Error "FINAL_RELEASE_REQUEST_INVALID: $($_.Exception.Message)"
        exit 1
    }

    $requestId = [string]$finalRequest.request_id
    $requestReason = [string]$finalRequest.reason
    $isFinalRelease = (
        $requestId -like 'arthur-final-release-*' -and
        [string]$finalRequest.device -eq 'jdcloud_re-ss-01' -and
        [string]$finalRequest.feature_id -eq 'arthur-adh-quickstart' -and
        $requestReason -match '(?i)Do not repeat feature development' -and
        $requestReason -match '(?i)replacement Candidate'
    )

    if ($isFinalRelease -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $runtimeStatePath = Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\ControlPlane\state\runtime-state.json'
        if (Test-Path -LiteralPath $runtimeStatePath -PathType Leaf) {
            try { $runtimeState = Get-Content -Raw -LiteralPath $runtimeStatePath | ConvertFrom-Json }
            catch {
                Write-Error "FINAL_RELEASE_RUNTIME_STATE_INVALID: $($_.Exception.Message)"
                exit 1
            }

            $runtimePhase = [string]$runtimeState.phase
            $runtimeTerminal = [string]$runtimeState.terminal_state
            $stalePreBuildPhases = @(
                'FORENSICS',
                'ADH_MANAGEMENT',
                'ADH_CHINESE',
                'CHANGE_IMPACT',
                'BASELINE_INHERITANCE',
                'EXPECTED_DIFF',
                'CONFIG',
                'PACKAGE',
                'PLUGIN_BASELINE_22',
                'ARGON_KUCAT',
                'LAN',
                'FAST_GATE'
            )

            if ([string]::IsNullOrWhiteSpace($runtimeTerminal) -and $stalePreBuildPhases -contains $runtimePhase) {
                $resumePrompt = 'Resume the interrupted Arthur final release: forensic -> root cause -> auto-fix -> rebuild -> PRE_FLASH_READY. Preserve the accepted ADH full manager, LuCI Chinese, official iStoreOS QuickStart and WIFI=VERIFIED_FROZEN. Do not repeat feature development and do not duplicate Build, Candidate, or Flash. Continue automatically through the existing safe production gates.'

                $runtimeState.phase = 'BUILD'
                if ($runtimeState.PSObject.Properties['current_stage']) { $runtimeState.current_stage = 'BUILD' }
                else { $runtimeState | Add-Member -NotePropertyName current_stage -NotePropertyValue 'BUILD' }
                $runtimeState.next_action = 'BUILD'
                $runtimeState.next_codex_prompt = $resumePrompt
                if ($runtimeState.PSObject.Properties['pending_human_gate']) { $runtimeState.pending_human_gate = $null }
                else { $runtimeState | Add-Member -NotePropertyName pending_human_gate -NotePropertyValue $null }

                $migration = [ordered]@{
                    request_id = $requestId
                    from = $runtimePhase
                    to = 'BUILD'
                    reason = 'FINAL_RELEASE_REQUEST_SUPERSEDES_STALE_PREBUILD_RUNTIME'
                }
                if ($runtimeState.PSObject.Properties['observability'] -and $runtimeState.observability) {
                    $runtimeState.observability | Add-Member -NotePropertyName final_release_runtime_migration -NotePropertyValue $migration -Force
                }
                else {
                    $runtimeState | Add-Member -NotePropertyName observability -NotePropertyValue ([pscustomobject]@{ final_release_runtime_migration = $migration }) -Force
                }

                $tmp = "$runtimeStatePath.$PID.tmp"
                $json = $runtimeState | ConvertTo-Json -Depth 30
                [IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
                Move-Item -LiteralPath $tmp -Destination $runtimeStatePath -Force
                Write-Host "FINAL_RELEASE_RUNTIME_MIGRATION=PASS from=$runtimePhase to=BUILD request_id=$requestId"
            }
            elseif ($runtimePhase -eq 'BUILD') {
                Write-Host "FINAL_RELEASE_RUNTIME_MIGRATION=ALREADY_CURRENT phase=BUILD request_id=$requestId"
            }
            else {
                Write-Host "FINAL_RELEASE_RUNTIME_MIGRATION=SKIPPED phase=$runtimePhase terminal_state=$runtimeTerminal request_id=$requestId"
            }
        }
        else {
            Write-Host "FINAL_RELEASE_RUNTIME_MIGRATION=SKIPPED reason=RUNTIME_STATE_MISSING request_id=$requestId"
        }
    }
}

# Durable GitHub Candidate failure evidence takes precedence over legacy local
# resume-state metadata. Use this clean current-main checkout for the resolver and
# repair controller; the persistent task workspace may intentionally be dirty or
# pinned to an older task source and must not decide the current repair route.
$repairOutput = & $failureRecoveryPath -Repository $Repository -Workspace $root 2>&1 | Out-String
$repairCode = $LASTEXITCODE
if (-not [string]::IsNullOrWhiteSpace($repairOutput)) { Write-Host $repairOutput.Trim() }
if ($repairCode -ne 0) {
    Write-Error "CANDIDATE_FAILURE_RECOVERY_FAILED: exit_code=$repairCode"
    exit $repairCode
}
if ($repairOutput -match 'CANDIDATE_FAILURE_REPAIR=(STARTED|ALREADY_RUNNING)') {
    Write-Host 'CONTROL_PLANE_REPAIR_ROUTED=PASS'
    Write-Host 'CONTROL_PLANE_MUTATION_SKIPPED=PASS reason=existing_v3_repair_controller_owns_failed_candidate'
    exit 0
}

# No failed Candidate owns this wakeup. Only now evaluate the canonical Resume Gate
# for ordinary continuation/reconciliation paths.
$resumeOutput = & $resumeGatePath -Repository $Repository -AllowRepositoryHeadDriftForReconciliation 2>&1 | Out-String
$resumeCode = $LASTEXITCODE
if (-not [string]::IsNullOrWhiteSpace($resumeOutput)) { Write-Host $resumeOutput.Trim() }
if ($resumeCode -ne 0) {
    Write-Error "UNIFIED_RESUME_GATE_BLOCKED: exit_code=$resumeCode"
    exit $resumeCode
}
Write-Host 'UNIFIED_RESUME_GATE=PASS'

& $controlPlanePath -Repository $Repository -WorkflowRunId $WorkflowRunId
exit $LASTEXITCODE
