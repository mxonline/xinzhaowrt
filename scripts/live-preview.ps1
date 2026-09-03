param(
    [string]$Target = 'root@192.168.6.1',
    [ValidateSet('AdGuard','QuickStart','Both','Generic')][string]$Feature = 'Generic',
    [string]$ManifestPath = '',
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$PolicyPath = Join-Path $Root 'production\live-preview-policy.json'
$RootPassword = $env:ARTHUR_ROOT_PASSWORD
$script:MutationStarted = $false
$script:BackupRecords = [System.Collections.Generic.List[object]]::new()
$script:BackupDir = ''
$script:TouchedRpcd = $false

function Normalize-RepoPath([string]$Path) {
    $p = ($Path -replace '\\','/')
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    return $p.TrimStart('/')
}

function Get-TargetHost {
    $parts = $Target -split '@'
    return $parts[-1]
}

function Get-Tool([string[]]$Candidates) {
    foreach ($candidate in $Candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    throw "REQUIRED_TOOL_MISSING candidates=$($Candidates -join ',')"
}

function Test-Prefix([string]$Value, [string[]]$Prefixes) {
    foreach ($prefix in $Prefixes) {
        if ($Value.StartsWith([string]$prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-RepoPathAllowed([string]$RepoPath, $Policy) {
    $p = Normalize-RepoPath $RepoPath
    if (Test-Prefix $p @($Policy.forbidden_repo_prefixes)) { return $false }
    return $true
}

function Test-RemotePathAllowed([string]$RemotePath, $Policy) {
    if (-not $RemotePath.StartsWith('/')) { return $false }
    if ($RemotePath -match '(?:^|/)\.\.(?:/|$)') { return $false }
    if ($RemotePath -notmatch '^/[A-Za-z0-9._/@+=,:-]+$') { return $false }
    if (-not (Test-Prefix $RemotePath @($Policy.allowed_remote_prefixes))) { return $false }
    if (Test-Prefix $RemotePath @($Policy.forbidden_remote_prefixes)) { return $false }
    return $true
}

function Test-ControlOnlyRepoPath([string]$RepoPath) {
    $p = Normalize-RepoPath $RepoPath
    return (
        $p.StartsWith('docs/') -or
        $p.StartsWith('knowledge/') -or
        $p.StartsWith('tests/') -or
        $p.StartsWith('.github/') -or
        $p -eq 'scripts/live-preview.ps1' -or
        $p -eq 'scripts/classify-build-scope.sh' -or
        $p -eq 'scripts/verify-project.sh' -or
        $p -eq 'production/live-preview-policy.json' -or
        $p -eq 'AGENTS.md'
    )
}

function Get-Policy {
    if (-not (Test-Path $PolicyPath)) { throw "LIVE_PREVIEW_POLICY_MISSING path=$PolicyPath" }
    try { $policy = Get-Content -Raw $PolicyPath | ConvertFrom-Json -Depth 20 }
    catch { throw "LIVE_PREVIEW_POLICY_INVALID $($_.Exception.Message)" }
    if ([int]$policy.schema_version -ne 1) { throw "LIVE_PREVIEW_POLICY_SCHEMA_UNSUPPORTED actual=$($policy.schema_version)" }
    $hostPart = Get-TargetHost
    if ($hostPart -ne [string]$policy.device.management_ip) {
        throw "LIVE_PREVIEW_TARGET_MISMATCH expected=$($policy.device.management_ip) actual=$hostPart"
    }
    return $policy
}

function Get-ChangedRepoPaths {
    $tracked = @(& git -C $Root diff --name-only HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'GIT_DIFF_FAILED' }
    $untracked = @(& git -C $Root ls-files --others --exclude-standard 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'GIT_UNTRACKED_SCAN_FAILED' }
    return @($tracked + $untracked | Where-Object { $_ } | ForEach-Object { Normalize-RepoPath ([string]$_) } | Sort-Object -Unique)
}

function Resolve-AutoMappedEntry([string]$RepoPath, $Policy) {
    foreach ($mapping in @($Policy.source_mappings)) {
        $prefix = [string]$mapping.repo_prefix
        if ($RepoPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $suffix = $RepoPath.Substring($prefix.Length)
            $remote = ([string]$mapping.remote_prefix) + $suffix
            return [pscustomobject]@{ Source = $RepoPath; Remote = $remote }
        }
    }
    return $null
}

function Read-ExplicitManifest([string]$Path, $Policy) {
    $resolved = (Resolve-Path $Path).Path
    try { $parsed = Get-Content -Raw $resolved | ConvertFrom-Json -Depth 20 }
    catch { throw "LIVE_PREVIEW_MANIFEST_INVALID $($_.Exception.Message)" }
    $entriesProperty = $parsed.PSObject.Properties['entries']
    $rawEntries = if ($entriesProperty) { @($parsed.entries) } else { @($parsed) }
    if ($rawEntries.Count -eq 0) { throw 'LIVE_PREVIEW_MANIFEST_EMPTY' }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in $rawEntries) {
        $source = Normalize-RepoPath ([string]$raw.source)
        $remote = [string]$raw.remote
        if (-not (Test-RepoPathAllowed $source $Policy)) { throw "LIVE_PREVIEW_SOURCE_FORBIDDEN path=$source" }
        if (-not (Test-RemotePathAllowed $remote $Policy)) { throw "LIVE_PREVIEW_REMOTE_FORBIDDEN path=$remote" }
        $full = [System.IO.Path]::GetFullPath((Join-Path $Root ($source -replace '/','\')))
        if (-not $full.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) { throw "LIVE_PREVIEW_SOURCE_OUTSIDE_REPO path=$source" }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "LIVE_PREVIEW_SOURCE_MISSING path=$source" }
        $entries.Add([pscustomobject]@{ Source = $source; Remote = $remote })
    }
    return @($entries)
}

function Assert-WorkingTreeScope([object[]]$Entries, $Policy) {
    $explicit = @{}
    foreach ($entry in $Entries) { $explicit[(Normalize-RepoPath ([string]$entry.Source))] = $true }
    foreach ($path in @(Get-ChangedRepoPaths)) {
        if (Test-ControlOnlyRepoPath $path) { continue }
        if (-not (Test-RepoPathAllowed $path $Policy)) { throw "LIVE_PREVIEW_DIRTY_PATH_FORBIDDEN path=$path" }
        if ($explicit.ContainsKey($path)) { continue }
        $auto = Resolve-AutoMappedEntry $path $Policy
        if ($null -eq $auto) { throw "LIVE_PREVIEW_DIRTY_PATH_UNMAPPED path=$path" }
    }
}

function Resolve-PreviewEntries($Policy) {
    if ($ManifestPath) {
        $entries = @(Read-ExplicitManifest $ManifestPath $Policy)
        Assert-WorkingTreeScope $entries $Policy
        return $entries
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($path in @(Get-ChangedRepoPaths)) {
        if (Test-ControlOnlyRepoPath $path) { continue }
        if (-not (Test-RepoPathAllowed $path $Policy)) { throw "LIVE_PREVIEW_DIRTY_PATH_FORBIDDEN path=$path" }
        $entry = Resolve-AutoMappedEntry $path $Policy
        if ($null -eq $entry) { throw "LIVE_PREVIEW_DIRTY_PATH_UNMAPPED path=$path" }
        $full = Join-Path $Root ($path -replace '/','\')
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "LIVE_PREVIEW_DELETION_UNSUPPORTED path=$path" }
        if (-not (Test-RemotePathAllowed ([string]$entry.Remote) $Policy)) { throw "LIVE_PREVIEW_REMOTE_FORBIDDEN path=$($entry.Remote)" }
        $entries.Add($entry)
    }
    if ($entries.Count -eq 0) { throw 'LIVE_PREVIEW_NO_DEPLOYABLE_CHANGES' }
    return @($entries)
}

function Invoke-Remote([string]$Command, [switch]$AllowFailure) {
    $ssh = Get-Tool @('ssh.exe','ssh')
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 $Target $Command 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    $text = ($raw -join "`n").Trim()
    if (-not $AllowFailure -and $code -ne 0) { throw "REMOTE_COMMAND_FAILED exit=$code command=$Command output=$text" }
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

function Copy-ToRemote([string]$Local, [string]$Remote) {
    $scp = Get-Tool @('scp.exe','scp')
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $scp -O -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 $Local "${Target}:$Remote" 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) { throw "REMOTE_COPY_FAILED local=$Local remote=$Remote output=$(($raw -join "`n").Trim())" }
}

function Assert-RemoteOutput([string]$Command, [string]$Pattern, [string]$Failure) {
    $result = Invoke-Remote $Command
    if ($result.Output -notmatch $Pattern) { throw "$Failure output=$($result.Output)" }
    return $result.Output
}

function Assert-ArthurIdentity($Policy) {
    Assert-RemoteOutput 'echo XINZHAO_LIVE_PREVIEW_SSH_OK' '^XINZHAO_LIVE_PREVIEW_SSH_OK$' 'LIVE_PREVIEW_SSH_AUTH_FAILED' | Out-Null
    Assert-RemoteOutput 'ubus call system board' ([string]$Policy.device.board_pattern) 'LIVE_PREVIEW_DEVICE_IDENTITY_MISMATCH' | Out-Null
    $expected = [regex]::Escape([string]$Policy.device.management_ip)
    Assert-RemoteOutput 'uci -q get network.lan.ipaddr' "^$expected(?:/24)?$" 'LIVE_PREVIEW_LAN_MISMATCH' | Out-Null
}

function Assert-EthernetControlPath($Policy) {
    if (-not (Get-Command Get-NetRoute -ErrorAction SilentlyContinue) -or -not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
        throw 'LIVE_PREVIEW_ETHERNET_GUARD_UNAVAILABLE: Windows Get-NetRoute/Get-NetAdapter are required.'
    }
    $hostPart = [string]$Policy.device.management_ip
    $route = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq "$hostPart/32" -or $_.DestinationPrefix -eq '192.168.6.0/24' } |
        Sort-Object RouteMetric |
        Select-Object -First 1
    if (-not $route) {
        $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric |
            Select-Object -First 1
    }
    $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop
    $description = [string]$adapter.InterfaceDescription
    $name = [string]$adapter.Name
    if ($name -match '(?i)wi-?fi|wireless|wlan' -or $description -match '(?i)wi-?fi|wireless|wlan|802\.11') {
        throw "LIVE_PREVIEW_UNSAFE_WIFI_CONTROL_PATH interface=$name description=$description"
    }
    Write-Host "LIVE_PREVIEW_CONTROL_PATH=PASS interface=$name"
}

function Clear-LuciCaches($Policy) {
    $cacheArgs = (@($Policy.luci_cache_paths) | ForEach-Object { [string]$_ }) -join ' '
    Invoke-Remote "rm -f $cacheArgs 2>/dev/null || true" -AllowFailure | Out-Null
}

function New-LivePreviewBackup([object[]]$Entries, $Policy) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $script:BackupDir = "$($Policy.backup_root)/$stamp-$PID"
    Invoke-Remote "mkdir -p '$($script:BackupDir)/files' '$($script:BackupDir)/meta'" | Out-Null

    foreach ($entry in $Entries) {
        $remote = [string]$entry.Remote
        $relative = $remote.TrimStart('/')
        $backupFile = "$($script:BackupDir)/files/$relative"
        $probe = Invoke-Remote "if [ -e '$remote' ]; then mkdir -p \"`$(dirname '$backupFile')\"; cp -p '$remote' '$backupFile'; printf 'EXISTS '; sha256sum '$remote' | cut -d' ' -f1; else echo MISSING; fi"
        $exists = $probe.Output.StartsWith('EXISTS ')
        $hash = if ($exists) { ($probe.Output -split '\s+',2)[1] } else { '' }
        $script:BackupRecords.Add([pscustomobject]@{ Remote = $remote; Backup = $backupFile; Existed = $exists; OriginalSha256 = $hash })
    }
    Write-Host "LIVE_PREVIEW_BACKUP=PASS path=$($script:BackupDir)"
}

function Restore-LivePreviewBackup($Policy) {
    if (-not $script:MutationStarted) { return }
    for ($i = $script:BackupRecords.Count - 1; $i -ge 0; $i--) {
        $record = $script:BackupRecords[$i]
        $remote = [string]$record.Remote
        if ([bool]$record.Existed) {
            Invoke-Remote "mkdir -p \"`$(dirname '$remote')\"; cp -p '$($record.Backup)' '$remote'" -AllowFailure | Out-Null
        } else {
            Invoke-Remote "rm -f '$remote'" -AllowFailure | Out-Null
        }
    }
    if ($script:TouchedRpcd) { Invoke-Remote '/etc/init.d/rpcd restart' -AllowFailure | Out-Null }
    Clear-LuciCaches $Policy
    if ($Feature -in @('AdGuard','Both')) {
        Invoke-Remote '/etc/init.d/adguardhome stop >/dev/null 2>&1 || true; /etc/init.d/adguardhome disable >/dev/null 2>&1 || true' -AllowFailure | Out-Null
    }
    Write-Host 'LIVE_PREVIEW=FAIL_ROLLED_BACK'
}

function Install-PreviewEntries([object[]]$Entries, $Policy) {
    $remoteTemp = "/tmp/xinzhaowrt-live-preview-$PID"
    Invoke-Remote "rm -rf '$remoteTemp'; mkdir -p '$remoteTemp'" | Out-Null
    try {
        $index = 0
        foreach ($entry in $Entries) {
            $index += 1
            $source = Join-Path $Root (([string]$entry.Source) -replace '/','\')
            $remote = [string]$entry.Remote
            $temp = "$remoteTemp/$index"
            $localHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()
            Copy-ToRemote $source $temp
            $script:MutationStarted = $true
            Invoke-Remote "mkdir -p \"`$(dirname '$remote')\"; cp '$temp' '$remote'; chmod 0644 '$remote'" | Out-Null
            $remoteHash = (Invoke-Remote "sha256sum '$remote' | cut -d' ' -f1").Output.Trim().ToLowerInvariant()
            if ($remoteHash -ne $localHash) { throw "LIVE_PREVIEW_HASH_MISMATCH source=$($entry.Source) remote=$remote" }
            if ($remote.StartsWith('/usr/share/rpcd/acl.d/')) { $script:TouchedRpcd = $true }
            Write-Host "LIVE_PREVIEW_FILE=PASS source=$($entry.Source) remote=$remote sha256=$localHash"
        }
        if ($script:TouchedRpcd) { Invoke-Remote '/etc/init.d/rpcd restart' | Out-Null }
        Clear-LuciCaches $Policy
    } finally {
        Invoke-Remote "rm -rf '$remoteTemp'" -AllowFailure | Out-Null
    }
}

function Invoke-Curl([string[]]$Arguments) {
    $curl = Get-Tool @('curl.exe','curl')
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $curl @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $code; Output = ($raw -join "`n") }
}

function Invoke-AuthenticatedLuciPage([string]$Route, $Policy) {
    if (-not $RootPassword) { throw 'LIVE_PREVIEW_AUTH_REQUIRED: ARTHUR_ROOT_PASSWORD is not set.' }
    $hostPart = [string]$Policy.device.management_ip
    $cookie = Join-Path ([System.IO.Path]::GetTempPath()) "xinzhao-live-preview-$PID.cookie"
    try {
        $login = Invoke-Curl @('-sS','--max-time','15','-c',$cookie,'-b',$cookie,'-L','--data-urlencode','luci_username=root','--data-urlencode',"luci_password=$RootPassword","http://$hostPart/cgi-bin/luci/")
        if ($login.ExitCode -ne 0) { throw "LIVE_PREVIEW_LUCI_LOGIN_FAILED output=$($login.Output)" }
        $page = Invoke-Curl @('-sS','--max-time','15','-b',$cookie,'-L',"http://$hostPart/cgi-bin/luci/$Route")
        if ($page.ExitCode -ne 0) { throw "LIVE_PREVIEW_LUCI_PAGE_FAILED route=$Route output=$($page.Output)" }
        return $page.Output
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $cookie
    }
}

function Invoke-Ubus($Request, $Policy) {
    $hostPart = [string]$Policy.device.management_ip
    $body = $Request | ConvertTo-Json -Compress -Depth 12
    $response = Invoke-Curl @('-sS','--max-time','15','-H','Content-Type: application/json','--data-binary',$body,"http://$hostPart/ubus")
    $json = $null
    if ($response.ExitCode -eq 0) {
        try { $json = $response.Output | ConvertFrom-Json -Depth 20 } catch { }
    }
    return [pscustomobject]@{ ExitCode = $response.ExitCode; Output = $response.Output; Json = $json }
}

function Assert-AdGuardRpcAccess($Policy) {
    if (-not $RootPassword) { throw 'LIVE_PREVIEW_AUTH_REQUIRED: ARTHUR_ROOT_PASSWORD is not set.' }
    $loginRequest = [ordered]@{ jsonrpc = '2.0'; id = 1; method = 'call'; params = @('00000000000000000000000000000000','session','login',[ordered]@{ username='root'; password=$RootPassword; timeout=300 }) }
    $login = Invoke-Ubus $loginRequest $Policy
    $sid = $null
    if ($login.Json -and @($login.Json.result).Count -ge 2 -and $login.Json.result[0] -eq 0) { $sid = [string]$login.Json.result[1].ubus_rpc_session }
    if (-not $sid) { throw "ADGUARD_PREVIEW_RPC_LOGIN_FAILED output=$($login.Output)" }
    try {
        $probes = @(
            @{ scope='ubus'; object='luci'; function='getInitList' },
            @{ scope='ubus'; object='luci'; function='setInitAction' },
            @{ scope='file'; object='/etc/adguardhome/adguardhome.yaml'; function='read' },
            @{ scope='file'; object='/etc/adguardhome/adguardhome.yaml'; function='write' },
            @{ scope='file'; object='/usr/bin/AdGuardHome --version'; function='exec' }
        )
        foreach ($probe in $probes) {
            $request = [ordered]@{ jsonrpc='2.0'; id=2; method='call'; params=@($sid,'session','access',$probe) }
            $response = Invoke-Ubus $request $Policy
            $allowed = $false
            if ($response.Json -and @($response.Json.result).Count -ge 2 -and $response.Json.result[0] -eq 0) { $allowed = [bool]$response.Json.result[1].access }
            if (-not $allowed) { throw "ADGUARD_PREVIEW_RPC_ACCESS_DENIED scope=$($probe.scope) object=$($probe.object) function=$($probe.function)" }
        }
    } finally {
        Invoke-Ubus ([ordered]@{ jsonrpc='2.0'; id=3; method='call'; params=@($sid,'session','destroy',[ordered]@{}) }) $Policy | Out-Null
    }
}

function Ensure-AdGuardDisabled {
    Invoke-Remote '/etc/init.d/adguardhome stop >/dev/null 2>&1 || true; /etc/init.d/adguardhome disable >/dev/null 2>&1 || true' -AllowFailure | Out-Null
}

function Test-AdGuardPreview($Policy) {
    $body = Invoke-AuthenticatedLuciPage ([string]$Policy.adguard_route) $Policy
    if ([string]::IsNullOrWhiteSpace($body) -or $body -notmatch '(?i)AdGuard' -or $body -match '(?i)x-luci-login-required|luci_username|登录') {
        throw 'ADGUARD_PREVIEW_PAGE_INCOMPLETE'
    }
    Assert-RemoteOutput '/usr/bin/AdGuardHome --version 2>&1' '(?i)AdGuard Home|AdGuardHome' 'ADGUARD_PREVIEW_CORE_MISSING' | Out-Null
    Assert-AdGuardRpcAccess $Policy
    Ensure-AdGuardDisabled
    Invoke-Remote '/etc/init.d/adguardhome start' | Out-Null
    Start-Sleep -Seconds 2
    Assert-RemoteOutput "pgrep -f '[A]dGuardHome' >/dev/null && echo ADGUARD_RUNNING" '^ADGUARD_RUNNING$' 'ADGUARD_PREVIEW_START_FAILED' | Out-Null
    $webPort = if ($Policy.PSObject.Properties['adguard_web_port']) { [int]$Policy.adguard_web_port } else { 3000 }
    Assert-RemoteOutput "curl -sS --max-time 5 -o /dev/null -w 'HTTP:%{http_code}' http://127.0.0.1:$webPort/" '^HTTP:(200|301|302|401|403)$' 'ADGUARD_PREVIEW_WEB_FAILED' | Out-Null
    Assert-RemoteOutput "logread -e AdGuardHome -l 20 >/dev/null 2>&1 || true; echo ADGUARD_LOG_READ_OK" '^ADGUARD_LOG_READ_OK$' 'ADGUARD_PREVIEW_LOG_READ_FAILED' | Out-Null
    Ensure-AdGuardDisabled
    Assert-RemoteOutput "/etc/init.d/adguardhome enabled >/dev/null 2>&1 && echo ADGUARD_ENABLED || echo ADGUARD_DISABLED" '^ADGUARD_DISABLED$' 'ADGUARD_PREVIEW_FINAL_ENABLE_STATE_FAILED' | Out-Null
    Assert-RemoteOutput "pgrep -f '[A]dGuardHome' >/dev/null && echo ADGUARD_RUNNING || echo ADGUARD_STOPPED" '^ADGUARD_STOPPED$' 'ADGUARD_PREVIEW_FINAL_PROCESS_STATE_FAILED' | Out-Null
    Write-Host 'ADGUARD_PREVIEW=PASS'
}

function Test-QuickStartPreview($Policy) {
    $body = Invoke-AuthenticatedLuciPage ([string]$Policy.quickstart_route) $Policy
    $ok = ($body -match '(?i)luci-static/quickstart/index\.js') -and ($body -match '(?i)<div[^>]+id=["'']app["'']') -and ($body -match '(?i)QuickStart') -and ($body -notmatch '(?i)x-luci-login-required|luci_username|登录')
    if (-not $ok) { throw 'QUICKSTART_PREVIEW_PAGE_INCOMPLETE' }
    Write-Host 'QUICKSTART_PREVIEW=PASS'
}

$Policy = Get-Policy
$Entries = @(Resolve-PreviewEntries $Policy)
Write-Host "STATIC_VALIDATION=PASS entries=$($Entries.Count)"
Write-Host 'WIFI=VERIFIED_FROZEN'
Write-Host 'REAL_DEVICE_VERIFY=NOT_RUN'
Write-Host 'RELEASE_ALLOWED=false'

if ($ValidateOnly) {
    Write-Host 'LIVE_PREVIEW_VALIDATE_ONLY=PASS'
    exit 0
}

Assert-ArthurIdentity $Policy
Assert-EthernetControlPath $Policy
New-LivePreviewBackup $Entries $Policy

try {
    Install-PreviewEntries $Entries $Policy
    if ($Feature -in @('AdGuard','Both')) { Test-AdGuardPreview $Policy }
    if ($Feature -in @('QuickStart','Both')) { Test-QuickStartPreview $Policy }
    Write-Host 'LIVE_PREVIEW=PASS'
    Write-Host "LIVE_PREVIEW_BACKUP_PATH=$($script:BackupDir)"
    Write-Host 'WIFI=VERIFIED_FROZEN'
    Write-Host 'REAL_DEVICE_VERIFY=NOT_RUN'
    Write-Host 'RELEASE_ALLOWED=false'
} catch {
    $message = $_.Exception.Message
    Restore-LivePreviewBackup $Policy
    Write-Error "LIVE_PREVIEW_FAILED: $message"
    throw
}
