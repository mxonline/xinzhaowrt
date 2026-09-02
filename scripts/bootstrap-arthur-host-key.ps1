param(
    [string]$TargetIp = '192.168.6.1',
    [string]$BaselinePath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'real-device-baseline-lib.ps1')
if (-not $BaselinePath) { $BaselinePath = Join-Path $Root 'production\real-device-baseline.json' }

function Fail([string]$Code,[string]$Message) {
    Write-Error "$Code $Message"
    exit 63
}

function Invoke-SshCapture {
    param(
        [Parameter(Mandatory=$true)][string]$KnownHostsFile,
        [Parameter(Mandatory=$true)][string]$StrictMode,
        [Parameter(Mandatory=$true)][string]$Command
    )
    $args = @(
        '-o',"UserKnownHostsFile=$KnownHostsFile",
        '-o',"StrictHostKeyChecking=$StrictMode",
        '-o','BatchMode=yes',
        '-o','ConnectTimeout=8',
        "root@$TargetIp",
        $Command
    )
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& ssh.exe @args 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    [pscustomobject]@{ ExitCode = $code; Output = (($raw | ForEach-Object { [string]$_ }) -join "`n").Trim() }
}

function Get-KnownHostLines {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& ssh-keygen.exe -F $TargetIp -f $Path 2>&1)
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    return @($raw | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_ -notmatch '^#' })
}

function Get-RemoteBuildInfo {
    param([Parameter(Mandatory=$true)][string]$KnownHostsFile,[Parameter(Mandatory=$true)][string]$StrictMode)
    $probe = Invoke-SshCapture -KnownHostsFile $KnownHostsFile -StrictMode $StrictMode -Command 'cat /www/luci-static/xinzhao/build-info.json'
    if ($probe.ExitCode -ne 0) {
        $class = Classify-ArthurSshProbe -ExitCode $probe.ExitCode -Output $probe.Output
        if ($class -eq 'SSH_AUTH_FAILED') { Fail 'SSH_AUTH_FAILED' "SSH authentication failed; host key was not changed: $($probe.Output)" }
        if ($class -eq 'SSH_HOST_IDENTITY_MISMATCH') { Fail 'SSH_HOST_IDENTITY_MISMATCH' $probe.Output }
        Fail 'DEVICE_UNREACHABLE' "Unable to read build-info over SSH: $($probe.Output)"
    }
    try { return ($probe.Output | ConvertFrom-Json) }
    catch { Fail 'REAL_DEVICE_BASELINE_BUILD_MISMATCH' "SSH build-info is invalid JSON: $($_.Exception.Message)" }
}

if (-not (Test-Path $BaselinePath)) { Fail 'REAL_DEVICE_BASELINE_EVIDENCE_MISSING' "Baseline missing: $BaselinePath" }
$Baseline = Get-Content -Raw $BaselinePath | ConvertFrom-Json
if (@($Baseline.device.management_addresses) -notcontains $TargetIp) {
    Fail 'DEVICE_IDENTITY_MISMATCH' "Target $TargetIp is not an authorized management address in the real-device baseline."
}

# Out-of-band read-only evidence must match the committed physical baseline before first-use trust is considered.
$httpUri = "http://$TargetIp/luci-static/xinzhao/build-info.json"
try {
    $httpResponse = Invoke-WebRequest -UseBasicParsing -Uri $httpUri -TimeoutSec 10
    $HttpBuild = $httpResponse.Content | ConvertFrom-Json
}
catch {
    Fail 'DEVICE_UNREACHABLE' "Unable to obtain read-only HTTP build identity from $httpUri: $($_.Exception.Message)"
}
if (-not (Test-ArthurBuildInfoMatchesBaseline -BuildInfo $HttpBuild -Baseline $Baseline)) {
    Fail 'REAL_DEVICE_BASELINE_BUILD_MISMATCH' "HTTP build identity does not match baseline $($Baseline.firmware.version)/$($Baseline.firmware.build_id)/$($Baseline.firmware.displayed_git_commit)."
}
Write-Host "SSH_HOST_KEY_HTTP_BASELINE=PASS version=$($Baseline.firmware.version) build_id=$($Baseline.firmware.build_id) commit=$($Baseline.firmware.displayed_git_commit)"

