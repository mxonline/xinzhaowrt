$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'scripts\ensure-arthur-unattended-access.ps1')

$policy = [pscustomobject]@{
    device = [pscustomobject]@{
        verified_management_mac = 'dc:d8:7c:45:91:99'
        board_pattern = 'jdcloud,re-ss-01|RE-SS-01'
        build_marker = 'XinZhaoWrt'
        build_info_path = '/luci-static/xinzhao/build-info.json'
    }
}

$validOutput = @'
{"model":"jdcloud,re-ss-01"}
---XINZHAO_BUILD---
{"Firmware":"XinZhaoWrt","Target":"qualcommax/ipq60xx","Profile":"jdcloud_re-ss-01","Version":"0.1.5","Build ID":"36764137044"}
---REMOTE_BR_LAN_MAC---
dc:d8:7c:45:91:99
---REMOTE_LINKS---
br-lan UP
---REMOTE_LAN_STATUS---
{"up":true}
'@
$probe = [pscustomobject]@{ ExitCode = 0; Output = $validOutput }

if (-not (Get-Command Test-ArthurReadOnlyAuthenticatedEvidence -ErrorAction SilentlyContinue)) {
    throw 'TEST_FAIL: password identity acceptance must include an explicit br-lan identity verifier.'
}
if (-not (Test-ArthurReadOnlyAuthenticatedEvidence -Probe $probe -Policy $policy)) {
    throw 'TEST_FAIL: matching board, build, target, profile, and br-lan MAC must pass.'
}

$wrongMac = [pscustomobject]@{ ExitCode = 0; Output = ($validOutput -replace 'dc:d8:7c:45:91:99','dc:d8:7c:46:91:24') }
if (Test-ArthurReadOnlyAuthenticatedEvidence -Probe $wrongMac -Policy $policy) {
    throw 'TEST_FAIL: a mismatched br-lan MAC must fail before any device write.'
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("arthur-key-scope-{0}" -f [guid]::NewGuid().ToString('N'))
$sshDir = Join-Path $tempRoot '.ssh'
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
$trustDir = Join-Path $tempRoot 'temporary-trust'
New-Item -ItemType Directory -Path $trustDir -Force | Out-Null
$knownHosts = Join-Path $trustDir 'candidate.known_hosts'
$privateKey = Join-Path $sshDir 'id_ed25519'
$publicKey = "$privateKey.pub"
$expectedPublicKey = 'AAAAC3NzaC1lZDI1NTE5AAAAIFRlc3RLZXlCeXRlcw=='
[System.IO.File]::WriteAllText($privateKey,'test-only-private-key-placeholder')
[System.IO.File]::WriteAllText($publicKey,"ssh-ed25519 $expectedPublicKey xinzhaowrt-controller")

$originalAuthorizedKeys = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFByZXZpb3VzS2V5 prior`n"
$originalBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($originalAuthorizedKeys))
$script:ProbeCalls = @()
$script:BackupPresent = $true
$script:DerivedPublicKey = $expectedPublicKey
function Invoke-ArthurAccessNative {
    param([string]$FilePath,[string[]]$Arguments)
    if ($Arguments.Count -eq 3 -and $Arguments[0] -eq '-y' -and $Arguments[1] -eq '-f') {
        return [pscustomobject]@{ ExitCode = 0; Output = "ssh-ed25519 $script:DerivedPublicKey" }
    }
    throw 'TEST_FAIL: unexpected local SSH native invocation in mocked key-scope test.'
}
function Invoke-ArthurSshProbe {
    param(
        [string]$DeviceIp,
        [string]$KnownHostsFile,
        [ValidateSet('yes','accept-new')][string]$StrictMode,
        [string]$Command,
        [string]$IdentityFile,
        [switch]$PasswordAuth
    )
    $script:ProbeCalls += [pscustomobject]@{ Command = $Command; PasswordAuth = $PasswordAuth.IsPresent }
    if ($Command -match 'base64') {
        if ($script:BackupPresent) { return [pscustomobject]@{ ExitCode = 0; Output = "ARTHUR_AUTHKEYS_PRESENT`n$originalBase64" } }
        return [pscustomobject]@{ ExitCode = 0; Output = 'ARTHUR_AUTHKEYS_MISSING' }
    }
    return [pscustomobject]@{ ExitCode = 0; Output = 'BACKUP_EXISTING' }
}

