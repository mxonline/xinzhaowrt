$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'scripts\ensure-arthur-unattended-access.ps1')

$script:MockNeighbors = @()

function Get-NetRoute {
    [CmdletBinding()]
    param([string]$AddressFamily)
    @([pscustomobject]@{
        DestinationPrefix = '192.168.6.0/24'
        InterfaceIndex = 18
        RouteMetric = 256
        NextHop = '0.0.0.0'
    })
}

function Get-NetAdapter {
    [CmdletBinding()]
    param([int]$InterfaceIndex)
    [pscustomobject]@{
        InterfaceIndex = $InterfaceIndex
        Name = 'Ethernet'
        InterfaceDescription = 'Test Ethernet Adapter'
        Status = 'Up'
    }
}

function Test-Connection {
    [CmdletBinding()]
    param([string]$ComputerName,[int]$Count,[switch]$Quiet)
    $true
}

function Start-Sleep {
    param([int]$Milliseconds)
}

function Get-NetNeighbor {
    [CmdletBinding()]
    param([string]$AddressFamily,[string]$IPAddress)
    $script:MockNeighbors
}

function Invoke-WebRequest {
    [CmdletBinding()]
    param([switch]$UseBasicParsing,[string]$Uri,[int]$TimeoutSec)
    [pscustomobject]@{ Content = '{"Firmware":"XinZhaoWrt","Target":"qualcommax/ipq60xx","Profile":"jdcloud_re-ss-01","Version":"0.1.5","Build ID":"36764137044"}' }
}

$policy = [pscustomobject]@{
    device = [pscustomobject]@{
        verified_management_mac = 'dc:d8:7c:45:91:99'
        build_marker = 'XinZhaoWrt'
        build_info_path = '/luci-static/xinzhao/build-info.json'
    }
}
$oldInformationPreference = $InformationPreference
$InformationPreference = 'SilentlyContinue'

