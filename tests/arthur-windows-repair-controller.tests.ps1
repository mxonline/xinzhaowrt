$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Controller = Join-Path $Root 'scripts\arthur-windows-repair-controller.ps1'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}
function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ([string]$Actual -ne [string]$Expected) {
        throw "TEST_FAIL: $Message expected='$Expected' actual='$Actual'"
    }
}
function Assert-NotContains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "TEST_FAIL: $Message (unexpected '$Needle')"
    }
}
function Assert-ThrowsContains {
    param([scriptblock]$Action,[string]$Needle,[string]$Message)
    try {
        & $Action
    }
    catch {
        if ([string]$_.Exception.Message -like "*$Needle*") { return }
        throw "TEST_FAIL: $Message wrong error='$($_.Exception.Message)'"
    }
    throw "TEST_FAIL: $Message expected error containing '$Needle'"
}

Assert-True (Test-Path -LiteralPath $Controller -PathType Leaf) 'Arthur Windows Repair Controller must exist'

$source = Get-Content -Raw -LiteralPath $Controller
Assert-NotContains $source 'sysupgrade' 'repair controller must never invoke device flashing'
Assert-NotContains $source 'workflow run arthur-update' 'repair controller must never dispatch firmware build workflows'
Assert-NotContains $source 'git reset --hard' 'repair controller must never hard-reset a repository'
Assert-NotContains $source 'git clean' 'repair controller must never clean a repository'
Assert-NotContains $source 'git stash' 'repair controller must never stash mutable task work'
Assert-NotContains $source 'Remove-Item $runtimeState' 'repair controller must never delete runtime-state.json'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('arthur-repair-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $env:ARTHUR_REPAIR_CONTROLLER_IMPORT_ONLY = '1'
    . $Controller -StateDir $tmp -ControlRoot $Root -HeadlessPythonExe ([Diagnostics.Process]::GetCurrentProcess().Path)

    $evidenceStale = [pscustomobject]@{
        protected = $false
        git = [pscustomobject]@{ dirty = $false; relation = 'BEHIND'; head = 'a'; origin_main = 'b' }
        task = [pscustomobject]@{ launcher_drift = $false }
        probe = [pscustomobject]@{ exit_class = 'PROBE_OK'; module_root_ok = $true; model_binding_ok = $true; account_preflight_ok = $true; model_catalog_skipped = $true }
        supervisor = [pscustomobject]@{ status = 'HEALTHY' }
    }
    $evidenceDirty = [pscustomobject]@{
        protected = $false
        git = [pscustomobject]@{ dirty = $true; relation = 'BEHIND'; head = 'a'; origin_main = 'b' }
        task = [pscustomobject]@{ launcher_drift = $false }
        probe = [pscustomobject]@{ exit_class = 'PROBE_OK'; module_root_ok = $true; model_binding_ok = $true; account_preflight_ok = $true; model_catalog_skipped = $true }
        supervisor = [pscustomobject]@{ status = 'HEALTHY' }
    }
    $evidenceModuleDrift = [pscustomobject]@{
        protected = $false
        git = [pscustomobject]@{ dirty = $false; relation = 'SAME'; head = 'b'; origin_main = 'b' }
        task = [pscustomobject]@{ launcher_drift = $false }
        probe = [pscustomobject]@{ exit_class = 'MODULE_ROOT_DRIFT'; module_root_ok = $false; model_binding_ok = $true; account_preflight_ok = $true; model_catalog_skipped = $true }
        supervisor = [pscustomobject]@{ status = 'RECOVERING' }
    }
    $evidenceModelDrift = [pscustomobject]@{
        protected = $false
        git = [pscustomobject]@{ dirty = $false; relation = 'SAME'; head = 'b'; origin_main = 'b' }
        task = [pscustomobject]@{ launcher_drift = $false }
        probe = [pscustomobject]@{ exit_class = 'MODEL_BINDING_DRIFT'; module_root_ok = $true; model_binding_ok = $false; account_preflight_ok = $true; model_catalog_skipped = $true }
        supervisor = [pscustomobject]@{ status = 'RECOVERING' }
    }
    $evidenceRetryExhausted = [pscustomobject]@{
        protected = $false
        git = [pscustomobject]@{ dirty = $false; relation = 'SAME'; head = 'b'; origin_main = 'b' }
        task = [pscustomobject]@{ launcher_drift = $false }
        probe = [pscustomobject]@{ exit_class = 'PROBE_OK'; module_root_ok = $true; model_binding_ok = $true; account_preflight_ok = $true; model_catalog_skipped = $true }
        supervisor = [pscustomobject]@{ status = 'CRASH_LOOP_BLOCKED' }
    }
    $evidenceUnknown = [pscustomobject]@{
        protected = $false
        git = [pscustomobject]@{ dirty = $false; relation = 'SAME'; head = 'b'; origin_main = 'b' }
        task = [pscustomobject]@{ launcher_drift = $false }
        probe = [pscustomobject]@{ exit_class = 'PROBE_OK'; module_root_ok = $true; model_binding_ok = $true; account_preflight_ok = $true; model_catalog_skipped = $true }
        supervisor = [pscustomobject]@{ status = 'HEALTHY' }
    }

    Assert-Equal (Get-ArthurRepairFailureClass $evidenceStale) 'CONTROL_RUNTIME_STALE' 'clean behind control-runtime must classify as stale'
    Assert-Equal (Get-ArthurRepairFailureClass $evidenceDirty) 'REPAIR_BLOCKED_DIRTY_CONTROL_RUNTIME' 'dirty control-runtime must fail closed'
    Assert-Equal (Get-ArthurRepairFailureClass $evidenceModuleDrift) 'MODULE_ROOT_DRIFT' 'probe module root outside control-runtime must be explicit'
    Assert-Equal (Get-ArthurRepairFailureClass $evidenceModelDrift) 'MODEL_BINDING_DRIFT' 'probe model mismatch must be explicit'
    Assert-Equal (Get-ArthurRepairFailureClass $evidenceRetryExhausted) 'SUPERVISOR_RETRY_EXHAUSTED' 'healthy probe plus crash-loop block may reset only retry state'
    Assert-Equal (Get-ArthurRepairFailureClass $evidenceUnknown) 'UNKNOWN_FAILURE' 'unknown conditions must not mutate'

    Assert-Equal (Get-ArthurApprovedRepairAction 'CONTROL_RUNTIME_STALE') 'FAST_FORWARD_CONTROL_RUNTIME' 'stale clean control code has one repair'
    Assert-Equal (Get-ArthurApprovedRepairAction 'TASK_LAUNCHER_DRIFT') 'REREGISTER_SUPERVISOR_TASK' 'task drift reuses canonical task name'
    Assert-Equal (Get-ArthurApprovedRepairAction 'MODULE_ROOT_DRIFT') 'REGENERATE_CANONICAL_LAUNCHER' 'module drift repairs launcher only'
    Assert-Equal (Get-ArthurApprovedRepairAction 'MODEL_BINDING_DRIFT') 'BIND_EXPLICIT_MODEL' 'model drift binds approved model only'
    Assert-Equal (Get-ArthurApprovedRepairAction 'SUPERVISOR_RETRY_EXHAUSTED') 'RESET_SUPERVISOR_RETRY_STATE' 'retry reset is allowed only after probe pass'
    Assert-Equal (Get-ArthurApprovedRepairAction 'UNKNOWN_FAILURE') $null 'unknown failure has no repair action'

    $flashState = [pscustomobject]@{ phase = 'FLASH'; human_gate = $null; pending_human_gate = $null }
    $humanGateState = [pscustomobject]@{ phase = 'BUILD'; human_gate = 'MANUAL_APPROVAL_REQUIRED'; pending_human_gate = $null }
    $pendingGateState = [pscustomobject]@{ phase = 'BUILD'; human_gate = $null; pending_human_gate = 'REAL_DEVICE_CONFIRMATION' }
    $buildState = [pscustomobject]@{ phase = 'BUILD'; human_gate = $null; pending_human_gate = $null }
    Assert-True (Test-ArthurRepairProtectedState $flashState) 'FLASH must always be repair-protected'
    Assert-True (Test-ArthurRepairProtectedState $humanGateState) 'human safety gate must always be repair-protected'
    Assert-True (Test-ArthurRepairProtectedState $pendingGateState) 'pending human safety gate must always be repair-protected'
    Assert-True (-not (Test-ArthurRepairProtectedState $buildState)) 'BUILD without human gate must remain repairable'

    $state = [pscustomobject]@{
        release_task_id = 'arthur-final'
        repo = 'mxonline/xinzhaowrt'
        branch = 'main'
        source_sha = 'abc123'
        request_id = 'req-1'
        phase = 'BUILD'
        candidate_sha256 = $null
        pending_human_gate = $null
    }
    $identity = Get-ArthurRuntimeStateIdentity $state
    Assert-Equal $identity.release_task_id 'arthur-final' 'runtime identity must include release task id'
    Assert-Equal $identity.phase 'BUILD' 'runtime identity must include phase'
    Assert-True (Test-ArthurRuntimeStateIdentity $identity $identity) 'identical runtime identities must match'

    $statePath = Join-Path $tmp 'runtime-state.json'
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8
    $different = [pscustomobject]@{
        release_task_id = 'arthur-final'
        repo = 'mxonline/xinzhaowrt'
        branch = 'main'
        source_sha = 'different-sha'
        request_id = 'req-1'
        phase = 'BUILD'
        candidate_sha256 = $null
        pending_human_gate = $null
    }
    $different | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8
    Assert-ThrowsContains {
        Invoke-ArthurApprovedRepair -Action 'BIND_EXPLICIT_MODEL' -Evidence $evidenceModelDrift -ExpectedIdentity $identity -StatePath $tmp -Root $Root -PythonExe ([Diagnostics.Process]::GetCurrentProcess().Path) -TaskName 'test-supervisor'
    } 'REPAIR_BLOCKED_RUNTIME_STATE_CHANGED' 'repair must refuse changed runtime identity'

    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8
    $protectedEvidence = [pscustomobject]@{
        protected = $true
        git = [pscustomobject]@{ dirty = $false; relation = 'SAME'; head = 'b'; origin_main = 'b' }
        task = [pscustomobject]@{ launcher_drift = $false }
        probe = $evidenceModelDrift.probe
        supervisor = [pscustomobject]@{ status = 'RECOVERING' }
    }
    Assert-ThrowsContains {
        Invoke-ArthurApprovedRepair -Action 'BIND_EXPLICIT_MODEL' -Evidence $protectedEvidence -ExpectedIdentity $identity -StatePath $tmp -Root $Root -PythonExe ([Diagnostics.Process]::GetCurrentProcess().Path) -TaskName 'test-supervisor'
    } 'REPAIR_BLOCKED_SAFETY' 'repair must refuse protected state'

    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8
    Assert-ThrowsContains {
        Invoke-ArthurApprovedRepair -Action 'BIND_EXPLICIT_MODEL' -Evidence $evidenceDirty -ExpectedIdentity $identity -StatePath $tmp -Root $Root -PythonExe ([Diagnostics.Process]::GetCurrentProcess().Path) -TaskName 'test-supervisor'
    } 'REPAIR_BLOCKED_DIRTY_CONTROL_RUNTIME' 'repair must refuse dirty control-runtime evidence'

    $fingerprint1 = Get-ArthurFailureFingerprint $evidenceModuleDrift
    $fingerprint2 = Get-ArthurFailureFingerprint $evidenceModuleDrift
    Assert-True (-not [string]::IsNullOrWhiteSpace($fingerprint1)) 'failure fingerprint must be non-empty'
    Assert-Equal $fingerprint1 $fingerprint2 'failure fingerprint must be deterministic'

    Write-Host 'ARTHUR_WINDOWS_REPAIR_CONTROLLER_DIAGNOSTIC_CONTRACT=PASS'
    Write-Host 'ARTHUR_WINDOWS_REPAIR_CONTROLLER_WHITELIST_CONTRACT=PASS'
    Write-Host 'ARTHUR_WINDOWS_REPAIR_CONTROLLER_SAFETY_BOUNDARY=PASS'
}
finally {
    Remove-Item Env:ARTHUR_REPAIR_CONTROLLER_IMPORT_ONLY -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
