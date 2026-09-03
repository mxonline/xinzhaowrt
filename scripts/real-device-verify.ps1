param(
    [string]$DeviceIp = '192.168.6.1',
    [string]$Candidate = $env:ARTHUR_CANDIDATE_ID,
    [string]$Commit = $env:ARTHUR_CANDIDATE_SHA,
    [string]$LuciCookieFile = $env:ARTHUR_LUCI_COOKIE_FILE
)

$ErrorActionPreference = 'Stop'

$Target = "root@$DeviceIp"
$Candidate = if ($Candidate) { $Candidate } else { 'candidate-not-supplied' }
$Commit = if ($Commit) { $Commit } else { 'commit-not-supplied' }
if ($Candidate -match '33462873812') {
    throw 'REJECTED_FOR_RELEASE: candidate 33462873812 is REAL_DEVICE_VERIFY_INVALIDATED and may not be reflashed or released.'
}
$TestFile = '/etc/xinzhao-real-device-test'
$OutDir = Join-Path $PSScriptRoot '..\output\real-device'
$JsonPath = Join-Path $OutDir 'real-device-verification.json'
$MdPath = Join-Path $OutDir 'real-device-verification.md'
$Required = @(Get-Content (Join-Path $PSScriptRoot '..\config\required-plugins.txt') | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() })
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$script:Checks = [ordered]@{}
$script:Failures = [System.Collections.Generic.List[object]]::new()

function Invoke-NativeCaptured {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = ($raw -join "`n").Trim() }
}

function Invoke-Remote([string]$Command) {
    $result = Invoke-NativeCaptured -FilePath 'ssh' -Arguments @('-o', 'BatchMode=yes', $Target, $Command)
    [pscustomobject]@{ ExitCode = $result.ExitCode; Output = $result.Output }
}

