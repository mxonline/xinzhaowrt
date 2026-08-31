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
$installPath = Join-Path $Root 'scripts/install-production-agent.ps1'
$deployPath = Join-Path $Root '.github/workflows/production-agent-deploy.yml'
$configPath = Join-Path $Root 'production/production-agent.json'
$flashProfilePath = Join-Path $Root 'production/arthur-flash-profile.json'

$agent = Get-Content -Raw $agentPath
$fetch = Get-Content -Raw $fetchPath
$gate = Get-Content -Raw $gatePath
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

Assert-Contains $fetch 'NEW_CREDENTIAL_PROVISIONING' 'artifact fetch must classify invalid GitHub credentials explicitly'
Assert-Contains $fetch 'gh auth status' 'artifact fetch must use authenticated GitHub CLI credential store'
Assert-Contains $fetch 'gh run download' 'artifact fetch must use immutable GitHub Actions artifact download path'
Assert-Contains $fetch 'Get-FileHash' 'artifact fetch must calculate local SHA256'
Assert-Contains $fetch 'ARTIFACT_BYTES_VERIFIED' 'artifact fetch must persist verified byte state'

Assert-Contains $agent 'ci-controller-v3.ps1' 'failed builds must reuse the existing Codex repair controller'
Assert-Contains $agent 'AUTO_FLASH_SAFETY_GATE=PASS' 'agent must require safety gate before flash'
Assert-Contains $agent 'real-device-verify' 'agent must reuse existing real-device verification'
Assert-Contains $agent 'PRODUCTION_RELEASED=YES' 'agent must expose the sole production terminal state'

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

Assert-Contains $install 'Register-ScheduledTask' 'installation must create a Scheduled Task'
Assert-Contains $install 'LogonTrigger' 'Scheduled Task must start in current-user logon context'
Assert-Contains $install '$env:USERDOMAIN' 'Scheduled Task principal must come from current interactive user'
Assert-Contains $install 'PowerShell/PowerShell' 'installer must be able to bootstrap official portable PowerShell when pwsh is absent'
Assert-True ($install -notmatch '(?i)-UserId\s+["'']?(SYSTEM|LocalSystem)["'']?') 'authenticated production agent must not run as SYSTEM/LocalSystem'
Assert-True ($install -notmatch '(?i)NT AUTHORITY\\SYSTEM') 'authenticated production agent must not run as NT AUTHORITY\SYSTEM'

# Deployment already has a successfully checked-out main worktree. It must not
# introduce a second GitHub clone/fetch boundary just to create the stable Agent
# runtime, because transient TLS failures there used to abort unattended deploys.
Assert-Contains $deploy '$env:GITHUB_WORKSPACE' 'deploy must source the persistent runtime from the already checked-out workspace'
Assert-True ($deploy -notmatch '(?im)^\s*git\s+clone\b') 'deploy must not perform a second network git clone'
Assert-True ($deploy -notmatch '(?im)^\s*git\s+-C\s+\$runtime\s+fetch\s+origin\b') 'deploy must not perform a second network git fetch during runtime sync'

Write-Host 'AUTO_ARTIFACT_FETCH_CONTRACT=PASS'
Write-Host 'AUTO_REMEDIATION_CONTRACT=PASS'
Write-Host 'AUTO_FLASH_POLICY_CONTRACT=PASS'
Write-Host 'PRODUCTION_AGENT_RESUME_CONTRACT=PASS'
Write-Host 'PRODUCTION_AGENT_LOCAL_SYNC_CONTRACT=PASS'
