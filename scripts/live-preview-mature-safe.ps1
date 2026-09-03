param(
    [string]$Target = 'root@192.168.6.1',
    [string]$ManifestPath = 'sources/live-preview-mature/manifest.json',
    [string]$FeatureId = 'arthur-adh-quickstart',
    [switch]$PauseAfterLivePreview,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$PolicyPath = Join-Path $Root 'production\live-preview-policy.json'
$AcceptedPreviewRoot = Join-Path $Root 'production\accepted-preview'
$DeployScript = Join-Path $Root 'scripts\live-preview.ps1'
$HandoffScript = Join-Path $Root 'scripts\feature-handoff.ps1'
$HandoffInstaller = Join-Path $Root 'scripts\install-feature-handoff.ps1'
$HandoffTask = 'XinZhaoWrt-Arthur-Feature-Handoff'
$RootPassword = $env:ARTHUR_ROOT_PASSWORD
. (Join-Path $PSScriptRoot 'feature-handoff-lib.ps1')
. (Join-Path $PSScriptRoot 'fast-safe-release-lib.ps1')

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
        $sshArgs = @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=8','-o','KexAlgorithms=curve25519-sha256')
        if ($env:ARTHUR_PREVIEW_KNOWN_HOSTS) { $sshArgs += @('-o',"UserKnownHostsFile=$($env:ARTHUR_PREVIEW_KNOWN_HOSTS)") }
        $raw = @(& $ssh @sshArgs $Target $Command 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    $text = ($raw -join "`n").Trim()
    if (-not $AllowFailure -and $code -ne 0) { throw "REMOTE_COMMAND_FAILED exit=$code command=$Command output=$text" }
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
    } finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ ExitCode = $code; Output = ($raw -join "`n") }
}

function Invoke-AuthenticatedLuciPage([string]$Route, $Policy) {
    if (-not $RootPassword) { throw 'LIVE_PREVIEW_AUTH_REQUIRED: ARTHUR_ROOT_PASSWORD is not set.' }
    $hostPart = [string]$Policy.device.management_ip
    $cookie = Join-Path ([System.IO.Path]::GetTempPath()) "xinzhao-mature-safe-$PID.cookie"
    try {
        $login = Invoke-Curl @(
            '-sS','--max-time','15','-c',$cookie,'-b',$cookie,'-L',
            '--data-urlencode','luci_username=root','--data-urlencode',"luci_password=$RootPassword",
            "http://$hostPart/cgi-bin/luci/"
        )
        if ($login.ExitCode -ne 0) { throw "LIVE_PREVIEW_LUCI_LOGIN_FAILED output=$($login.Output)" }
        $page = Invoke-Curl @('-sS','--max-time','15','-b',$cookie,'-L',"http://$hostPart/cgi-bin/luci/$Route")
        if ($page.ExitCode -ne 0) { throw "LIVE_PREVIEW_LUCI_PAGE_FAILED route=$Route output=$($page.Output)" }
        return $page.Output
    } finally { Remove-Item -Force -ErrorAction SilentlyContinue $cookie }
}

function Assert-LuciPage([string]$Route, [string]$Marker, [string]$Failure, $Policy) {
    $body = Invoke-AuthenticatedLuciPage $Route $Policy
    if ([string]::IsNullOrWhiteSpace($body) -or $body -match '(?i)x-luci-login-required|luci_username') { throw "$Failure reason=login-or-empty" }
    if ($Marker -and $body -notmatch $Marker) { throw "$Failure reason=marker-missing marker=$Marker" }
    return $body
}

function Assert-HttpAsset([string]$Path, [int]$MinimumBytes, [string]$Failure, $Policy) {
    $hostPart = [string]$Policy.device.management_ip
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "xinzhao-mature-safe-asset-$PID-$([Guid]::NewGuid().ToString('N'))"
    try {
        $response = Invoke-Curl @('-sS','--max-time','15','-o',$temp,'-w','HTTP:%{http_code}',"http://$hostPart$Path")
        if ($response.ExitCode -ne 0 -or $response.Output -notmatch '^HTTP:200$') { throw "$Failure output=$($response.Output)" }
        $length = (Get-Item -LiteralPath $temp).Length
        if ($length -lt $MinimumBytes) { throw "$Failure bytes=$length expected_at_least=$MinimumBytes" }
    } finally { Remove-Item -Force -ErrorAction SilentlyContinue $temp }
}

