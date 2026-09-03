$script:ArthurAccessAskPassExe = $null

function Get-ArthurAccessPolicy {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $path = Join-Path $root 'production\arthur-control-plane.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "ARTHUR_CONTROL_POLICY_MISSING path=$path"
    }
    $policy = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -Depth 12
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

    $args += @('-o','BatchMode=yes',"root@$DeviceIp",$Command)
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
    Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $path -OutputType ConsoleApplication -ErrorAction Stop
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

function Assert-ArthurEthernetIdentity {
    param([Parameter(Mandatory=$true)][string]$DeviceIp,$Policy)
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
        Where-Object { $_.LinkLayerAddress -and $_.State -notin @('Unreachable','Incomplete') })
    if ($neighbors.Count -lt 1) { throw "DEVICE_UNREACHABLE: no Ethernet neighbor entry for $DeviceIp" }
    $actualMac = Normalize-ArthurMac ([string]$neighbors[0].LinkLayerAddress)
    $expectedMac = Normalize-ArthurMac ([string]$Policy.device.verified_management_mac)
    if ($actualMac -ne $expectedMac) {
        throw "MANAGEMENT_MAC_MISMATCH expected=$expectedMac actual=$actualMac"
    }

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

    Write-Host "ARTHUR_CONTROL_PATH=PASS interface=$($selected.Adapter.Name) mac=$actualMac"
    Write-Host 'ARTHUR_HTTP_IDENTITY=PASS device=jdcloud_re-ss-01'
}

function Test-ArthurAuthenticatedEvidence {
    param([Parameter(Mandatory=$true)]$Probe,$Policy)
    if ($Probe.ExitCode -ne 0) { return $false }
    return ($Probe.Output -match [string]$Policy.device.board_pattern) -and
           ($Probe.Output -match [regex]::Escape([string]$Policy.device.build_marker)) -and
           ($Probe.Output -match 'qualcommax/ipq60xx') -and
           ($Probe.Output -match 'jdcloud_re-ss-01')
}

function Get-ArthurIdentityCommand {
    return "ubus call system board; printf '\n---XINZHAO_BUILD---\n'; cat /www/luci-static/xinzhao/build-info.json"
}

function Ensure-ArthurRunnerKey {
    param([Parameter(Mandatory=$true)][string]$DeviceIp,[Parameter(Mandatory=$true)][string]$KnownHostsFile)
    $sshDir = Split-Path -Parent $KnownHostsFile
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    $privateKey = Join-Path $sshDir 'id_ed25519'
    $publicKey = "$privateKey.pub"
    $keygen = Get-ArthurSshTool 'ssh-keygen'

    if (-not (Test-Path -LiteralPath $privateKey -PathType Leaf)) {
        $created = Invoke-ArthurAccessNative -FilePath $keygen -Arguments @('-q','-t','ed25519','-N','','-C','xinzhaowrt-controller','-f',$privateKey)
        if ($created.ExitCode -ne 0) { throw 'UNRECOVERABLE_SSH_AUTH: failed to create controller SSH key.' }
    }
    if (-not (Test-Path -LiteralPath $publicKey -PathType Leaf)) {
        $derived = Invoke-ArthurAccessNative -FilePath $keygen -Arguments @('-y','-f',$privateKey)
        if ($derived.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($derived.Output)) { throw 'UNRECOVERABLE_SSH_AUTH: failed to derive controller public key.' }
        ("{0} xinzhaowrt-controller" -f $derived.Output.Trim()) | Set-Content -Encoding ASCII -LiteralPath $publicKey
    }

    $parts = @((Get-Content -Raw -LiteralPath $publicKey).Trim() -split '\s+' | Where-Object { $_ })
    if ($parts.Count -lt 2 -or $parts[0] -ne 'ssh-ed25519') { throw 'UNRECOVERABLE_SSH_AUTH: invalid controller public key.' }
    $line = "ssh-ed25519 $($parts[1]) xinzhaowrt-controller"
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $backup = "/etc/dropbear/authorized_keys.xinzhaowrt-backup-$stamp"
    $command = "umask 077; mkdir -p /etc/dropbear; if [ -e /etc/dropbear/authorized_keys ]; then cp -p /etc/dropbear/authorized_keys '$backup'; echo BACKUP_EXISTING; else echo BACKUP_MISSING; fi; touch /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys; grep -qxF '$line' /etc/dropbear/authorized_keys || printf '%s\n' '$line' >> /etc/dropbear/authorized_keys"
    $install = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $KnownHostsFile -StrictMode yes -Command $command -PasswordAuth
    if ($install.ExitCode -ne 0) { throw 'UNRECOVERABLE_SSH_AUTH: verified password authentication could not install the controller key.' }
    $hadFile = $install.Output -match 'BACKUP_EXISTING'
    Write-Host 'ARTHUR_RUNNER_KEY=PASS'
    return [pscustomobject]@{ Changed=$true; Backup=$backup; HadFile=$hadFile }
}

