$script:ArthurAccessAskPassExe = $null

function Get-ArthurAccessPolicy {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $path = Join-Path $root 'production\arthur-control-plane.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "ARTHUR_CONTROL_POLICY_MISSING path=$path"
    }
    $policy = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    if ([int]$policy.schema_version -ne 1) { throw 'ARTHUR_CONTROL_POLICY_SCHEMA_UNSUPPORTED' }
    return $policy
}

function Invoke-ArthurAccessNative {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$Arguments
    )
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $FilePath @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    [pscustomobject]@{ ExitCode = $code; Output = (($raw | ForEach-Object { [string]$_ }) -join "`n").Trim() }
}

function Get-ArthurSshTool([string]$Name) {
    $candidates = if ($Name -eq 'ssh') { @('ssh.exe','ssh') } elseif ($Name -eq 'ssh-keygen') { @('ssh-keygen.exe','ssh-keygen') } else { @($Name) }
    foreach ($candidate in $candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    throw "ARTHUR_ACCESS_TOOL_MISSING tool=$Name"
}

function Invoke-ArthurSshProbe {
    param(
        [Parameter(Mandatory=$true)][string]$DeviceIp,
        [Parameter(Mandatory=$true)][string]$KnownHostsFile,
        [Parameter(Mandatory=$true)][ValidateSet('yes','accept-new')][string]$StrictMode,
        [Parameter(Mandatory=$true)][string]$Command,
        [string]$IdentityFile,
        [switch]$PasswordAuth
    )
    $ssh = Get-ArthurSshTool 'ssh'
    $args = @(
        '-o', "UserKnownHostsFile=$KnownHostsFile",
        '-o', "StrictHostKeyChecking=$StrictMode",
        '-o', 'ConnectTimeout=8',
        '-o', 'ServerAliveInterval=4',
        '-o', 'ServerAliveCountMax=2'
    )

    if ($PasswordAuth) {
        if ([string]::IsNullOrWhiteSpace($env:ARTHUR_ROOT_PASSWORD)) {
            return [pscustomobject]@{ ExitCode = 61; Output = 'UNRECOVERABLE_SSH_AUTH: ARTHUR_ROOT_PASSWORD is unavailable.' }
        }
        $askPass = Get-ArthurAskPassHelper
        $oldAskPass = $env:SSH_ASKPASS
        $oldRequire = $env:SSH_ASKPASS_REQUIRE
        $oldDisplay = $env:DISPLAY
        try {
            $env:SSH_ASKPASS = $askPass
            $env:SSH_ASKPASS_REQUIRE = 'force'
            $env:DISPLAY = 'xinzhaowrt-unattended'
            $args += @('-o','BatchMode=no','-o','PreferredAuthentications=password','-o','PubkeyAuthentication=no','-o','NumberOfPasswordPrompts=1')
            $args += @("root@$DeviceIp", $Command)
            return Invoke-ArthurAccessNative -FilePath $ssh -Arguments $args
        }
        finally {
            if ($null -eq $oldAskPass) { Remove-Item Env:SSH_ASKPASS -ErrorAction SilentlyContinue } else { $env:SSH_ASKPASS = $oldAskPass }
            if ($null -eq $oldRequire) { Remove-Item Env:SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue } else { $env:SSH_ASKPASS_REQUIRE = $oldRequire }
            if ($null -eq $oldDisplay) { Remove-Item Env:DISPLAY -ErrorAction SilentlyContinue } else { $env:DISPLAY = $oldDisplay }
        }
    }

    $args += @('-o','BatchMode=yes')
    if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
        $args += @('-o','IdentitiesOnly=yes','-i',$IdentityFile)
    }
    $args += @("root@$DeviceIp",$Command)
    return Invoke-ArthurAccessNative -FilePath $ssh -Arguments $args
}