function Resolve-ManifestPath {
    if ([System.IO.Path]::IsPathRooted($ManifestPath)) { return (Resolve-Path -LiteralPath $ManifestPath).Path }
    return (Resolve-Path -LiteralPath (Join-Path $Root $ManifestPath)).Path
}

function Read-Manifest([string]$ResolvedPath) {
    try { $manifest = Get-Content -Raw -LiteralPath $ResolvedPath | ConvertFrom-Json -Depth 20 }
    catch { throw "LIVE_PREVIEW_MANIFEST_INVALID $($_.Exception.Message)" }
    if (@($manifest.entries).Count -eq 0) { throw 'LIVE_PREVIEW_MANIFEST_EMPTY' }
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
    if (@($entries | Where-Object { ([string]$_.remote).StartsWith('/usr/share/rpcd/acl.d/') }).Count -gt 0) { Invoke-Remote '/etc/init.d/rpcd restart' -AllowFailure | Out-Null }
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
    } finally { $ErrorActionPreference = $previous }
    $text = @($raw | ForEach-Object { [string]$_ })
    if ($code -ne 0) { throw "GENERIC_LIVE_PREVIEW_FAILED exit=$code output=$($text -join "`n")" }
    return $text
}

function Get-BackupPath([string[]]$DeployOutput) {
    $backup = ''
    foreach ($line in $DeployOutput) { if ($line -match '^LIVE_PREVIEW_BACKUP_PATH=(.+)$') { $backup = $Matches[1].Trim() } }
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
    $ok = ($body -match '(?i)luci-static/quickstart/index\.js') -and ($body -match '(?i)luci-static/quickstart/style\.css') -and ($body -match '(?i)<div[^>]+id=["'']app["'']') -and ($body -notmatch '(?i)x-luci-login-required|luci_username')
    if (-not $ok) { throw 'QUICKSTART_PREVIEW_PAGE_INCOMPLETE' }
    Assert-HttpAsset '/luci-static/quickstart/index.js' 100000 'QUICKSTART_PREVIEW_INDEX_ASSET_FAILED' $Policy
    Assert-HttpAsset '/luci-static/quickstart/style.css' 50000 'QUICKSTART_PREVIEW_STYLE_ASSET_FAILED' $Policy
    Assert-HttpAsset '/luci-static/quickstart/vendor.js' 100000 'QUICKSTART_PREVIEW_VENDOR_ASSET_FAILED' $Policy
    Write-Host 'QUICKSTART_PREVIEW=PASS'
}

function Start-FeatureHandoff([string]$ResolvedManifest) {
    if ($PauseAfterLivePreview) { Write-Host 'FEATURE_HANDOFF=PAUSED_BY_USER'; return }
    if (-not (Test-Path -LiteralPath $HandoffScript -PathType Leaf)) { throw "FEATURE_HANDOFF_SCRIPT_MISSING=$HandoffScript" }
    if (-not (Test-Path -LiteralPath $HandoffInstaller -PathType Leaf)) { throw "FEATURE_HANDOFF_INSTALLER_MISSING=$HandoffInstaller" }
    $pwsh=Get-Tool @('pwsh.exe','pwsh')
    $runtime=Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\FeatureHandoff'
    New-Item -ItemType Directory -Force -Path $runtime | Out-Null
    $safeFeature=($FeatureId -replace '[^a-zA-Z0-9._-]','-')
    $evidencePath=Join-Path $runtime ("preview-evidence-$safeFeature.json")
    [ordered]@{
        LIVE_PREVIEW='PASS'; ADGUARD_UI_PREVIEW='PASS'; ADGUARD_PREVIEW='PASS'; QUICKSTART_PREVIEW='PASS';
        WIFI='VERIFIED_FROZEN'; REAL_DEVICE_VERIFY='NOT_RUN'; RELEASE_ALLOWED=$false;
        ADGUARD_NETWORK_MUTATION_TEST='DEFERRED_TO_REAL_DEVICE_VERIFY';
        ADGUARD_WEB_RUNTIME_TEST='DEFERRED_TO_REAL_DEVICE_VERIFY'; captured_at=(Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $evidencePath -Encoding UTF8

    $acceptedSha=(& git -C $Root rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
    if ($LASTEXITCODE -ne 0 -or $acceptedSha -notmatch '^[0-9a-f]{40}$') { throw 'FEATURE_HANDOFF_ACCEPTED_SOURCE_SHA_UNAVAILABLE' }

    $acceptArgs=@(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$HandoffScript,
        '-Mode','AcceptPreview','-FeatureId',$FeatureId,
        '-AcceptedPreviewSourceSha',$acceptedSha,
        '-PreviewManifestPath',$ResolvedManifest,
        '-PreviewEvidencePath',$evidencePath
    )
    $acceptRaw=@(& $pwsh @acceptArgs 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "FEATURE_HANDOFF_ACCEPT_FAILED=$($acceptRaw -join ' ')" }

    $installRaw=@(& $pwsh -NoProfile -ExecutionPolicy Bypass -File $HandoffInstaller 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "FEATURE_HANDOFF_INSTALL_FAILED=$($installRaw -join ' ')" }
    Start-ScheduledTask -TaskName $HandoffTask -ErrorAction Stop
    Write-Host "FEATURE_HANDOFF_STARTED=TASK:$HandoffTask"
    Write-Host "FEATURE_HANDOFF_EVIDENCE=$evidencePath"
}

function Resume-AcceptedFeatureHandoff {
    if ($PauseAfterLivePreview) { Write-Host 'FEATURE_HANDOFF=PAUSED_BY_USER'; return }
    $task = Get-ScheduledTask -TaskName $HandoffTask -ErrorAction SilentlyContinue
    if ($task) {
        Start-ScheduledTask -TaskName $HandoffTask -ErrorAction SilentlyContinue
        Write-Host "FEATURE_HANDOFF_STARTED=EXISTING_TASK:$HandoffTask"
    } else {
        Write-Host 'FEATURE_HANDOFF_STARTED=ACCEPTED_RECORD_REUSED_NO_DUPLICATE_ACCEPT'
    }
}

function Get-AcceptedPreviewRecord([string]$ResolvedManifest) {
    if ($FeatureId -notmatch '^[a-z0-9][a-z0-9._-]{2,80}$') { return $null }
    $recordPath = Join-Path $AcceptedPreviewRoot "$FeatureId.json"
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return $null }
    try { $record = Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json -Depth 40 }
    catch { throw "ACCEPTED_PREVIEW_RECORD_INVALID path=$recordPath error=$($_.Exception.Message)" }
    if ([string]$record.feature_id -ne $FeatureId) { return $null }
    $currentManifest = Get-PreviewManifestIdentity -RepoRoot $Root -ManifestPath $ResolvedManifest
    if ([string]$currentManifest.manifest_sha256 -ne [string]$record.preview_manifest_sha256) { return $null }
    foreach ($file in @($record.frozen_files)) {
        $overlay = Join-Path $Root (([string]$file.overlay) -replace '/','\')
        if (-not (Test-Path -LiteralPath $overlay -PathType Leaf)) { return $null }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $overlay).Hash.ToLowerInvariant()
        if ($actual -ne ([string]$file.sha256).ToLowerInvariant()) { return $null }
    }
    return $record
}

function ConvertTo-ShellSingleQuoted([string]$Text) {
    if ($Text -match "[\r\n]") { throw 'ACCEPTED_PREVIEW_REMOTE_PATH_INVALID' }
    return "'" + ($Text -replace "'", "'\"'\"'") + "'"
}

function Get-RemoteAcceptedHashes($AcceptedRecord) {
    $commands = New-Object System.Collections.Generic.List[string]
    foreach ($file in @($AcceptedRecord.frozen_files | Sort-Object { [string]$_.remote })) {
        $remote = [string]$file.remote
        $quoted = ConvertTo-ShellSingleQuoted $remote
        $commands.Add("p=$quoted; if [ -f \"`$p\" ]; then h=`$(sha256sum \"`$p\" | awk '{print `$1}'); printf '%s\\t%s\\n' \"`$p\" \"`$h\"; else printf '%s\\tMISSING\\n' \"`$p\"; fi")
    }
    $result = Invoke-Remote ($commands -join '; ')
    $hashes = @{}
    foreach ($line in @($result.Output -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split "`t",2
        if ($parts.Count -ne 2) { throw "ACCEPTED_PREVIEW_HASH_OUTPUT_INVALID line=$line" }
        $hashes[$parts[0]] = if ($parts[1] -eq 'MISSING') { '' } else { $parts[1].ToLowerInvariant() }
    }
    return $hashes
}