function Restore-ArthurRunnerKey {
    param([string]$DeviceIp,[string]$KnownHostsFile,$Record)
    if (-not $Record -or -not $Record.Changed -or [string]::IsNullOrWhiteSpace($env:ARTHUR_ROOT_PASSWORD)) { return }
    $command = if ($Record.HadFile) {
        "test -e '$($Record.Backup)' && cp -p '$($Record.Backup)' /etc/dropbear/authorized_keys && rm -f '$($Record.Backup)'"
    } else {
        "rm -f /etc/dropbear/authorized_keys '$($Record.Backup)'"
    }
    $restore = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $KnownHostsFile -StrictMode yes -Command $command -PasswordAuth
    if ($restore.ExitCode -ne 0) { Write-Warning 'KNOWN_HOSTS_ROLLBACK_FAILED: remote authorized_keys rollback also failed.' }
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
    param([string]$DeviceIp = '192.168.6.1')
    $policy = Get-ArthurAccessPolicy
    if ($DeviceIp -ne [string]$policy.device.management_ip) {
        throw "DEVICE_IDENTITY_MISMATCH expected=$($policy.device.management_ip) actual=$DeviceIp"
    }

    $sshDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh'
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    $knownHosts = Join-Path $sshDir 'known_hosts'
    if (-not (Test-Path -LiteralPath $knownHosts -PathType Leaf)) {
        [System.IO.File]::WriteAllText($knownHosts,'',[System.Text.Encoding]::ASCII)
    }
    $identityCommand = Get-ArthurIdentityCommand

    $strict = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $knownHosts -StrictMode yes -Command $identityCommand
    if (Test-ArthurAuthenticatedEvidence -Probe $strict -Policy $policy) {
        Write-Host 'ARTHUR_UNATTENDED_ACCESS=PASS mode=strict-existing-trust'
        return [pscustomobject]@{ KnownHosts=$knownHosts; Mode='strict-existing-trust'; HostKeyRebound=$false }
    }

    $class = Get-ArthurSshFailureClass -ExitCode $strict.ExitCode -Output $strict.Output
    if ($strict.ExitCode -eq 0) { throw 'AUTHENTICATED_DEVICE_IDENTITY_MISMATCH: strict SSH endpoint returned unexpected identity.' }
    if ($class -eq 'DEVICE_UNREACHABLE') { throw "DEVICE_UNREACHABLE: $($strict.Output)" }

    Assert-ArthurEthernetIdentity -DeviceIp $DeviceIp -Policy $policy

    $tempKnownHosts = Join-Path ([System.IO.Path]::GetTempPath()) ("xinzhaowrt-arthur-candidate-{0}.known_hosts" -f $PID)
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $tempKnownHosts
    $runnerRecord = $null
    $knownHostsRecord = $null
    try {
        $candidate = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $tempKnownHosts -StrictMode 'accept-new' -Command $identityCommand
        $authMode = 'runner-key'
        if (-not (Test-ArthurAuthenticatedEvidence -Probe $candidate -Policy $policy)) {
            $candidateClass = Get-ArthurSshFailureClass -ExitCode $candidate.ExitCode -Output $candidate.Output
            if ($candidateClass -notin @('AUTH_RECOVERY_REQUIRED','ACCESS_RECOVERY_REQUIRED')) {
                throw "AUTHENTICATED_DEVICE_IDENTITY_MISMATCH: candidate SSH evidence failed class=$candidateClass"
            }
            $passwordProbe = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $tempKnownHosts -StrictMode yes -Command $identityCommand -PasswordAuth
            if (-not (Test-ArthurAuthenticatedEvidence -Probe $passwordProbe -Policy $policy)) {
                if ($passwordProbe.ExitCode -eq 61) { throw 'UNRECOVERABLE_SSH_AUTH: neither runner key nor secured password recovery is available.' }
                throw 'AUTHENTICATED_DEVICE_IDENTITY_MISMATCH: password-authenticated endpoint did not prove the authorized Arthur identity.'
            }
            $runnerRecord = Ensure-ArthurRunnerKey -DeviceIp $DeviceIp -KnownHostsFile $tempKnownHosts
            $candidate = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $tempKnownHosts -StrictMode yes -Command $identityCommand
            if (-not (Test-ArthurAuthenticatedEvidence -Probe $candidate -Policy $policy)) {
                throw 'UNRECOVERABLE_SSH_AUTH: controller key installation did not produce strict key authentication.'
            }
            $authMode = 'password-recovered-runner-key'
        }

        $knownHostsRecord = Set-ArthurVerifiedKnownHost -DeviceIp $DeviceIp -KnownHosts $knownHosts -CandidateKnownHosts $tempKnownHosts
        $final = Invoke-ArthurSshProbe -DeviceIp $DeviceIp -KnownHostsFile $knownHosts -StrictMode yes -Command $identityCommand
        if (-not (Test-ArthurAuthenticatedEvidence -Probe $final -Policy $policy)) {
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
