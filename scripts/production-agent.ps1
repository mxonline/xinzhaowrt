param(
    [ValidateSet('Resume','Status','RunOnce')]
    [string]$Mode = 'Resume',
    [long]$RunId = 0,
    [int]$PollSeconds = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ConfigPath = Join-Path $Root 'production\production-agent.json'
$Config = Get-Content -Raw $ConfigPath | ConvertFrom-Json
$Out = Join-Path $Root 'output\production-agent'
$StatePath = Join-Path $Out 'state.json'
$HandoffPath = Join-Path $Out 'handoff.json'
$LogPath = Join-Path $Out 'agent.log'
$ManifestPath = Join-Path $Out 'candidate-manifest.json'
$MetadataPath = Join-Path $Out 'artifact-metadata.json'
$ArtifactDir = Join-Path $Out 'artifact'
$RollbackDir = Join-Path $Out 'rollback'
$LockPath = Join-Path $Out 'production-agent.lock'
New-Item -ItemType Directory -Force -Path $Out,$RollbackDir | Out-Null
if ($PollSeconds -le 0) { $PollSeconds = [int]$Config.poll_seconds }
$ExplicitRunId = $RunId -gt 0
if ($RunId -le 0) { $RunId = [long]$Config.bootstrap.run_id }

$Stages = @(
    'REQUESTED',
    'ARTIFACT_METADATA_VERIFIED',
    'ARTIFACT_BYTES_VERIFIED',
    'CANDIDATE_VERIFIED',
    'AUTO_FLASH_SAFETY_GATE',
    'FLASH_STARTED',
    'WAIT_DEVICE',
    'REAL_DEVICE_VERIFY',
    'RELEASE_GATE',
    'PRODUCTION_RELEASED'
)

function Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
}

function New-State([long]$RequestedRunId) {
    return [pscustomobject]@{
        schema_version='1.1'; stage='REQUESTED'; status='LIVE'; run_id=$RequestedRunId;
        artifact_id=[long]0; artifact_name=''; source_sha=''; candidate_sha256=''; candidate_path='';
        remote_candidate=''; target=''; last_error=''; human_gate=$null; repair_controller_started=$false;
        updated_at=(Get-Date).ToString('o')
    }
}

function Reset-RunLocalEvidence([long]$RequestedRunId) {
    if (Test-Path $StatePath) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -Force $StatePath (Join-Path $Out "state-${stamp}-before-run-${RequestedRunId}.json") -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $ArtifactDir
    Remove-Item -Force -ErrorAction SilentlyContinue $ManifestPath,$MetadataPath
}

function Load-State {
    if (-not (Test-Path $StatePath)) { return (New-State -RequestedRunId $RunId) }
    $state = Get-Content -Raw $StatePath | ConvertFrom-Json
    if ($ExplicitRunId -and [long]$state.run_id -ne $RunId) {
        Log "RUN_RECONCILE old=$($state.run_id) new=$RunId; preserving old evidence and starting the requested production run."
        Reset-RunLocalEvidence -RequestedRunId $RunId
        return (New-State -RequestedRunId $RunId)
    }
    return $state
}

function Save-State($State,[string]$Stage,[string]$Status='LIVE',[string]$Message='') {
    $State.stage = $Stage
    $State.status = $Status
    $State.updated_at = (Get-Date).ToString('o')
    if ($Message) { $State.last_error = $Message }
    $State | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $StatePath
    [ordered]@{
        article_id = $null
        project = 'Arthur / JDCloud RE-SS-01'
        current_stage = $State.stage
        stage_status = $State.status
        run_id = $State.run_id
        artifact_id = $State.artifact_id
        source_sha = $State.source_sha
        candidate_sha256 = $State.candidate_sha256
        target = $State.target
        human_gate = $State.human_gate
        next_action = if ($Stage -eq 'PRODUCTION_RELEASED') { 'NONE' } elseif ($Status -eq 'BLOCKED') { 'WAIT_FOR_SAFETY_GATE_CLEARANCE' } else { 'AUTO_RESUME_FIRST_INCOMPLETE_GATE' }
        last_updated = $State.updated_at
    } | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $HandoffPath
    Log "STATE stage=$Stage status=$Status run=$($State.run_id)"
}

