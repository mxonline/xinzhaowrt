$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}

function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message (missing '$Needle')"
    }
}

$baselinePath = Join-Path $Root 'production/real-device-baseline.json'
$expectedDiffPath = Join-Path $Root 'production/expected-diff.json'
$libPath = Join-Path $Root 'scripts/real-device-baseline-lib.ps1'
$snapshotPath = Join-Path $Root 'scripts/real-device-snapshot.ps1'
$gatePath = Join-Path $Root 'scripts/real-device-baseline-gate.ps1'
$agentPath = Join-Path $Root 'scripts/production-agent.ps1'
$safetyPath = Join-Path $Root 'scripts/auto-flash-safety-gate.ps1'
$configPath = Join-Path $Root 'production/production-agent.json'

foreach ($required in @($baselinePath,$expectedDiffPath,$libPath,$snapshotPath,$gatePath)) {
    Assert-True (Test-Path $required) "real-device baseline implementation file missing: $required"
}

. $libPath

$baseline = Get-Content -Raw $baselinePath | ConvertFrom-Json
Assert-True ([string]$baseline.device.profile -eq 'jdcloud_re-ss-01') 'baseline profile must bind JDCloud Arthur'
Assert-True ([string]$baseline.device.target -eq 'qualcommax/ipq60xx') 'baseline target must be qualcommax/ipq60xx'
Assert-True ([string]$baseline.device.model -match 'RE-SS-01') 'baseline model must be JDCloud RE-SS-01'
Assert-True ([string]$baseline.firmware.version -eq '0.1.3') 'physical development baseline version must be 0.1.3'
Assert-True ([string]$baseline.firmware.build_id -eq '33368080615') 'physical baseline must preserve observed Build ID 33368080615'
Assert-True ($baseline.machine_verified -eq $false) 'bootstrap record must not falsely claim machine verification before the snapshot succeeds'
Assert-True ([string]$baseline.status -match 'BOOTSTRAP|PENDING') 'bootstrap baseline must clearly advertise pending machine evidence'

Assert-True ((Compare-ArthurVersion '0.1.2' '0.1.3') -lt 0) 'semantic version comparison must order 0.1.2 below 0.1.3'
Assert-True ((Compare-ArthurVersion '0.1.3' '0.1.3') -eq 0) 'semantic version comparison must identify equal versions'
Assert-True ((Compare-ArthurVersion '0.1.4' '0.1.3') -gt 0) 'semantic version comparison must order 0.1.4 above 0.1.3'
Assert-True (-not (Test-ForwardCandidateVersion -CandidateVersion '0.1.2' -BaselineVersion '0.1.3')) 'normal 0.1.2 candidate must be blocked over physical 0.1.3'
Assert-True (Test-ForwardCandidateVersion -CandidateVersion '0.1.3' -BaselineVersion '0.1.3') 'same-version forward candidate may proceed to the remaining gates'
Assert-True (Test-ForwardCandidateVersion -CandidateVersion '0.1.4' -BaselineVersion '0.1.3') 'newer forward candidate may proceed to the remaining gates'
Assert-True (Test-ArthurVersionOperation -CandidateVersion '0.1.0' -BaselineVersion '0.1.3' -Operation 'rollback') 'explicit rollback must be exempt from normal forward version ordering'

Assert-True ([string](Classify-ArthurSshProbe -ExitCode 255 -Output 'ssh: connect to host 192.168.6.1 port 22: Connection timed out') -eq 'DEVICE_UNREACHABLE') 'network timeout must be classified as DEVICE_UNREACHABLE'
Assert-True ([string](Classify-ArthurSshProbe -ExitCode 255 -Output 'root@192.168.6.1: Permission denied (publickey,password).') -eq 'SSH_AUTH_FAILED') 'SSH credential rejection must be classified as SSH_AUTH_FAILED'
Assert-True ([string](Classify-ArthurSshProbe -ExitCode 0 -Output '{"model":"Other Router","board_name":"other,router"}') -eq 'DEVICE_IDENTITY_MISMATCH') 'successful SSH to the wrong board must be DEVICE_IDENTITY_MISMATCH'
Assert-True ([string](Classify-ArthurSshProbe -ExitCode 0 -Output '{"model":"JDCloud RE-SS-01","board_name":"jdcloud,re-ss-01"}') -eq 'DEVICE_VERIFIED') 'Arthur board must be DEVICE_VERIFIED'

