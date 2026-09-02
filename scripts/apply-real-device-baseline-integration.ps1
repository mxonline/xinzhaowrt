$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $Root

$agentPath = 'scripts/production-agent.ps1'
$agent = Get-Content -Raw $agentPath

$anchor = @'
$Config = Get-Content -Raw $ConfigPath | ConvertFrom-Json
$Out = Join-Path $Root 'output\production-agent'
'@
$replacement = @'
$Config = Get-Content -Raw $ConfigPath | ConvertFrom-Json
$RealDeviceBaselineDefault = 'production\real-device-baseline.json'
$ExpectedDiffDefault = 'production\expected-diff.json'
$RealDeviceBaselineRelative = if ([string]$Config.real_device_baseline) { [string]$Config.real_device_baseline } else { $RealDeviceBaselineDefault }
$ExpectedDiffRelative = if ([string]$Config.expected_diff) { [string]$Config.expected_diff } else { $ExpectedDiffDefault }
$RealDeviceBaselinePath = Join-Path $Root $RealDeviceBaselineRelative
$ExpectedDiffPath = Join-Path $Root $ExpectedDiffRelative
$SnapshotPath = Join-Path $Root 'output\real-device\real-device-snapshot.json'
. (Join-Path $PSScriptRoot 'real-device-baseline-lib.ps1')
$Out = Join-Path $Root 'output\production-agent'
'@
if (-not $agent.Contains($anchor)) { throw 'agent config anchor missing' }
$agent = $agent.Replace($anchor,$replacement)

$stageAnchor = @'
    'CANDIDATE_VERIFIED',
    'AUTO_FLASH_SAFETY_GATE',
'@
$stageReplacement = @'
    'CANDIDATE_VERIFIED',
    'REAL_DEVICE_BASELINE_GATE',
    'AUTO_FLASH_SAFETY_GATE',
'@
if (-not $agent.Contains($stageAnchor)) { throw 'agent stage anchor missing' }
$agent = $agent.Replace($stageAnchor,$stageReplacement)

$stateAnchor = "        remote_candidate=''; target=''; last_error=''; human_gate=`$null; repair_controller_started=`$false;"
$stateReplacement = "        remote_candidate=''; target=''; last_error=''; human_gate=`$null; repair_controller_started=`$false; replacement_build_requested=`$false;"
if (-not $agent.Contains($stateAnchor)) { throw 'agent state anchor missing' }
$agent = $agent.Replace($stateAnchor,$stateReplacement)

$deviceFunction = @'
function Get-DeviceTarget($State) {
    $diagnostics = New-Object System.Collections.Generic.List[string]
    $sawAuthFailure = $false
    foreach ($ip in @($Config.recovery_addresses)) {
        $target = "root@$ip"
        $probe = Invoke-Process 'ssh.exe' @('-o','BatchMode=yes','-o','ConnectTimeout=5',$target,'ubus call system board') -AllowFailure
        $probeText = [string]$probe.Output
        $class = Classify-ArthurSshProbe -ExitCode $probe.ExitCode -Output $probeText

        if ($class -eq 'DEVICE_VERIFIED') {
            $State.human_gate = $null
            $State.target = $target
            Save-State $State ([string]$State.stage) 'LIVE'
            return $target
        }

        if ($class -in @('DEVICE_IDENTITY_MISMATCH','SSH_HOST_IDENTITY_MISMATCH')) {
            $State.human_gate = $class
            Save-State $State ([string]$State.stage) 'BLOCKED' "$class for $ip. Probe: $probeText"
            throw $class
        }

        if ($class -eq 'SSH_AUTH_FAILED') { $sawAuthFailure = $true }
        $compact = ($probeText -replace '\s+',' ').Trim()
        if ($compact.Length -gt 300) { $compact = $compact.Substring(0,300) }
        $diagnostics.Add("$ip class=$class exit=$($probe.ExitCode) $compact")
        Log "DEVICE_PROBE_RETRY ip=$ip class=$class exit=$($probe.ExitCode) detail=$compact"
    }

    $State.human_gate = $null
    $summary = ($diagnostics -join ' | ')
    $classification = if ($sawAuthFailure) { 'SSH_AUTH_FAILED' } else { 'DEVICE_UNREACHABLE' }
    Save-State $State ([string]$State.stage) 'RETRYING' "${classification}: Arthur is not safely reachable yet. $summary"
    Log "DEVICE_IDENTITY_RETRYABLE class=$classification; unattended recovery will retry without entering the write path."
    # Classify-ArthurSshProbe treats REMOTE HOST IDENTIFICATION HAS CHANGED as SSH_HOST_IDENTITY_MISMATCH.
    throw $classification
}
'@
$devicePattern = '(?s)function Get-DeviceTarget\(\$State\) \{.*?\r?\n\}\r?\n\r?\nfunction Ensure-Artifact'
if ($agent -notmatch $devicePattern) { throw 'Get-DeviceTarget block missing' }
$agent = [regex]::Replace($agent,$devicePattern,($deviceFunction + "`r`nfunction Ensure-Artifact"),1)

