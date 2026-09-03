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

function Test-Exact([string]$Value, [object[]]$Values) {
    foreach ($candidate in @($Values)) {
        if ($Value.Equals([string]$candidate, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
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

    $exact = @()
    if ($Policy.PSObject.Properties['allowed_remote_exact']) { $exact = @($Policy.allowed_remote_exact) }
    if (Test-Exact $RemotePath $exact) { return $true }

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
        $p -eq '.gitignore' -or
        $p -eq 'scripts/live-preview.ps1' -or
        $p -eq 'scripts/prepare-live-preview-sources.ps1' -or
        $p -eq 'scripts/classify-build-scope.sh' -or
        $p -eq 'scripts/verify-project.sh' -or
        $p -eq 'production/live-preview-policy.json' -or
        $p -eq 'production/mature-ui-sources.json' -or
        $p -eq 'AGENTS.md'
    )
}

function Get-Policy {
    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) { throw "LIVE_PREVIEW_POLICY_MISSING path=$PolicyPath" }
    try { $policy = Get-Content -Raw -LiteralPath $PolicyPath | ConvertFrom-Json -Depth 20 }
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
            return [pscustomobject]@{ Source = $RepoPath; Remote = $remote; Mode = '0644' }
        }
    }
    return $null
}

function Read-ExplicitManifest([string]$Path, $Policy) {
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    try { $parsed = Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json -Depth 20 }
    catch { throw "LIVE_PREVIEW_MANIFEST_INVALID $($_.Exception.Message)" }
    $entriesProperty = $parsed.PSObject.Properties['entries']
    $rawEntries = if ($entriesProperty) { @($parsed.entries) } else { @($parsed) }
    if ($rawEntries.Count -eq 0) { throw 'LIVE_PREVIEW_MANIFEST_EMPTY' }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in $rawEntries) {
        $source = Normalize-RepoPath ([string]$raw.source)
        $remote = [string]$raw.remote
        $mode = '0644'
        if ($raw.PSObject.Properties['mode']) { $mode = [string]$raw.mode }
        if ($mode -notin @('0644','0755')) { throw "LIVE_PREVIEW_MODE_FORBIDDEN source=$source mode=$mode" }
        if (-not (Test-RepoPathAllowed $source $Policy)) { throw "LIVE_PREVIEW_SOURCE_FORBIDDEN path=$source" }
        if (-not (Test-RemotePathAllowed $remote $Policy)) { throw "LIVE_PREVIEW_REMOTE_FORBIDDEN path=$remote" }
        $full = [System.IO.Path]::GetFullPath((Join-Path $Root ($source -replace '/','\')))
        $rootPrefix = $Root.TrimEnd('\') + '\'
        if (-not $full.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "LIVE_PREVIEW_SOURCE_OUTSIDE_REPO path=$source" }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "LIVE_PREVIEW_SOURCE_MISSING path=$source" }
        $entries.Add([pscustomobject]@{ Source = $source; Remote = $remote; Mode = $mode })
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

function Stop-AdGuardPreviewProcess {
    Invoke-Remote '/etc/init.d/AdGuardHome stop >/dev/null 2>&1 || true; pkill -TERM AdGuardHome >/dev/null 2>&1 || true; sleep 1; pkill -KILL AdGuardHome >/dev/null 2>&1 || true' -AllowFailure | Out-Null
}

function Restore-LivePreviewBackup($Policy) {
    if (-not $script:MutationStarted) { return }
    if ($Feature -in @('AdGuard','Both')) { Stop-AdGuardPreviewProcess }
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
            $mode = [string]$entry.Mode
            if ($mode -notin @('0644','0755')) { throw "LIVE_PREVIEW_MODE_FORBIDDEN source=$($entry.Source) mode=$mode" }
            $temp = "$remoteTemp/$index"
            $localHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()
            Copy-ToRemote $source $temp
            $script:MutationStarted = $true
            Invoke-Remote "mkdir -p \"`$(dirname '$remote')\"; cp '$temp' '$remote'; chmod $mode '$remote'" | Out-Null
            $remoteHash = (Invoke-Remote "sha256sum '$remote' | cut -d' ' -f1").Output.Trim().ToLowerInvariant()
            if ($remoteHash -ne $localHash) { throw "LIVE_PREVIEW_HASH_MISMATCH source=$($entry.Source) remote=$remote" }
            if ($remote.StartsWith('/usr/share/rpcd/acl.d/')) { $script:TouchedRpcd = $true }
            Write-Host "LIVE_PREVIEW_FILE=PASS source=$($entry.Source) remote=$remote mode=$mode sha256=$localHash"
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

function Assert-LuciPage([string]$Route, [string]$Marker, [string]$Failure, $Policy) {
    $body = Invoke-AuthenticatedLuciPage $Route $Policy
    if ([string]::IsNullOrWhiteSpace($body) -or $body -match '(?i)x-luci-login-required|luci_username|登录') {
        throw "$Failure reason=login-or-empty"
    }
    if ($Marker -and $body -notmatch $Marker) { throw "$Failure reason=marker-missing marker=$Marker" }
    return $body
}

function Assert-HttpAsset([string]$Path, [int]$MinimumBytes, [string]$Failure, $Policy) {
    $hostPart = [string]$Policy.device.management_ip
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "xinzhao-live-preview-asset-$PID-$([Guid]::NewGuid().ToString('N'))"
    try {
        $response = Invoke-Curl @('-sS','--max-time','15','-o',$temp,'-w','HTTP:%{http_code}',"http://$hostPart$Path")
        if ($response.ExitCode -ne 0 -or $response.Output -notmatch '^HTTP:200$') {
            throw "$Failure output=$($response.Output)"
        }
        $length = (Get-Item -LiteralPath $temp).Length
        if ($length -lt $MinimumBytes) { throw "$Failure bytes=$length expected_at_least=$MinimumBytes" }
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $temp
    }
}

function Ensure-AdGuardDisabled {
    Invoke-Remote "uci -q set AdGuardHome.AdGuardHome.enabled='0'; uci -q commit AdGuardHome; /etc/init.d/AdGuardHome stop >/dev/null 2>&1 || true; /etc/init.d/AdGuardHome disable >/dev/null 2>&1 || true" -AllowFailure | Out-Null
}

function Test-AdGuardPreview($Policy) {
    Assert-RemoteOutput "test -x /etc/init.d/AdGuardHome && echo ADGUARD_INIT_OK" '^ADGUARD_INIT_OK$' 'ADGUARD_PREVIEW_INIT_MISSING' | Out-Null
    Assert-RemoteOutput "test -r /etc/AdGuardHome.yaml && test -w /etc/AdGuardHome.yaml && echo ADGUARD_CONFIG_RW_OK" '^ADGUARD_CONFIG_RW_OK$' 'ADGUARD_PREVIEW_CONFIG_ACCESS_FAILED' | Out-Null
    Assert-RemoteOutput "test -x /usr/share/AdGuardHome/update_core.sh && echo ADGUARD_UPDATE_TOOL_OK" '^ADGUARD_UPDATE_TOOL_OK$' 'ADGUARD_PREVIEW_UPDATE_TOOL_MISSING' | Out-Null
    Assert-RemoteOutput '/usr/bin/AdGuardHome --version 2>&1' '(?i)AdGuard Home|AdGuardHome' 'ADGUARD_PREVIEW_CORE_MISSING' | Out-Null

    Ensure-AdGuardDisabled
    Assert-RemoteOutput 'uci -q get AdGuardHome.AdGuardHome.enabled' '^0$' 'ADGUARD_PREVIEW_DEFAULT_ENABLE_STATE_FAILED' | Out-Null
    Assert-RemoteOutput 'uci -q get AdGuardHome.AdGuardHome.redirect' '^none$' 'ADGUARD_PREVIEW_REDIRECT_NOT_SAFE' | Out-Null
    Assert-RemoteOutput "uci -q get dhcp.@dnsmasq[0].port >/dev/null && echo DNSMASQ_PORT_PRESENT" '^DNSMASQ_PORT_PRESENT$' 'ADGUARD_PREVIEW_DNSMASQ_GUARD_FAILED' | Out-Null

    Assert-LuciPage ([string]$Policy.adguard_route) '(?i)AdGuard' 'ADGUARD_PREVIEW_OVERVIEW_INCOMPLETE' $Policy | Out-Null
    Assert-LuciPage ([string]$Policy.adguard_base_route) '(?i)AdGuard|基础|设置' 'ADGUARD_PREVIEW_BASE_INCOMPLETE' $Policy | Out-Null
    Assert-LuciPage ([string]$Policy.adguard_tools_route) '(?i)AdGuard|运维|更新' 'ADGUARD_PREVIEW_TOOLS_INCOMPLETE' $Policy | Out-Null
    Assert-LuciPage ([string]$Policy.adguard_log_route) '(?i)AdGuard|日志|log' 'ADGUARD_PREVIEW_LOG_INCOMPLETE' $Policy | Out-Null
    Assert-LuciPage ([string]$Policy.adguard_manual_route) '(?i)AdGuard|YAML|手动' 'ADGUARD_PREVIEW_MANUAL_INCOMPLETE' $Policy | Out-Null

    $statusBefore = Invoke-AuthenticatedLuciPage ([string]$Policy.adguard_status_route) $Policy
    if ($statusBefore -notmatch '"running"\s*:\s*false') { throw "ADGUARD_PREVIEW_STATUS_BEFORE_INVALID body=$statusBefore" }

    Invoke-Remote '/etc/init.d/AdGuardHome start' | Out-Null
    Start-Sleep -Seconds 3
    Assert-RemoteOutput "pgrep -x AdGuardHome >/dev/null && echo ADGUARD_RUNNING" '^ADGUARD_RUNNING$' 'ADGUARD_PREVIEW_START_FAILED' | Out-Null
    $statusRunning = Invoke-AuthenticatedLuciPage ([string]$Policy.adguard_status_route) $Policy
    if ($statusRunning -notmatch '"running"\s*:\s*true') { throw "ADGUARD_PREVIEW_STATUS_RUNNING_INVALID body=$statusRunning" }

    $webPort = if ($Policy.PSObject.Properties['adguard_web_port']) { [int]$Policy.adguard_web_port } else { 3000 }
    Assert-RemoteOutput "curl -sS --max-time 5 -o /dev/null -w 'HTTP:%{http_code}' http://127.0.0.1:$webPort/" '^HTTP:(200|301|302|401|403)$' 'ADGUARD_PREVIEW_WEB_FAILED' | Out-Null
    Assert-RemoteOutput "logread -e AdGuardHome -l 20 >/dev/null 2>&1 || true; echo ADGUARD_LOG_READ_OK" '^ADGUARD_LOG_READ_OK$' 'ADGUARD_PREVIEW_LOG_READ_FAILED' | Out-Null

    Ensure-AdGuardDisabled
    Assert-RemoteOutput "/etc/init.d/AdGuardHome enabled >/dev/null 2>&1 && echo ADGUARD_ENABLED || echo ADGUARD_DISABLED" '^ADGUARD_DISABLED$' 'ADGUARD_PREVIEW_FINAL_ENABLE_STATE_FAILED' | Out-Null
    Assert-RemoteOutput "pgrep -x AdGuardHome >/dev/null && echo ADGUARD_RUNNING || echo ADGUARD_STOPPED" '^ADGUARD_STOPPED$' 'ADGUARD_PREVIEW_FINAL_PROCESS_STATE_FAILED' | Out-Null
    Assert-RemoteOutput 'uci -q get AdGuardHome.AdGuardHome.enabled' '^0$' 'ADGUARD_PREVIEW_FINAL_UCI_STATE_FAILED' | Out-Null
    $statusAfter = Invoke-AuthenticatedLuciPage ([string]$Policy.adguard_status_route) $Policy
    if ($statusAfter -notmatch '"running"\s*:\s*false') { throw "ADGUARD_PREVIEW_STATUS_AFTER_INVALID body=$statusAfter" }

    Write-Host 'ADGUARD_PREVIEW=PASS'
}

function Test-QuickStartPreview($Policy) {
    Assert-RemoteOutput "pgrep -x quickstart >/dev/null && echo QUICKSTART_BACKEND_RUNNING" '^QUICKSTART_BACKEND_RUNNING$' 'QUICKSTART_PREVIEW_BACKEND_NOT_RUNNING' | Out-Null
    $body = Invoke-AuthenticatedLuciPage ([string]$Policy.quickstart_route) $Policy
    $ok = ($body -match '(?i)luci-static/quickstart/index\.js') -and
          ($body -match '(?i)luci-static/quickstart/style\.css') -and
          ($body -match '(?i)<div[^>]+id=["'']app["'']') -and
          ($body -notmatch '(?i)x-luci-login-required|luci_username|登录')
    if (-not $ok) { throw 'QUICKSTART_PREVIEW_PAGE_INCOMPLETE' }

    Assert-HttpAsset '/luci-static/quickstart/index.js' 100000 'QUICKSTART_PREVIEW_INDEX_ASSET_FAILED' $Policy
    Assert-HttpAsset '/luci-static/quickstart/style.css' 50000 'QUICKSTART_PREVIEW_STYLE_ASSET_FAILED' $Policy
    Assert-HttpAsset '/luci-static/quickstart/vendor.js' 100000 'QUICKSTART_PREVIEW_VENDOR_ASSET_FAILED' $Policy
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