function Get-ArthurAskPassHelper {
    if ($script:ArthurAccessAskPassExe -and (Test-Path -LiteralPath $script:ArthurAccessAskPassExe)) {
        return $script:ArthurAccessAskPassExe
    }
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("xinzhaowrt-arthur-askpass-{0}.exe" -f $PID)
    Remove-Item -Force -ErrorAction SilentlyContinue $path
    $source = @'
using System;
public static class XinZhaoWrtArthurAskPass {
    public static int Main(string[] args) {
        string value = Environment.GetEnvironmentVariable("ARTHUR_ROOT_PASSWORD");
        if (String.IsNullOrEmpty(value)) return 1;
        Console.WriteLine(value);
        return 0;
    }
}
'@
    $compilerCandidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $compilerCommand = Get-Command csc.exe -ErrorAction SilentlyContinue
    if ($compilerCommand) { $compilerCandidates += $compilerCommand.Source }
    $compiler = $compilerCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (-not $compiler) { throw 'ARTHUR_ASKPASS_COMPILER_MISSING' }

    $sourcePath = Join-Path ([System.IO.Path]::GetTempPath()) ("xinzhaowrt-arthur-askpass-{0}.cs" -f $PID)
    try {
        [System.IO.File]::WriteAllText($sourcePath,$source,[System.Text.UTF8Encoding]::new($false))
        $compilerOutput = @(& $compiler '/nologo' '/target:exe' "/out:$path" $sourcePath 2>&1)
        $compilerExitCode = $LASTEXITCODE
    }
    finally {
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $sourcePath
    }
    if ($compilerExitCode -ne 0) { throw "ARTHUR_ASKPASS_HELPER_COMPILE_FAILED exit=$compilerExitCode" }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'ARTHUR_ASKPASS_HELPER_FAILED' }
    $script:ArthurAccessAskPassExe = $path
    return $path
}

function Get-ArthurSshFailureClass {
    param([int]$ExitCode,[string]$Output)
    if ($ExitCode -eq 0) { return 'PASS' }
    if ($Output -match '(?i)REMOTE HOST IDENTIFICATION HAS CHANGED|Offending .* key|Host key verification failed|No .* host key is known|strict checking') { return 'HOST_KEY_RECOVERY_REQUIRED' }
    if ($Output -match '(?i)Permission denied|Authentication failed|No supported authentication methods') { return 'AUTH_RECOVERY_REQUIRED' }
    if ($Output -match '(?i)Connection timed out|Connection refused|No route to host|Could not resolve|Network is unreachable|Connection reset') { return 'DEVICE_UNREACHABLE' }
    return 'ACCESS_RECOVERY_REQUIRED'
}

function Normalize-ArthurMac([string]$Mac) {
    return (($Mac.Trim().ToLowerInvariant()) -replace '-',':')
}

function Get-ArthurEthernetIdentityContext {
    param([Parameter(Mandatory=$true)][string]$DeviceIp)
    if (-not (Get-Command Get-NetRoute -ErrorAction SilentlyContinue) -or -not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) -or -not (Get-Command Get-NetNeighbor -ErrorAction SilentlyContinue)) {
        throw 'UNSAFE_CONTROL_PATH: Windows route/adapter/neighbor commands are required.'
    }

    $subnetPrefix = (($DeviceIp -split '\.')[0..2] -join '.') + '.0/24'
    $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq "$DeviceIp/32" -or $_.DestinationPrefix -eq $subnetPrefix } |
        Sort-Object RouteMetric)
    if ($routes.Count -eq 0) { throw "UNSAFE_CONTROL_PATH: no direct route to $DeviceIp" }

    $selected = $null
    foreach ($route in $routes) {
        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $adapter -or [string]$adapter.Status -ne 'Up') { continue }
        $label = "{0} {1}" -f [string]$adapter.Name,[string]$adapter.InterfaceDescription
        if ($label -match '(?i)wi-?fi|wireless|wlan|802\.11') { continue }
        $selected = [pscustomobject]@{ Route=$route; Adapter=$adapter }
        break
    }
    if (-not $selected) { throw 'UNSAFE_CONTROL_PATH: Arthur management route is not proven to use Ethernet.' }

    Test-Connection -ComputerName $DeviceIp -Count 1 -Quiet -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Milliseconds 250
    $neighbors = @(Get-NetNeighbor -AddressFamily IPv4 -IPAddress $DeviceIp -ErrorAction SilentlyContinue |
        Where-Object {
            [int]$_.InterfaceIndex -eq [int]$selected.Route.InterfaceIndex -and
            $_.LinkLayerAddress -and
            $_.State -notin @('Unreachable','Incomplete')
        })
    if ($neighbors.Count -lt 1) { throw "DEVICE_UNREACHABLE: no Ethernet neighbor entry for $DeviceIp on interface $($selected.Route.InterfaceIndex)" }
    $neighborMacs = @($neighbors |
        ForEach-Object { Normalize-ArthurMac ([string]$_.LinkLayerAddress) } |
        Where-Object { $_ } |
        Sort-Object -Unique)
    if ($neighborMacs.Count -lt 1) { throw "IDENTITY_UNRESOLVED: no usable Ethernet neighbor MAC for $DeviceIp on interface $($selected.Route.InterfaceIndex)" }
    if ($neighborMacs.Count -gt 1) { throw "AMBIGUOUS_MANAGEMENT_IDENTITY: multiple neighbor MACs for $DeviceIp on interface $($selected.Route.InterfaceIndex)" }
    return [pscustomobject]@{
        DeviceIp = $DeviceIp
        Route = $selected.Route
        Adapter = $selected.Adapter
        InterfaceIndex = [int]$selected.Route.InterfaceIndex
        Mac = [string]$neighborMacs[0]
    }
}