$baselineFunctions = @'
function Request-CurrentSourceRebuild($State,[string]$Reason) {
    if (-not ($State.PSObject.Properties.Name -contains 'replacement_build_requested')) {
        $State | Add-Member -NotePropertyName replacement_build_requested -NotePropertyValue $false
    }
    if ($State.replacement_build_requested -ne $true) {
        $controller = Join-Path $PSScriptRoot 'ci-controller-v3.ps1'
        if (-not (Test-Path $controller)) { throw 'ci-controller-v3.ps1 is missing; cannot rebuild the current source safely.' }
        $proc = Start-Process -FilePath 'pwsh.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$controller,'-Mode','Rebuild') -WorkingDirectory $Root -WindowStyle Hidden -PassThru
        $State.replacement_build_requested = $true
        Save-State $State 'CANDIDATE_VERIFIED' 'REBUILD_REQUESTED' $Reason
        Log "CURRENT_SOURCE_REBUILD_REQUESTED pid=$($proc.Id) old_run=$($State.run_id) reason=$Reason"
    } else {
        Save-State $State 'CANDIDATE_VERIFIED' 'REBUILD_REQUESTED' $Reason
        Log "CURRENT_SOURCE_REBUILD_ALREADY_REQUESTED old_run=$($State.run_id)"
    }
    Write-Host 'CURRENT_SOURCE_REBUILD_REQUESTED=YES'
}

function Invoke-RealDeviceBaselineGate($State,[string]$Target) {
    Log "Collecting read-only real-device snapshot from $Target before any candidate upload."
    $snapshot = Invoke-Process 'pwsh' @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'real-device-snapshot.ps1'),
        '-Target',$Target,'-OutputPath',$SnapshotPath
    ) -AllowFailure
    if ($snapshot.ExitCode -ne 0) {
        $snapshotText = [string]$snapshot.Output
        $class = if ($snapshotText -match 'SSH_HOST_IDENTITY_MISMATCH') { 'SSH_HOST_IDENTITY_MISMATCH' }
            elseif ($snapshotText -match 'DEVICE_IDENTITY_MISMATCH') { 'DEVICE_IDENTITY_MISMATCH' }
            elseif ($snapshotText -match 'SSH_AUTH_FAILED') { 'SSH_AUTH_FAILED' }
            else { 'DEVICE_UNREACHABLE' }
        if ($class -in @('DEVICE_IDENTITY_MISMATCH','SSH_HOST_IDENTITY_MISMATCH')) {
            $State.human_gate = $class
            Save-State $State ([string]$State.stage) 'BLOCKED' "Read-only real-device snapshot failed hard safety classification: $class. $snapshotText"
        } else {
            $State.human_gate = $null
            Save-State $State ([string]$State.stage) 'RETRYING' "Read-only real-device snapshot not available yet: $class. $snapshotText"
        }
        throw $class
    }

    $gate = Invoke-Process 'pwsh' @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'real-device-baseline-gate.ps1'),
        '-CandidateManifest',$ManifestPath,'-SnapshotPath',$SnapshotPath,'-Operation','forward',
        '-BaselinePath',$RealDeviceBaselinePath,'-ExpectedDiffPath',$ExpectedDiffPath
    ) -AllowFailure
    if ($gate.ExitCode -ne 0) {
        $gateText = [string]$gate.Output
        if ($gateText -match 'CANDIDATE_VERSION_OLDER_THAN_REAL_DEVICE_BASELINE') {
            Request-CurrentSourceRebuild $State 'LEGACY_CANDIDATE_REJECTED: Candidate is older than the machine-verified physical 0.1.3 baseline; build current source instead of flashing or resuming the stale run.'
            return $false
        }

        $hardClass = if ($gateText -match 'REAL_DEVICE_BASELINE_BUILD_MISMATCH') { 'REAL_DEVICE_BASELINE_BUILD_MISMATCH' } else { 'REAL_DEVICE_BASELINE_GATE_FAILED' }
        $State.human_gate = $hardClass
        Save-State $State ([string]$State.stage) 'BLOCKED' "${hardClass}: $gateText"
        throw $hardClass
    }

    Write-Host $gate.Output
    Save-State $State 'REAL_DEVICE_BASELINE_GATE' 'VERIFIED'
    return $true
}
'@
$uploadAnchor = 'function Upload-Candidate($State,[string]$Target) {'
if (-not $agent.Contains($uploadAnchor)) { throw 'Upload-Candidate anchor missing' }
$agent = $agent.Replace($uploadAnchor,($baselineFunctions + "`r`n" + $uploadAnchor))