$snapshot = Get-Content -Raw $snapshotPath
foreach ($requiredRead in @('ubus call system board','/etc/openwrt_release','uci -q show network','uci -q show wireless','df -h')) {
    Assert-Contains $snapshot $requiredRead "snapshot must collect read-only evidence: $requiredRead"
}
foreach ($forbiddenWrite in @('sysupgrade',' mtd ','mtd write',' nandwrite','uci set','uci commit','/etc/init.d/','reboot','poweroff','dd if=')) {
    Assert-True (-not $snapshot.ToLowerInvariant().Contains($forbiddenWrite.ToLowerInvariant())) "snapshot must remain read-only; forbidden token: $forbiddenWrite"
}
Assert-Contains $snapshot 'output\real-device' 'snapshot must persist runtime evidence under output/real-device'
Assert-Contains $snapshot 'DEVICE_UNREACHABLE' 'snapshot must preserve reachability classification'
Assert-Contains $snapshot 'SSH_AUTH_FAILED' 'snapshot must preserve SSH auth classification'
Assert-Contains $snapshot 'DEVICE_IDENTITY_MISMATCH' 'snapshot must preserve true identity mismatch classification'

$agent = Get-Content -Raw $agentPath
Assert-Contains $agent 'real-device-baseline.json' 'Production Agent must consume the real-device baseline'
Assert-Contains $agent 'real-device-snapshot.ps1' 'Production Agent must obtain a read-only snapshot before a write path'
Assert-Contains $agent 'real-device-baseline-gate.ps1' 'Production Agent must run the baseline/expected-diff gate before upload/flash'
Assert-Contains $agent 'DEVICE_UNREACHABLE' 'Production Agent must classify unreachable device separately'
Assert-Contains $agent 'SSH_AUTH_FAILED' 'Production Agent must classify SSH auth failure separately'
Assert-Contains $agent 'DEVICE_IDENTITY_MISMATCH' 'Production Agent must use a true identity mismatch hard-stop class'
Assert-True ($agent -notmatch "human_gate\s*=\s*'UNKNOWN_DEVICE_IDENTITY'") 'generic UNKNOWN_DEVICE_IDENTITY must no longer be the device access hard stop'

$safety = Get-Content -Raw $safetyPath
Assert-Contains $safety '$Known.rollback.sha256' 'Safety Gate must verify the downloaded rollback against rollback.sha256'
Assert-True ($safety -notmatch '\$Known\.sha256\)\.ToLowerInvariant\(\).*Rollback') 'Safety Gate must not compare rollback bytes to the unrelated top-level known-good digest'

$config = Get-Content -Raw $configPath | ConvertFrom-Json
Assert-True ([string]$config.real_device_baseline -eq 'production/real-device-baseline.json') 'Production Agent config must name real-device baseline authority'
Assert-True ([string]$config.expected_diff -eq 'production/expected-diff.json') 'Production Agent config must name expected-diff policy'
Assert-True (@($config.human_stop_classes) -contains 'DEVICE_IDENTITY_MISMATCH') 'true device identity mismatch must remain a human safety stop'
Assert-True (@($config.human_stop_classes) -notcontains 'DEVICE_UNREACHABLE') 'device unreachable must be recoverable'
Assert-True (@($config.human_stop_classes) -notcontains 'SSH_AUTH_FAILED') 'SSH auth failure must be recoverable'

$version = (Get-Content -Raw (Join-Path $Root 'VERSION')).Trim()
$buildEnv = Get-Content -Raw (Join-Path $Root 'build.env')
$arthurConfig = Get-Content -Raw (Join-Path $Root 'config/arthur.config')
Assert-True ($version -eq '0.1.3') 'VERSION must align with physical baseline 0.1.3'
Assert-Contains $buildEnv 'FIRMWARE_VERSION="0.1.3"' 'build.env firmware version must align with 0.1.3'
Assert-Contains $arthurConfig 'CONFIG_VERSION_NUMBER="0.1.3"' 'arthur.config version number must align with 0.1.3'

Write-Host 'REAL_DEVICE_BASELINE_CONTRACT=PASS'
Write-Host 'REAL_DEVICE_ACCESS_CLASSIFICATION_CONTRACT=PASS'
Write-Host 'REAL_DEVICE_VERSION_ORDER_CONTRACT=PASS'
Write-Host 'REAL_DEVICE_SNAPSHOT_READ_ONLY_CONTRACT=PASS'