function Get-ArthurHttpBuildInfo {
    param([Parameter(Mandatory=$true)][string]$DeviceIp,$Policy)
    $uri = "http://$DeviceIp$([string]$Policy.device.build_info_path)"
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 10
        $build = $response.Content | ConvertFrom-Json
    }
    catch {
        throw "DEVICE_UNREACHABLE: read-only build identity unavailable at $uri"
    }
    if ([string]$build.Firmware -ne [string]$Policy.device.build_marker -or [string]$build.Target -ne 'qualcommax/ipq60xx' -or [string]$build.Profile -ne 'jdcloud_re-ss-01') {
        throw 'HTTP_BUILD_IDENTITY_MISMATCH: endpoint does not match the authorized Arthur firmware identity.'
    }
    return $build
}

function Assert-ArthurEthernetIdentity {
    param([Parameter(Mandatory=$true)][string]$DeviceIp,$Policy)
    $context = Get-ArthurEthernetIdentityContext -DeviceIp $DeviceIp
    $expectedMac = Normalize-ArthurMac ([string]$Policy.device.verified_management_mac)
    if ($context.Mac -ne $expectedMac) {
        throw "MANAGEMENT_MAC_MISMATCH expected=$expectedMac actual=$($context.Mac)"
    }
    $build = Get-ArthurHttpBuildInfo -DeviceIp $DeviceIp -Policy $Policy

    Write-Host "ARTHUR_CONTROL_PATH=PASS interface=$($context.Adapter.Name) mac=$($context.Mac)"
    Write-Host 'ARTHUR_HTTP_IDENTITY=PASS device=jdcloud_re-ss-01'
    return [pscustomobject]@{ Network=$context; Build=$build }
}

function Test-ArthurAuthenticatedEvidence {
    param([Parameter(Mandatory=$true)]$Probe,$Policy)
    if ($Probe.ExitCode -ne 0) { return $false }
    return ($Probe.Output -match [string]$Policy.device.board_pattern) -and
           ($Probe.Output -match [regex]::Escape([string]$Policy.device.build_marker)) -and
           ($Probe.Output -match 'qualcommax/ipq60xx') -and
           ($Probe.Output -match 'jdcloud_re-ss-01')
}

function Test-ArthurReadOnlyAuthenticatedEvidence {
    param(
        [Parameter(Mandatory=$true)]$Probe,
        $Policy,
        [string]$ExpectedVersion = '',
        [string]$ExpectedBuildId = ''
    )
    if (-not (Test-ArthurAuthenticatedEvidence -Probe $Probe -Policy $Policy)) { return $false }
    $match = [regex]::Match([string]$Probe.Output,'(?m)^---REMOTE_BR_LAN_MAC---\r?\n(?<mac>[0-9a-fA-F:.-]+)\s*(?:\r?\n|$)')
    if (-not $match.Success) { return $false }
    if ((Normalize-ArthurMac $match.Groups['mac'].Value) -ne (Normalize-ArthurMac ([string]$Policy.device.verified_management_mac))) { return $false }
    $versionRequested = -not [string]::IsNullOrWhiteSpace($ExpectedVersion)
    $buildRequested = -not [string]::IsNullOrWhiteSpace($ExpectedBuildId)
    if ($versionRequested -ne $buildRequested) { return $false }
    if (-not $versionRequested) { return $true }

    $marker = [regex]::Match([string]$Probe.Output,'(?m)^---XINZHAO_BUILD---\r?\n')
    if (-not $marker.Success) { return $false }
    $buildStart = $marker.Index + $marker.Length
    $buildText = ([string]$Probe.Output).Substring($buildStart)
    $nextMarker = [regex]::Match($buildText,'(?m)^---')
    if ($nextMarker.Success) { $buildText = $buildText.Substring(0,$nextMarker.Index) }
    try { $build = $buildText.Trim() | ConvertFrom-Json } catch { return $false }
    $fields = Get-ArthurBuildIdentityFields -Build $build
    return ([string]$fields.Firmware -eq [string]$Policy.device.build_marker) -and
           ([string]$fields.Version -eq $ExpectedVersion) -and
           ([string]$fields.BuildId -eq $ExpectedBuildId) -and
           ([string]$fields.Target -eq 'qualcommax/ipq60xx') -and
           ([string]$fields.Profile -eq 'jdcloud_re-ss-01')
}

