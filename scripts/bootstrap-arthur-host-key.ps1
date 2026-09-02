param(
    [string]$TargetIp = '192.168.6.1',
    [string]$BaselinePath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'real-device-baseline-lib.ps1')
if (-not $BaselinePath) { $BaselinePath = Join-Path $Root 'production\real-device-baseline.json' }
$BuildEnvPath = Join-Path $Root 'build.env'
$script:AskPassExe = $null

function Fail([string]$Code,[string]$Message) {
    Write-Error "$Code $Message"
    exit 63
}

function Get-BuildEnvValue {
    param([Parameter(Mandatory=$true)][string]$Name)
    if (-not (Test-Path $BuildEnvPath)) { Fail 'SSH_AUTH_BOOTSTRAP_CONFIG_MISSING' "build.env missing: $BuildEnvPath" }
    $line = Get-Content $BuildEnvPath | Where-Object { $_ -match ('^\s*' + [regex]::Escape($Name) + '=') } | Select-Object -First 1
    if (-not $line) { Fail 'SSH_AUTH_BOOTSTRAP_CONFIG_MISSING' "Required build.env value missing: $Name" }
    $value = (($line -split '=',2)[1]).Trim()
    if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
        $value = $value.Substring(1,$value.Length - 2)
    }
    if (-not $value) { Fail 'SSH_AUTH_BOOTSTRAP_CONFIG_MISSING' "Required build.env value is empty: $Name" }
    return $value
}

function Get-InitialRootPassword {
    return (Get-BuildEnvValue -Name 'DEFAULT_ROOT_PASSWORD')
}