try {
    $missingKeyDirectory = Join-Path $tempRoot 'missing-controller-key'
    $missingKeyFailure = ''
    try { Ensure-ArthurRunnerKey -DeviceIp '192.168.6.1' -KnownHostsFile $knownHosts -RunnerKeyDirectory $missingKeyDirectory | Out-Null }
    catch { $missingKeyFailure = $_.Exception.Message }
    if ($missingKeyFailure -notmatch 'existing controller SSH keypair is unavailable') {
        throw 'TEST_FAIL: key repair must require the existing controller keypair instead of generating another key.'
    }
    if (Test-Path -LiteralPath $missingKeyDirectory) {
        throw 'TEST_FAIL: missing controller keypair must not create a new key in a temporary trust directory.'
    }

    $script:DerivedPublicKey = 'AAAAC3NzaC1lZDI1NTE5AAAAIURpZmZlcmVudEtleQ=='
    $mismatchFailure = ''
    try { Ensure-ArthurRunnerKey -DeviceIp '192.168.6.1' -KnownHostsFile $knownHosts -RunnerKeyDirectory $sshDir | Out-Null }
    catch { $mismatchFailure = $_.Exception.Message }
    if ($mismatchFailure -notmatch 'does not match the existing private key' -or $script:ProbeCalls.Count -ne 0) {
        throw 'TEST_FAIL: a public key that differs from the current private key must fail before remote access.'
    }
    $script:DerivedPublicKey = $expectedPublicKey

    $record = Ensure-ArthurRunnerKey -DeviceIp '192.168.6.1' -KnownHostsFile $knownHosts -RunnerKeyDirectory $sshDir
    if (-not $record.BackupPath -or -not (Test-Path -LiteralPath $record.BackupPath -PathType Leaf)) {
        throw 'TEST_FAIL: existing authorized_keys must be backed up to the runner before the device write.'
    }
    $saved = [System.IO.File]::ReadAllText($record.BackupPath)
    if ($saved -ne $originalAuthorizedKeys) {
        throw 'TEST_FAIL: runner backup must preserve the exact existing authorized_keys bytes.'
    }

    foreach ($call in $script:ProbeCalls) {
        $remotePaths = @([regex]::Matches($call.Command,'/etc/dropbear/[A-Za-z0-9_.-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        if ($remotePaths | Where-Object { $_ -ne '/etc/dropbear/authorized_keys' }) {
            throw "TEST_FAIL: remote command touched a path outside /etc/dropbear/authorized_keys: $($remotePaths -join ',')"
        }
    }
    if (@($script:ProbeCalls | Where-Object { $_.Command -match [regex]::Escape($expectedPublicKey) }).Count -lt 1) {
        throw 'TEST_FAIL: remote key installation must use the existing runner public key.'
    }

    $script:ProbeCalls = @()
    $env:ARTHUR_ROOT_PASSWORD = 'test-only-not-a-real-password'
    Restore-ArthurRunnerKey -DeviceIp '192.168.6.1' -KnownHostsFile $knownHosts -Record $record
    if ($script:ProbeCalls.Count -ne 1) { throw 'TEST_FAIL: failed strict verification must perform one exact rollback command.' }
    $rollbackPaths = @([regex]::Matches($script:ProbeCalls[0].Command,'/etc/dropbear/[A-Za-z0-9_.-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($rollbackPaths.Count -ne 1 -or $rollbackPaths[0] -ne '/etc/dropbear/authorized_keys') {
        throw 'TEST_FAIL: rollback may only restore /etc/dropbear/authorized_keys.'
    }
    if ($script:ProbeCalls[0].Command -notmatch [regex]::Escape($originalBase64)) {
        throw 'TEST_FAIL: rollback must restore the exact runner-side backup content.'
    }

    $script:ProbeCalls = @()
    $script:BackupPresent = $false
    $missingRecord = Ensure-ArthurRunnerKey -DeviceIp '192.168.6.1' -KnownHostsFile $knownHosts -RunnerKeyDirectory $sshDir
    if ($missingRecord.HadFile -or $missingRecord.BackupPath) {
        throw 'TEST_FAIL: absence of an original authorized_keys file must be recorded without a fabricated backup.'
    }
    $script:ProbeCalls = @()
    Restore-ArthurRunnerKey -DeviceIp '192.168.6.1' -KnownHostsFile $knownHosts -Record $missingRecord
    if ($script:ProbeCalls.Count -ne 1 -or $script:ProbeCalls[0].Command -ne 'rm -f /etc/dropbear/authorized_keys') {
        throw 'TEST_FAIL: rollback must remove only authorized_keys when no original file existed.'
    }

    $script:RecoveryPolicy = [pscustomobject]@{
        device = [pscustomobject]@{
            management_ip = '192.168.6.1'
            verified_management_mac = 'dc:d8:7c:45:91:99'
            board_pattern = 'jdcloud,re-ss-01|RE-SS-01'
            build_marker = 'XinZhaoWrt'
            build_info_path = '/luci-static/xinzhao/build-info.json'
        }
    }
    $script:EnsureKeyCallCount = 0
    $script:RecoveryProbeCalls = @()
    function Get-ArthurAccessPolicy { $script:RecoveryPolicy }
    function Assert-ArthurEthernetIdentity { param([string]$DeviceIp,$Policy) [pscustomobject]@{ Network = $null; Build = $null } }
    function Ensure-ArthurRunnerKey { $script:EnsureKeyCallCount++; [pscustomobject]@{ Changed = $true } }
    function Invoke-ArthurSshProbe {
        param(
            [string]$DeviceIp,
            [string]$KnownHostsFile,
            [ValidateSet('yes','accept-new')][string]$StrictMode,
            [string]$Command,
            [string]$IdentityFile,
            [switch]$PasswordAuth
        )
        $script:RecoveryProbeCalls += [pscustomobject]@{ Command = $Command; StrictMode = $StrictMode; PasswordAuth = $PasswordAuth.IsPresent }
        if (-not $PasswordAuth) {
            return [pscustomobject]@{ ExitCode = 255; Output = 'Permission denied (publickey).' }
        }
        if ($Command -match 'REMOTE_BR_LAN_MAC') {
            return [pscustomobject]@{ ExitCode = 0; Output = ($validOutput -replace 'dc:d8:7c:45:91:99','dc:d8:7c:46:91:24') }
        }
        return [pscustomobject]@{ ExitCode = 0; Output = $validOutput }
    }

    $env:ARTHUR_ROOT_PASSWORD = 'test-only-not-a-real-password'
    $identityMismatch = ''
    try { Ensure-ArthurUnattendedAccess -DeviceIp '192.168.6.1' | Out-Null }
    catch { $identityMismatch = $_.Exception.Message }
    if ($identityMismatch -notmatch 'AUTHENTICATED_DEVICE_IDENTITY_MISMATCH') {
        throw 'TEST_FAIL: a password-authenticated br-lan MAC mismatch must abort recovery.'
    }
    if ($script:EnsureKeyCallCount -ne 0 -or $script:RecoveryProbeCalls.Command -match 'authorized_keys') {
        throw 'TEST_FAIL: the helper must prove br-lan identity before calling the device key writer.'
    }

    $script:RecoveryProbeCalls = @()
    $script:KeyInstalled = $false
    function Ensure-ArthurRunnerKey {
        $script:EnsureKeyCallCount++
        $script:KeyInstalled = $true
        [pscustomobject]@{ Changed = $true }
    }
    function Set-ArthurVerifiedKnownHost { [pscustomobject]@{ HadKnownHosts = $true; Backup = 'test-backup' } }
    function Invoke-ArthurSshProbe {
        param(
            [string]$DeviceIp,
            [string]$KnownHostsFile,
            [ValidateSet('yes','accept-new')][string]$StrictMode,
            [string]$Command,
            [string]$IdentityFile,
            [switch]$PasswordAuth
        )
        $script:RecoveryProbeCalls += [pscustomobject]@{ Command = $Command; StrictMode = $StrictMode; PasswordAuth = $PasswordAuth.IsPresent }
        if ($PasswordAuth -or $script:KeyInstalled) { return [pscustomobject]@{ ExitCode = 0; Output = $validOutput } }
        return [pscustomobject]@{ ExitCode = 255; Output = 'Permission denied (publickey).' }
    }
    $recovered = @(Ensure-ArthurUnattendedAccess -DeviceIp '192.168.6.1')
    if ($recovered.Count -ne 1 -or $recovered[0].Mode -ne 'password-recovered-runner-key') {
        throw 'TEST_FAIL: recovery must return only its result object after the Ethernet assertion.'
    }

    Write-Output 'ARTHUR_PASSWORD_IDENTITY_INCLUDES_BRLAN_MAC=PASS'
    Write-Output 'ARTHUR_AUTHORIZED_KEYS_REMOTE_WRITE_SCOPE=PASS'
    Write-Output 'ARTHUR_AUTHORIZED_KEYS_ROLLBACK=PASS'
    Write-Output 'ARTHUR_NO_KEY_WRITE_BEFORE_BRLAN_IDENTITY=PASS'
}
finally {
    Remove-Item Env:ARTHUR_ROOT_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -LiteralPath $tempRoot
}
