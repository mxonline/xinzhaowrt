param(
    [string]$Target = 'root@192.168.6.1',
    [string]$ManifestPath = 'sources/live-preview-mature/manifest.json',
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$PolicyPath = Join-Path $Root 'production\live-preview-policy.json'
$DeployScript = Join-Path $Root 'scripts\live-preview.ps1'
$RootPassword = $env:ARTHUR_ROOT_PASSWORD

function Get-Tool([string[]]$Candidates) {
    foreach ($candidate in $Candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    throw "REQUIRED_TOOL_MISSING candidates=$($Candidates -join ',')"
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
    if (-not $AllowFailure -and $code -ne 0) {
        throw "REMOTE_COMMAND_FAILED exit=$code command=$Command output=$text"
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

function Assert-RemoteOutput([string]$Command, [string]$Pattern, [string]$Failure) {
    $result = Invoke-Remote $Command
    if ($result.Output -notmatch $Pattern) { throw "$Failure output=$($result.Output)" }
    return $result.Output
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
    $cookie = Join-Path ([System.IO.Path]::GetTempPath()) "xinzhao-mature-safe-$PID.cookie"
    try {
        $login = Invoke-Curl @(
            '-sS','--max-time','15','-c',$cookie,'-b',$cookie,'-L',
            '--data-urlencode','luci_username=root',
            '--data-urlencode',"luci_password=$RootPassword",
            "http://$hostPart/cgi-bin/luci/"
        )
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
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "xinzhao-mature-safe-asset-$PID-$([Guid]::NewGuid().ToString('N'))"
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

function Resolve-ManifestPath {
    if ([System.IO.Path]::IsPathRooted($ManifestPath)) { return (Resolve-Path -LiteralPath $ManifestPath).Path }
    return (Resolve-Path -LiteralPath (Join-Path $Root $ManifestPath)).Path
}

function Read-Manifest([string]$ResolvedPath) {
    try { $manifest = Get-Content -Raw -LiteralPath $ResolvedPath | ConvertFrom-Json -Depth 20 }
    catch { throw "LIVE_PREVIEW_MANIFEST_INVALID $($_.Exception.Message)" }
    $entries = @($manifest.entries)
    if ($entries.Count -eq 0) { throw 'LIVE_PREVIEW_MANIFEST_EMPTY' }
    return $manifest
}

function Restore-PreviewFiles($Manifest, [string]$BackupPath) {
    if (-not $BackupPath) { return }
    $entries = @($Manifest.entries)
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $remote = [string]$entries[$i].remote
        $relative = $remote.TrimStart('/')
        $backup = "$BackupPath/files/$relative"
        $command = 'if [ -e ''{0}'' ]; then mkdir -p "$(dirname ''{1}'')"; cp -p ''{0}'' ''{1}''; else rm -f ''{1}''; fi' -f $backup, $remote
        Invoke-Remote $command -AllowFailure | Out-Null
    }
    if (@($entries | Where-Object { ([string]$_.remote).StartsWith('/usr/share/rpcd/acl.d/') }).Count -gt 0) {
        Invoke-Remote '/etc/init.d/rpcd restart' -AllowFailure | Out-Null
    }
    Invoke-Remote 'rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache/* 2>/dev/null || true' -AllowFailure | Out-Null
    Write-Host 'LIVE_PREVIEW=FAIL_ROLLED_BACK'
}

function Invoke-GenericDeploy([string]$ResolvedManifest, [switch]$OnlyValidate) {
    $pwsh = Get-Tool @('pwsh.exe','pwsh')
    $invokeArgs = @('-NoProfile','-File',$DeployScript,'-Target',$Target,'-Feature','Generic','-ManifestPath',$ResolvedManifest)
    if ($OnlyValidate) { $invokeArgs += '-ValidateOnly' }

    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $pwsh @invokeArgs 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    $text = @($raw | ForEach-Object { [string]$_ })
    if ($code -ne 0) { throw "GENERIC_LIVE_PREVIEW_FAILED exit=$code output=$($text -join "`n")" }
    return $text
}

function Get-BackupPath([string[]]$DeployOutput) {
    $backup = ''
    foreach ($line in $DeployOutput) {
        if ($line -match '^LIVE_PREVIEW_BACKUP_PATH=(.+)$') { $backup = $Matches[1].Trim() }
    }
    return $backup
}

function Test-AdGuardUiPreview($Policy) {
    Assert-RemoteOutput "test -x /etc/init.d/AdGuardHome && echo ADGUARD_INIT_OK" '^ADGUARD_INIT_OK$' 'ADGUARD_PREVIEW_INIT_MISSING' | Out-Null
    Assert-RemoteOutput "test -r /etc/AdGuardHome.yaml && test -w /etc/AdGuardHome.yaml && echo ADGUARD_CONFIG_RW_OK" '^ADGUARD_CONFIG_RW_OK$' 'ADGUARD_PREVIEW_CONFIG_ACCESS_FAILED' | Out-Null
    Assert-RemoteOutput "test -x /usr/share/AdGuardHome/update_core.sh && echo ADGUARD_UPDATE_TOOL_OK" '^ADGUARD_UPDATE_TOOL_OK$' 'ADGUARD_PREVIEW_UPDATE_TOOL_MISSING' | Out-Null
    Assert-RemoteOutput '/usr/bin/AdGuardHome --version 2>&1' '(?i)AdGuard Home|AdGuardHome' 'ADGUARD_PREVIEW_CORE_MISSING' | Out-Null
    Assert-RemoteOutput 'uci -q get AdGuardHome.AdGuardHome.enabled' '^0$' 'ADGUARD_PREVIEW_DEFAULT_ENABLE_STATE_FAILED' | Out-Null
    Assert-RemoteOutput 'uci -q get AdGuardHome.AdGuardHome.redirect' '^none$' 'ADGUARD_PREVIEW_REDIRECT_NOT_SAFE' | Out-Null
    Assert-RemoteOutput "pgrep -x AdGuardHome >/dev/null && echo ADGUARD_RUNNING || echo ADGUARD_STOPPED" '^ADGUARD_STOPPED$' 'ADGUARD_PREVIEW_PROCESS_NOT_SAFE' | Out-Null

    Assert-LuciPage ([string]$Policy.adguard_route) '(?i)AdGuard' 'ADGUARD_PREVIEW_OVERVIEW_INCOMPLETE' $Policy | Out-Null
    Assert-LuciPage ([string]$Policy.adguard_base_route) '(?i)AdGuard|基础|设置' 'ADGUARD_PREVIEW_BASE_INCOMPLETE' $Policy | Out-Null
    Assert-LuciPage ([string]$Policy.adguard_tools_route) '(?i)AdGuard|运维|更新' 'ADGUARD_PREVIEW_TOOLS_INCOMPLETE' $Policy | Out-Null
    Assert-LuciPage ([string]$Policy.adguard_log_route) '(?i)AdGuard|日志|log' 'ADGUARD_PREVIEW_LOG_INCOMPLETE' $Policy | Out-Null
    Assert-LuciPage ([string]$Policy.adguard_manual_route) '(?i)AdGuard|YAML|手动' 'ADGUARD_PREVIEW_MANUAL_INCOMPLETE' $Policy | Out-Null

    $status = Invoke-AuthenticatedLuciPage ([string]$Policy.adguard_status_route) $Policy
    if ($status -notmatch '"running"\s*:\s*false') { throw "ADGUARD_PREVIEW_STATUS_INVALID body=$status" }

    Write-Host 'ADGUARD_UI_PREVIEW=PASS'
    Write-Host 'ADGUARD_NETWORK_MUTATION_TEST=DEFERRED_TO_REAL_DEVICE_VERIFY'
    Write-Host 'ADGUARD_WEB_RUNTIME_TEST=DEFERRED_TO_REAL_DEVICE_VERIFY'
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

if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) { throw "LIVE_PREVIEW_POLICY_MISSING path=$PolicyPath" }
try { $Policy = Get-Content -Raw -LiteralPath $PolicyPath | ConvertFrom-Json -Depth 20 }
catch { throw "LIVE_PREVIEW_POLICY_INVALID $($_.Exception.Message)" }
if ([int]$Policy.schema_version -ne 1) { throw "LIVE_PREVIEW_POLICY_SCHEMA_UNSUPPORTED actual=$($Policy.schema_version)" }

$ResolvedManifest = Resolve-ManifestPath
$Manifest = Read-Manifest $ResolvedManifest

if ($ValidateOnly) {
    Invoke-GenericDeploy $ResolvedManifest -OnlyValidate | Out-Null
    Write-Host 'MATURE_SAFE_VALIDATE_ONLY=PASS'
    Write-Host 'WIFI=VERIFIED_FROZEN'
    Write-Host 'REAL_DEVICE_VERIFY=NOT_RUN'
    Write-Host 'RELEASE_ALLOWED=false'
    exit 0
}

if (-not $RootPassword) { throw 'LIVE_PREVIEW_AUTH_REQUIRED: ARTHUR_ROOT_PASSWORD is not set.' }

$DeployOutput = @(Invoke-GenericDeploy $ResolvedManifest)
$BackupPath = Get-BackupPath $DeployOutput
if (-not $BackupPath) { throw 'LIVE_PREVIEW_BACKUP_PATH_MISSING_AFTER_DEPLOY' }

try {
    Test-AdGuardUiPreview $Policy
    Test-QuickStartPreview $Policy
    Write-Host 'LIVE_PREVIEW=PASS'
    Write-Host "LIVE_PREVIEW_BACKUP_PATH=$BackupPath"
    Write-Host 'WIFI=VERIFIED_FROZEN'
    Write-Host 'REAL_DEVICE_VERIFY=NOT_RUN'
    Write-Host 'RELEASE_ALLOWED=false'
} catch {
    $message = $_.Exception.Message
    Restore-PreviewFiles $Manifest $BackupPath
    Write-Error "LIVE_PREVIEW_SAFE_FALLBACK_FAILED: $message"
    throw
}