function Get-AskPassHelper {
    if ($script:AskPassExe -and (Test-Path $script:AskPassExe)) { return $script:AskPassExe }
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("xinzhaowrt-ssh-askpass-{0}.exe" -f $PID)
    Remove-Item -Force -ErrorAction SilentlyContinue $path
    $source = @'
using System;
public static class XinZhaoWrtAskPass {
    public static int Main(string[] args) {
        string value = Environment.GetEnvironmentVariable("XINZHAO_SSH_BOOTSTRAP_PASSWORD");
        if (String.IsNullOrEmpty(value)) return 1;
        Console.WriteLine(value);
        return 0;
    }
}
'@
    try {
        Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $path -OutputType ConsoleApplication -ErrorAction Stop
    }
    catch {
        Fail 'SSH_AUTH_BOOTSTRAP_HELPER_FAILED' "Unable to create temporary SSH_ASKPASS helper: $($_.Exception.Message)"
    }
    if (-not (Test-Path $path)) { Fail 'SSH_AUTH_BOOTSTRAP_HELPER_FAILED' 'Temporary SSH_ASKPASS helper was not created.' }
    $script:AskPassExe = $path
    return $path
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

function Invoke-SshPasswordCapture {
    param(
        [Parameter(Mandatory=$true)][string]$KnownHostsFile,
        [Parameter(Mandatory=$true)][string]$StrictMode,
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(Mandatory=$true)][string]$Password
    )
    $askPass = Get-AskPassHelper
    $oldAskPass = $env:SSH_ASKPASS
    $oldAskPassRequire = $env:SSH_ASKPASS_REQUIRE
    $oldDisplay = $env:DISPLAY
    $oldBootstrapPassword = $env:XINZHAO_SSH_BOOTSTRAP_PASSWORD
    try {
        $env:SSH_ASKPASS = $askPass
        $env:SSH_ASKPASS_REQUIRE = 'force'
        $env:DISPLAY = 'xinzhaowrt-bootstrap'
        $env:XINZHAO_SSH_BOOTSTRAP_PASSWORD = $Password
        $args = @(
            '-o',"UserKnownHostsFile=$KnownHostsFile",
            '-o',"StrictHostKeyChecking=$StrictMode",
            '-o','BatchMode=no',
            '-o','PreferredAuthentications=password',
            '-o','PubkeyAuthentication=no',
            '-o','NumberOfPasswordPrompts=1',
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
        return [pscustomobject]@{ ExitCode = $code; Output = (($raw | ForEach-Object { [string]$_ }) -join "`n").Trim() }
    }
    finally {
        if ($null -eq $oldAskPass) { Remove-Item Env:SSH_ASKPASS -ErrorAction SilentlyContinue } else { $env:SSH_ASKPASS = $oldAskPass }
        if ($null -eq $oldAskPassRequire) { Remove-Item Env:SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue } else { $env:SSH_ASKPASS_REQUIRE = $oldAskPassRequire }
        if ($null -eq $oldDisplay) { Remove-Item Env:DISPLAY -ErrorAction SilentlyContinue } else { $env:DISPLAY = $oldDisplay }
        if ($null -eq $oldBootstrapPassword) { Remove-Item Env:XINZHAO_SSH_BOOTSTRAP_PASSWORD -ErrorAction SilentlyContinue } else { $env:XINZHAO_SSH_BOOTSTRAP_PASSWORD = $oldBootstrapPassword }
    }
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

function Get-RemoteBuildInfoPassword {
    param(
        [Parameter(Mandatory=$true)][string]$KnownHostsFile,
        [Parameter(Mandatory=$true)][string]$StrictMode,
        [Parameter(Mandatory=$true)][string]$Password
    )
    $probe = Invoke-SshPasswordCapture -KnownHostsFile $KnownHostsFile -StrictMode $StrictMode -Command 'cat /www/luci-static/xinzhao/build-info.json' -Password $Password
    if ($probe.ExitCode -ne 0) {
        $class = Classify-ArthurSshProbe -ExitCode $probe.ExitCode -Output $probe.Output
        if ($class -eq 'SSH_HOST_IDENTITY_MISMATCH') { Fail 'SSH_HOST_IDENTITY_MISMATCH' $probe.Output }
        if ($class -eq 'SSH_AUTH_FAILED') { Fail 'SSH_AUTH_FAILED' "Initial credential did not authenticate the verified Arthur endpoint: $($probe.Output)" }
        Fail 'DEVICE_UNREACHABLE' "Unable to read build-info with the initial credential: $($probe.Output)"
    }
    try { return ($probe.Output | ConvertFrom-Json) }
    catch { Fail 'REAL_DEVICE_BASELINE_BUILD_MISMATCH' "Password-authenticated SSH build-info is invalid JSON: $($_.Exception.Message)" }
}

function Ensure-RunnerSshIdentity {
    param([Parameter(Mandatory=$true)][string]$SshDirectory)
    New-Item -ItemType Directory -Force -Path $SshDirectory | Out-Null
    $privateKey = Join-Path $SshDirectory 'id_ed25519'
    $publicKey = "$privateKey.pub"
    if (-not (Test-Path $privateKey)) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'ssh-keygen.exe'
        $psi.Arguments = "-q -t ed25519 -N `"`" -C `"xinzhaowrt-controller`" -f `"$privateKey`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or -not (Test-Path $privateKey)) {
            Fail 'SSH_AUTH_KEY_GENERATION_FAILED' "Unable to create Runner id_ed25519 at $privateKey"
        }
        Write-Host "SSH_AUTH_RUNNER_KEY=GENERATED path=$privateKey"
    }
    elseif (-not (Test-Path $publicKey)) {
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $derived = @(& ssh-keygen.exe -y -f $privateKey 2>&1)
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
        if ($code -ne 0 -or $derived.Count -lt 1) { Fail 'SSH_AUTH_KEY_GENERATION_FAILED' 'Unable to derive public key from existing Runner id_ed25519.' }
        ("{0} xinzhaowrt-controller" -f ([string]$derived[0]).Trim()) | Set-Content -Encoding ASCII $publicKey
        Write-Host "SSH_AUTH_RUNNER_PUBLIC_KEY=DERIVED path=$publicKey"
    }
    else {
        Write-Host "SSH_AUTH_RUNNER_KEY=REUSE path=$privateKey"
    }

    $publicLine = (Get-Content -Raw $publicKey).Trim()
    $parts = @($publicLine -split '\s+' | Where-Object { $_ })
    if ($parts.Count -lt 2 -or $parts[0] -ne 'ssh-ed25519' -or $parts[1] -notmatch '^[A-Za-z0-9+/=]+$') {
        Fail 'SSH_AUTH_KEY_GENERATION_FAILED' 'Runner id_ed25519 public key is invalid.'
    }
    return ("ssh-ed25519 {0} xinzhaowrt-controller" -f $parts[1])
}

