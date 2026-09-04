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
$controllerPath = Join-Path $Root 'scripts/ci-controller-v3.ps1'
$deployPath = Join-Path $Root '.github/workflows/production-agent-deploy.yml'
$pipelinePath = Join-Path $Root 'ai_orchestrator/arthur.py'
$controlPlanePath = Join-Path $Root 'scripts/arthur-control-plane.ps1'

foreach ($required in @($baselinePath,$expectedDiffPath,$libPath,$snapshotPath,$gatePath,$deployPath,$pipelinePath,$controlPlanePath)) {
    Assert-True (Test-Path $required) "real-device baseline implementation file missing: $required"
}

. $libPath

$baseline = Get-Content -Raw $baselinePath | ConvertFrom-Json
Assert-True ([string]$baseline.device.profile -eq 'jdcloud_re-ss-01') 'baseline profile must bind JDCloud Arthur'
Assert-True ([string]$baseline.device.target -eq 'qualcommax/ipq60xx') 'baseline target must be qualcommax/ipq60xx'
Assert-True ([string]$baseline.device.model -match 'RE-SS-01') 'baseline model must be JDCloud RE-SS-01'
Assert-True ([string]$baseline.firmware.version -eq '0.1.3') 'physical development baseline version must be 0.1.3'
Assert-True ([string]$baseline.firmware.build_id -eq '33462873812') 'physical baseline must preserve live-observed Build ID 33462873812'
Assert-True ([string]$baseline.firmware.source_sha -eq 'e27bafac2d4a3ecf0f7a0e4cf2f7b34cf77571c9') 'baseline must bind the full Git commit behind the live physical UI short commit'
Assert-True ([string]$baseline.firmware.sha256 -eq 'bca247eb69c4d210c2965832c29271270320b3b85296ebe5e86a15a3648e880a') 'baseline must bind the reconciled GitHub artifact firmware SHA256'
Assert-True ([string]$baseline.firmware.displayed_git_commit -eq 'e27bafa') 'baseline must preserve the live physical displayed Git commit'
Assert-True ([string]$baseline.firmware.artifact_id -eq '9784138318') 'baseline must bind the exact GitHub artifact behind the physical build'
Assert-True ($baseline.machine_verified -eq $false) 'committed bootstrap record must not falsely claim a live SSH snapshot already occurred'

Assert-True ((Compare-ArthurVersion '0.1.2' '0.1.3') -lt 0) 'semantic version comparison must order 0.1.2 below 0.1.3'
Assert-True ((Compare-ArthurVersion '0.1.3' '0.1.3') -eq 0) 'semantic version comparison must identify equal versions'
Assert-True ((Compare-ArthurVersion '0.1.4' '0.1.3') -gt 0) 'semantic version comparison must order 0.1.4 above 0.1.3'
Assert-True (-not (Test-ForwardCandidateVersion -CandidateVersion '0.1.2' -BaselineVersion '0.1.3')) 'normal 0.1.2 candidate must be blocked over physical 0.1.3'
Assert-True (Test-ArthurVersionOperation -CandidateVersion '0.1.0' -BaselineVersion '0.1.3' -Operation 'rollback') 'explicit rollback must be exempt from normal forward ordering'

Assert-True ([string](Classify-ArthurSshProbe -ExitCode 255 -Output 'ssh: connect to host 192.168.6.1 port 22: Connection timed out') -eq 'DEVICE_UNREACHABLE') 'network timeout must be DEVICE_UNREACHABLE'
Assert-True ([string](Classify-ArthurSshProbe -ExitCode 255 -Output 'root@192.168.6.1: Permission denied (publickey,password).') -eq 'SSH_AUTH_FAILED') 'credential rejection must be SSH_AUTH_FAILED'
Assert-True ([string](Classify-ArthurSshProbe -ExitCode 255 -Output 'WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!') -eq 'SSH_HOST_IDENTITY_MISMATCH') 'host-key anomaly must remain a hard safety class'
Assert-True ([string](Classify-ArthurSshProbe -ExitCode 0 -Output '{"model":"Other Router","board_name":"other,router"}') -eq 'DEVICE_IDENTITY_MISMATCH') 'wrong authenticated board must be DEVICE_IDENTITY_MISMATCH'
Assert-True ([string](Classify-ArthurSshProbe -ExitCode 0 -Output '{"model":"JDCloud RE-SS-01","board_name":"jdcloud,re-ss-01"}') -eq 'DEVICE_VERIFIED') 'Arthur board must be DEVICE_VERIFIED'