$userProfile = [Environment]::GetFolderPath('UserProfile')
$sshDir = Join-Path $userProfile '.ssh'
$knownHosts = Join-Path $sshDir 'known_hosts'
$existing = @(Get-KnownHostLines -Path $knownHosts)
if ($existing.Count -gt 0) {
    # Existing trust is never replaced automatically. It must verify strictly as-is.
    $existingBoard = Invoke-SshCapture -KnownHostsFile $knownHosts -StrictMode 'yes' -Command 'ubus call system board'
    if ($existingBoard.ExitCode -ne 0) {
        $existingClass = Classify-ArthurSshProbe -ExitCode $existingBoard.ExitCode -Output $existingBoard.Output
        if ($existingClass -eq 'SSH_AUTH_FAILED') { Fail 'SSH_AUTH_FAILED' "Existing host key verified but SSH authentication failed: $($existingBoard.Output)" }
        Fail 'SSH_HOST_IDENTITY_MISMATCH' "Existing known_hosts entry did not verify strictly and will not be replaced: $($existingBoard.Output)"
    }
    if (-not (Test-ArthurBoardIdentity -BoardOutput $existingBoard.Output)) {
        Fail 'DEVICE_IDENTITY_MISMATCH' "Existing trusted SSH endpoint is not JDCloud RE-SS-01: $($existingBoard.Output)"
    }
    $existingBuild = Get-RemoteBuildInfo -KnownHostsFile $knownHosts -StrictMode 'yes'
    if (-not (Test-ArthurBuildInfoMatchesBaseline -BuildInfo $existingBuild -Baseline $Baseline)) {
        Fail 'REAL_DEVICE_BASELINE_BUILD_MISMATCH' 'Existing trusted SSH endpoint does not match the physical firmware baseline.'
    }
    Write-Host "SSH_HOST_KEY_ALREADY_TRUSTED=PASS target=$TargetIp"
    Write-Host "SSH_HOST_KEY_BOOTSTRAP=PASS target=$TargetIp mode=already-trusted"
    exit 0
}

$tempKnownHosts = Join-Path ([System.IO.Path]::GetTempPath()) ("xinzhaowrt-arthur-hostkey-{0}.known_hosts" -f $PID)
$tempKeyLines = Join-Path ([System.IO.Path]::GetTempPath()) ("xinzhaowrt-arthur-hostkey-{0}.lines" -f $PID)
Remove-Item -Force -ErrorAction SilentlyContinue $tempKnownHosts,$tempKeyLines

# StrictHostKeyChecking=accept-new is constrained to a disposable known_hosts file, never the real trust store.
$boardProbe = Invoke-SshCapture -KnownHostsFile $tempKnownHosts -StrictMode 'accept-new' -Command 'ubus call system board'
if ($boardProbe.ExitCode -ne 0) {
    $class = Classify-ArthurSshProbe -ExitCode $boardProbe.ExitCode -Output $boardProbe.Output
    if ($class -eq 'SSH_AUTH_FAILED') { Fail 'SSH_AUTH_FAILED' "Temporary trust succeeded but client authentication failed; key was not enrolled. $($boardProbe.Output)" }
    if ($class -eq 'SSH_HOST_IDENTITY_MISMATCH') { Fail 'SSH_HOST_IDENTITY_MISMATCH' $boardProbe.Output }
    Fail 'DEVICE_UNREACHABLE' "Unable to verify Arthur board through temporary trust: $($boardProbe.Output)"
}
if (-not (Test-ArthurBoardIdentity -BoardOutput $boardProbe.Output)) {
    Fail 'DEVICE_IDENTITY_MISMATCH' "Authenticated SSH board evidence is not JDCloud RE-SS-01: $($boardProbe.Output)"
}
Write-Host 'SSH_HOST_KEY_TEMP_BOARD=PASS device=jdcloud_re-ss-01'