function Install-RunnerPublicKey {
    param(
        [Parameter(Mandatory=$true)][string]$KnownHostsFile,
        [Parameter(Mandatory=$true)][string]$Password,
        [Parameter(Mandatory=$true)][string]$PublicKeyLine
    )
    if ($PublicKeyLine -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+ xinzhaowrt-controller$') {
        Fail 'SSH_AUTH_KEY_GENERATION_FAILED' 'Refusing to install an unexpected Runner public-key format.'
    }
    $remote = "umask 077; mkdir -p /etc/dropbear; touch /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys; grep -qxF '$PublicKeyLine' /etc/dropbear/authorized_keys || printf '%s\n' '$PublicKeyLine' >> /etc/dropbear/authorized_keys"
    $install = Invoke-SshPasswordCapture -KnownHostsFile $KnownHostsFile -StrictMode 'yes' -Command $remote -Password $Password
    if ($install.ExitCode -ne 0) {
        $class = Classify-ArthurSshProbe -ExitCode $install.ExitCode -Output $install.Output
        if ($class -eq 'SSH_HOST_IDENTITY_MISMATCH') { Fail 'SSH_HOST_IDENTITY_MISMATCH' $install.Output }
        if ($class -eq 'SSH_AUTH_FAILED') { Fail 'SSH_AUTH_FAILED' "Initial credential stopped authenticating before Runner key installation: $($install.Output)" }
        Fail 'SSH_AUTH_KEY_INSTALL_FAILED' "Unable to install Runner public key: $($install.Output)"
    }
    Write-Host 'SSH_AUTH_KEY_INSTALL=PASS path=/etc/dropbear/authorized_keys'
}

