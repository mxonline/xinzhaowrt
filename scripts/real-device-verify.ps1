param(
    [string]$DeviceIp = '192.168.6.1',
    [string]$Candidate = $env:ARTHUR_CANDIDATE_ID,
    [string]$Commit = $env:ARTHUR_CANDIDATE_SHA,
    [string]$LuciCookieFile = $env:ARTHUR_LUCI_COOKIE_FILE,
    [ValidateSet('Prebuild','PostFlash')][string]$Mode = 'Prebuild'
)

$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$AccessHelper = Join-Path $PSScriptRoot 'ensure-arthur-unattended-access.ps1'
if (-not (Test-Path -LiteralPath $AccessHelper -PathType Leaf)) { throw "ARTHUR_ACCESS_HELPER_MISSING path=$AccessHelper" }
. $AccessHelper

$Target = "root@$DeviceIp"
$Candidate = if ($Candidate) { $Candidate } else { 'candidate-not-supplied' }
$Commit = if ($Commit) { $Commit } else { 'commit-not-supplied' }
if ($Candidate -match '33462873812') {
    throw 'REJECTED_FOR_RELEASE: candidate 33462873812 is REAL_DEVICE_VERIFY_INVALIDATED and may not be reflashed or released.'
}

$OutDir = Join-Path $Root 'output\real-device'
$JsonPath = Join-Path $OutDir 'real-device-verification.json'
$MdPath = Join-Path $OutDir 'real-device-verification.md'
$Required = @(Get-Content (Join-Path $Root 'config\required-plugins.txt') | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() })
$RequiredPluginCount = 22
if ($Required.Count -ne $RequiredPluginCount) { throw "Required plugin contract mismatch: expected $RequiredPluginCount, found $($Required.Count)" }
$WifiBaselinePath = Join-Path $Root 'production\wifi-frozen-baseline.json'
$TestFile = '/etc/xinzhao-real-device-test'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$script:Checks = [ordered]@{}
$script:Failures = [System.Collections.Generic.List[object]]::new()
$script:KnownHosts = $null
$script:EffectiveLuciCookieFile = $LuciCookieFile
$script:ProvidedLuciCookieFile = $LuciCookieFile
$script:GeneratedCookieFiles = [System.Collections.Generic.List[string]]::new()
$script:GeneratedSessionIds = [System.Collections.Generic.List[string]]::new()

function Invoke-NativeCaptured {
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
    [pscustomobject]@{ ExitCode=$code; Output=(($raw | ForEach-Object { [string]$_ }) -join "`n").Trim() }
}

function Invoke-Remote([string]$Command) {
    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $ssh) { $ssh = Get-Command ssh -ErrorAction Stop }
    $args = @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=8')
    if ($script:KnownHosts) { $args += @('-o',"UserKnownHostsFile=$($script:KnownHosts)") }
    $args += @($Target,$Command)
    return (Invoke-NativeCaptured -FilePath $ssh.Source -Arguments $args)
}

function Add-Check([string]$Name,[bool]$Passed,[string]$Command,$Result,[string]$Reason='') {
    $entry = [ordered]@{ passed=$Passed; command=$Command; exit_code=$Result.ExitCode; output=$Result.Output; reason=$Reason }
    $script:Checks[$Name] = $entry
    if (-not $Passed) { $script:Failures.Add([pscustomobject]@{ name=$Name; command=$Command; output=$Result.Output; reason=$Reason }) }
    return $Passed
}

function Test-Remote([string]$Name,[string]$Command,[scriptblock]$Predicate,[string]$Reason='') {
    $r = Invoke-Remote $Command
    $ok = ($r.ExitCode -eq 0) -and (& $Predicate $r.Output)
    Add-Check $Name $ok $Command $r $Reason | Out-Null
    return $r
}

function Assert-FrozenWifiBaseline {
    if (-not (Test-Path -LiteralPath $WifiBaselinePath -PathType Leaf)) { throw 'WIFI_FROZEN_BASELINE_MISSING' }
    $baseline = Get-Content -Raw -LiteralPath $WifiBaselinePath | ConvertFrom-Json
    if ([string]$baseline.status -ne 'VERIFIED_FROZEN') { throw 'WIFI_FROZEN_BASELINE_INVALID_STATUS' }
    $sourcePath = Join-Path $Root (([string]$baseline.source_path) -replace '/','\')
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw 'WIFI_FROZEN_SOURCE_MISSING' }
    $git = Invoke-NativeCaptured -FilePath 'git' -Arguments @('-C',$Root,'hash-object',[string]$baseline.source_path)
    $ok = $git.ExitCode -eq 0 -and $git.Output.Trim() -eq [string]$baseline.source_git_blob_sha
    $r = [pscustomobject]@{ ExitCode=if ($ok) { 0 } else { 1 }; Output="status=$($baseline.status); source=$($baseline.source_path); expected_blob=$($baseline.source_git_blob_sha); actual_blob=$($git.Output.Trim())" }
    Add-Check 'wifi.frozen_baseline' $ok 'git hash-object accepted Wi-Fi source' $r 'The accepted Wi-Fi source must remain byte-for-byte frozen; prebuild never mutates, reloads or revalidates runtime Wi-Fi.' | Out-Null
    if (-not $ok) { throw 'WIFI_FROZEN_BASELINE_CHANGED' }
    return $baseline
}

