param(
    [string]$DeviceIp = '192.168.6.1',
    [Parameter(Mandatory = $true)] [string]$OutFile,
    [switch]$ProbeOnly,
    [string]$FixtureFile
)

$ErrorActionPreference = 'Stop'

function New-EmptyReport {
    [ordered]@{
        test_mode = 'POST_RELEASE_DEVICE_TEST'
        captured_at_utc = [DateTime]::UtcNow.ToString('o')
        device_ip = $DeviceIp
        connection = [ordered]@{ status = 'NOT_ATTEMPTED'; error = $null }
        updater = [ordered]@{
            events = @()
            candidate_paths = @()
            samples = @()
            peak_rss_kb = $null
            peak_pss_kb = $null
        }
        mihomo = [ordered]@{ processes = @(); samples = @(); peak_rss_kb = $null; peak_pss_kb = $null }
        memory = [ordered]@{ samples = @(); memavailable_floor_kb = $null }
        resident_services = [ordered]@{ adguardhome = @(); quickfile = @(); quickstart = @(); init_state = @() }
        sysupgrade_preserved_state = [ordered]@{ uci = @(); init_links = @(); disable_logic_observed = $false }
        concurrency = [ordered]@{ updater_pids = @(); lock_state = @(); simultaneous_candidates = $false }
        segfaults = [ordered]@{ actual_binary_argv = @(); log_excerpt = @(); evidence_status = 'MISSING' }
        raw_probe = @()
    }
}

if ($FixtureFile) {
    if (-not (Test-Path -LiteralPath $FixtureFile -PathType Leaf)) { throw "Fixture file missing: $FixtureFile" }
    $report = Get-Content -Raw -LiteralPath $FixtureFile | ConvertFrom-Json
    $report.test_mode = 'POST_RELEASE_DEVICE_TEST'
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutFile -Encoding utf8
    exit 0
}

$report = New-EmptyReport
$remoteScript = @'
set +e
echo "XZ_BEGIN|$(date -u +%Y-%m-%dT%H:%M:%SZ)"
awk '/^MemAvailable:/ { print "XZ_MEM|" $2 }' /proc/meminfo
for name in mihomo openclash_core.sh clash_meta AdGuardHome adguardhome quickfile quickstart; do
    pids="$(pidof "$name" 2>/dev/null)"
    echo "XZ_PIDS|$name|$pids"
done
for pid in $(ps w 2>/dev/null | awk '/openclash|mihomo|clash_meta|core_download/ && !/awk/ {print $1}'); do
    [ -r "/proc/$pid/status" ] || continue
    comm="$(awk '/^Name:/ {print $2}' "/proc/$pid/status")"
    rss="$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status")"
    pss="$(awk '/^Pss:/ {print $2}' "/proc/$pid/smaps_rollup 2>/dev/null")"
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null)"
    argv="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    echo "XZ_PROC|$pid|$comm|$rss|$pss|$exe|$argv"