function Invoke-PasswordAuthBootstrap {
    param(
        [Parameter(Mandatory=$true)][string]$KnownHostsFile,
        [Parameter(Mandatory=$true)][string]$StrictMode,
        [Parameter(Mandatory=$true)][string]$SshDirectory
    )
    $password = Get-InitialRootPassword
    $board = Invoke-SshPasswordCapture -KnownHostsFile $KnownHostsFile -StrictMode $StrictMode -Command 'ubus call system board' -Password $password
    if ($board.ExitCode -ne 0) {
        $class = Classify-ArthurSshProbe -ExitCode $board.ExitCode -Output $board.Output
        if ($class -eq 'SSH_HOST_IDENTITY_MISMATCH') { Fail 'SSH_HOST_IDENTITY_MISMATCH' $board.Output }
        if ($class -eq 'SSH_AUTH_FAILED') { Fail 'SSH_AUTH_FAILED' "Project initial credential did not authenticate the Arthur endpoint; no trust or Runner key was installed. $($board.Output)" }
        Fail 'DEVICE_UNREACHABLE' "Unable to authenticate the Arthur endpoint for SSH key bootstrap: $($board.Output)"
    }
    if (-not (Test-ArthurBoardIdentity -BoardOutput $board.Output)) {
        Fail 'DEVICE_IDENTITY_MISMATCH' "Password-authenticated SSH endpoint is not JDCloud RE-SS-01: $($board.Output)"
    }
    Write-Host 'SSH_AUTH_TEMP_BOARD=PASS device=jdcloud_re-ss-01'

    $sshBuild = Get-RemoteBuildInfoPassword -KnownHostsFile $KnownHostsFile -StrictMode 'yes' -Password $password
    if (-not (Test-ArthurBuildInfoMatchesBaseline -BuildInfo $sshBuild -Baseline $Baseline)) {
        Fail 'REAL_DEVICE_BASELINE_BUILD_MISMATCH' "Password-authenticated SSH build identity does not match baseline $($Baseline.firmware.version)/$($Baseline.firmware.build_id)/$($Baseline.firmware.displayed_git_commit)."
    }
    Write-Host "SSH_AUTH_TEMP_BUILD=PASS version=$($sshBuild.Version) build_id=$($sshBuild.'Build ID') commit=$($sshBuild.'Git Commit')"

    $publicKeyLine = Ensure-RunnerSshIdentity -SshDirectory $SshDirectory
    Install-RunnerPublicKey -KnownHostsFile $KnownHostsFile -Password $password -PublicKeyLine $publicKeyLine
    Write-Host 'SSH_AUTH_BOOTSTRAP=PASS mode=initial-password-to-runner-key'
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
    Fail 'DEVICE_UNREACHABLE' "Unable to obtain read-only HTTP build identity from ${httpUri}: $($_.Exception.Message)"
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
    # Existing trust is never replaced automatically. First try the normal key-auth path.
    $existingBoard = Invoke-SshCapture -KnownHostsFile $knownHosts -StrictMode 'yes' -Command 'ubus call system board'
    if ($existingBoard.ExitCode -ne 0) {
        $existingClass = Classify-ArthurSshProbe -ExitCode $existingBoard.ExitCode -Output $existingBoard.Output
        if ($existingClass -eq 'SSH_AUTH_FAILED') {
            Invoke-PasswordAuthBootstrap -KnownHostsFile $knownHosts -StrictMode 'yes' -SshDirectory $sshDir
            $existingBoard = Invoke-SshCapture -KnownHostsFile $knownHosts -StrictMode 'yes' -Command 'ubus call system board'
            if ($existingBoard.ExitCode -ne 0) {
                Fail 'SSH_AUTH_FAILED' "Runner key bootstrap completed but strict BatchMode=yes authentication still failed: $($existingBoard.Output)"
            }
        }
        elseif ($existingClass -eq 'SSH_HOST_IDENTITY_MISMATCH') {
            Fail 'SSH_HOST_IDENTITY_MISMATCH' "Existing known_hosts entry did not verify strictly and will not be replaced: $($existingBoard.Output)"
        }
        else {
            Fail 'DEVICE_UNREACHABLE' "Existing trusted Arthur endpoint is not reachable: $($existingBoard.Output)"
        }
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

# First try normal key auth while capturing an unknown first-use host key only in a disposable trust store.
$boardProbe = Invoke-SshCapture -KnownHostsFile $tempKnownHosts -StrictMode 'accept-new' -Command 'ubus call system board'
$usedPasswordBootstrap = $false
if ($boardProbe.ExitCode -ne 0) {
    $class = Classify-ArthurSshProbe -ExitCode $boardProbe.ExitCode -Output $boardProbe.Output
    if ($class -eq 'SSH_AUTH_FAILED') {
        $tempStrictMode = if (@(Get-KnownHostLines -Path $tempKnownHosts).Count -gt 0) { 'yes' } else { 'accept-new' }
        Invoke-PasswordAuthBootstrap -KnownHostsFile $tempKnownHosts -StrictMode $tempStrictMode -SshDirectory $sshDir
        $usedPasswordBootstrap = $true
        $boardProbe = Invoke-SshCapture -KnownHostsFile $tempKnownHosts -StrictMode 'yes' -Command 'ubus call system board'
        if ($boardProbe.ExitCode -ne 0) {
            Fail 'SSH_AUTH_FAILED' "Runner key was installed but temporary strict BatchMode=yes authentication failed: $($boardProbe.Output)"
        }
    }
    elseif ($class -eq 'SSH_HOST_IDENTITY_MISMATCH') {
        Fail 'SSH_HOST_IDENTITY_MISMATCH' $boardProbe.Output
    }
    else {
        Fail 'DEVICE_UNREACHABLE' "Unable to verify Arthur board through temporary trust: $($boardProbe.Output)"
    }
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
    if ($strictBoard.ExitCode -ne 0) {
        $strictClass = Classify-ArthurSshProbe -ExitCode $strictBoard.ExitCode -Output $strictBoard.Output
        throw "STRICT_VERIFY_CLASS=$strictClass detail=$($strictBoard.Output)"
    }
    if (-not (Test-ArthurBoardIdentity -BoardOutput $strictBoard.Output)) {
        throw "STRICT_VERIFY_CLASS=DEVICE_IDENTITY_MISMATCH detail=$($strictBoard.Output)"
    }
    $strictBuild = Get-RemoteBuildInfo -KnownHostsFile $knownHosts -StrictMode 'yes'
    if (-not (Test-ArthurBuildInfoMatchesBaseline -BuildInfo $strictBuild -Baseline $Baseline)) {
        throw 'STRICT_VERIFY_CLASS=REAL_DEVICE_BASELINE_BUILD_MISMATCH detail=Strict post-enrollment build verification does not match the physical baseline.'
    }
}
catch {
    $strictError = $_.Exception.Message
    if ($hadKnownHosts -and $backup -and (Test-Path $backup)) {
        Copy-Item -Force $backup $knownHosts
    }
    elseif (-not $hadKnownHosts) {
        [System.IO.File]::WriteAllText($knownHosts,'',[System.Text.Encoding]::ASCII)
    }
    if ($strictError -match 'STRICT_VERIFY_CLASS=SSH_AUTH_FAILED') { Fail 'SSH_AUTH_FAILED' "Host key enrollment was rolled back because strict Runner key authentication failed. $strictError" }
    if ($strictError -match 'STRICT_VERIFY_CLASS=DEVICE_IDENTITY_MISMATCH|STRICT_VERIFY_CLASS=REAL_DEVICE_BASELINE_BUILD_MISMATCH|STRICT_VERIFY_CLASS=SSH_HOST_IDENTITY_MISMATCH') {
        Fail 'SSH_HOST_IDENTITY_MISMATCH' "Host-key enrollment was rolled back because strict identity verification failed. $strictError"
    }
    Fail 'DEVICE_UNREACHABLE' "Host-key enrollment was rolled back because strict verification could not complete. $strictError"
}

$mode = if ($usedPasswordBootstrap) { 'enrolled-first-use-auth-recovered' } else { 'enrolled-first-use' }
Write-Host "SSH_HOST_KEY_BOOTSTRAP=PASS target=$TargetIp mode=$mode"
