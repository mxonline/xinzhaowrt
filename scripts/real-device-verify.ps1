$ErrorActionPreference = 'Continue'

$Target = 'root@192.168.1.1'
$Candidate = 'arthur-known-good-32853100232'
$Commit = '236abeaaea06442aa0f8f34efd0b4464b35c5061'
$TestFile = '/etc/xinzhao-real-device-test'
$OutDir = Join-Path $PSScriptRoot '..\output\real-device'
$JsonPath = Join-Path $OutDir 'real-device-verification.json'
$MdPath = Join-Path $OutDir 'real-device-verification.md'
$Required = @(Get-Content (Join-Path $PSScriptRoot '..\config\required-plugins.txt') | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() })
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$script:Checks = [ordered]@{}
$script:Failures = [System.Collections.Generic.List[object]]::new()

function Invoke-Remote([string]$Command) {
    $raw = @(& ssh -o BatchMode=yes $Target $Command 2>&1)
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($raw -join "`n").Trim() }
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
    $command = 'curl -k -sS -o /dev/null -w HTTP:%{http_code} https://192.168.1.1/cgi-bin/luci/'
    try {
        $out = @(& curl.exe -k -sS --max-time 15 -o NUL -w 'HTTP:%{http_code}' 'https://192.168.1.1/cgi-bin/luci/' 2>&1)
        $code = $LASTEXITCODE
        $text = ($out -join "`n").Trim()
        $r = [pscustomobject]@{ ExitCode = $code; Output = $text }
        Add-Check 'luci' ($code -eq 0 -and $text -match 'HTTP:(200|301|302|401|403)$') $command $r 'LuCI must respond over HTTPS; self-signed certificate is explicitly allowed.' | Out-Null
    } catch {
        $r = [pscustomobject]@{ ExitCode = 1; Output = $_.Exception.Message }
        Add-Check 'luci' $false $command $r 'LuCI must be reachable over HTTPS (self-signed certificate accepted).' | Out-Null
    }
}

function Run-Phase([string]$Prefix) {
    $board = Test-Remote "$Prefix.boot.board" 'ubus call system board' { param($o) $o -match 'jdcloud,re-ss-01|RE-SS-01' } 'Board identity must be JDCloud RE-SS-01 / jdcloud,re-ss-01.'
    Test-Remote "$Prefix.boot.system" 'cat /etc/openwrt_release; uname -a; uptime' { param($o) $o -match 'OpenWrt|ImmortalWrt' -and $o -match 'Linux' } 'ImmortalWrt/OpenWrt must be running normally.' | Out-Null
    Test-Remote "$Prefix.ssh" 'echo CODEX_SSH_OK' { param($o) $o -eq 'CODEX_SSH_OK' } | Out-Null
    Test-Remote "$Prefix.storage" 'uname -a; free -h; df -h; mount; command -v mmc || true; lsblk 2>/dev/null || true; dmesg | tail -n 80' { param($o) $o -match 'Linux' -and $o -match 'overlay' -and $o -notmatch '(?im)(kernel panic|I/O error|input/output error|filesystem error|EXT4-fs error|segfault|out of memory|oom-killer|watchdog.*(timeout|reset|bite|failed|crash|reboot)|firmware crashed)' } 'Kernel, memory, overlay, eMMC, filesystem and mounts must be healthy.' | Out-Null
    Test-Remote "$Prefix.lan" 'ubus call network.interface.lan status; ip -4 addr; ip route' { param($o) $o -match '"up":\s*true' -and $o -match '192\.168\.' } 'LAN must be up with an IPv4 address.' | Out-Null
    Test-Remote "$Prefix.wan" 'ubus call network.interface.wan status; ip route show default' { param($o) $o -match '"up":\s*true' -and $o -match '(?m)^default\s' } 'WAN must be up and have a default route.' | Out-Null
    Test-Remote "$Prefix.internet" 'ping -c 2 -W 3 1.1.1.1; uclient-fetch -qO- --timeout=10 https://api.ipify.org 2>/dev/null || true' { param($o) $o -match '(?m)0% packet loss' -and $o -match '\d+\.\d+\.\d+\.\d+' } 'Public IP connectivity must work.' | Out-Null
    Test-Remote "$Prefix.dns" 'nslookup openwrt.org 2>&1 || busybox nslookup openwrt.org 2>&1' { param($o) $o -match 'Address|address' -and $o -match '\d+\.\d+\.\d+\.\d+' } 'DNS resolution must work.' | Out-Null
    $wifi = Test-Remote "$Prefix.wifi" 'ubus call wireless status 2>/dev/null || true; iwinfo 2>/dev/null' { param($o) $o -match '(?i)(ESSID|phy0|phy1)' } 'Both Wi-Fi radios/interfaces must be present and operational.'
    Add-Check "$Prefix.wifi_2g" ($wifi.Output -match '2\.4\d+ GHz') 'ubus call wireless status 2>/dev/null || true; iwinfo' $wifi '2.4 GHz radio must be present.' | Out-Null
    Add-Check "$Prefix.wifi_5g" ($wifi.Output -match '5\.\d+ GHz') 'ubus call wireless status 2>/dev/null || true; iwinfo' $wifi '5 GHz radio must be present.' | Out-Null
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
    Test-Luci
}