function Get-WifiConfigurationSnapshot {
    $r = Invoke-Remote 'uci -q show wireless'
    $hash = $null
    if ($r.ExitCode -eq 0) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($r.Output)
        $hash = ([System.Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    }
    [pscustomobject]@{
        ExitCode = $r.ExitCode
        Sha256 = $hash
        Output = if ($hash) { "sha256=$hash" } else { $r.Output }
    }
}

function Add-Check([string]$Name, [bool]$Passed, [string]$Command, $Result, [string]$Reason = '') {
    $entry = [ordered]@{ passed = $Passed; command = $Command; exit_code = $Result.ExitCode; output = $Result.Output; reason = $Reason }
    $script:Checks[$Name] = $entry
    if (-not $Passed) { $script:Failures.Add([pscustomobject]@{ name = $Name; command = $Command; output = $Result.Output; reason = $Reason }) }
    return $Passed
}

function Test-Remote([string]$Name, [string]$Command, [scriptblock]$Predicate, [string]$Reason = '') {
    $r = Invoke-Remote $Command
    $ok = ($r.ExitCode -eq 0) -and (& $Predicate $r.Output)
    Add-Check $Name $ok $Command $r $Reason | Out-Null
    return $r
}

function Test-Luci {
    $command = "curl -sS -o /dev/null -w HTTP:%{{http_code}} http://$DeviceIp/"
    try {
        $out = @(& curl.exe -sS --max-time 15 -o NUL -w 'HTTP:%{http_code}' "http://$DeviceIp/" 2>&1)
        $code = $LASTEXITCODE
        $text = ($out -join "`n").Trim()
        $r = [pscustomobject]@{ ExitCode = $code; Output = $text }
        Add-Check 'luci' ($code -eq 0 -and $text -match 'HTTP:(200|301|302|401|403)$') $command $r 'LuCI must respond over HTTP port 80.' | Out-Null
    } catch {
        $r = [pscustomobject]@{ ExitCode = 1; Output = $_.Exception.Message }
        Add-Check 'luci' $false $command $r 'LuCI must be reachable over HTTP port 80.' | Out-Null
    }
}

function Invoke-Ubus([object]$Request) {
    $body = $Request | ConvertTo-Json -Compress -Depth 12
    $raw = @(& curl.exe -sS --max-time 15 -H 'Content-Type: application/json' --data-binary $body "http://$DeviceIp/ubus" 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($raw -join "`n").Trim()
    $parsed = $null
    if ($exitCode -eq 0) {
        try { $parsed = $text | ConvertFrom-Json } catch { }
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $text; Json = $parsed }
}

function Get-LuciSessionId {
    if ([string]::IsNullOrWhiteSpace($LuciCookieFile) -or -not (Test-Path -LiteralPath $LuciCookieFile -PathType Leaf)) {
        return $null
    }
    foreach ($line in (Get-Content -LiteralPath $LuciCookieFile)) {
        if ($line -match '^\s*[^#].*\s+(?:sysauth|sysauth_http)\s+(\S+)\s*$') {
            return $Matches[1]
        }
    }
    return $null
}

function Invoke-AuthenticatedUbus([object]$Request) {
    $sid = Get-LuciSessionId
    if ([string]::IsNullOrWhiteSpace($sid)) {
        return [pscustomobject]@{ ExitCode = 1; Output = 'No sysauth session was found in the supplied LuCI cookie.'; Json = $null }
    }
    $body = $Request | ConvertTo-Json -Compress -Depth 12
    $raw = @(& curl.exe -sS --fail-with-body --max-time 15 -b $LuciCookieFile -H 'Content-Type: application/json' --data-binary $body "http://$DeviceIp/ubus" 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($raw -join "`n").Trim()
    $parsed = $null
    if ($exitCode -eq 0) {
        try { $parsed = $text | ConvertFrom-Json } catch { }
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $text; Json = $parsed }
}

function Test-AdguardRpcFunctional([string]$Prefix) {
    $command = 'authenticated /ubus session access checks for mature AdGuard Home RPC dependencies'
    $sid = Get-LuciSessionId
    $probes = @(
        @{ scope = 'ubus'; object = 'service'; function = 'list' },
        @{ scope = 'ubus'; object = 'uci'; function = 'get' },
        @{ scope = 'ubus'; object = 'network.interface.lan'; function = 'status' },
        @{ scope = 'file'; object = '/usr/bin/AdGuardHome --version'; function = 'exec' }
    )
    $failed = [System.Collections.Generic.List[string]]::new()
    $outputs = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($sid)) {
        $failed.Add('session cookie/sysauth')
        $outputs.Add('No existing authenticated LuCI cookie was supplied; rpcd access verification is fail-closed.')
    } else {
        foreach ($probe in $probes) {
            $request = [ordered]@{ jsonrpc = '2.0'; id = 1; method = 'call'; params = @($sid, 'session', 'access', $probe) }
            $response = Invoke-AuthenticatedUbus $request
            $allowed = $false
            if ($response.Json -and @($response.Json.result).Count -ge 2 -and $response.Json.result[0] -eq 0) {
                $allowed = [bool]$response.Json.result[1].access
            }
            if (-not $allowed) { $failed.Add("$($probe.scope):$($probe.object):$($probe.function)") }
            $outputs.Add("$($probe.scope):$($probe.object):$($probe.function) access=$allowed")
        }
    }
    $r = [pscustomobject]@{ ExitCode = if ($failed.Count -eq 0) { 0 } else { 1 }; Output = (($outputs + $failed) -join "`n") }
    Add-Check "$Prefix.adguard_rpc_functional" ($failed.Count -eq 0) $command $r 'Authenticated LuCI rpcd access must be proven for service lifecycle discovery, UCI reads, LAN status and AdGuard version discovery.' | Out-Null
}

function Invoke-AuthenticatedHttp([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($LuciCookieFile) -or -not (Test-Path -LiteralPath $LuciCookieFile -PathType Leaf)) {
        return [pscustomobject]@{ ExitCode = 1; Output = 'No existing authenticated LuCI cookie was supplied; page acceptance is fail-closed.' }
    }
    $url = if ($Path -match '^https?://') { $Path } else { "http://$DeviceIp$Path" }
    $raw = @(& curl.exe -sS --fail-with-body --max-time 15 -b $LuciCookieFile -w "`nHTTP_STATUS:%{http_code}" $url 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($raw -join "`n").Trim()
    $status = 0
    if ($text -match '(?m)HTTP_STATUS:(\d{3})$') { $status = [int]$Matches[1]; $text = ($text -replace "(?m)`nHTTP_STATUS:\d{3}$", '').Trim() }
    [pscustomobject]@{ ExitCode = if ($exitCode -eq 0 -and $status -ge 200 -and $status -lt 300) { 0 } else { 1 }; Output = "HTTP_STATUS=$status`n$text" }
}

function Test-AdguardPageFunctional([string]$Prefix) {
    $command = 'authenticated GET AdGuard Home LuCI page and mature view module using an existing LuCI session'
    $page = Invoke-AuthenticatedHttp '/cgi-bin/luci/admin/services/adguardhome/'
    $view = Invoke-AuthenticatedHttp '/luci-static/resources/view/adguardhome/config.js'
    $pageOk = $page.ExitCode -eq 0 -and $page.Output -notmatch '(?i)x-luci-login-required|luci_username|luci_password|登录'
    $viewOk = $view.ExitCode -eq 0 -and $view.Output -match 'form\.Map' -and $view.Output -match 'adguardhome' -and $view.Output -match 'object:\s*.*service' -and $view.Output -match 'method:\s*.*list' -and $view.Output -match 'form\.TypedSection' -and $view.Output -match 'poll\.add'
    $ok = $pageOk -and $viewOk
    $r = [pscustomobject]@{ ExitCode = if ($ok) { 0 } else { 1 }; Output = "PAGE`n$($page.Output)`nVIEW`n$($view.Output)" }
    Add-Check "$Prefix.adguard_page_functional" $ok $command $r 'AdGuard acceptance requires an authenticated real page plus the mature upstream manager module; missing session, login page, or failed page/resource request is a hard failure.' | Out-Null
}

function Test-QuickstartHomepage([string]$Prefix) {
    $command = "authenticated GET /cgi-bin/luci/admin/quickstart/ requiring the official QuickStart homepage and frontend"
    $page = Invoke-AuthenticatedHttp '/cgi-bin/luci/admin/quickstart/'
    $index = Invoke-AuthenticatedHttp '/luci-static/quickstart/index.js'
    $style = Invoke-AuthenticatedHttp '/luci-static/quickstart/style.css'
    $ok = ($page.ExitCode -eq 0) -and ($index.ExitCode -eq 0) -and ($style.ExitCode -eq 0) -and ($page.Output -match '(?i)luci-static/quickstart/index\.js') -and ($page.Output -match '(?i)<div[^>]+id=["'']app["'']') -and ($page.Output -match '(?i)vue_base|quickstart_features') -and ($page.Output -notmatch '(?i)x-luci-login-required|luci_username|luci_password|登录') -and ($index.Output.Length -gt 10000)
    $r = [pscustomobject]@{ ExitCode = if ($ok) { 0 } else { 1 }; Output = "PAGE`n$($page.Output)`nINDEX`n$($index.Output)`nSTYLE`n$($style.Output)" }
    Add-Check "$Prefix.quickstart_home_functional" $ok $command $r 'The authenticated homepage must render the official QuickStart application, not merely expose package files.' | Out-Null
}

function Run-Phase([string]$Prefix) {
    $board = Test-Remote "$Prefix.boot.board" 'ubus call system board' { param($o) $o -match 'jdcloud,re-ss-01|RE-SS-01' } 'Board identity must be JDCloud RE-SS-01 / jdcloud,re-ss-01.'
    Test-Remote "$Prefix.boot.system" 'cat /etc/openwrt_release; uname -a; uptime' { param($o) $o -match 'OpenWrt|ImmortalWrt' -and $o -match 'Linux' } 'ImmortalWrt/OpenWrt must be running normally.' | Out-Null
    Test-Remote "$Prefix.target_profile" 'cat /etc/openwrt_release; ubus call system board' { param($o) $o -match 'qualcommax/ipq60xx' -and $o -match 'jdcloud,re-ss-01|RE-SS-01' } 'Target/profile must remain qualcommax/ipq60xx and jdcloud_re-ss-01.' | Out-Null
    Test-Remote "$Prefix.ssh" 'echo CODEX_SSH_OK' { param($o) $o -eq 'CODEX_SSH_OK' } | Out-Null
    Test-Remote "$Prefix.storage" 'uname -a; free -h; df -h; mount; command -v mmc || true; lsblk 2>/dev/null || true; dmesg | tail -n 80' { param($o) $o -match 'Linux' -and $o -match 'overlay' -and $o -notmatch '(?im)(kernel panic|I/O error|input/output error|filesystem error|EXT4-fs error|segfault|out of memory|oom-killer|watchdog.*(timeout|reset|bite|failed|crash|reboot)|firmware crashed)' } 'Kernel, memory, overlay, eMMC, filesystem and mounts must be healthy.' | Out-Null
    Test-Remote "$Prefix.lan" 'ubus call network.interface.lan status; ip -4 addr; ip route' { param($o) $o -match '"up":\s*true' -and $o -match '192\.168\.6\.1' } 'LAN must be up at 192.168.6.1.' | Out-Null
    Test-Remote "$Prefix.wan" 'ubus call network.interface.wan status; ip route show default' { param($o) $o -match '"up":\s*true' -and $o -match '(?m)^default\s' } 'WAN must be up and have a default route.' | Out-Null
    Test-Remote "$Prefix.internet" 'ping -c 2 -W 3 1.1.1.1' { param($o) $o -match '(?m)0% packet loss' } 'Public IP connectivity must work; an HTTP-fetched public IP alone is not sufficient.' | Out-Null
    Test-Remote "$Prefix.dns" 'nslookup openwrt.org 2>&1 || busybox nslookup openwrt.org 2>&1' { param($o) $o -match 'Address|address' -and $o -match '\d+\.\d+\.\d+\.\d+' } 'DNS resolution must work.' | Out-Null
    $wifi = Test-Remote "$Prefix.wifi" 'ubus call wireless status 2>/dev/null || true; iwinfo 2>/dev/null' { param($o) $o -match '(?i)(ESSID|phy0|phy1)' } 'Both Wi-Fi radios/interfaces must be present and operational.'
    Add-Check "$Prefix.wifi_2g" ($wifi.Output -match '2\.4\d+ GHz') 'ubus call wireless status 2>/dev/null || true; iwinfo' $wifi '2.4 GHz radio must be present.' | Out-Null
    Add-Check "$Prefix.wifi_5g" ($wifi.Output -match '5\.\d+ GHz') 'ubus call wireless status 2>/dev/null || true; iwinfo' $wifi '5 GHz radio must be present.' | Out-Null
    Test-Remote "$Prefix.wifi_ssids" 'uci -q show wireless; iwinfo 2>/dev/null' { param($o) ([regex]::Matches($o, '(?i)(?:ssid=|ESSID:\s*"?)xinzhaowrt')).Count -ge 2 } 'Both radios must expose the authoritative SSID xinzhaowrt.' | Out-Null
    Test-Remote "$Prefix.wifi_password" 'uci -q show wireless' { param($o) $o -match "12345678" -and $o -notmatch "12356789" } 'The authoritative Wi-Fi password 12345678 must be configured, with no obsolete value.' | Out-Null
    $wifiLive = @("$Prefix.wifi_2g", "$Prefix.wifi_5g", "$Prefix.wifi_ssids", "$Prefix.wifi_password") | ForEach-Object { $script:Checks[$_] } | Where-Object { $_ }
    $wifiLivePassed = @($wifiLive | Where-Object { $_.passed }).Count -eq 4
    $wifiLiveOutput = '2G={0}; 5G={1}; SSID={2}; password={3}' -f $script:Checks["$Prefix.wifi_2g"].passed, $script:Checks["$Prefix.wifi_5g"].passed, $script:Checks["$Prefix.wifi_ssids"].passed, $script:Checks["$Prefix.wifi_password"].passed
    $wifiLiveResult = [pscustomobject]@{ ExitCode = if ($wifiLivePassed) { 0 } else { 1 }; Output = $wifiLiveOutput }
    Add-Check "$Prefix.wifi_live" $wifiLivePassed 'Existing Wi-Fi real-device evidence (configuration is read-only in this gate)' $wifiLiveResult 'Wi-Fi is an existing accepted result and is never changed by this repair; any missing/failed evidence keeps the prebuild gate closed.' | Out-Null
    Test-Remote "$Prefix.logread" 'logread -l 300' { param($o) $o -notmatch '(?im)(kernel panic|I/O error|input/output error|filesystem error|EXT4-fs error|segfault|out of memory|oom-killer|watchdog.*(timeout|reset|bite|failed|crash|reboot)|wireless.*(crash|failed|firmware))' } 'Critical runtime errors in logread are a failure; ordinary warnings are allowed.' | Out-Null
    Test-Remote "$Prefix.dmesg" 'dmesg' { param($o) $o -notmatch '(?im)(kernel panic|I/O error|input/output error|filesystem error|EXT4-fs error|segfault|out of memory|oom-killer|watchdog.*(timeout|reset|bite|failed|crash|reboot)|wireless.*(crash|failed|firmware))' } 'Critical runtime errors in dmesg are a failure; ordinary warnings are allowed.' | Out-Null
    $pm = Test-Remote "$Prefix.package_manager" 'if command -v apk >/dev/null 2>&1; then echo apk; elif command -v opkg >/dev/null 2>&1; then echo opkg; else echo none; exit 1; fi' { param($o) $o -match '^(apk|opkg)$' } 'The installed package manager must be apk or opkg.'
    $manager = if ($pm.Output -match 'apk') { 'apk' } elseif ($pm.Output -match 'opkg') { 'opkg' } else { 'none' }
    $pluginResults = @()
    foreach ($p in $Required) {
        $pkgCommand = if ($manager -eq 'apk') { "apk info -e '$p'" } elseif ($manager -eq 'opkg') { "opkg status '$p'" } else { 'false' }
        $pkgResult = Invoke-Remote $pkgCommand
        $installed = if ($manager -eq 'apk') { $pkgResult.ExitCode -eq 0 } else { $pkgResult.ExitCode -eq 0 -and $pkgResult.Output -match '(?i)Status:\s*install\s+ok\s+installed' }
        $pluginResults += [pscustomobject]@{ name = $p; passed = [bool]$installed; package_manager = $manager; command = $pkgCommand; exit_code = $pkgResult.ExitCode; output = $pkgResult.Output }
        if (-not $installed) { $script:Failures.Add([pscustomobject]@{ name = "$Prefix.plugin.$p"; command = $pkgCommand; output = $pkgResult.Output; reason = 'Required LuCI plugin is not installed.' }) }
    }
    $script:Checks["$Prefix.required_plugins"] = [ordered]@{ passed = (($pluginResults | Where-Object passed).Count -eq $Required.Count); total = $Required.Count; passed_count = ($pluginResults | Where-Object passed).Count; package_manager = $manager; items = $pluginResults }
    Test-Remote "$Prefix.luci_components" 'find /usr/share/luci/menu.d /usr/share/luci/rpcd /usr/libexec/rpcd /etc/init.d -maxdepth 2 -type f 2>/dev/null | sort' { param($o) $o -match 'luci|rpcd|init.d' } 'LuCI menus, RPC/controller area and init.d service files must exist.' | Out-Null
    Test-Remote "$Prefix.luci_locale_theme" "uci -q get luci.main.lang; uci -q get luci.main.mediaurlbase; test -d /www/luci-static/argon; test -d /www/luci-static/kucat" { param($o) $o -match 'zh_cn' -and $o -match '/luci-static/argon' } 'zh_cn and Argon/KuCat theme resources must be present.' | Out-Null
    Test-Remote "$Prefix.kucat_theme" "test -d /www/luci-static/kucat; grep -R -F '/luci-static/kucat' /etc/config /etc/uci-defaults 2>/dev/null" { param($o) $o -match '/luci-static/kucat' } 'KuCat must remain selectable and its resources must be present.' | Out-Null
    Test-Remote "$Prefix.branding" 'test -s /www/luci-static/xinzhao/logo.png && test -s /www/luci-static/xinzhao/favicon.ico && test -s /www/luci-static/xinzhao/branding.js && grep -R -F XinZhaoWrt /etc/xinzhao-build-info /www/luci-static/xinzhao/build-info.json 2>/dev/null' { param($o) $o -match 'XinZhaoWrt' } 'XinZhaoWrt branding, icon/logo and author/build information must be present.' | Out-Null
    Test-Remote "$Prefix.adguard_manager" 'test -s /www/luci-static/resources/view/adguardhome/config.js && test -s /etc/config/adguardhome && test -x /etc/init.d/adguardhome' { param($o) $true } 'Complete AdGuard Home manager, config and service must be present.' | Out-Null
    Test-Remote "$Prefix.adguard_default_off" 'printf "enabled=%s\n" "$(uci -q get adguardhome.config.enabled 2>/dev/null || true)"; ! pidof AdGuardHome >/dev/null 2>&1; ! ls /etc/rc.d/S*adguardhome >/dev/null 2>&1' { param($o) $o -match '(?m)^enabled=0$' } 'AdGuard Home must be disabled by default.' | Out-Null
    Test-Remote "$Prefix.adguard_dns_53" "! pidof AdGuardHome >/dev/null 2>&1; (ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null || true)" { param($o) $o -notmatch '(?i)AdGuardHome.*:53' } 'AdGuard Home must not claim DNS port 53 on first boot.' | Out-Null
    Test-Remote "$Prefix.quickstart_page" 'test -s /usr/share/luci/menu.d/luci-app-quickstart.json; test -s /www/luci-static/quickstart/index.js; test -s /www/luci-static/quickstart/style.css' { param($o) $true } 'Official QuickStart route and frontend assets must be present.' | Out-Null
    Test-Remote "$Prefix.quickstart_backend" 'command -v quickstart && quickstart --help 2>&1; test -x /etc/init.d/quickstart; pidof quickstart >/dev/null 2>&1' { param($o) $o -match '(?i)quickstart|usage|help' } 'QuickStart backend must be executable and running for its homepage route.' | Out-Null
    Test-AdguardRpcFunctional $Prefix
    Test-AdguardPageFunctional $Prefix
    Test-QuickstartHomepage $Prefix
    Test-Luci
}

Test-Remote 'ssh' 'echo CODEX_SSH_OK' { param($o) $o -eq 'CODEX_SSH_OK' } 'SSH connectivity is required.' | Out-Null
$timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$wifiBefore = Get-WifiConfigurationSnapshot
Add-Check 'wifi_configuration.before_snapshot' ($wifiBefore.ExitCode -eq 0 -and $wifiBefore.Sha256) 'uci -q show wireless (hashed locally)' $wifiBefore 'The prebuild gate requires a readable Wi-Fi configuration snapshot before any verification activity.' | Out-Null
$before = Invoke-Remote "printf 'candidate=%s\ntime=%s\n' '$Candidate' '$timestamp' > $TestFile; sync; cat $TestFile"
Add-Check 'test_file.create' ($before.ExitCode -eq 0 -and $before.Output -match $Candidate) "printf ... > $TestFile; sync; cat $TestFile" $before 'Test file must be written and synced.' | Out-Null
Run-Phase 'before_reboot'

$reboot = Invoke-Remote 'sync; reboot'
$script:Checks['reboot.command'] = [ordered]@{ passed = ($reboot.ExitCode -eq 0 -or $reboot.Output -match '(?i)(closed|reset|connection)'); command = 'sync; reboot'; exit_code = $reboot.ExitCode; output = $reboot.Output }
Start-Sleep -Seconds 10
$recovered = $false
$waitLog = [System.Collections.Generic.List[string]]::new()
for ($i = 1; $i -le 60; $i++) {
    $ping = Test-Connection -ComputerName $DeviceIp -Count 1 -Quiet -ErrorAction SilentlyContinue
    $ssh = if ($ping) { Invoke-Remote 'echo CODEX_SSH_OK' } else { $null }
    $waitLog.Add("minute=$([math]::Round($i*5/60,2)); ping=$ping; ssh=$($ssh.ExitCode -eq 0)")
    if ($ping -and $ssh.ExitCode -eq 0 -and $ssh.Output -eq 'CODEX_SSH_OK') { $recovered = $true; break }
    Start-Sleep -Seconds 5
}
$script:Checks['reboot.recovery'] = [ordered]@{ passed = $recovered; command = "ping $DeviceIp; ssh -o BatchMode=yes $Target echo CODEX_SSH_OK"; exit_code = if ($recovered) { 0 } else { 1 }; output = ($waitLog -join "`n") }
if (-not $recovered) { $script:Failures.Add([pscustomobject]@{ name = 'reboot.recovery'; command = 'ping/ssh recovery loop'; output = ($waitLog -join "`n"); reason = 'Device did not recover within 5 minutes.' }) }

if ($recovered) {
    $persist = Invoke-Remote "test -f $TestFile && cat $TestFile"
    Add-Check 'persistence' ($persist.ExitCode -eq 0 -and $persist.Output -match $Candidate) "test -f $TestFile && cat $TestFile" $persist 'Test file must survive reboot.' | Out-Null
    Run-Phase 'after_reboot'
    $wifiAfter = Get-WifiConfigurationSnapshot
} else {
    $script:Failures.Add([pscustomobject]@{ name = 'persistence'; command = "test -f $TestFile"; output = 'Skipped: SSH did not recover'; reason = 'Cannot verify persistence without SSH recovery.' })
    $wifiAfter = [pscustomobject]@{ ExitCode = 1; Sha256 = $null; Output = 'Skipped: SSH did not recover' }
}

$cleanup = Invoke-Remote "rm -f $TestFile; sync; test ! -e $TestFile"
$script:Checks['test_file.cleanup'] = [ordered]@{ passed = ($cleanup.ExitCode -eq 0); command = "rm -f $TestFile; sync; test ! -e $TestFile"; exit_code = $cleanup.ExitCode; output = $cleanup.Output }
if ($cleanup.ExitCode -ne 0) { $script:Failures.Add([pscustomobject]@{ name = 'test_file.cleanup'; command = "rm -f $TestFile; sync; test ! -e $TestFile"; output = $cleanup.Output; reason = 'Test file cleanup failed.' }) }

$beforePlugins = @($script:Checks['before_reboot.required_plugins'].items)
$afterPlugins = @($script:Checks['after_reboot.required_plugins'].items)
$adguardLive = [bool]$script:Checks['after_reboot.adguard_page_functional'].passed
$quickstartLive = [bool]$script:Checks['after_reboot.quickstart_home_functional'].passed
$wifiLive = [bool]$script:Checks['after_reboot.wifi_live'].passed
$wifiComparable = ($wifiBefore.ExitCode -eq 0) -and ($wifiAfter.ExitCode -eq 0) -and $wifiBefore.Sha256 -and $wifiAfter.Sha256
$wifiConfigurationMutated = if ($wifiComparable) { $wifiBefore.Sha256 -ne $wifiAfter.Sha256 } else { $null }
$wifiMutationSafe = ($wifiComparable -and $wifiConfigurationMutated -eq $false)
$wifiAuditResult = [pscustomobject]@{
    ExitCode = if ($wifiMutationSafe) { 0 } else { 1 }
    Output = "before=$($wifiBefore.Sha256); after=$($wifiAfter.Sha256); comparable=$([bool]$wifiComparable); mutated=$wifiConfigurationMutated"
}
Add-Check 'wifi_configuration.unchanged' $wifiMutationSafe 'compare hashed uci -q show wireless snapshots' $wifiAuditResult 'Wi-Fi configuration must be readable before and after verification and must remain byte-for-byte unchanged.' | Out-Null
$prebuildPass = $adguardLive -and $quickstartLive -and $wifiLive -and $wifiMutationSafe
$prebuildFeatures = [ordered]@{
    ADGUARD_LIVE = if ($adguardLive) { 'PASS' } else { 'FAIL' }
    QUICKSTART_LIVE = if ($quickstartLive) { 'PASS' } else { 'FAIL' }
    WIFI_LIVE = if ($wifiLive) { 'PASS' } else { 'FAIL' }
    FIRMWARE_BUILD_ALLOWED = if ($prebuildPass) { 'true' } else { 'false' }
    authenticated_session = if ([string]::IsNullOrWhiteSpace($LuciCookieFile)) { 'missing' } else { 'provided' }
    wifi_configuration_mutated = $wifiConfigurationMutated
}
$result = if ($script:Failures.Count -eq 0 -and $beforePlugins.Count -eq $Required.Count -and $afterPlugins.Count -eq $Required.Count -and (@($beforePlugins | Where-Object passed).Count -eq 22) -and (@($afterPlugins | Where-Object passed).Count -eq 22)) { 'PASS' } else { 'FAIL' }
$report = [ordered]@{
    device = [ordered]@{ model = 'JDCloud RE-SS-01'; target = 'jdcloud_re-ss-01'; address = $DeviceIp; lan = '192.168.6.1'; luci = 'http://192.168.6.1/' }
    candidate = $Candidate
    commit = $Commit
    ssh = $script:Checks.ssh
    boot = [ordered]@{ before = $script:Checks['before_reboot.boot.board','before_reboot.boot.system']; after = $script:Checks['after_reboot.boot.board','after_reboot.boot.system']; checks = @($script:Checks.Values | Where-Object { $_ -and $_.PSObject.Properties['command'] -and $_.command -match 'boot' }) }
    storage = $script:Checks['after_reboot.storage']
    lan = $script:Checks['after_reboot.lan']
    wan = $script:Checks['after_reboot.wan']
    internet = $script:Checks['after_reboot.internet']
    dns = $script:Checks['after_reboot.dns']
    wifi_2g = $script:Checks['after_reboot.wifi_2g']
    wifi_5g = $script:Checks['after_reboot.wifi_5g']
    wifi_live = $script:Checks['after_reboot.wifi_live']
    wifi_configuration_audit = [ordered]@{ before = $wifiBefore; after = $wifiAfter; comparable = [bool]$wifiComparable }
    adguard_live = $script:Checks['after_reboot.adguard_page_functional']
    quickstart_live = $script:Checks['after_reboot.quickstart_home_functional']
    prebuild_features = $prebuildFeatures
    luci = $script:Checks['luci']
    required_plugins_total = $Required.Count
    required_plugins_passed = @($afterPlugins | Where-Object passed).Count
    required_plugins_before_reboot = $beforePlugins
    required_plugins_after_reboot = $afterPlugins
    reboot = $script:Checks['reboot.recovery']
    persistence = $script:Checks.persistence
    critical_log_errors = @($script:Failures | Where-Object { $_.name -match 'logread|dmesg' })
    failures = @($script:Failures)
    result = $result
}
$report | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 $JsonPath
$first = if ($script:Failures.Count) { $script:Failures[0] } else { $null }
$md = @("# Real Device Verification", "", "- Device: JDCloud RE-SS-01 (jdcloud_re-ss-01)", "- Candidate: $Candidate", "- Commit: $Commit", "- Result: $result", "- Required plugins: $(@($afterPlugins | Where-Object passed).Count)/$($Required.Count) after reboot", "")
if ($first) { $md += @('## First explicit failure', "- Check: $($first.name)", "- Reason: $($first.reason)", '```text', $first.output, '```', '') }
$md += '## Checks'
foreach ($k in $script:Checks.Keys) { $v = $script:Checks[$k]; if ($v.PSObject.Properties['passed']) { $md += "- $($k): $($v.passed)" } }
$md | Set-Content -Encoding UTF8 $MdPath
Write-Output "JSON: $((Resolve-Path $JsonPath).Path)"
Write-Output "Markdown: $((Resolve-Path $MdPath).Path)"
Write-Output "RESULT: $result"
Write-Output "ADGUARD_LIVE=$($prebuildFeatures.ADGUARD_LIVE)"
Write-Output "QUICKSTART_LIVE=$($prebuildFeatures.QUICKSTART_LIVE)"
Write-Output "WIFI_LIVE=$($prebuildFeatures.WIFI_LIVE)"
Write-Output "FIRMWARE_BUILD_ALLOWED=$($prebuildFeatures.FIRMWARE_BUILD_ALLOWED)"
if ($first) { Write-Output "FIRST_FAILURE: $($first.name) -- $($first.reason)"; Write-Output $first.output }