function Stage-Index([string]$Stage) { return [array]::IndexOf($Stages,$Stage) }
function At-Or-After($State,[string]$Stage) { return (Stage-Index ([string]$State.stage)) -ge (Stage-Index $Stage) }

function Invoke-Process([string]$File,[string[]]$Args,[switch]$AllowFailure) {
    $text = (& $File @Args 2>&1 | Out-String).Trim()
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) { throw "$File $($Args -join ' ') failed ($code): $text" }
    [pscustomobject]@{ ExitCode=$code; Output=$text }
}

function Assert-GitHubAuth($State) {
    $auth = Invoke-Process 'gh' @('api',"repos/$([string]$Config.repository)",'--jq','.full_name') -AllowFailure
    if ($auth.ExitCode -ne 0) {
        $State.human_gate = $null
        Save-State $State ([string]$State.stage) 'RETRYING' "GITHUB_AUTH_RECOVERABLE: API credential probe failed. $($auth.Output)"
        throw 'GITHUB_AUTH_RECOVERABLE'
    }
    $State.human_gate = $null
}

function Ensure-Rollback($State) {
    $Known = Get-Content -Raw (Join-Path $Root 'production\known-good.json') | ConvertFrom-Json
    $rollback = Join-Path $RollbackDir ([string]$Known.firmware_file)
    if (-not (Test-Path $rollback)) {
        Assert-GitHubAuth $State
        Log "Downloading verified rollback from release $($Known.stable_tag)"
        $dl = Invoke-Process 'gh' @('release','download',[string]$Known.stable_tag,'--repo',[string]$Config.repository,'--dir',$RollbackDir,'--clobber','--pattern',[string]$Known.firmware_file) -AllowFailure
        if ($dl.ExitCode -ne 0) {
            if ([string]$dl.Output -match '(?i)authentication|bad credentials|HTTP 401|rate limit|HTTP 403|HTTP 5\d\d|timeout|timed out|EOF|connection reset|connection refused') {
                Save-State $State ([string]$State.stage) 'RETRYING' "ROLLBACK_FETCH_RECOVERABLE: $($dl.Output)"
                throw 'ROLLBACK_FETCH_RECOVERABLE'
            }
            $State.human_gate = 'NO_SAFE_ROLLBACK'
            Save-State $State ([string]$State.stage) 'BLOCKED' "Rollback download failed deterministically: $($dl.Output)"
            throw 'NO_SAFE_ROLLBACK'
        }
    }
    if (-not (Test-Path $rollback)) {
        $State.human_gate = 'NO_SAFE_ROLLBACK'
        Save-State $State ([string]$State.stage) 'BLOCKED' 'Verified rollback artifact is unavailable.'
        throw 'NO_SAFE_ROLLBACK'
    }
    $hash = (Get-FileHash -Algorithm SHA256 $rollback).Hash.ToLowerInvariant()
    if ($hash -ne ([string]$Known.sha256).ToLowerInvariant()) {
        $State.human_gate = 'NO_SAFE_ROLLBACK'
        Save-State $State ([string]$State.stage) 'BLOCKED' "Rollback SHA256 mismatch: $hash"
        throw 'NO_SAFE_ROLLBACK'
    }
    return $rollback
}

function Get-DeviceTarget($State) {
    foreach ($ip in @($Config.recovery_addresses)) {
        $target = "root@$ip"
        $probe = Invoke-Process 'ssh.exe' @('-o','BatchMode=yes','-o','ConnectTimeout=5',$target,'ubus call system board') -AllowFailure
        if ($probe.ExitCode -eq 0 -and $probe.Output -match 'jdcloud,re-ss-01|RE-SS-01') {
            $State.target = $target
            Save-State $State ([string]$State.stage) 'LIVE'
            return $target
        }
    }
    $State.human_gate = 'UNKNOWN_DEVICE_IDENTITY'
    Save-State $State ([string]$State.stage) 'BLOCKED' 'No verified Arthur device found at expected/recovery addresses.'
    throw 'UNKNOWN_DEVICE_IDENTITY'
}

