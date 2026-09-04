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

$requiredFiles = @(
    'scripts/production-agent.ps1',
    'scripts/fetch-production-artifact.ps1',
    'scripts/auto-flash-safety-gate.ps1',
    'scripts/ci-controller-v3.ps1',
    'scripts/install-production-agent.ps1',
    'scripts/uninstall-production-agent.ps1',
    'scripts/start-production-agent.ps1',
    'scripts/production-agent-status.ps1',
    'production/production-agent.json',
    'production/arthur-flash-profile.json',
    '.github/workflows/production-agent-deploy.yml'
)

foreach ($relative in $requiredFiles) {
    Assert-True (Test-Path (Join-Path $Root $relative)) "required production automation file missing: $relative"
}

$agentPath = Join-Path $Root 'scripts/production-agent.ps1'
$fetchPath = Join-Path $Root 'scripts/fetch-production-artifact.ps1'
$gatePath = Join-Path $Root 'scripts/auto-flash-safety-gate.ps1'
$controllerPath = Join-Path $Root 'scripts/ci-controller-v3.ps1'
$installPath = Join-Path $Root 'scripts/install-production-agent.ps1'
$deployPath = Join-Path $Root '.github/workflows/production-agent-deploy.yml'
$configPath = Join-Path $Root 'production/production-agent.json'
$flashProfilePath = Join-Path $Root 'production/arthur-flash-profile.json'

$agent = Get-Content -Raw $agentPath
$fetch = Get-Content -Raw $fetchPath
$gate = Get-Content -Raw $gatePath
$controller = Get-Content -Raw $controllerPath
$install = Get-Content -Raw $installPath
$deploy = Get-Content -Raw $deployPath
$config = Get-Content -Raw $configPath | ConvertFrom-Json
$flashProfile = Get-Content -Raw $flashProfilePath | ConvertFrom-Json

foreach ($mode in @('Resume','Status','RunOnce')) {
    Assert-Contains $agent $mode "production agent must expose mode $mode"
}

foreach ($stage in @(
    'ARTIFACT_METADATA_VERIFIED',
    'ARTIFACT_BYTES_VERIFIED',
    'CANDIDATE_VERIFIED',
    'AUTO_FLASH_SAFETY_GATE',
    'WAIT_DEVICE',
    'REAL_DEVICE_VERIFY',
    'PRODUCTION_RELEASED'
)) {
    Assert-Contains $agent $stage "production agent missing durable stage $stage"
}

Assert-Contains $fetch 'NEW_CREDENTIAL_PROVISIONING' 'artifact fetch must classify genuinely unavailable GitHub credentials explicitly'
Assert-Contains $fetch 'gh run download' 'artifact fetch must use immutable GitHub Actions artifact download path'
Assert-Contains $fetch 'Get-FileHash' 'artifact fetch must calculate local SHA256'
Assert-Contains $fetch 'ARTIFACT_BYTES_VERIFIED' 'artifact fetch must persist verified byte state'
Assert-Contains $fetch 'Arthur-v3-Candidate-' 'artifact fetch must discover the production Candidate artifact from the live run instead of a stale bootstrap artifact'
Assert-Contains $fetch 'headSha' 'artifact fetch must derive source SHA from the live GitHub run'

Assert-Contains $agent 'ci-controller-v3.ps1' 'legacy production agent repair code must remain available for forensic compatibility'
Assert-Contains $agent 'AUTO_FLASH_SAFETY_GATE=PASS' 'agent must require safety gate before flash'
Assert-Contains $agent 'real-device-verify' 'agent must reuse existing real-device verification'
Assert-Contains $agent 'PRODUCTION_RELEASED=YES' 'agent must expose the sole production terminal state'
Assert-Contains $agent "Invoke-Process 'gh' @('api'" 'production agent must verify credentials by a real GitHub API request'
Assert-Contains $agent 'repos/$([string]$Config.repository)' 'production agent GitHub API probe must target the configured repository'
Assert-True ($agent -notmatch "(?m)Invoke-Process\s+'gh'\s+@\('auth','status'") 'production agent must not hard-stop on gh auth status when a machine credential can still perform API calls'