$oldFlow = @'
    if (-not (At-Or-After $state 'AUTO_FLASH_SAFETY_GATE')) {
        $rollback = Ensure-Rollback $state
        $target = Get-DeviceTarget $state
        $remote = Upload-Candidate $state $target
        Invoke-SafetyGate $state $target $rollback $remote
        $state = Load-State
    }
'@
$newFlow = @'
    if (-not (At-Or-After $state 'REAL_DEVICE_BASELINE_GATE')) {
        $rollback = Ensure-Rollback $state
        $target = Get-DeviceTarget $state
        $baselinePassed = Invoke-RealDeviceBaselineGate $state $target
        if (-not $baselinePassed) { return }
        $state = Load-State
    }

    if (-not (At-Or-After $state 'AUTO_FLASH_SAFETY_GATE')) {
        $rollback = Ensure-Rollback $state
        $target = if ([string]$state.target) { [string]$state.target } else { Get-DeviceTarget $state }
        $remote = Upload-Candidate $state $target
        Invoke-SafetyGate $state $target $rollback $remote
        $state = Load-State
    }
'@
if (-not $agent.Contains($oldFlow)) { throw 'pre-flash flow anchor missing' }
$agent = $agent.Replace($oldFlow,$newFlow)

$loopAnchor = @'
            Run-ProductionOnce
            if ((Load-State).stage -eq 'PRODUCTION_RELEASED') { exit 0 }
'@
$loopReplacement = @'
            Run-ProductionOnce
            $loopState = Load-State
            if ([string]$loopState.status -eq 'REBUILD_REQUESTED') {
                Log 'Replacement current-source build is now owned by ci-controller-v3; exiting this stale-run agent so the new run can acquire the production lock.'
                exit 0
            }
            if ([string]$loopState.stage -eq 'PRODUCTION_RELEASED') { exit 0 }
'@
if (-not $agent.Contains($loopAnchor)) { throw 'agent loop anchor missing' }
$agent = $agent.Replace($loopAnchor,$loopReplacement)

Set-Content -Path $agentPath -Value $agent -Encoding UTF8

$controllerPath = 'scripts/ci-controller-v3.ps1'
$controller = Get-Content -Raw $controllerPath
$controllerAnchor = '$ProductionStateFile = Join-Path $RepoRoot ''output\production-agent\state.json'''
$controllerReplacement = @'
$ProductionStateFile = Join-Path $RepoRoot 'output\production-agent\state.json'
$ProductionConfigFile = Join-Path $RepoRoot 'production\production-agent.json'
$ProductionConfig = Get-Content -Raw $ProductionConfigFile | ConvertFrom-Json
'@
if (-not $controller.Contains($controllerAnchor)) { throw 'controller config anchor missing' }
$controller = $controller.Replace($controllerAnchor,$controllerReplacement)

$oldHardGate = "        if (`$humanGate -in @('UNKNOWN_DEVICE_IDENTITY','NO_SAFE_ROLLBACK','UNRECOVERABLE_IRREVERSIBLE_OPERATION')) {"
$newHardGate = "        if (`$humanGate -and `$humanGate -in @(`$ProductionConfig.human_stop_classes)) {"
if (-not $controller.Contains($oldHardGate)) { throw 'controller hard-gate anchor missing' }
$controller = $controller.Replace($oldHardGate,$newHardGate)
Set-Content -Path $controllerPath -Value $controller -Encoding UTF8

foreach ($file in @($agentPath,$controllerPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file),[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw (($errors | ForEach-Object Message) -join '; ') }
}

& ./tests/real-device-baseline.tests.ps1
& ./tests/production-agent.tests.ps1

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
foreach ($normalizePath in @($agentPath,$controllerPath,$MyInvocation.MyCommand.Path)) {
    $normalized = (Get-Content -Raw $normalizePath).TrimEnd("`r","`n") + "`n"
    [System.IO.File]::WriteAllText((Resolve-Path $normalizePath),$normalized,$utf8NoBom)
}
git diff --check
if ($LASTEXITCODE -ne 0) { throw "git diff --check failed: $LASTEXITCODE" }
Write-Host 'REAL_DEVICE_BASELINE_RUNTIME_INTEGRATION=PASS'
