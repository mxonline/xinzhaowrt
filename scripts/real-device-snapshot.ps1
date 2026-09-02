param(
    [string]$Target = 'root@192.168.6.1',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'real-device-baseline-lib.ps1')

$OutDir = Join-Path $Root 'output\real-device'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if (-not $OutputPath) { $OutputPath = Join-Path $OutDir 'real-device-snapshot.json' }

function Invoke-ReadOnlyRemote {
    param([Parameter(Mandatory=$true)][string]$Command)
    $raw = @(& ssh.exe -o BatchMode=yes -o ConnectTimeout=8 $Target $Command 2>&1)
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($raw -join "`n").Trim() }
}

$hostPart = ($Target -split '@')[-1]
$tcp = Test-NetConnection -ComputerName $hostPart -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $tcp) { throw 'DEVICE_UNREACHABLE' }

$auth = Invoke-ReadOnlyRemote 'echo XINZHAO_SSH_OK'
if ($auth.ExitCode -ne 0) {
    $class = Classify-ArthurSshProbe -ExitCode $auth.ExitCode -Output $auth.Output
    throw $class
}

$board = Invoke-ReadOnlyRemote 'ubus call system board'
$boardClass = Classify-ArthurSshProbe -ExitCode $board.ExitCode -Output $board.Output
if ($boardClass -ne 'DEVICE_VERIFIED') { throw $boardClass }

$buildInfo = Invoke-ReadOnlyRemote 'cat /www/luci-static/xinzhao/build-info.json'
if ($buildInfo.ExitCode -ne 0 -or -not $buildInfo.Output) { throw 'REAL_DEVICE_BUILD_INFO_MISSING' }
try { $buildInfoJson = $buildInfo.Output | ConvertFrom-Json }
catch { throw "REAL_DEVICE_BUILD_INFO_INVALID $($_.Exception.Message)" }

$system = Invoke-ReadOnlyRemote 'cat /etc/openwrt_release; cat /etc/os-release 2>/dev/null || true; uname -a; uptime'
$network = Invoke-ReadOnlyRemote 'uci -q show network; ubus call network.interface.lan status; ip -4 addr; ip route'
$wireless = Invoke-ReadOnlyRemote "uci -q show wireless | grep -v '\.key=' || true; ubus call wireless status 2>/dev/null || true; iwinfo 2>/dev/null || true"
$packages = Invoke-ReadOnlyRemote "if command -v apk >/dev/null 2>&1; then apk info; elif command -v opkg >/dev/null 2>&1; then opkg list-installed; fi"
$luci = Invoke-ReadOnlyRemote "uci -q get luci.main.lang 2>/dev/null || true; uci -q get luci.main.mediaurlbase 2>/dev/null || true; ls -1 /www/luci-static 2>/dev/null || true"
$istore = Invoke-ReadOnlyRemote "command -v quickstart 2>/dev/null || true; test -d /www/luci-static/quickstart && echo QUICKSTART_ASSETS_PRESENT || true; ubus -q list 2>/dev/null | grep -Ei 'istore|quickstart|store' || true"
$adguard = Invoke-ReadOnlyRemote "pgrep -af AdGuardHome 2>/dev/null || true; ubus -q list 2>/dev/null | grep -i adguard || true; test -f /etc/adguardhome/adguardhome.yaml && echo ADGUARD_CONFIG_PRESENT || true"
$storage = Invoke-ReadOnlyRemote 'df -h; mount; lsblk 2>/dev/null || true; cat /proc/mtd 2>/dev/null || true'
$health = Invoke-ReadOnlyRemote "uptime; free -h; dmesg | tail -n 120; logread -l 200 2>/dev/null || true"

foreach ($probe in @($system,$network,$wireless,$packages,$luci,$istore,$adguard,$storage,$health)) {
    if ($probe.ExitCode -ne 0) { throw "READ_ONLY_SNAPSHOT_FAILED exit=$($probe.ExitCode) output=$($probe.Output)" }
}

$snapshot = [ordered]@{
    schema_version = '1.0'
    result = 'DEVICE_VERIFIED'
    machine_verified = $true
    target = $Target
    collected_at = (Get-Date).ToString('o')
    device = [ordered]@{
        expected_profile = 'jdcloud_re-ss-01'
        expected_target = 'qualcommax/ipq60xx'
        board = $board.Output
    }
    firmware = [ordered]@{
        version = Get-ArthurVersionFromText ([string]$buildInfoJson.Version)
        build_id = [string]$buildInfoJson.'Build ID'
        build_date = [string]$buildInfoJson.'Build Date'
        git_commit = [string]$buildInfoJson.'Git Commit'
        build_info = $buildInfoJson
        system = $system.Output
    }
    network = $network.Output
    wireless_redacted = $wireless.Output
    installed_packages = $packages.Output
    luci_theme_state = $luci.Output
    istore_quickstart_state = $istore.Output
    adguardhome_state = $adguard.Output
    storage = $storage.Output
    health = $health.Output
    secret_redaction = 'wireless .key lines excluded from runtime evidence'
}

$snapshot | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 $OutputPath
Write-Host "REAL_DEVICE_SNAPSHOT=PASS path=$OutputPath"
Write-Host "REAL_DEVICE_BUILD_INFO=PASS version=$($snapshot.firmware.version) build_id=$($snapshot.firmware.build_id) commit=$($snapshot.firmware.git_commit)"
Write-Host 'DEVICE_IDENTITY=PASS device=jdcloud_re-ss-01'