Test-Remote 'ssh' 'echo CODEX_SSH_OK' { param($o) $o -eq 'CODEX_SSH_OK' } 'SSH connectivity is required.' | Out-Null
$timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$before = Invoke-Remote "printf 'candidate=%s\ntime=%s\n' '$Candidate' '$timestamp' > $TestFile; sync; cat $TestFile"
Add-Check 'test_file.create' ($before.ExitCode -eq 0 -and $before.Output -match $Candidate) "printf ... > $TestFile; sync; cat $TestFile" $before 'Test file must be written and synced.' | Out-Null
Run-Phase 'before_reboot'

$reboot = Invoke-Remote 'sync; reboot'
$script:Checks['reboot.command'] = [ordered]@{ passed = ($reboot.ExitCode -eq 0 -or $reboot.Output -match '(?i)(closed|reset|connection)'); command = 'sync; reboot'; exit_code = $reboot.ExitCode; output = $reboot.Output }
Start-Sleep -Seconds 10
$recovered = $false
$waitLog = [System.Collections.Generic.List[string]]::new()
for ($i = 1; $i -le 60; $i++) {
    $ping = Test-Connection -ComputerName 192.168.1.1 -Count 1 -Quiet -ErrorAction SilentlyContinue
    $ssh = if ($ping) { Invoke-Remote 'echo CODEX_SSH_OK' } else { $null }
    $waitLog.Add("minute=$([math]::Round($i*5/60,2)); ping=$ping; ssh=$($ssh.ExitCode -eq 0)")
    if ($ping -and $ssh.ExitCode -eq 0 -and $ssh.Output -eq 'CODEX_SSH_OK') { $recovered = $true; break }
    Start-Sleep -Seconds 5
}
$script:Checks['reboot.recovery'] = [ordered]@{ passed = $recovered; command = 'ping 192.168.1.1; ssh -o BatchMode=yes root@192.168.1.1 echo CODEX_SSH_OK'; exit_code = if ($recovered) { 0 } else { 1 }; output = ($waitLog -join "`n") }
if (-not $recovered) { $script:Failures.Add([pscustomobject]@{ name = 'reboot.recovery'; command = 'ping/ssh recovery loop'; output = ($waitLog -join "`n"); reason = 'Device did not recover within 5 minutes.' }) }

if ($recovered) {
    $persist = Invoke-Remote "test -f $TestFile && cat $TestFile"
    Add-Check 'persistence' ($persist.ExitCode -eq 0 -and $persist.Output -match $Candidate) "test -f $TestFile && cat $TestFile" $persist 'Test file must survive reboot.' | Out-Null
    Run-Phase 'after_reboot'
} else {
    $script:Failures.Add([pscustomobject]@{ name = 'persistence'; command = "test -f $TestFile"; output = 'Skipped: SSH did not recover'; reason = 'Cannot verify persistence without SSH recovery.' })
}

$cleanup = Invoke-Remote "rm -f $TestFile; sync; test ! -e $TestFile"
$script:Checks['test_file.cleanup'] = [ordered]@{ passed = ($cleanup.ExitCode -eq 0); command = "rm -f $TestFile; sync; test ! -e $TestFile"; exit_code = $cleanup.ExitCode; output = $cleanup.Output }
if ($cleanup.ExitCode -ne 0) { $script:Failures.Add([pscustomobject]@{ name = 'test_file.cleanup'; command = "rm -f $TestFile; sync; test ! -e $TestFile"; output = $cleanup.Output; reason = 'Test file cleanup failed.' }) }

$beforePlugins = @($script:Checks['before_reboot.required_plugins'].items)
$afterPlugins = @($script:Checks['after_reboot.required_plugins'].items)
$result = if ($script:Failures.Count -eq 0 -and $beforePlugins.Count -eq $Required.Count -and $afterPlugins.Count -eq $Required.Count -and (@($beforePlugins | Where-Object passed).Count -eq 22) -and (@($afterPlugins | Where-Object passed).Count -eq 22)) { 'PASS' } else { 'FAIL' }
$report = [ordered]@{
    device = [ordered]@{ model = 'JDCloud RE-SS-01'; target = 'jdcloud_re-ss-01'; address = '192.168.1.1' }
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
if ($first) { Write-Output "FIRST_FAILURE: $($first.name) -- $($first.reason)"; Write-Output $first.output }