try {
    # A different adapter's neighbor is deliberately first. The Ethernet route
    # is interface 18 and its unique MAC matches the frozen management identity.
    $script:MockNeighbors = @(
        [pscustomobject]@{ InterfaceIndex = 7; IPAddress = '192.168.6.1'; LinkLayerAddress = '00:11:22:33:44:55'; State = 'Reachable' },
        [pscustomobject]@{ InterfaceIndex = 18; IPAddress = '192.168.6.1'; LinkLayerAddress = 'dc:d8:7c:45:91:99'; State = 'Reachable' }
    )
    try {
        $null = Assert-ArthurEthernetIdentity -DeviceIp '192.168.6.1' -Policy $policy
    }
    catch {
        throw "TEST_FAIL: neighbor selection must use the selected Ethernet interface; $($_.Exception.Message)"
    }

    # Two different usable MACs on the selected interface cannot identify one
    # management endpoint safely.
    $script:MockNeighbors = @(
        [pscustomobject]@{ InterfaceIndex = 18; IPAddress = '192.168.6.1'; LinkLayerAddress = 'dc:d8:7c:45:91:99'; State = 'Reachable' },
        [pscustomobject]@{ InterfaceIndex = 18; IPAddress = '192.168.6.1'; LinkLayerAddress = 'dc:d8:7c:46:91:24'; State = 'Stale' }
    )
    $ambiguous = $false
    try { $null = Assert-ArthurEthernetIdentity -DeviceIp '192.168.6.1' -Policy $policy }
    catch { $ambiguous = $_.Exception.Message -match 'AMBIGUOUS_MANAGEMENT_IDENTITY' }
    if (-not $ambiguous) { throw 'TEST_FAIL: distinct usable MACs on the selected interface must fail as ambiguous.' }

    # A neighbor on another interface cannot substitute for a missing Ethernet
    # neighbor, even when it is the only record returned for this IP.
    $script:MockNeighbors = @(
        [pscustomobject]@{ InterfaceIndex = 7; IPAddress = '192.168.6.1'; LinkLayerAddress = 'dc:d8:7c:45:91:99'; State = 'Reachable' }
    )
    $unresolved = $false
    try { $null = Assert-ArthurEthernetIdentity -DeviceIp '192.168.6.1' -Policy $policy }
    catch { $unresolved = $_.Exception.Message -match 'DEVICE_UNREACHABLE|IDENTITY_UNRESOLVED' }
    if (-not $unresolved) { throw 'TEST_FAIL: no selected-interface neighbor must remain unresolved.' }

    # Forensics may investigate an old frozen pin only with authenticated
    # identity evidence, using a disposable trust store and the existing key.
    # It must not modify the formal known_hosts file or enroll a remote key.
    $script:MockNeighbors = @(
        [pscustomobject]@{ InterfaceIndex = 18; IPAddress = '192.168.6.1'; LinkLayerAddress = 'dc:d8:7c:45:91:99'; State = 'Reachable' }
    )
    $script:ForensicPolicy = [pscustomobject]@{
        device = [pscustomobject]@{
            management_ip = '192.168.6.1'
            verified_management_mac = 'dc:d8:7c:46:91:24'
            board_pattern = 'jdcloud,re-ss-01|RE-SS-01'
            build_marker = 'XinZhaoWrt'
            build_info_path = '/luci-static/xinzhao/build-info.json'
        }
    }
    $script:ForensicSshCalls = @()
    $script:KnownHostWriteCount = 0
    $script:ForensicProbeExitCode = 0
    $script:MockRemoteIdentity = @'
{"model":"jdcloud,re-ss-01"}
---XINZHAO_BUILD---
{"Firmware":"XinZhaoWrt","Target":"qualcommax/ipq60xx","Profile":"jdcloud_re-ss-01","Version":"0.1.5","Build ID":"36764137044"}
---REMOTE_BR_LAN_MAC---
dc:d8:7c:45:91:99
---REMOTE_LINKS---
br-lan UP 00:00:00:00:00:00
---REMOTE_LAN_STATUS---
{"up":true}
'@
    $script:ForensicProbeOutput = $script:MockRemoteIdentity
    function Get-ArthurAccessPolicy { $script:ForensicPolicy }
    function Invoke-ArthurSshProbe {
        [CmdletBinding()]
        param(
            [string]$DeviceIp,
            [string]$KnownHostsFile,
            [ValidateSet('yes','accept-new')][string]$StrictMode,
            [string]$Command,
            [string]$IdentityFile,
            [switch]$PasswordAuth
        )
        $script:ForensicSshCalls += [pscustomobject]@{
            KnownHostsFile = $KnownHostsFile
            StrictMode = $StrictMode
            Command = $Command
            IdentityFile = $IdentityFile
            PasswordAuth = $PasswordAuth.IsPresent
        }
        [pscustomobject]@{ ExitCode = $script:ForensicProbeExitCode; Output = $script:ForensicProbeOutput }
    }
    function Set-ArthurVerifiedKnownHost {
        $script:KnownHostWriteCount++
        throw 'TEST_FAIL: forensic mode must not change formal known_hosts.'
    }
    try {
        $forensic = Invoke-ArthurReadOnlyIdentityForensics -DeviceIp '192.168.6.1'
    }
    catch {
        throw "TEST_FAIL: read-only forensic mode must gather identity evidence when the frozen MAC is stale; $($_.Exception.Message)"
    }
    if ($forensic.LocalEthernetMac -ne 'dc:d8:7c:45:91:99') { throw 'TEST_FAIL: forensic result must report the selected Ethernet neighbor MAC.' }
    if ($forensic.RemoteBrLanMac -ne 'dc:d8:7c:45:91:99') { throw 'TEST_FAIL: forensic result must report the remote br-lan MAC.' }
    if ($forensic.FrozenManagementMacStatus -ne 'STALE') { throw 'TEST_FAIL: stale frozen MAC must be reported without being silently accepted.' }
    if ($forensic.HttpIdentity -ne 'PASS' -or $forensic.RunnerKeyAuth -ne 'PASS') { throw 'TEST_FAIL: HTTP and runner-key evidence must both pass.' }
    if ($script:ForensicSshCalls.Count -ne 1 -or $script:ForensicSshCalls[0].StrictMode -ne 'accept-new') { throw 'TEST_FAIL: SSH forensics must use one disposable accept-new trust store.' }
    if ($script:ForensicSshCalls[0].KnownHostsFile -eq (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh\known_hosts')) { throw 'TEST_FAIL: SSH forensics must never use formal known_hosts.' }
    if ($script:ForensicSshCalls[0].PasswordAuth) { throw 'TEST_FAIL: SSH forensics must not use password authentication or enroll a key.' }
    if ($script:ForensicSshCalls[0].IdentityFile -ne (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh\id_ed25519')) { throw 'TEST_FAIL: SSH forensics must use the existing runner key file.' }
    if ($script:ForensicSshCalls[0].Command -match '(?i)authorized_keys|uci\s+(set|commit)|reboot|sysupgrade|mtd|dd\s') { throw 'TEST_FAIL: forensic SSH command must remain read-only.' }
    if ($script:KnownHostWriteCount -ne 0 -or $forensic.FormalKnownHostsChanged) { throw 'TEST_FAIL: forensic mode must not change the formal host-key store.' }

    $script:ForensicProbeExitCode = 255
    $script:ForensicProbeOutput = 'Permission denied (publickey).'
    $authFailure = ''
    try { Invoke-ArthurReadOnlyIdentityForensics -DeviceIp '192.168.6.1' | Out-Null }
    catch { $authFailure = $_.Exception.Message }
    if ($authFailure -notmatch 'TEMP_SSH_EXISTING_RUNNER_KEY_AUTH=FAIL class=AUTH_RECOVERY_REQUIRED') {
        throw 'TEST_FAIL: runner-key authentication failure must be classified without password fallback.'
    }
    if ($script:ForensicSshCalls[-1].PasswordAuth -or $script:KnownHostWriteCount -ne 0) { throw 'TEST_FAIL: failed runner-key forensics must not enroll credentials or alter known_hosts.' }

    Write-Output 'ARTHUR_INTERFACE_SCOPED_MAC_TEST=PASS'
    Write-Output 'ARTHUR_READONLY_IDENTITY_FORENSICS_TEST=PASS'
    Write-Output 'ARTHUR_FORENSICS_AUTH_FAILURE_GUARD_TEST=PASS'
}
finally {
    $InformationPreference = $oldInformationPreference
}