function Test-ArthurExpectedAuthenticatedEvidence {
    param(
        [Parameter(Mandatory=$true)]$Probe,
        $Policy,
        [string]$ExpectedVersion = '',
        [string]$ExpectedBuildId = ''
    )
    if ([string]::IsNullOrWhiteSpace($ExpectedVersion) -and [string]::IsNullOrWhiteSpace($ExpectedBuildId)) {
        return (Test-ArthurAuthenticatedEvidence -Probe $Probe -Policy $Policy)
    }
    return (Test-ArthurReadOnlyAuthenticatedEvidence -Probe $Probe -Policy $Policy -ExpectedVersion $ExpectedVersion -ExpectedBuildId $ExpectedBuildId)
}

function Get-ArthurIdentityCommand {
    return "ubus call system board; printf '\n---XINZHAO_BUILD---\n'; cat /www/luci-static/xinzhao/build-info.json"
}

function Get-ArthurReadOnlyIdentityCommand {
    $identity = Get-ArthurIdentityCommand
    return "$identity; printf '\n---REMOTE_BR_LAN_MAC---\n'; cat /sys/class/net/br-lan/address; printf '\n---REMOTE_LINKS---\n'; ip -br link; printf '\n---REMOTE_LAN_STATUS---\n'; ubus call network.interface.lan status"
}