done
for path in /tmp/openclash-core-update/*/* /tmp/clash_meta* /etc/openclash/core/*; do
    [ -e "$path" ] && echo "XZ_PATH|$path"
done
for service in adguardhome AdGuardHome quickfile quickstart; do
    if [ -x "/etc/init.d/$service" ]; then exists=1; else exists=0; fi
    if [ -e "/etc/rc.d/S*${service}" ] || ls "/etc/rc.d/S"*"$service" >/dev/null 2>&1; then enabled=1; else enabled=0; fi
    echo "XZ_INIT|$service|$exists|$enabled"
done
for file in /etc/config/adguardhome /etc/config/AdGuardHome /etc/config/openclash; do
    [ -f "$file" ] && { echo "XZ_UCI|$file|$(sed -n '1,80p' "$file" | tr '\n' ' ')"; }
done
for i in 1 2 3 4 5 6 7 8; do
    now="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    echo "XZ_SAMPLE_MEM|$now"
    for pid in $(ps w 2>/dev/null | awk '/openclash|mihomo|clash_meta|core_download/ && !/awk/ {print $1}'); do
        rss="$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null)"
        pss="$(awk '/^Pss:/ {print $2}' "/proc/$pid/smaps_rollup 2>/dev/null)"
        comm="$(awk '/^Name:/ {print $2}' "/proc/$pid/status" 2>/dev/null)"
        echo "XZ_SAMPLE_PROC|$pid|$comm|$rss|$pss"
    done
    sleep 1
done
echo "XZ_OPENCLASH_LOG|$(logread 2>/dev/null | grep -Ei 'openclash|mihomo|core|out of memory|segfault|sigsegv' | tail -n 120 | tr '\n' ' ')"
echo "XZ_KERNEL_LOG|$(dmesg 2>/dev/null | grep -Ei 'out of memory|oom|segfault|sigsegv|killed process' | tail -n 80 | tr '\n' ' ')"
for event in download replace chmod execute; do
    logread 2>/dev/null | grep -Eiq "$event|core.*update|update.*core" && echo "XZ_EVENT|$event|observed"
done
echo "XZ_END|$(date -u +%Y-%m-%dT%H:%M:%SZ)"
'@

try {
    if (-not ($DeviceIp -match '^(?:\d{1,3}\.){3}\d{1,3}$')) { throw "Unsafe device IP: $DeviceIp" }
    $ssh = (Get-Command ssh.exe -ErrorAction Stop).Source
    $args = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'StrictHostKeyChecking=yes', "root@$DeviceIp", $remoteScript)
    $raw = & $ssh @args 2>&1
    $exitCode = $LASTEXITCODE
    $report.connection.status = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
    $report.connection.error = if ($exitCode -eq 0) { $null } else { ($raw | Out-String).Trim() }
    $report.raw_probe = @($raw | ForEach-Object { [string]$_ })
} catch {
    $report.connection.status = 'FAIL'
    $report.connection.error = $_.Exception.Message
}

foreach ($line in $report.raw_probe) {
    $parts = $line -split '\|', 7
    switch ($parts[0]) {
        'XZ_MEM' { $report.memory.samples += [int64]$parts[1] }
        'XZ_SAMPLE_MEM' { $report.memory.samples += [int64]$parts[1] }
        'XZ_PROC' {
            $item = [ordered]@{ pid = $parts[1]; name = $parts[2]; rss_kb = $parts[3]; pss_kb = $parts[4]; exe = $parts[5]; argv = $parts[6] }
            if ($parts[2] -match 'mihomo|clash') { $report.mihomo.processes += $item }
            if ($parts[2] -match 'openclash|core|clash') { $report.updater.samples += $item }
            if ($parts[5] -and $parts[6]) { $report.segfaults.actual_binary_argv += [ordered]@{ exe = $parts[5]; argv = $parts[6]; pid = $parts[1] } }
        }
        'XZ_SAMPLE_PROC' {
            $item = [ordered]@{ pid = $parts[1]; name = $parts[2]; rss_kb = $parts[3]; pss_kb = $parts[4] }
            if ($parts[2] -match 'mihomo|clash') { $report.mihomo.samples += $item }
            if ($parts[2] -match 'openclash|core|clash') { $report.updater.samples += $item }
        }
        'XZ_PATH' { $report.updater.candidate_paths += $parts[1] }
        'XZ_EVENT' { $report.updater.events += [ordered]@{ phase = $parts[1]; evidence = $parts[2] } }
        'XZ_PIDS' {
            if ($parts[2]) { $report.concurrency.updater_pids += [ordered]@{ name = $parts[1]; pids = $parts[2] } }
            if ($parts[1] -in @('AdGuardHome', 'adguardhome', 'quickfile', 'quickstart')) { $report.resident_services.($parts[1]) += $parts[2] }
        }
        'XZ_INIT' { $report.resident_services.init_state += [ordered]@{ service = $parts[1]; exists = $parts[2]; enabled = $parts[3] } }
        'XZ_UCI' { $report.sysupgrade_preserved_state.uci += $parts[1..6] -join '|' }
        'XZ_OPENCLASH_LOG' { $report.segfaults.log_excerpt += $parts[1] }
        'XZ_KERNEL_LOG' { $report.segfaults.log_excerpt += $parts[1] }
    }
}

if ($report.memory.samples.Count -gt 0) { $report.memory.memavailable_floor_kb = ($report.memory.samples | Measure-Object -Minimum).Minimum }
foreach ($bucket in @($report.updater, $report.mihomo)) {
    $rss = @($bucket.samples | Where-Object { $_.rss_kb -as [int64] } | ForEach-Object { [int64]$_.rss_kb })
    $pss = @($bucket.samples | Where-Object { $_.pss_kb -as [int64] } | ForEach-Object { [int64]$_.pss_kb })
    if ($rss.Count -gt 0) { $bucket.peak_rss_kb = ($rss | Measure-Object -Maximum).Maximum }
    if ($pss.Count -gt 0) { $bucket.peak_pss_kb = ($pss | Measure-Object -Maximum).Maximum }
}
$report.segfaults.evidence_status = if ($report.segfaults.actual_binary_argv.Count -gt 0 -and $report.segfaults.log_excerpt.Count -gt 0) { 'PRESENT' } else { 'MISSING' }
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutFile -Encoding utf8
if ($report.connection.status -ne 'PASS') { exit 1 }