$matchingBuild = [pscustomobject]@{ Version='0.1.3'; 'Build ID'='33462873812'; 'Git Commit'='e27bafa' }
$wrongBuild = [pscustomobject]@{ Version='0.1.2'; 'Build ID'='33570985102'; 'Git Commit'='7375e24' }
Assert-True (Test-ArthurBuildInfoMatchesBaseline -BuildInfo $matchingBuild -Baseline $baseline) 'live build-info matching physical 0.1.3 must verify'
Assert-True (-not (Test-ArthurBuildInfoMatchesBaseline -BuildInfo $wrongBuild -Baseline $baseline)) 'different build/version must not impersonate the physical baseline'

$snapshot = Get-Content -Raw $snapshotPath
foreach ($requiredRead in @('ubus call system board','/www/luci-static/xinzhao/build-info.json','/etc/openwrt_release','uci -q show network','uci -q show wireless','df -h')) {
    Assert-Contains $snapshot $requiredRead "snapshot must collect read-only evidence: $requiredRead"
}
foreach ($forbiddenWrite in @('sysupgrade',' mtd ','mtd write',' nandwrite','uci set','uci commit','/etc/init.d/','reboot','poweroff','dd if=')) {
    Assert-True (-not $snapshot.ToLowerInvariant().Contains($forbiddenWrite.ToLowerInvariant())) "snapshot must remain read-only; forbidden token: $forbiddenWrite"
}
Assert-Contains $snapshot 'output\real-device' 'snapshot must persist runtime evidence under output/real-device'
Assert-Contains $snapshot "grep -v '\.key='" 'snapshot must redact wireless keys rather than commit or log them'

$gate = Get-Content -Raw $gatePath
Assert-Contains $gate 'Test-ArthurBuildInfoMatchesBaseline' 'baseline gate must bind live version/build/commit to the physical baseline'
Assert-Contains $gate 'CANDIDATE_VERSION_OLDER_THAN_REAL_DEVICE_BASELINE' 'baseline gate must block a normal downgrade before upload/flash'
Assert-Contains $gate 'BASELINE_INHERITANCE_GATE=PASS' 'baseline inheritance must be an explicit gate'
Assert-Contains $gate 'EXPECTED_DIFF_GATE=PASS' 'expected diff must be an explicit gate'

$agent = Get-Content -Raw $agentPath
Assert-Contains $agent 'real-device-baseline.json' 'Production Agent must consume the real-device baseline'
Assert-Contains $agent 'real-device-snapshot.ps1' 'Production Agent must obtain a read-only snapshot before a write path'
Assert-Contains $agent 'real-device-baseline-gate.ps1' 'Production Agent must run baseline/expected-diff/version gate before upload'
Assert-Contains $agent 'DEVICE_UNREACHABLE' 'unreachable device must be separately classified'
Assert-Contains $agent 'SSH_AUTH_FAILED' 'SSH auth failure must be separately classified'
Assert-Contains $agent 'DEVICE_IDENTITY_MISMATCH' 'wrong device must have a hard safety class'
Assert-Contains $agent 'SSH_HOST_IDENTITY_MISMATCH' 'host-key anomaly must have a hard safety class'
Assert-Contains $agent 'Request-CurrentSourceRebuild' 'legacy candidate rejection must explicitly request a current-source replacement build'
Assert-Contains $agent 'REBUILD_REQUESTED' 'legacy candidate rejection must persist a durable rebuild request rather than resume the same successful old run'