Assert-True ($agent -notmatch 'function\s+Invoke-Process\(\[string\]\$File,\[string\[\]\]\$Args') 'Invoke-Process must not bind native arguments through automatic variable $args'
Assert-Contains $agent '[string[]]$ProcessArgs' 'Invoke-Process must use an explicit non-automatic argument parameter'
Assert-Contains $agent '@ProcessArgs' 'Invoke-Process must splat the explicit process argument array'

Assert-Contains $agent '$Known.rollback.target' 'rollback download must use production/known-good.json rollback.target'
Assert-Contains $agent '$Known.rollback.firmware' 'rollback download must use production/known-good.json rollback.firmware'
Assert-Contains $agent '$Known.rollback.sha256' 'rollback integrity check must use production/known-good.json rollback.sha256'

Assert-Contains $agent 'DEVICE_IDENTITY_RETRYABLE' 'temporary SSH/device unreachability must re-enter the unattended loop'
Assert-Contains $agent 'DEVICE_PROBE_RETRY' 'device probe failures must preserve diagnostic evidence for automatic retries'
Assert-Contains $agent 'REMOTE HOST IDENTIFICATION HAS CHANGED' 'host-key identity anomalies must remain a hard safety stop'
Assert-True ($agent -notmatch 'Save-State\s+\$State\s+\(\[string\]\$State\.stage\)\s+''BLOCKED''\s+''No verified Arthur device found at expected/recovery addresses\.''') 'mere device unreachability must not be promoted directly to BLOCKED'

Assert-Contains $controller 'production-agent.ps1' 'legacy controller compatibility path must still be internally coherent'
Assert-Contains $controller 'PRODUCTION_RELEASED' 'controller must follow the release chain to the sole terminal state'
Assert-Contains $controller 'RECOVERABLE_CODEX_TIMEOUT' 'Codex timeout must be classified as recoverable and re-enter the loop'
Assert-True ($controller -notmatch 'Next hard gate is manual flash plus real-device verification') 'controller must not stop at Candidate publication waiting for manual flash'
Assert-True ($controller -notmatch 'throw "BLOCKED: Codex repair timed out') 'Codex timeout must not become a terminal BLOCKED state'

Assert-Contains $gate 'jdcloud_re-ss-01' 'safety gate must bind Arthur profile'
Assert-Contains $gate '192.168.6.1' 'safety gate must bind expected Arthur LAN'
Assert-Contains $gate 'rollback' 'safety gate must verify rollback evidence'
Assert-Contains $gate 'remote_sha256' 'safety gate must require remote SHA256 evidence'

Assert-True ([string]$config.repository -eq 'mxonline/xinzhaowrt') 'production agent repository must be mxonline/xinzhaowrt'
Assert-True ([string]$config.device -eq 'jdcloud_re-ss-01') 'production agent device must be jdcloud_re-ss-01'
Assert-True ([string]$config.expected_lan -eq '192.168.6.1') 'production agent expected LAN must remain 192.168.6.1'
Assert-True ([int]$config.luci_http_port -eq 80) 'LuCI public HTTP port must remain 80'
Assert-True ([string]$config.default_language -eq 'zh_cn') 'default LuCI language must remain zh_cn'
Assert-True ([string]$config.default_theme -eq 'argon') 'Argon must remain default theme'
Assert-True ([string]$config.secondary_theme -eq 'kucat') 'Kucat must remain second theme'
Assert-True ([int]$config.required_plugin_count -eq 22) 'required plugin count must remain 22'
Assert-True ($config.adguardhome_default_enabled -eq $false) 'AdGuardHome must remain disabled by default'
Assert-True (@($config.human_stop_classes) -notcontains 'NEW_CREDENTIAL_PROVISIONING') 'credential renewal/recovery must remain automatic rather than a human stop class'

Assert-True ([string]$flashProfile.device -eq 'jdcloud_re-ss-01') 'flash profile must bind Arthur device'
Assert-True ([string]$flashProfile.transport -eq 'windows-openssh') 'flash transport must be Windows OpenSSH'
Assert-True ([string]$flashProfile.remote_upgrade_binary -eq '/sbin/sysupgrade') 'flash profile must use standard sysupgrade binary'
Assert-True ($flashProfile.verified -eq $true) 'flash profile must be explicitly marked historically verified before automatic flash'
Assert-True ([string]$flashProfile.verification_evidence -ne '') 'flash profile must name verification evidence'
Assert-True ([string]$flashProfile.argument_template -ne '') 'flash profile must encode an explicit verified argument template'