function Get-ArthurBuildField {
    param($Build,[Parameter(Mandatory=$true)][string[]]$Names)
    foreach ($name in $Names) {
        $property = $Build.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    return ''
}

function Get-ArthurBuildIdentityFields {
    param($Build)
    return [pscustomobject]@{
        Firmware = Get-ArthurBuildField -Build $Build -Names @('Firmware','Distribution')
        Target = Get-ArthurBuildField -Build $Build -Names @('Target')
        Profile = Get-ArthurBuildField -Build $Build -Names @('Profile','Device Profile')
        Version = Get-ArthurBuildField -Build $Build -Names @('Version')
        BuildId = Get-ArthurBuildField -Build $Build -Names @('Build ID','BuildID','Build Id','build_id','buildId')
        GitCommit = Get-ArthurBuildField -Build $Build -Names @('Git Commit','GitCommit','git_commit')
    }
}

function Invoke-ArthurReadOnlyIdentityForensics {
    param([string]$DeviceIp = '192.168.6.1')
    $policy = Get-ArthurAccessPolicy
    if ($DeviceIp -ne [string]$policy.device.management_ip) {
        throw "DEVICE_IDENTITY_MISMATCH expected=$($policy.device.management_ip) actual=$DeviceIp"
    }

    $network = Get-ArthurEthernetIdentityContext -DeviceIp $DeviceIp
    $httpBuild = Get-ArthurHttpBuildInfo -DeviceIp $DeviceIp -Policy $policy
    $httpFields = Get-ArthurBuildIdentityFields -Build $httpBuild
    if ([string]::IsNullOrWhiteSpace($httpFields.BuildId)) {
        throw 'HTTP_BUILD_IDENTITY_INCOMPLETE: build ID is required for stale-MAC reconciliation.'
    }

    $sshDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh'
    $runnerKey = Join-Path $sshDir 'id_ed25519'
    $tempKnownHosts = Join-Path ([System.IO.Path]::GetTempPath()) ("xinzhaowrt-arthur-forensic-{0}-{1}.known_hosts" -f $PID,[guid]::NewGuid().ToString('N'))
    try {
        $probe = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $tempKnownHosts -StrictMode 'accept-new' -Command (Get-ArthurReadOnlyIdentityCommand) -IdentityFile $runnerKey
        if ($probe.ExitCode -ne 0) {
            $failureClass = Get-ArthurSshFailureClass -ExitCode $probe.ExitCode -Output $probe.Output
            throw "TEMP_SSH_EXISTING_RUNNER_KEY_AUTH=FAIL class=$failureClass"
        }
        if (-not (Test-ArthurAuthenticatedEvidence -Probe $probe -Policy $policy)) {
            throw 'AUTHENTICATED_DEVICE_IDENTITY_MISMATCH: temporary runner-key SSH did not prove the authorized Arthur board and build.'
        }

        $remoteBuildMatch = [regex]::Match([string]$probe.Output,'(?s)---XINZHAO_BUILD---\s*(\{.*?\})\s*---REMOTE_BR_LAN_MAC---')
        if (-not $remoteBuildMatch.Success) { throw 'SSH_BUILD_IDENTITY_UNRESOLVED: build-info JSON missing from authenticated probe.' }
        try { $remoteBuild = $remoteBuildMatch.Groups[1].Value | ConvertFrom-Json }
        catch { throw 'SSH_BUILD_IDENTITY_UNRESOLVED: authenticated build-info JSON is invalid.' }
        $remoteFields = Get-ArthurBuildIdentityFields -Build $remoteBuild
        foreach ($field in @('Firmware','Target','Profile','Version','BuildId')) {
            if ([string]::IsNullOrWhiteSpace([string]$remoteFields.$field) -or [string]$remoteFields.$field -ne [string]$httpFields.$field) {
                throw "AUTHENTICATED_BUILD_IDENTITY_MISMATCH: HTTP and SSH $field values differ or are missing."
            }
        }

        $remoteMacMatch = [regex]::Match([string]$probe.Output,'(?m)^---REMOTE_BR_LAN_MAC---\s*\r?\n\s*([0-9a-fA-F:-]+)\s*$')
        if (-not $remoteMacMatch.Success) { throw 'REMOTE_BR_LAN_MAC_UNRESOLVED: authenticated SSH did not report br-lan address.' }
        $remoteMac = Normalize-ArthurMac $remoteMacMatch.Groups[1].Value
        if ($remoteMac -ne [string]$network.Mac) {
            throw "AMBIGUOUS_DEVICE_IDENTITY: Ethernet neighbor MAC $($network.Mac) differs from remote br-lan MAC $remoteMac."
        }

        $frozenMac = Normalize-ArthurMac ([string]$policy.device.verified_management_mac)
        $frozenStatus = if ($remoteMac -eq $frozenMac) { 'MATCH' } else { 'STALE' }
        Write-Host 'ARTHUR_HTTP_IDENTITY=PASS'
        Write-Host 'TEMP_SSH_EXISTING_RUNNER_KEY_AUTH=PASS'
        Write-Host 'SSH_BOARD_TARGET_PROFILE=PASS'
        Write-Host "FROZEN_MANAGEMENT_MAC_STATUS=$frozenStatus"
        return [pscustomobject]@{
            DeviceIp = $DeviceIp
            EthernetRoute = 'PASS'
            SelectedEthernetInterfaceIndex = [int]$network.InterfaceIndex
            SelectedEthernetInterface = [string]$network.Adapter.Name
            LocalEthernetMac = [string]$network.Mac
            FrozenManagementMac = [string]$frozenMac
            FrozenManagementMacStatus = [string]$frozenStatus
            HttpIdentity = 'PASS'
            HttpFirmware = [string]$httpFields.Firmware
            HttpTarget = [string]$httpFields.Target
            HttpProfile = [string]$httpFields.Profile
            HttpVersion = [string]$httpFields.Version
            HttpBuildId = [string]$httpFields.BuildId
            HttpGitCommit = [string]$httpFields.GitCommit
            RunnerKeyAuth = 'PASS'
            SshBoardIdentity = 'PASS'
            SshBuildIdentity = 'PASS'
            RemoteBrLanMac = [string]$remoteMac
            RemoteNetworkStatus = 'READ_ONLY_CAPTURED'
            FormalKnownHostsChanged = $false
            TempTrustStore = 'DISPOSABLE_ACCEPT_NEW'
        }
    }
    finally {
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $tempKnownHosts
    }
}

function Ensure-ArthurRunnerKey {
    param(
        [Parameter(Mandatory=$true)][string]$DeviceIp,
        [Parameter(Mandatory=$true)][string]$KnownHostsFile,
        [string]$RunnerKeyDirectory = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh')
    )
    if (-not (Test-Path -LiteralPath $RunnerKeyDirectory -PathType Container)) {
        throw 'UNRECOVERABLE_SSH_AUTH: existing controller SSH keypair is unavailable.'
    }
    $sshDir = (Resolve-Path -LiteralPath $RunnerKeyDirectory).Path
    $privateKey = Join-Path $sshDir 'id_ed25519'
    $publicKey = "$privateKey.pub"
    $keygen = Get-ArthurSshTool 'ssh-keygen'

    if (-not (Test-Path -LiteralPath $privateKey -PathType Leaf) -or -not (Test-Path -LiteralPath $publicKey -PathType Leaf)) {
        throw 'UNRECOVERABLE_SSH_AUTH: existing controller SSH keypair is unavailable.'
    }
    $derived = Invoke-ArthurAccessNative -FilePath $keygen -Arguments @('-y','-f',$privateKey)
    if ($derived.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($derived.Output)) {
        throw 'UNRECOVERABLE_SSH_AUTH: existing controller private key cannot be read.'
    }
    $derivedParts = @($derived.Output.Trim() -split '\s+')
    $publicParts = @((Get-Content -Raw -LiteralPath $publicKey).Trim() -split '\s+')
    if (
        $derivedParts.Count -lt 2 -or $publicParts.Count -lt 2 -or
        $derivedParts[0] -ne 'ssh-ed25519' -or $publicParts[0] -ne 'ssh-ed25519' -or
        $derivedParts[1] -ne $publicParts[1]
    ) {
        throw 'UNRECOVERABLE_SSH_AUTH: controller public key does not match the existing private key.'
    }

    $parts = @($publicParts | Where-Object { $_ })
    if ($parts.Count -lt 2 -or $parts[0] -ne 'ssh-ed25519') { throw 'UNRECOVERABLE_SSH_AUTH: invalid controller public key.' }
    $line = "ssh-ed25519 $($parts[1]) xinzhaowrt-controller"
    $backupCommand = "if [ -f /etc/dropbear/authorized_keys ]; then printf 'ARTHUR_AUTHKEYS_PRESENT\n'; base64 /etc/dropbear/authorized_keys; else printf 'ARTHUR_AUTHKEYS_MISSING\n'; fi"
    $backupProbe = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $KnownHostsFile -StrictMode yes -Command $backupCommand -PasswordAuth
    if ($backupProbe.ExitCode -ne 0) { throw 'UNRECOVERABLE_SSH_AUTH: could not read authorized_keys for local rollback backup.' }

    $backupLines = @(([string]$backupProbe.Output -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $hadFile = $backupLines.Count -gt 0 -and $backupLines[0] -eq 'ARTHUR_AUTHKEYS_PRESENT'
    $missingFile = $backupLines.Count -gt 0 -and $backupLines[0] -eq 'ARTHUR_AUTHKEYS_MISSING'
    if (-not $hadFile -and -not $missingFile) { throw 'UNRECOVERABLE_SSH_AUTH: authorized_keys backup response was malformed.' }

    $backupPath = $null
    if ($hadFile) {
        $encoded = ($backupLines | Select-Object -Skip 1) -join ''
        try { $backupBytes = [Convert]::FromBase64String($encoded) }
        catch { throw 'UNRECOVERABLE_SSH_AUTH: authorized_keys backup could not be decoded.' }
        $backupPath = "$KnownHostsFile.authorized_keys_backup"
        try { [System.IO.File]::WriteAllBytes($backupPath,$backupBytes) }
        catch { throw 'UNRECOVERABLE_SSH_AUTH: could not save authorized_keys backup on the runner.' }
    }

    $record = [pscustomobject]@{ Changed=$true; BackupPath=$backupPath; HadFile=$hadFile }
    $command = "test -d /etc/dropbear || exit 72; touch /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys; grep -qxF '$line' /etc/dropbear/authorized_keys || printf '%s\n' '$line' >> /etc/dropbear/authorized_keys"
    $install = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $KnownHostsFile -StrictMode yes -Command $command -PasswordAuth
    if ($install.ExitCode -ne 0) {
        Restore-ArthurRunnerKey -DeviceIp $DeviceIp -KnownHostsFile $KnownHostsFile -Record $record
        throw 'UNRECOVERABLE_SSH_AUTH: verified password authentication could not install the controller key.'
    }
    Write-Host 'ARTHUR_RUNNER_KEY=PASS'
    return $record
}

function Restore-ArthurRunnerKey {
    param([string]$DeviceIp,[string]$KnownHostsFile,$Record)
    if (-not $Record -or -not $Record.Changed -or [string]::IsNullOrWhiteSpace($env:ARTHUR_ROOT_PASSWORD)) { return }
    $command = if ($Record.HadFile) {
        if (-not $Record.BackupPath -or -not (Test-Path -LiteralPath $Record.BackupPath -PathType Leaf)) {
            Write-Warning 'AUTHORIZED_KEYS_ROLLBACK_FAILED: runner-side authorized_keys backup is unavailable.'
            return
        }
        $encoded = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Record.BackupPath))
        "printf '%s' '$encoded' | base64 -d > /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys"
    } else {
        'rm -f /etc/dropbear/authorized_keys'
    }
    $restore = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $KnownHostsFile -StrictMode yes -Command $command -PasswordAuth
    if ($restore.ExitCode -ne 0) { Write-Warning 'AUTHORIZED_KEYS_ROLLBACK_FAILED: remote restore of /etc/dropbear/authorized_keys failed.' }
    elseif ($Record.BackupPath) { Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $Record.BackupPath }
}

function Get-ArthurKnownHostLines {
    param([string]$DeviceIp,[string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $keygen = Get-ArthurSshTool 'ssh-keygen'
    $found = Invoke-ArthurAccessNative -FilePath $keygen -Arguments @('-F',$DeviceIp,'-f',$Path)
    if ($found.ExitCode -ne 0) { return @() }
    return @($found.Output -split "`n" | Where-Object { $_ -and $_ -notmatch '^#' })
}

function Set-ArthurVerifiedKnownHost {
    param([string]$DeviceIp,[string]$KnownHosts,[string]$CandidateKnownHosts)
    $candidateLines = @(Get-ArthurKnownHostLines -DeviceIp $DeviceIp -Path $CandidateKnownHosts)
    if ($candidateLines.Count -lt 1) { throw 'SSH_HOST_KEY_CAPTURE_FAILED: candidate trust store contains no Arthur key.' }

    $sshDir = Split-Path -Parent $KnownHosts
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    $hadKnownHosts = Test-Path -LiteralPath $KnownHosts -PathType Leaf
    $backup = "$KnownHosts.xinzhaowrt-backup-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
    if ($hadKnownHosts) { Copy-Item -Force -LiteralPath $KnownHosts -Destination $backup }
    else { [System.IO.File]::WriteAllText($KnownHosts,'',[System.Text.Encoding]::ASCII) }

    try {
        $keygen = Get-ArthurSshTool 'ssh-keygen'
        # This target-specific removal occurs only after Ethernet, MAC, HTTP and authenticated SSH identity proofs.
        $remove = Invoke-ArthurAccessNative -FilePath $keygen -Arguments @('-R',$DeviceIp,'-f',$KnownHosts)
        if ($remove.ExitCode -notin @(0,1)) { throw "known_hosts target removal failed: $($remove.Output)" }
        foreach ($line in $candidateLines) {
            [System.IO.File]::AppendAllText($KnownHosts,([string]$line + [Environment]::NewLine),[System.Text.Encoding]::ASCII)
        }
        return [pscustomobject]@{ HadKnownHosts=$hadKnownHosts; Backup=$backup }
    }
    catch {
        if ($hadKnownHosts -and (Test-Path -LiteralPath $backup)) { Copy-Item -Force -LiteralPath $backup -Destination $KnownHosts }
        elseif (-not $hadKnownHosts) { Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $KnownHosts }
        throw
    }
}

function Restore-ArthurKnownHosts {
    param([string]$KnownHosts,$Record)
    if (-not $Record) { return }
    if ($Record.HadKnownHosts -and (Test-Path -LiteralPath $Record.Backup)) {
        Copy-Item -Force -LiteralPath $Record.Backup -Destination $KnownHosts
    }
    elseif (-not $Record.HadKnownHosts) {
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $KnownHosts
    }
}

function Ensure-ArthurUnattendedAccess {
    param(
        [string]$DeviceIp = '192.168.6.1',
        [string]$ExpectedVersion = '',
        [string]$ExpectedBuildId = ''
    )
    $policy = Get-ArthurAccessPolicy
    $exactVersionRequested = -not [string]::IsNullOrWhiteSpace($ExpectedVersion)
    $exactBuildRequested = -not [string]::IsNullOrWhiteSpace($ExpectedBuildId)
    if ($exactVersionRequested -ne $exactBuildRequested) {
        throw 'DEVICE_IDENTITY_EXPECTATION_INVALID: expected version and build ID must be supplied together.'
    }
    if ($DeviceIp -ne [string]$policy.device.management_ip) {
        throw "DEVICE_IDENTITY_MISMATCH expected=$($policy.device.management_ip) actual=$DeviceIp"
    }

    $sshDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh'
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    $knownHosts = Join-Path $sshDir 'known_hosts'
    if (-not (Test-Path -LiteralPath $knownHosts -PathType Leaf)) {
        [System.IO.File]::WriteAllText($knownHosts,'',[System.Text.Encoding]::ASCII)
    }
    $identityCommand = if ($exactVersionRequested) { Get-ArthurReadOnlyIdentityCommand } else { Get-ArthurIdentityCommand }

    $strict = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $knownHosts -StrictMode yes -Command $identityCommand
    if (Test-ArthurExpectedAuthenticatedEvidence -Probe $strict -Policy $policy -ExpectedVersion $ExpectedVersion -ExpectedBuildId $ExpectedBuildId) {
        Write-Host 'ARTHUR_UNATTENDED_ACCESS=PASS mode=strict-existing-trust'
        return [pscustomobject]@{ KnownHosts=$knownHosts; Mode='strict-existing-trust'; HostKeyRebound=$false }
    }

    $class = Get-ArthurSshFailureClass -ExitCode $strict.ExitCode -Output $strict.Output
    if ($strict.ExitCode -eq 0) { throw 'AUTHENTICATED_DEVICE_IDENTITY_MISMATCH: strict SSH endpoint returned unexpected identity.' }
    if ($class -eq 'DEVICE_UNREACHABLE') { throw "DEVICE_UNREACHABLE: $($strict.Output)" }

    $null = Assert-ArthurEthernetIdentity -DeviceIp $DeviceIp -Policy $policy

    $tempKnownHosts = Join-Path ([System.IO.Path]::GetTempPath()) ("xinzhaowrt-arthur-candidate-{0}.known_hosts" -f $PID)
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $tempKnownHosts
    $runnerRecord = $null
    $knownHostsRecord = $null
    try {
        $candidate = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $tempKnownHosts -StrictMode 'accept-new' -Command $identityCommand
        $authMode = 'runner-key'
        if (-not (Test-ArthurExpectedAuthenticatedEvidence -Probe $candidate -Policy $policy -ExpectedVersion $ExpectedVersion -ExpectedBuildId $ExpectedBuildId)) {
            $candidateClass = Get-ArthurSshFailureClass -ExitCode $candidate.ExitCode -Output $candidate.Output
            if ($candidateClass -notin @('AUTH_RECOVERY_REQUIRED','ACCESS_RECOVERY_REQUIRED')) {
                throw "AUTHENTICATED_DEVICE_IDENTITY_MISMATCH: candidate SSH evidence failed class=$candidateClass"
            }
            $passwordProbe = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $tempKnownHosts -StrictMode yes -Command $identityCommand -PasswordAuth
            if (-not (Test-ArthurExpectedAuthenticatedEvidence -Probe $passwordProbe -Policy $policy -ExpectedVersion $ExpectedVersion -ExpectedBuildId $ExpectedBuildId)) {
                if ($passwordProbe.ExitCode -eq 61) { throw 'UNRECOVERABLE_SSH_AUTH: neither runner key nor secured password recovery is available.' }
                throw 'AUTHENTICATED_DEVICE_IDENTITY_MISMATCH: password-authenticated endpoint did not prove the authorized Arthur identity.'
            }
        $readOnlyProbe = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $tempKnownHosts -StrictMode yes -Command (Get-ArthurReadOnlyIdentityCommand) -PasswordAuth
        if (-not (Test-ArthurReadOnlyAuthenticatedEvidence -Probe $readOnlyProbe -Policy $policy -ExpectedVersion $ExpectedVersion -ExpectedBuildId $ExpectedBuildId)) {
            throw 'AUTHENTICATED_DEVICE_IDENTITY_MISMATCH: password-authenticated board, build, target, profile, and br-lan MAC evidence did not match the authorized Arthur identity.'
        }
        Write-Host 'PASSWORD_AUTH_IDENTITY=PASS board=target=profile=br-lan'
            $runnerRecord = Ensure-ArthurRunnerKey -DeviceIp $DeviceIp -KnownHostsFile $tempKnownHosts
            $candidate = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $tempKnownHosts -StrictMode yes -Command $identityCommand
            if (-not (Test-ArthurExpectedAuthenticatedEvidence -Probe $candidate -Policy $policy -ExpectedVersion $ExpectedVersion -ExpectedBuildId $ExpectedBuildId)) {
                throw 'UNRECOVERABLE_SSH_AUTH: controller key installation did not produce strict key authentication.'
            }
            $authMode = 'password-recovered-runner-key'
        }

        $knownHostsRecord = Set-ArthurVerifiedKnownHost -DeviceIp $DeviceIp -KnownHosts $knownHosts -CandidateKnownHosts $tempKnownHosts
        $final = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $knownHosts -StrictMode yes -Command $identityCommand
        if (-not (Test-ArthurExpectedAuthenticatedEvidence -Probe $final -Policy $policy -ExpectedVersion $ExpectedVersion -ExpectedBuildId $ExpectedBuildId)) {
            throw 'SSH_HOST_IDENTITY_MISMATCH: strict verification failed after verified known_hosts replacement.'
        }

        Write-Host "ARTHUR_UNATTENDED_ACCESS=PASS mode=$authMode host_key=rebound-after-independent-identity-proof"
        return [pscustomobject]@{ KnownHosts=$knownHosts; Mode=$authMode; HostKeyRebound=$true }
    }
    catch {
        $message = $_.Exception.Message
        if ($knownHostsRecord) { Restore-ArthurKnownHosts -KnownHosts $knownHosts -Record $knownHostsRecord }
        if ($runnerRecord) { Restore-ArthurRunnerKey -DeviceIp $DeviceIp -KnownHostsFile $tempKnownHosts -Record $runnerRecord }
        throw $message
    }
    finally {
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $tempKnownHosts
        if ($script:ArthurAccessAskPassExe) {
            Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $script:ArthurAccessAskPassExe
            $script:ArthurAccessAskPassExe = $null
        }
    }
}