$SshBuild = Get-RemoteBuildInfo -KnownHostsFile $tempKnownHosts -StrictMode 'yes'
if (-not (Test-ArthurBuildInfoMatchesBaseline -BuildInfo $SshBuild -Baseline $Baseline)) {
    Fail 'REAL_DEVICE_BASELINE_BUILD_MISMATCH' "Authenticated SSH build identity does not match baseline $($Baseline.firmware.version)/$($Baseline.firmware.build_id)/$($Baseline.firmware.displayed_git_commit)."
}
Write-Host "SSH_HOST_KEY_TEMP_BUILD=PASS version=$($SshBuild.Version) build_id=$($SshBuild.'Build ID') commit=$($SshBuild.'Git Commit')"

$currentLines = @(Get-KnownHostLines -Path $tempKnownHosts)
if ($currentLines.Count -lt 1) { Fail 'SSH_HOST_KEY_CAPTURE_FAILED' 'Temporary known_hosts contains no key for the Arthur target.' }
$currentLines | Set-Content -Encoding ASCII $tempKeyLines
$fpPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $fingerprints = @(& ssh-keygen.exe -lf $tempKeyLines 2>&1)
}
finally { $ErrorActionPreference = $fpPreference }
foreach ($fingerprint in $fingerprints) { Write-Host "SSH_HOST_KEY_CANDIDATE_FINGERPRINT=$fingerprint" }

# Recheck after all evidence collection to avoid overwriting a key introduced concurrently.
if (@(Get-KnownHostLines -Path $knownHosts).Count -gt 0) {
    Fail 'SSH_HOST_IDENTITY_MISMATCH' "A known_hosts entry for $TargetIp appeared during verification; refusing automatic enrollment."
}

New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
$hadKnownHosts = Test-Path $knownHosts
$backup = $null
if ($hadKnownHosts) {
    $backup = "$knownHosts.xinzhaowrt-backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item -Force $knownHosts $backup
}
else {
    [System.IO.File]::WriteAllText($knownHosts,'',[System.Text.Encoding]::ASCII)
}

try {
    foreach ($line in $currentLines) {
        [System.IO.File]::AppendAllText($knownHosts,([string]$line + [Environment]::NewLine),[System.Text.Encoding]::ASCII)
    }

    $strictBoard = Invoke-SshCapture -KnownHostsFile $knownHosts -StrictMode 'yes' -Command 'ubus call system board'
    if ($strictBoard.ExitCode -ne 0 -or -not (Test-ArthurBoardIdentity -BoardOutput $strictBoard.Output)) {
        throw "Strict post-enrollment board verification failed: $($strictBoard.Output)"
    }
    $strictBuild = Get-RemoteBuildInfo -KnownHostsFile $knownHosts -StrictMode 'yes'
    if (-not (Test-ArthurBuildInfoMatchesBaseline -BuildInfo $strictBuild -Baseline $Baseline)) {
        throw 'Strict post-enrollment build verification does not match the physical baseline.'
    }
}
catch {
    if ($hadKnownHosts -and $backup -and (Test-Path $backup)) {
        Copy-Item -Force $backup $knownHosts
    }
    elseif (-not $hadKnownHosts) {
        [System.IO.File]::WriteAllText($knownHosts,'',[System.Text.Encoding]::ASCII)
    }
    Fail 'SSH_HOST_IDENTITY_MISMATCH' "Host-key enrollment was rolled back because strict verification failed: $($_.Exception.Message)"
}

Write-Host "SSH_HOST_KEY_BOOTSTRAP=PASS target=$TargetIp mode=enrolled-first-use"