$automaticPath = ($agent + "`n" + $gate + "`n" + $fetch).ToLowerInvariant()
foreach ($forbidden in @(' mtd ', 'mtd write', ' nandwrite', 'uboot', 'u-boot write', ' raw_emmc', ' raw spi', ' raw nand')) {
    Assert-True (-not $automaticPath.Contains($forbidden)) "automatic path contains forbidden raw flash token: $forbidden"
}
Assert-True ($automaticPath -notmatch '(?m)(^|[;&|]\s*)dd\s+if=') 'automatic path must not execute dd raw writes'

Assert-Contains $install 'Register-ScheduledTask' 'legacy installer must remain parseable for rollback/forensics'
Assert-Contains $install 'PowerShell/PowerShell' 'legacy installer must be able to bootstrap official portable PowerShell when inspected'
Assert-Contains $install "gh api repos/mxonline/xinzhaowrt" 'legacy installer credential probe must remain explicit'

# Active unattended topology: GitHub schedule -> dedicated self-hosted runner -> persistent workspace -> Arthur Control Plane -> ai_orchestrator.
Assert-Contains $deploy "cron: '*/5 * * * *'" 'runner wakeup must execute every five minutes'
Assert-Contains $deploy 'xinzhaowrt-controller' 'runner wakeup must use the dedicated self-hosted controller label'
Assert-Contains $deploy "XinZhaoWrt\ControlPlane" 'runner wakeup must use the canonical Control Plane root'
Assert-Contains $deploy "Join-Path $root 'workspace'" 'runner wakeup must preserve a persistent source workspace under the canonical root'
Assert-Contains $deploy 'CONTROL_PLANE_WORKSPACE_DIRTY=PRESERVED' 'dirty headless source changes must survive the next schedule'
Assert-Contains $deploy 'merge --ff-only' 'clean persistent main may only fast-forward'
Assert-Contains $deploy '$env:GITHUB_WORKSPACE = $env:ARTHUR_CONTROL_PLANE_WORKSPACE' 'resume-state, baseline and Headless Codex must execute against the persistent workspace'
Assert-Contains $deploy 'scripts\arthur-control-plane.ps1' 'runner wakeup must invoke the Arthur Control Plane directly'
Assert-True ($deploy -notmatch '(?i)actions/checkout@v4') 'active unattended wakeup must not replace the persistent source with an ephemeral checkout'
Assert-True ($deploy -notmatch '(?i)reset --hard') 'active wakeup must not destroy unfinished Headless Codex changes'
Assert-True ($deploy -notmatch '(?i)git clean') 'active wakeup must not clean unfinished Headless Codex changes'
Assert-True ($deploy -notmatch '(?i)LogonType\s+Interactive') 'active wakeup must not depend on interactive Windows logon'
Assert-True ($deploy -notmatch '(?i)XinZhaoWrt-Arthur-v3-Controller') 'active wakeup must not launch the legacy v3 Scheduled Task'
Assert-True ($deploy -notmatch '(?i)install-production-agent\.ps1') 'active wakeup must not install the legacy Production Agent Scheduled Task'
Assert-True ($deploy -notmatch '(?i)recover-existing-bridge-context\.ps1') 'active wakeup must not recover the GUI Codex user context'
Assert-True ($deploy -notmatch '(?i)PRODUCTION_AGENT_AUTHENTICATED_CONTINUATION') 'active wakeup must not contain the legacy ten-minute continuation loop'

Write-Host 'AUTO_ARTIFACT_FETCH_CONTRACT=PASS'
Write-Host 'AUTO_REMEDIATION_CONTRACT=PASS'
Write-Host 'AUTO_FLASH_POLICY_CONTRACT=PASS'
Write-Host 'PRODUCTION_AGENT_LEGACY_SAFETY_CONTRACT=PASS'
Write-Host 'RUNNER_CONTROL_PLANE_WAKEUP_CONTRACT=PASS'