# Candidate routing ownership moved from the legacy deploy loop to the single ai_orchestrator pipeline.
$deploy = Get-Content -Raw $deployPath
$pipeline = Get-Content -Raw $pipelinePath
$controlPlane = Get-Content -Raw $controlPlanePath
Assert-Contains $deploy 'scripts\arthur-control-plane.ps1' 'runner wakeup must delegate release continuation to the Control Plane'
Assert-Contains $controlPlane 'python -m ai_orchestrator resume' 'Control Plane must resume the single durable executor'
Assert-Contains $pipeline '.github/workflows/arthur-update-v3.yml' 'production Candidate routing must remain bound to the Arthur v3 workflow'
Assert-Contains $pipeline 'RECOVERABLE_ROUTE_MISMATCH' 'wrong Candidate route must remain recoverable and never become flash evidence'
Assert-Contains $pipeline 'flash_allowed' 'pipeline must retain explicit Candidate flash eligibility'

$safety = Get-Content -Raw $safetyPath
Assert-Contains $safety '$Known.rollback.sha256' 'Safety Gate must verify the downloaded rollback against rollback.sha256'
Assert-Contains $safety '192.168.6.1' 'Safety Gate must preserve the expected Arthur LAN invariant while consuming baseline authority'

$config = Get-Content -Raw $configPath | ConvertFrom-Json
Assert-True ([string]$config.real_device_baseline -eq 'production/real-device-baseline.json') 'Production Agent config must name real-device baseline authority'
Assert-True ([string]$config.expected_diff -eq 'production/expected-diff.json') 'Production Agent config must name expected-diff policy'
Assert-True (@($config.human_stop_classes) -contains 'DEVICE_IDENTITY_MISMATCH') 'true device identity mismatch must remain a human safety stop'
Assert-True (@($config.human_stop_classes) -contains 'SSH_HOST_IDENTITY_MISMATCH') 'host-key anomaly must remain a human safety stop'
Assert-True (@($config.human_stop_classes) -contains 'REAL_DEVICE_BASELINE_BUILD_MISMATCH') 'live build identity mismatch must freeze the write path'
Assert-True (@($config.human_stop_classes) -contains 'REAL_DEVICE_BASELINE_GATE_FAILED') 'unexpected baseline policy failure must freeze the write path'
Assert-True (@($config.human_stop_classes) -notcontains 'DEVICE_UNREACHABLE') 'device unreachable must be recoverable'
Assert-True (@($config.human_stop_classes) -notcontains 'SSH_AUTH_FAILED') 'SSH auth failure must be recoverable'

$controller = Get-Content -Raw $controllerPath
Assert-Contains $controller '$ProductionConfig.human_stop_classes' 'legacy controller must still consume Production Agent hard safety classes for forensic compatibility'

$version = (Get-Content -Raw (Join-Path $Root 'VERSION')).Trim()
$buildEnv = Get-Content -Raw (Join-Path $Root 'build.env')
$arthurConfig = Get-Content -Raw (Join-Path $Root 'config/arthur.config')
Assert-True ($version -eq '0.1.3') 'VERSION must align with physical baseline 0.1.3'
Assert-Contains $buildEnv 'FIRMWARE_VERSION="0.1.3"' 'build.env firmware version must align with 0.1.3'
Assert-Contains $arthurConfig 'CONFIG_VERSION_NUMBER="0.1.3"' 'arthur.config version number must align with 0.1.3'

Write-Host 'REAL_DEVICE_BASELINE_CONTRACT=PASS'
Write-Host 'REAL_DEVICE_ACCESS_CLASSIFICATION_CONTRACT=PASS'
Write-Host 'REAL_DEVICE_BUILD_IDENTITY_CONTRACT=PASS'
Write-Host 'REAL_DEVICE_VERSION_ORDER_CONTRACT=PASS'
Write-Host 'REAL_DEVICE_SNAPSHOT_READ_ONLY_CONTRACT=PASS'