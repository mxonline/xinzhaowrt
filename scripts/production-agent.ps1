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
$ArtifactDir = Join-Path $Out 'artifact'
$RollbackDir = Join-Path $Out 'rollback'
$LockPath = Join-Path $Out 'production-agent.lock'
New-Item -ItemType Directory -Force -Path $Out,$RollbackDir | Out-Null
if ($PollSeconds -le 0) { $PollSeconds = [int]$Config.poll_seconds }
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

function Load-State {
    if (-not (Test-Path $StatePath)) {
        return [pscustomobject]@{
            schema_version='1.0'; stage='REQUESTED'; status='LIVE'; run_id=$RunId;
            artifact_id=[long]$Config.bootstrap.artifact_id; artifact_name=[string]$Config.bootstrap.artifact_name;
            source_sha=[string]$Config.bootstrap.source_sha; candidate_sha256=''; candidate_path='';
            target=''; last_error=''; human_gate=$null; updated_at=(Get-Date).ToString('o')
        }
    }
    return (Get-Content -Raw $StatePath | ConvertFrom-Json)
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
        next_action = if ($Stage -eq 'PRODUCTION_RELEASED') { 'NONE' } else { 'AUTO_RESUME_FIRST_INCOMPLETE_GATE' }
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
    $auth = Invoke-Process 'gh' @('auth','status','--hostname','github.com') -AllowFailure
    if ($auth.ExitCode -ne 0) {
        $State.human_gate = 'NEW_CREDENTIAL_PROVISIONING'
        Save-State $State ([string]$State.stage) 'BLOCKED' 'GitHub CLI authentication unavailable.'
        throw 'NEW_CREDENTIAL_PROVISIONING'
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
            $State.human_gate = 'NO_SAFE_ROLLBACK'
            Save-State $State ([string]$State.stage) 'BLOCKED' "Rollback download failed: $($dl.Output)"
            throw 'NO_SAFE_ROLLBACK'
        }
    }
    if (-not (Test-Path $rollback)) { throw 'NO_SAFE_ROLLBACK' }
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
    Log "Fetching immutable artifact for Run $($State.run_id)"
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fetch-production-artifact.ps1') `
        -RunId ([long]$State.run_id) -ArtifactId ([long]$State.artifact_id) -ArtifactName ([string]$State.artifact_name) `
        -ExpectedCandidateSha256 ([string]$Config.bootstrap.candidate_sha256) -ExpectedCandidateSize ([long]$Config.bootstrap.candidate_size) `
        -Repository ([string]$Config.repository) -Destination $ArtifactDir | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Artifact fetch failed exit=$LASTEXITCODE" }
    $manifest = Get-Content -Raw $ManifestPath | ConvertFrom-Json
    $State.candidate_sha256 = [string]$manifest.candidate_sha256
    $State.candidate_path = [string]$manifest.candidate_path
    $State.source_sha = [string]$manifest.source_sha
    Save-State $State 'CANDIDATE_VERIFIED' 'LIVE'
}

function Upload-Candidate($State,[string]$Target) {
    $Profile = Get-Content -Raw (Join-Path $Root 'production\arthur-flash-profile.json') | ConvertFrom-Json
    $remote = [string]$Profile.remote_candidate
    Log "Uploading candidate to ${Target}:$remote"
    $scp = Invoke-Process 'scp.exe' @('-o','BatchMode=yes','-o','ConnectTimeout=10',[string]$State.candidate_path,"${Target}:$remote") -AllowFailure
    if ($scp.ExitCode -ne 0) { throw "Candidate upload failed: $($scp.Output)" }
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
    if (-not $Profile.verified) { throw 'UNRECOVERABLE_IRREVERSIBLE_OPERATION' }
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

function Invoke-RealDeviceVerify($State,[string]$Target) {
    $tag = "arthur-update-$($State.run_id)"
    Log "Running full real-device verification candidate=$tag target=$Target"
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'real-device-verify-v3.ps1') -Candidate $tag -Commit ([string]$State.source_sha) -Target $Target | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Save-State $State 'REAL_DEVICE_VERIFY' 'FAILED' 'Real-device verification failed; route to batched Codex repair.'
        Invoke-RepairController $State
        throw 'REAL_DEVICE_VERIFY_FAILED_REPAIR_STARTED'
    }
    $report = Join-Path $Root 'output\real-device\real-device-verification.json'
    if (-not (Test-Path $report)) { throw 'Real-device verifier produced no JSON report.' }
    $result = Get-Content -Raw $report | ConvertFrom-Json
    if ([string]$result.result -ne 'PASS') {
        Save-State $State 'REAL_DEVICE_VERIFY' 'FAILED' 'Real-device report result != PASS.'
        Invoke-RepairController $State
        throw 'REAL_DEVICE_VERIFY_FAILED_REPAIR_STARTED'
    }
    Save-State $State 'RELEASE_GATE' 'VERIFIED'
}

function Invoke-RepairController($State) {
    $controller = Join-Path $PSScriptRoot 'ci-controller-v3.ps1'
    if (-not (Test-Path $controller)) { throw 'Existing ci-controller-v3.ps1 repair controller is missing.' }
    Log 'Routing deterministic build/verification failure to existing Codex auto-repair controller.'
    $proc = Start-Process -FilePath 'pwsh.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$controller,'-Mode','Resume') -WorkingDirectory $Root -WindowStyle Hidden -PassThru
    Log "AUTO_REMEDIATION_CONTROLLER_STARTED pid=$($proc.Id)"
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
    Ensure-Artifact $state
    $rollback = Ensure-Rollback $state
    $target = Get-DeviceTarget $state
    $remote = Upload-Candidate $state $target
    Invoke-SafetyGate $state $target $rollback $remote
    Invoke-VerifiedSysupgrade $state $target $remote
    $target = Wait-Device $state
    Invoke-RealDeviceVerify $state $target
    Complete-Release $state
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
                Log "HUMAN_GATE=$($state.human_gate); persistent agent remains installed and will resume after the gate is cleared."
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $LockPath
}