function New-DriftOnlyManifest($AcceptedRecord,[string[]]$Paths) {
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($remote in $Paths) {
        $file = @($AcceptedRecord.frozen_files | Where-Object { [string]$_.remote -eq $remote }) | Select-Object -First 1
        if (-not $file) { throw "ACCEPTED_PREVIEW_DRIFT_PATH_UNRESOLVED=$remote" }
        $overlay = [string]$file.overlay
        $full = Join-Path $Root ($overlay -replace '/','\')
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "ACCEPTED_PREVIEW_FROZEN_BYTE_MISSING=$overlay" }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToLowerInvariant()
        if ($actual -ne ([string]$file.sha256).ToLowerInvariant()) { throw "ACCEPTED_PREVIEW_FROZEN_BYTE_HASH_MISMATCH=$overlay" }
        $entries.Add([ordered]@{ source=$overlay; remote=$remote; mode=[string]$file.mode })
    }
    $path = Join-Path ([System.IO.Path]::GetTempPath()) "xinzhao-preview-drift-$PID-$([Guid]::NewGuid().ToString('N')).json"
    [ordered]@{ schema_version=1; entries=@($entries) } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Try-ReuseAcceptedPreview([string]$ResolvedManifest,$Policy) {
    $record = Get-AcceptedPreviewRecord $ResolvedManifest
    if (-not $record) { return $false }
    $deviceHashes = Get-RemoteAcceptedHashes $record
    $decision = Get-PreviewReuseDecision -AcceptedRecord $record -DeviceHashes $deviceHashes
    Write-Host "PREVIEW_REUSE_ACTION=$($decision.action)"
    Write-Host "ACCEPTED_PREVIEW_FINGERPRINT=$($decision.fingerprint)"

    if ([string]$decision.action -eq 'REUSE_PREVIEW_ACCEPTED') {
        Write-Host 'REUSE_PREVIEW_ACCEPTED=PASS'
        Write-Host 'PREVIEW_FULL_DEPLOY_SKIPPED=true'
        Write-Host 'LIVE_PREVIEW=PASS_REUSED_ACCEPTED'
        Write-Host 'WIFI=VERIFIED_FROZEN'
        Write-Host 'REAL_DEVICE_VERIFY=NOT_RUN'
        Write-Host 'RELEASE_ALLOWED=false'
        Resume-AcceptedFeatureHandoff
        return $true
    }
    if ([string]$decision.action -ne 'RESTORE_DRIFTED_PREVIEW_FILES') { return $false }

    $partialManifestPath = New-DriftOnlyManifest -AcceptedRecord $record -Paths @($decision.paths)
    $partialManifest = $null
    $backup = ''
    try {
        $partialManifest = Read-Manifest $partialManifestPath
        $deploy = @(Invoke-GenericDeploy $partialManifestPath)
        $backup = Get-BackupPath $deploy
        if (-not $backup) { throw 'ACCEPTED_PREVIEW_DRIFT_BACKUP_MISSING' }
        Test-AdGuardUiPreview $Policy
        Test-QuickStartPreview $Policy
        Write-Host "RESTORE_DRIFTED_PREVIEW_FILES=PASS count=$(@($decision.paths).Count)"
        Write-Host 'PREVIEW_FULL_DEPLOY_SKIPPED=true'
        Write-Host 'LIVE_PREVIEW=PASS'
        Write-Host 'WIFI=VERIFIED_FROZEN'
        Write-Host 'REAL_DEVICE_VERIFY=NOT_RUN'
        Write-Host 'RELEASE_ALLOWED=false'
        Resume-AcceptedFeatureHandoff
        return $true
    } catch {
        if ($partialManifest -and $backup) { Restore-PreviewFiles $partialManifest $backup }
        throw
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $partialManifestPath
    }
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

if (Try-ReuseAcceptedPreview -ResolvedManifest $ResolvedManifest -Policy $Policy) { exit 0 }

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
    Start-FeatureHandoff $ResolvedManifest
} catch {
    $message = $_.Exception.Message
    if ($message -like 'FEATURE_HANDOFF_*') {
        Write-Error "LIVE_PREVIEW_PASS_BUT_HANDOFF_FAILED: $message"
        throw
    }
    Restore-PreviewFiles $Manifest $BackupPath
    Write-Error "LIVE_PREVIEW_SAFE_FALLBACK_FAILED: $message"
    throw
}