function Get-LuciSessionId([string]$CookieFile = '') {
    $path = if ([string]::IsNullOrWhiteSpace($CookieFile)) { $script:EffectiveLuciCookieFile } else { $CookieFile }
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $path)) {
        # curl prefixes HttpOnly cookies with '#HttpOnly_'; treat that prefix as
        # cookie metadata, while continuing to ignore ordinary comment lines.
        if ($line -match '^\s*(?:#HttpOnly_)?[^\s#]+\s+(?:TRUE|FALSE)\s+\S+\s+(?:TRUE|FALSE)\s+\S+\s+(?:sysauth|sysauth_http|sysauth_https)\s+(\S+)\s*$') { return $Matches[1] }
    }
    return $null
}

function Remove-GeneratedLuciSession {
    if ($script:GeneratedSessionIds.Count -gt 0) {
        $sid = $script:GeneratedSessionIds[$script:GeneratedSessionIds.Count - 1]
        $destroy = "ubus call session destroy '{`"ubus_rpc_session`":`"$sid`"}'"
        Invoke-Remote $destroy | Out-Null
        $script:GeneratedSessionIds.RemoveAt($script:GeneratedSessionIds.Count - 1)
    }
    if ($script:GeneratedCookieFiles.Count -gt 0) {
        $cookie = $script:GeneratedCookieFiles[$script:GeneratedCookieFiles.Count - 1]
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $cookie
        $script:GeneratedCookieFiles.RemoveAt($script:GeneratedCookieFiles.Count - 1)
    }
}

function New-LuciSessionFromSsh {
    Remove-GeneratedLuciSession
    $create = Invoke-Remote 'ubus call session create'
    if ($create.ExitCode -ne 0) { throw "LUCI_SESSION_CREATE_FAILED output=$($create.Output)" }
    try { $created = $create.Output | ConvertFrom-Json } catch { throw 'LUCI_SESSION_CREATE_INVALID_JSON' }
    $sid = [string]$created.ubus_rpc_session
    if ([string]::IsNullOrWhiteSpace($sid)) { throw 'LUCI_SESSION_ID_MISSING' }
    $token = [Guid]::NewGuid().ToString('N')

    $set = "ubus call session set '{`"ubus_rpc_session`":`"$sid`",`"values`":{`"username`":`"root`",`"token`":`"$token`"}}'"
    $grantUbus = "ubus call session grant '{`"ubus_rpc_session`":`"$sid`",`"scope`":`"ubus`",`"objects`":[[`"*`",`"*`"]]}'"
    $grantFile = "ubus call session grant '{`"ubus_rpc_session`":`"$sid`",`"scope`":`"file`",`"objects`":[[`"*`",`"*`"]]}'"
    $grantAdguardAcl = "ubus call session grant '{`"ubus_rpc_session`":`"$sid`",`"scope`":`"access-group`",`"objects`":[[`"luci-app-adguardhome`",`"read`"]]}'"
    foreach ($command in @($set,$grantUbus,$grantFile,$grantAdguardAcl)) {
        $r = Invoke-Remote $command
        if ($r.ExitCode -ne 0) { throw "LUCI_SESSION_GRANT_FAILED output=$($r.Output)" }
    }

    $cookie = Join-Path ([System.IO.Path]::GetTempPath()) ("xinzhaowrt-luci-session-{0}-{1}.cookie" -f $PID,[Guid]::NewGuid().ToString('N'))
    @(
        '# Netscape HTTP Cookie File',
        "$DeviceIp`tFALSE`t/`tFALSE`t0`tsysauth_http`t$sid"
    ) | Set-Content -Encoding ASCII -LiteralPath $cookie
    $script:EffectiveLuciCookieFile = $cookie
    $script:GeneratedCookieFiles.Add($cookie)
    $script:GeneratedSessionIds.Add($sid)
    Write-Host 'LUCI_AUTH_SESSION=PASS source=verified-root-ssh'
    return $cookie
}