function Ensure-Artifact($State) {
    if ((At-Or-After $State 'CANDIDATE_VERIFIED') -and (Test-Path ([string]$State.candidate_path))) { return }
    Assert-GitHubAuth $State
    Log "Fetching immutable production artifact for Run $($State.run_id)"
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fetch-production-artifact.ps1') `
        -RunId ([long]$State.run_id) -Repository ([string]$Config.repository) -Destination $ArtifactDir | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Save-State $State ([string]$State.stage) 'RETRYING' "ARTIFACT_FETCH_RECOVERABLE exit=$LASTEXITCODE; same run will be retried without rebuild."
        throw "ARTIFACT_FETCH_RECOVERABLE_$LASTEXITCODE"
    }
    $manifest = Get-Content -Raw $ManifestPath | ConvertFrom-Json
    $metadata = Get-Content -Raw $MetadataPath | ConvertFrom-Json
    $State.artifact_id = [long]$metadata.artifact_id
    $State.artifact_name = [string]$metadata.artifact_name
    $State.candidate_sha256 = [string]$manifest.candidate_sha256
    $State.candidate_path = [string]$manifest.candidate_path
    $State.source_sha = [string]$manifest.source_sha
    Save-State $State 'CANDIDATE_VERIFIED' 'VERIFIED'
}

function Upload-Candidate($State,[string]$Target) {
    $Profile = Get-Content -Raw (Join-Path $Root 'production\arthur-flash-profile.json') | ConvertFrom-Json
    $remote = [string]$Profile.remote_candidate
    Log "Uploading candidate to ${Target}:$remote"
    $scp = Invoke-Process 'scp.exe' @('-o','BatchMode=yes','-o','ConnectTimeout=10',[string]$State.candidate_path,"${Target}:$remote") -AllowFailure
    if ($scp.ExitCode -ne 0) { throw "CANDIDATE_UPLOAD_RECOVERABLE: $($scp.Output)" }
    $State.remote_candidate = $remote
    Save-State $State ([string]$State.stage) 'LIVE'
    return $remote
}