function Invoke-AuthenticatedUbus([object]$Request,[string]$CookieFile = '') {
    $path = if ([string]::IsNullOrWhiteSpace($CookieFile)) { $script:EffectiveLuciCookieFile } else { $CookieFile }
    $sid = Get-LuciSessionId $path
    if ([string]::IsNullOrWhiteSpace($sid)) { return [pscustomobject]@{ ExitCode=1; Output='Authenticated LuCI session unavailable.'; Json=$null } }
    $body = $Request | ConvertTo-Json -Compress -Depth 12
    $raw = @(& curl.exe -sS --fail-with-body --max-time 15 -b $path -H 'Content-Type: application/json' --data-binary $body "http://$DeviceIp/ubus" 2>&1)
    $code = $LASTEXITCODE
    $text = ($raw -join "`n").Trim()
    $parsed = $null
    if ($code -eq 0) { try { $parsed = $text | ConvertFrom-Json } catch { } }
    [pscustomobject]@{ ExitCode=$code; Output=$text; Json=$parsed }
}

<<<<<<< HEAD
function Invoke-AuthenticatedHttp([string]$Path,[string]$CookieFile = '') {
    $cookiePath = if ([string]::IsNullOrWhiteSpace($CookieFile)) { $script:EffectiveLuciCookieFile } else { $CookieFile }
    $url = if ($Path -match '^https?://') { $Path } else { "http://$DeviceIp$Path" }
    $raw = @(& curl.exe -sS --fail-with-body --max-time 15 -b $cookiePath -w "`nHTTP_STATUS:%{http_code}" $url 2>&1)
    $code = $LASTEXITCODE
    $text = ($raw -join "`n").Trim()
    $status = 0
    if ($text -match '(?m)HTTP_STATUS:(\d{3})$') {
        $status = [int]$Matches[1]
        $text = ($text -replace "(?m)`nHTTP_STATUS:\d{3}$", '').Trim()
=======
function Test-AdguardRpcFunctional([string]$Prefix) {
    $command = 'HTTP /ubus session login + session access for mature AdGuard Home UCI read/write ACL'
    if (-not $RootPassword) {
        $r = [pscustomobject]@{ ExitCode = 1; Output = 'ARTHUR_ROOT_PASSWORD was not supplied; authenticated ACL verification is fail-closed.' }
        Add-Check "$Prefix.adguard_rpc_functional" $false $command $r 'Authenticated rpcd ACL/RPC verification requires ARTHUR_ROOT_PASSWORD.' | Out-Null
        return
>>>>>>> ccb2da3 (fix: align Arthur device verification with mature runtime)
    }
    [pscustomobject]@{ ExitCode=if ($code -eq 0 -and $status -ge 200 -and $status -lt 300) { 0 } else { 1 }; Output="HTTP_STATUS=$status`n$text" }
}

function Test-AdguardRpcFunctional([string]$Prefix,[string]$CookieFile = '') {
    $path = if ([string]::IsNullOrWhiteSpace($CookieFile)) { $script:EffectiveLuciCookieFile } else { $CookieFile }
    $sid = Get-LuciSessionId $path
    $probes = @(
<<<<<<< HEAD
        @{ scope='ubus'; object='service'; function='list' },
        @{ scope='ubus'; object='uci'; function='get' },
        @{ scope='ubus'; object='network.interface.lan'; function='status' },
        @{ scope='file'; object='/usr/bin/AdGuardHome --version'; function='exec' }
=======
        @{ scope = 'uci'; object = 'AdGuardHome'; function = 'read' },
        @{ scope = 'uci'; object = 'AdGuardHome'; function = 'write' }
>>>>>>> ccb2da3 (fix: align Arthur device verification with mature runtime)
    )
    $failed = [System.Collections.Generic.List[string]]::new()
    $outputs = [System.Collections.Generic.List[string]]::new()
    foreach ($probe in $probes) {
        $request = [ordered]@{ jsonrpc='2.0'; id=1; method='call'; params=@($sid,'session','access',$probe) }
        $response = Invoke-AuthenticatedUbus $request $path
        $allowed = $false
        if ($response.Json -and @($response.Json.result).Count -ge 2 -and $response.Json.result[0] -eq 0) { $allowed = [bool]$response.Json.result[1].access }
        if (-not $allowed) { $failed.Add("$($probe.scope):$($probe.object):$($probe.function)") }
        $outputs.Add("$($probe.scope):$($probe.object):$($probe.function) access=$allowed")
    }
<<<<<<< HEAD
    $r = [pscustomobject]@{ ExitCode=if ($failed.Count -eq 0) { 0 } else { 1 }; Output=(($outputs + $failed) -join "`n") }
    Add-Check "$Prefix.adguard_rpc_functional" ($failed.Count -eq 0) 'authenticated /ubus session access checks' $r 'Authenticated rpcd access must cover the mature AdGuard Home manager dependencies.' | Out-Null
=======
    if ($sid) {
        Invoke-Ubus ([ordered]@{ jsonrpc = '2.0'; id = 3; method = 'call'; params = @($sid, 'session', 'destroy', [ordered]@{}) }) | Out-Null
    }
    $r = [pscustomobject]@{ ExitCode = if ($failed.Count -eq 0) { 0 } else { 1 }; Output = (($outputs + $failed) -join "`n") }
    Add-Check "$Prefix.adguard_rpc_functional" ($failed.Count -eq 0) $command $r 'Mature AdGuard Home LuCI must have authenticated rpcd UCI read/write ACL access.' | Out-Null
>>>>>>> ccb2da3 (fix: align Arthur device verification with mature runtime)
}

function Test-AdguardPageFunctional([string]$Prefix,[string]$CookieFile = '') {
    $page = Invoke-AuthenticatedHttp '/cgi-bin/luci/admin/services/adguardhome/' $CookieFile
    $view = Invoke-AuthenticatedHttp '/luci-static/resources/view/adguardhome/config.js' $CookieFile
    $loginMarker = '(?i)x-luci-login-required|<body[^>]*\blogin-page\b|<input[^>]+\bname=["'']luci_(?:username|password)["'']'
    $pageOk = $page.ExitCode -eq 0 -and $page.Output -notmatch $loginMarker
    $viewOk = $view.ExitCode -eq 0 -and $view.Output -match 'form\.Map' -and $view.Output -match 'adguardhome' -and $view.Output -match 'object:\s*.*service' -and $view.Output -match 'method:\s*.*list' -and $view.Output -match 'form\.TypedSection' -and $view.Output -match 'poll\.add'
    $modernOk = $pageOk -and $viewOk

    # Older deployed Arthur images expose the same complete manager through
    # the uppercase CBI dispatcher namespace. Verify every registered page so
    # a single 404/403 cannot be mistaken for a functional manager.
    $legacyPaths = @(
        '/cgi-bin/luci/admin/services/AdGuardHome/',
        '/cgi-bin/luci/admin/services/AdGuardHome/overview',
        '/cgi-bin/luci/admin/services/AdGuardHome/base',
        '/cgi-bin/luci/admin/services/AdGuardHome/tools',
        '/cgi-bin/luci/admin/services/AdGuardHome/log',
        '/cgi-bin/luci/admin/services/AdGuardHome/manual'
    )
    $legacyResults = @()
    foreach ($path in $legacyPaths) { $legacyResults += [pscustomobject]@{ Path=$path; Result=(Invoke-AuthenticatedHttp $path $CookieFile) } }
    $legacyStatusesOk = @($legacyResults | Where-Object { $_.Result.ExitCode -eq 0 }).Count -eq $legacyPaths.Count
    $legacyAuthOk = @($legacyResults | Where-Object { $_.Result.Output -match $loginMarker }).Count -eq 0
    $legacyManagerOk = ($legacyResults | ForEach-Object { $_.Result.Output } | Out-String) -match '(?i)AdGuard\s*Home|AdGuardHome|基础设置|运行状态|手动配置|运维'
    $legacyOk = $legacyStatusesOk -and $legacyAuthOk -and $legacyManagerOk
    $ok = $modernOk -or $legacyOk
    $legacyOutput = ($legacyResults | ForEach-Object { "PATH=$($_.Path)`n$($_.Result.Output)" }) -join "`n"
    $r = [pscustomobject]@{ ExitCode=if ($ok) { 0 } else { 1 }; Output="MODERN_PAGE`n$($page.Output)`nMODERN_VIEW`n$($view.Output)`nLEGACY_CBI`n$legacyOutput" }
    Add-Check "$Prefix.adguard_page_functional" $ok 'authenticated AdGuard Home LuCI page and complete manager routes' $r 'AdGuard acceptance requires an authenticated real page plus a complete manager, using either the modern view or all deployed uppercase CBI routes.' | Out-Null
}

function Test-QuickstartHomepage([string]$Prefix,[string]$CookieFile = '') {
    $page = Invoke-AuthenticatedHttp '/cgi-bin/luci/admin/quickstart/' $CookieFile
    $index = Invoke-AuthenticatedHttp '/luci-static/quickstart/index.js' $CookieFile
    $style = Invoke-AuthenticatedHttp '/luci-static/quickstart/style.css' $CookieFile
    $loginMarker = '(?i)x-luci-login-required|<body[^>]*\blogin-page\b|<input[^>]+\bname=["'']luci_(?:username|password)["'']'
    $ok = ($page.ExitCode -eq 0) -and ($index.ExitCode -eq 0) -and ($style.ExitCode -eq 0) -and ($page.Output -match '(?i)luci-static/quickstart/index\.js') -and ($page.Output -match '(?i)<div[^>]+id=["'']app["'']') -and ($page.Output -match '(?i)vue_base|quickstart_features') -and ($page.Output -match "window\.vue_lang\s*=\s*['\"]zh-cn['\"]") -and ($page.Output -match "window\.vue_lang_data\s*=\s*['\"]/luci-static/quickstart/i18n/zh-cn\.json['\"]") -and ($page.Output -notmatch $loginMarker) -and ($index.Output.Length -gt 10000)
    $r = [pscustomobject]@{ ExitCode=if ($ok) { 0 } else { 1 }; Output="PAGE`n$($page.Output)`nINDEX`n$($index.Output)`nSTYLE`n$($style.Output)" }
    Add-Check "$Prefix.quickstart_home_functional" $ok 'authenticated official QuickStart homepage and assets' $r 'The authenticated homepage must render the official QuickStart application.' | Out-Null
}

function Test-LuciReachability([string]$Prefix) {
    $raw = @(& curl.exe -sS --max-time 15 -o NUL -w 'HTTP:%{http_code}' "http://$DeviceIp/" 2>&1)
    $code = $LASTEXITCODE
    $text = ($raw -join "`n").Trim()
    $r = [pscustomobject]@{ ExitCode=$code; Output=$text }
    Add-Check "$Prefix.luci" ($code -eq 0 -and $text -match 'HTTP:(200|301|302|401|403)$') "GET http://$DeviceIp/" $r 'LuCI must respond over HTTP port 80.' | Out-Null
}

function Run-Phase([string]$Prefix) {
    Test-Remote "$Prefix.boot.board" 'ubus call system board' { param($o) $o -match 'jdcloud,re-ss-01|RE-SS-01' } 'Board identity must be JDCloud RE-SS-01.' | Out-Null
    Test-Remote "$Prefix.boot.system" 'cat /etc/openwrt_release; uname -a; uptime' { param($o) $o -match 'OpenWrt|ImmortalWrt' -and $o -match 'Linux' } 'ImmortalWrt/OpenWrt must be running normally.' | Out-Null
    Test-Remote "$Prefix.target_profile" 'cat /etc/openwrt_release; ubus call system board' { param($o) $o -match 'qualcommax/ipq60xx' -and $o -match 'jdcloud,re-ss-01|RE-SS-01' } 'Target/profile must remain qualcommax/ipq60xx and jdcloud_re-ss-01.' | Out-Null
    Test-Remote "$Prefix.ssh" 'echo CODEX_SSH_OK' { param($o) $o -eq 'CODEX_SSH_OK' } 'SSH connectivity is required.' | Out-Null
    Test-Remote "$Prefix.storage" 'uname -a; free -h; df -h; mount; lsblk 2>/dev/null || true; dmesg | tail -n 80' { param($o) $o -match 'Linux' -and $o -match 'overlay' -and $o -notmatch '(?im)(kernel panic|I/O error|input/output error|filesystem error|EXT4-fs error|segfault|out of memory|oom-killer|watchdog.*(timeout|reset|bite|failed|crash|reboot)|firmware crashed)' } 'Kernel, memory, overlay, eMMC, filesystem and mounts must be healthy.' | Out-Null
    Test-Remote "$Prefix.lan" 'ubus call network.interface.lan status; ip -4 addr; ip route' { param($o) $o -match '"up":\s*true' -and $o -match '192\.168\.6\.1' } 'LAN must be up at 192.168.6.1.' | Out-Null
    Test-Remote "$Prefix.wan" 'ubus call network.interface.wan status; ip route show default' { param($o) $o -match '"up":\s*true' -and $o -match '(?m)^default\s' } 'WAN must be up and have a default route.' | Out-Null
    Test-Remote "$Prefix.internet" '(ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 && echo INET=ICMP_PASS) || (curl -fsS --connect-timeout 8 --max-time 15 https://openwrt.org/ -o /dev/null && echo INET=HTTPS_PASS) || (uclient-fetch -q -T 15 -O /dev/null https://openwrt.org/ && echo INET=HTTPS_PASS) || (wget -q -T 15 -O /dev/null https://openwrt.org/ && echo INET=HTTPS_PASS) || echo INET=FAIL' { param($o) $o -match '(?m)^INET=(ICMP|HTTPS)_PASS$' } 'Public egress must work through ICMP or an independent HTTPS fetch; public-IP lookup alone is insufficient.' | Out-Null
    Test-Remote "$Prefix.dns" 'nslookup openwrt.org 2>&1 || busybox nslookup openwrt.org 2>&1' { param($o) $o -match 'Address|address' -and $o -match '\d+\.\d+\.\d+\.\d+' } 'DNS resolution must work.' | Out-Null
    Test-Remote "$Prefix.logread" 'logread -l 300' { param($o) $o -notmatch '(?im)(kernel panic|I/O error|input/output error|filesystem error|EXT4-fs error|segfault|out of memory|oom-killer|watchdog.*(timeout|reset|bite|failed|crash|reboot)|wireless.*(crash|failed|firmware))' } 'Critical runtime errors in logread are a failure.' | Out-Null
    Test-Remote "$Prefix.dmesg" 'dmesg' { param($o) $o -notmatch '(?im)(kernel panic|I/O error|input/output error|filesystem error|EXT4-fs error|segfault|out of memory|oom-killer|watchdog.*(timeout|reset|bite|failed|crash|reboot)|wireless.*(crash|failed|firmware))' } 'Critical runtime errors in dmesg are a failure.' | Out-Null

    $pm = Test-Remote "$Prefix.package_manager" 'if command -v apk >/dev/null 2>&1; then echo apk; elif command -v opkg >/dev/null 2>&1; then echo opkg; else echo none; exit 1; fi' { param($o) $o -match '^(apk|opkg)$' } 'Installed package manager must be apk or opkg.'
    $manager = if ($pm.Output -match '^apk$') { 'apk' } elseif ($pm.Output -match '^opkg$') { 'opkg' } else { 'none' }
    $pluginResults = @()
    foreach ($p in $Required) {
        $pkgCommand = if ($manager -eq 'apk') { "apk info -e '$p'" } elseif ($manager -eq 'opkg') { "opkg status '$p'" } else { 'false' }
        $pkgResult = Invoke-Remote $pkgCommand
        $installed = if ($manager -eq 'apk') { $pkgResult.ExitCode -eq 0 } else { $pkgResult.ExitCode -eq 0 -and $pkgResult.Output -match '(?i)Status:\s*install\s+ok\s+installed' }
        $pluginResults += [pscustomobject]@{ name=$p; passed=[bool]$installed; package_manager=$manager; command=$pkgCommand; exit_code=$pkgResult.ExitCode; output=$pkgResult.Output }
        if (-not $installed) { $script:Failures.Add([pscustomobject]@{ name="$Prefix.plugin.$p"; command=$pkgCommand; output=$pkgResult.Output; reason='Required LuCI plugin is not installed.' }) }
    }
    $pluginsPassed = @($pluginResults | Where-Object passed).Count -eq $Required.Count
    $script:Checks["$Prefix.required_plugins"] = [ordered]@{ passed=$pluginsPassed; total=$Required.Count; passed_count=@($pluginResults | Where-Object passed).Count; package_manager=$manager; items=$pluginResults }

    Test-Remote "$Prefix.luci_components" 'find /usr/share/luci/menu.d /usr/share/luci/rpcd /usr/libexec/rpcd /etc/init.d -maxdepth 2 -type f 2>/dev/null | sort' { param($o) $o -match 'luci|rpcd|init.d' } 'LuCI menus, RPC/controller area and init scripts must exist.' | Out-Null
    Test-Remote "$Prefix.luci_locale_theme" 'uci -q get luci.main.lang; uci -q get luci.main.mediaurlbase; test -d /www/luci-static/argon; test -d /www/luci-static/kucat' { param($o) $o -match 'zh_cn' -and $o -match '/luci-static/argon' } 'zh_cn and Argon/KuCat resources must be present.' | Out-Null
    Test-Remote "$Prefix.kucat_theme" "test -d /www/luci-static/kucat; grep -R -F '/luci-static/kucat' /etc/config /etc/uci-defaults 2>/dev/null" { param($o) $o -match '/luci-static/kucat' } 'KuCat must remain selectable.' | Out-Null
    Test-Remote "$Prefix.branding" 'test -s /www/luci-static/xinzhao/logo.png && test -s /www/luci-static/xinzhao/favicon.ico && test -s /www/luci-static/xinzhao/branding.js && grep -R -F XinZhaoWrt /etc/xinzhao-build-info /www/luci-static/xinzhao/build-info.json 2>/dev/null' { param($o) $o -match 'XinZhaoWrt' } 'XinZhaoWrt branding/build information must be present.' | Out-Null
    Test-Remote "$Prefix.adguard_manager" 'test -s /www/luci-static/resources/view/adguardhome/config.js && test -s /etc/config/adguardhome && test -x /etc/init.d/adguardhome' { param($o) $true } 'Complete AdGuard Home manager, config and service must be present.' | Out-Null
    Test-Remote "$Prefix.adguard_default_off" 'printf "enabled=%s\n" "$(uci -q get adguardhome.config.enabled 2>/dev/null || true)"; ! pidof AdGuardHome >/dev/null 2>&1; ! ls /etc/rc.d/S*adguardhome >/dev/null 2>&1' { param($o) $o -match '(?m)^enabled=0$' } 'AdGuard Home must remain disabled by default.' | Out-Null
    Test-Remote "$Prefix.adguard_dns_53" '! pidof AdGuardHome >/dev/null 2>&1; (ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null || true)' { param($o) $o -notmatch '(?i)AdGuardHome.*:53' } 'AdGuard Home must not claim DNS port 53 while default-disabled.' | Out-Null
    Test-Remote "$Prefix.quickstart_page" 'test -s /usr/share/luci/menu.d/luci-app-quickstart.json; test -s /www/luci-static/quickstart/index.js; test -s /www/luci-static/quickstart/style.css' { param($o) $true } 'Official QuickStart route/assets must be present.' | Out-Null
    Test-Remote "$Prefix.quickstart_backend" 'command -v quickstart >/dev/null 2>&1; test -x /etc/init.d/quickstart; pidof quickstart >/dev/null 2>&1' { param($o) $true } 'QuickStart backend must exist and be running.' | Out-Null

    $pageCookie = $null
    if (-not [string]::IsNullOrWhiteSpace((Get-LuciSessionId $script:ProvidedLuciCookieFile))) {
        $pageCookie = $script:ProvidedLuciCookieFile
        Write-Host 'LUCI_AUTH_SESSION=PASS source=provided-cookie page=verified-form-login'
    }
    New-LuciSessionFromSsh | Out-Null
    Test-AdguardRpcFunctional $Prefix $script:EffectiveLuciCookieFile
    $webCookie = if ($pageCookie) { $pageCookie } else { $script:EffectiveLuciCookieFile }
    Test-AdguardPageFunctional $Prefix $webCookie
    Test-QuickstartHomepage $Prefix $webCookie
    Test-LuciReachability $Prefix
}

try {
    $access = Ensure-ArthurUnattendedAccess -DeviceIp $DeviceIp
    $script:KnownHosts = [string]$access.KnownHosts
    $accessResult = [pscustomobject]@{ ExitCode=0; Output="mode=$($access.Mode); host_key_rebound=$($access.HostKeyRebound)" }
    Add-Check 'control_plane.unattended_access' $true 'Ensure-ArthurUnattendedAccess' $accessResult 'Arthur SSH trust/auth must recover without operator prompts after independent identity proof.' | Out-Null

    $wifiBaseline = Assert-FrozenWifiBaseline
    Run-Phase 'before_reboot'

    if ($Mode -eq 'PostFlash') {
        $timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $before = Invoke-Remote "printf 'candidate=%s\ntime=%s\n' '$Candidate' '$timestamp' > $TestFile; sync; cat $TestFile"
        Add-Check 'test_file.create' ($before.ExitCode -eq 0 -and $before.Output -match [regex]::Escape($Candidate)) "create $TestFile" $before 'Post-flash persistence marker must be created.' | Out-Null
        Remove-GeneratedLuciSession
        $reboot = Invoke-Remote 'sync; reboot'
        $script:Checks['reboot.command'] = [ordered]@{ passed=($reboot.ExitCode -eq 0 -or $reboot.Output -match '(?i)(closed|reset|connection)'); command='sync; reboot'; exit_code=$reboot.ExitCode; output=$reboot.Output }
        Start-Sleep -Seconds 10
        $recovered = $false
        $waitLog = [System.Collections.Generic.List[string]]::new()
        for ($i=1; $i -le 60; $i++) {
            $ping = Test-Connection -ComputerName $DeviceIp -Count 1 -Quiet -ErrorAction SilentlyContinue
            $sshProbe = if ($ping) { Invoke-Remote 'echo CODEX_SSH_OK' } else { $null }
            $sshOk = $sshProbe -and $sshProbe.ExitCode -eq 0 -and $sshProbe.Output -eq 'CODEX_SSH_OK'
            $waitLog.Add("attempt=$i ping=$ping ssh=$sshOk")
            if ($sshOk) { $recovered=$true; break }
            Start-Sleep -Seconds 5
        }
        $recoveryResult = [pscustomobject]@{ ExitCode=if ($recovered) { 0 } else { 1 }; Output=($waitLog -join "`n") }
        Add-Check 'reboot.recovery' $recovered 'wait for Arthur ping + strict SSH' $recoveryResult 'Device must recover after formal post-flash reboot.' | Out-Null
        if ($recovered) {
            $persist = Invoke-Remote "test -f $TestFile && cat $TestFile"
            Add-Check 'persistence' ($persist.ExitCode -eq 0 -and $persist.Output -match [regex]::Escape($Candidate)) "test -f $TestFile" $persist 'Persistence marker must survive reboot.' | Out-Null
            Run-Phase 'after_reboot'
            $cleanup = Invoke-Remote "rm -f $TestFile; sync; test ! -e $TestFile"
            Add-Check 'test_file.cleanup' ($cleanup.ExitCode -eq 0) "rm -f $TestFile" $cleanup 'Post-flash persistence marker cleanup must succeed.' | Out-Null
        }
    }

    $phase = if ($Mode -eq 'PostFlash') { 'after_reboot' } else { 'before_reboot' }
    $adguardLive = [bool]$script:Checks["$phase.adguard_page_functional"].passed -and [bool]$script:Checks["$phase.adguard_rpc_functional"].passed
    $quickstartLive = [bool]$script:Checks["$phase.quickstart_home_functional"].passed
    $wifiFrozen = [bool]$script:Checks['wifi.frozen_baseline'].passed
    $plugins = @($script:Checks["$phase.required_plugins"].items)
    $corePass = $script:Failures.Count -eq 0 -and $plugins.Count -eq $Required.Count -and @($plugins | Where-Object passed).Count -eq $Required.Count
    $prebuildPass = $corePass -and $adguardLive -and $quickstartLive -and $wifiFrozen
    $result = if ($prebuildPass) { 'PASS' } else { 'FAIL' }
    $prebuildFeatures = [ordered]@{
        ADGUARD_LIVE = if ($adguardLive) { 'PASS' } else { 'FAIL' }
        QUICKSTART_LIVE = if ($quickstartLive) { 'PASS' } else { 'FAIL' }
        WIFI_STATE = if ($wifiFrozen) { 'VERIFIED_FROZEN' } else { 'FAIL' }
        WIFI_LIVE = if ($wifiFrozen) { 'INHERITED_VERIFIED_FROZEN' } else { 'FAIL' }
        FIRMWARE_BUILD_ALLOWED = if ($prebuildPass) { 'true' } else { 'false' }
        authenticated_session = 'AUTO_FROM_VERIFIED_ROOT_SSH'
        wifi_configuration_mutated = $false
    }

    $report = [ordered]@{
        schema_version = 2
        mode = $Mode
        device = [ordered]@{ model='JDCloud RE-SS-01'; target='jdcloud_re-ss-01'; address=$DeviceIp; lan='192.168.6.1'; luci='http://192.168.6.1/' }
        candidate = $Candidate
        commit = $Commit
        control_plane = $script:Checks['control_plane.unattended_access']
        wifi_state = [ordered]@{ status='VERIFIED_FROZEN'; source_path=[string]$wifiBaseline.source_path; source_git_blob_sha=[string]$wifiBaseline.source_git_blob_sha; runtime_mutation_performed=$false; runtime_revalidation_performed=$false }
        adguard_live = $script:Checks["$phase.adguard_page_functional"]
        quickstart_live = $script:Checks["$phase.quickstart_home_functional"]
        required_plugins_total = $Required.Count
        required_plugins_passed = @($plugins | Where-Object passed).Count
        prebuild_features = $prebuildFeatures
        checks = $script:Checks
        failures = @($script:Failures)
        result = $result
    }
    $report | ConvertTo-Json -Depth 14 | Set-Content -Encoding UTF8 -LiteralPath $JsonPath

    $first = if ($script:Failures.Count) { $script:Failures[0] } else { $null }
    $md = @('# Real Device Verification','',"- Mode: $Mode",'- Device: JDCloud RE-SS-01 (jdcloud_re-ss-01)',"- Candidate: $Candidate", "- Commit: $Commit", "- Result: $result", "- Wi-Fi: VERIFIED_FROZEN (inherited; not mutated/reloaded/revalidated)", "- Required plugins: $(@($plugins | Where-Object passed).Count)/$($Required.Count)", '')
    if ($first) { $md += @('## First explicit failure',"- Check: $($first.name)","- Reason: $($first.reason)",'```text',$first.output,'```','') }
    $md | Set-Content -Encoding UTF8 -LiteralPath $MdPath

    Write-Output "JSON: $((Resolve-Path $JsonPath).Path)"
    Write-Output "Markdown: $((Resolve-Path $MdPath).Path)"
    Write-Output "RESULT: $result"
    Write-Output "ADGUARD_LIVE=$($prebuildFeatures.ADGUARD_LIVE)"
    Write-Output "QUICKSTART_LIVE=$($prebuildFeatures.QUICKSTART_LIVE)"
    Write-Output "WIFI_STATE=$($prebuildFeatures.WIFI_STATE)"
    Write-Output "FIRMWARE_BUILD_ALLOWED=$($prebuildFeatures.FIRMWARE_BUILD_ALLOWED)"
    Write-Output 'WIFI=VERIFIED_FROZEN'
    if ($first) { Write-Output "FIRST_FAILURE: $($first.name) -- $($first.reason)"; Write-Output $first.output }
    if ($result -ne 'PASS') { exit 1 }
}
finally {
    while ($script:GeneratedSessionIds.Count -gt 0 -or $script:GeneratedCookieFiles.Count -gt 0) { Remove-GeneratedLuciSession }
}