function Invoke-SafetyGate($State,[string]$Target,[string]$Rollback,[string]$Remote) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'auto-flash-safety-gate.ps1') `
        -CandidateManifest $ManifestPath -RollbackPath $Rollback -Target $Target -RemoteCandidate $Remote | Tee-Object -FilePath (Join-Path $Out 'auto-flash-safety-gate.log') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "AUTO_FLASH_SAFETY_GATE failed exit=$LASTEXITCODE" }
    Write-Host 'AUTO_FLASH_SAFETY_GATE=PASS'
    Save-State $State 'AUTO_FLASH_SAFETY_GATE' 'VERIFIED'
}

function Invoke-VerifiedSysupgrade($State,[string]$Target,[string]$Remote) {
    $Profile = Get-Content -Raw (Join-Path $Root 'production\arthur-flash-profile.json') | ConvertFrom-Json
    if (-not $Profile.verified) {
        $State.human_gate = 'UNRECOVERABLE_IRREVERSIBLE_OPERATION'
        Save-State $State ([string]$State.stage) 'BLOCKED' 'Arthur sysupgrade profile is not historically verified.'
        throw 'UNRECOVERABLE_IRREVERSIBLE_OPERATION'
    }
    $args = ([string]$Profile.argument_template).Replace('{remote_candidate}',$Remote)
    $command = "$( [string]$Profile.remote_upgrade_binary ) $args"
    Save-State $State 'FLASH_STARTED' 'LIVE'
    Log "Executing historically verified standard sysupgrade on $Target"
    $result = Invoke-Process 'ssh.exe' @('-o','BatchMode=yes','-o','ConnectTimeout=10',$Target,$command) -AllowFailure
    if ($result.ExitCode -ne 0 -and $result.Output -notmatch '(?i)closed|reset|broken pipe|connection') {
        throw "sysupgrade did not enter expected reboot/disconnect path: $($result.Output)"
    }
    Save-State $State 'WAIT_DEVICE' 'LIVE'
}

function Wait-Device($State) {
    $deadline = (Get-Date).AddSeconds([int]$Config.wait_device_timeout_seconds)
    $target = "root@$($Config.expected_lan)"
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $probe = Invoke-Process 'ssh.exe' @('-o','BatchMode=yes','-o','ConnectTimeout=5',$target,'ubus call system board') -AllowFailure
        if ($probe.ExitCode -eq 0 -and $probe.Output -match 'jdcloud,re-ss-01|RE-SS-01') {
            $State.target = $target
            Save-State $State 'REAL_DEVICE_VERIFY' 'LIVE'
            return $target
        }
    }
    throw "WAIT_DEVICE timeout: Arthur did not recover at $($Config.expected_lan)"
}

function Invoke-RepairController($State) {
    if ($State.PSObject.Properties.Name -contains 'repair_controller_started' -and $State.repair_controller_started -eq $true) {
        Log 'AUTO_REMEDIATION_CONTROLLER already started for this run; not launching a duplicate.'
        return
    }
    $controller = Join-Path $PSScriptRoot 'ci-controller-v3.ps1'
    if (-not (Test-Path $controller)) { throw 'Existing ci-controller-v3.ps1 repair controller is missing.' }
    Log 'Routing deterministic build/verification failure to existing Codex auto-repair controller.'
    $proc = Start-Process -FilePath 'pwsh.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$controller,'-Mode','Resume','-RunId',[string]$State.run_id) -WorkingDirectory $Root -WindowStyle Hidden -PassThru
    $State.repair_controller_started = $true
    Save-State $State ([string]$State.stage) ([string]$State.status)
    Log "AUTO_REMEDIATION_CONTROLLER_STARTED pid=$($proc.Id) run=$($State.run_id)"
}

function Invoke-RealDeviceVerify($State,[string]$Target) {
    $tag = "arthur-update-$($State.run_id)"
    Log "Running full real-device verification candidate=$tag target=$Target"
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'real-device-verify-v3.ps1') -Candidate $tag -Commit ([string]$State.source_sha) -Target $Target | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Save-State $State 'REAL_DEVICE_VERIFY' 'FAILED' 'Real-device verification failed; existing Codex repair controller will process evidence while the Production Agent stays on this checkpoint.'
        Invoke-RepairController $State
        throw 'REAL_DEVICE_VERIFY_FAILED_REPAIR_STARTED'
    }
    $report = Join-Path $Root 'output\real-device\real-device-verification.json'
    if (-not (Test-Path $report)) { throw 'Real-device verifier produced no JSON report.' }
    $result = Get-Content -Raw $report | ConvertFrom-Json
    if ([string]$result.result -ne 'PASS') {
        Save-State $State 'REAL_DEVICE_VERIFY' 'FAILED' 'Real-device report result != PASS; existing Codex repair controller will process evidence while the Production Agent stays on this checkpoint.'
        Invoke-RepairController $State
        throw 'REAL_DEVICE_VERIFY_FAILED_REPAIR_STARTED'
    }
    $State.repair_controller_started = $false
    Save-State $State 'RELEASE_GATE' 'VERIFIED'
}

function Complete-Release($State) {
    $tag = "arthur-production-$($State.run_id)"
    $existing = Invoke-Process 'gh' @('release','view',$tag,'--repo',[string]$Config.repository) -AllowFailure
    if ($existing.ExitCode -ne 0) {
        $create = Invoke-Process 'gh' @('release','create',$tag,[string]$State.candidate_path,'--repo',[string]$Config.repository,'--title',"XinZhaoWrt Arthur Production $($State.run_id)",'--notes',"Verified Arthur production release. Source $($State.source_sha); SHA256 $($State.candidate_sha256).") -AllowFailure
        if ($create.ExitCode -ne 0) { throw "GitHub Release failed: $($create.Output)" }
    }
    Save-State $State 'PRODUCTION_RELEASED' 'VERIFIED'
    Write-Host 'PRODUCTION_RELEASED=YES'
}

function Run-ProductionOnce {
    $state = Load-State
    if ([string]$state.stage -eq 'PRODUCTION_RELEASED') { Write-Host 'PRODUCTION_RELEASED=YES'; return }

    Assert-GitHubAuth $state

    if (-not (At-Or-After $state 'CANDIDATE_VERIFIED')) {
        Ensure-Artifact $state
        $state = Load-State
    }

    if (-not (At-Or-After $state 'AUTO_FLASH_SAFETY_GATE')) {
        $rollback = Ensure-Rollback $state
        $target = Get-DeviceTarget $state
        $remote = Upload-Candidate $state $target
        Invoke-SafetyGate $state $target $rollback $remote
        $state = Load-State
    }

    if ([string]$state.stage -eq 'AUTO_FLASH_SAFETY_GATE') {
        $target = if ([string]$state.target) { [string]$state.target } else { Get-DeviceTarget $state }
        $remote = if ([string]$state.remote_candidate) { [string]$state.remote_candidate } else { Upload-Candidate $state $target }
        Invoke-VerifiedSysupgrade $state $target $remote
        $state = Load-State
    }

    if ([string]$state.stage -eq 'FLASH_STARTED') {
        # A crash/restart after FLASH_STARTED must never blindly execute sysupgrade again.
        # Reconcile the real device by entering WAIT_DEVICE instead.
        Save-State $state 'WAIT_DEVICE' 'LIVE' 'Recovered after FLASH_STARTED; reconciling device state without a second write.'
        $state = Load-State
    }

    if ([string]$state.stage -eq 'WAIT_DEVICE') {
        Wait-Device $state | Out-Null
        $state = Load-State
    }

    if ([string]$state.stage -eq 'REAL_DEVICE_VERIFY') {
        $target = if ([string]$state.target) { [string]$state.target } else { "root@$($Config.expected_lan)" }
        Invoke-RealDeviceVerify $state $target
        $state = Load-State
    }

    if ([string]$state.stage -eq 'RELEASE_GATE') {
        Complete-Release $state
    }
}

if ($Mode -eq 'Status') {
    $state = Load-State
    $state | ConvertTo-Json -Depth 10
    exit 0
}

if (Test-Path $LockPath) {
    try {
        $oldPid = [int](Get-Content -Raw $LockPath)
        if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) { Write-Host "PRODUCTION_AGENT_ALREADY_RUNNING pid=$oldPid"; exit 0 }
    } catch {}
    Remove-Item -Force -ErrorAction SilentlyContinue $LockPath
}
$PID | Set-Content -Encoding ASCII $LockPath
try {
    if ($Mode -eq 'RunOnce') { Run-ProductionOnce; exit 0 }
    while ($true) {
        try {
            Run-ProductionOnce
            if ((Load-State).stage -eq 'PRODUCTION_RELEASED') { exit 0 }
        }
        catch {
            $message = $_.Exception.Message
            Log "AGENT_ITERATION_ERROR $message"
            $state = Load-State
            if ([string]$state.human_gate -in @($Config.human_stop_classes)) {
                Log "HUMAN_GATE=$($state.human_gate); only a frozen flash-safety condition may pause the write path."
            } else {
                Save-State $state ([string]$state.stage) 'RETRYING' $message
                Log 'RECOVERABLE_AGENT_ERROR; persistent loop will execute next_action automatically.'
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $LockPath
}
