$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BootstrapPath = Join-Path $Root 'scripts\bootstrap-arthur-host-key.ps1'
$LibPath = Join-Path $Root 'scripts\real-device-baseline-lib.ps1'
$AgentPath = Join-Path $Root 'scripts\production-agent.ps1'
$ConfigPath = Join-Path $Root 'production\production-agent.json'
$WorkflowPath = Join-Path $Root '.github\workflows\arthur-host-key-bootstrap.yml'
$BuildEnvPath = Join-Path $Root 'build.env'

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

Assert-True (Test-Path $BootstrapPath) 'safe Arthur host-key bootstrap script must exist'
Assert-True (Test-Path $WorkflowPath) 'recurring Arthur host-key bootstrap workflow must exist'
Assert-True (Test-Path $BuildEnvPath) 'build.env must remain the authority for initial credentials'

. $LibPath
Assert-True ([string](Classify-ArthurSshProbe -ExitCode 255 -Output 'Host key verification failed.') -eq 'SSH_HOST_KEY_UNTRUSTED') 'generic first-use host-key failure must not impersonate a changed-key mismatch'
Assert-True ([string](Classify-ArthurSshProbe -ExitCode 255 -Output 'WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! Offending ED25519 key') -eq 'SSH_HOST_IDENTITY_MISMATCH') 'explicit changed/offending host key must remain a hard safety mismatch'

$buildEnv = Get-Content -Raw $BuildEnvPath
Assert-Contains $buildEnv 'DEFAULT_ROOT_PASSWORD=' 'initial password must be sourced from build.env rather than duplicated in bootstrap logic'

$bootstrap = Get-Content -Raw $BootstrapPath
foreach ($needle in @(
    '/luci-static/xinzhao/build-info.json',
    'Test-ArthurBuildInfoMatchesBaseline',
    'ssh-keygen.exe',
    'UserKnownHostsFile',
    'StrictHostKeyChecking=$StrictMode',
    "-StrictMode 'accept-new'",
    'Test-ArthurBoardIdentity',
    'ubus call system board',
    'SSH_HOST_KEY_ALREADY_TRUSTED=PASS',
    'SSH_HOST_KEY_BOOTSTRAP=PASS'
)) {
    Assert-Contains $bootstrap $needle "bootstrap contract requires $needle"
}
Assert-Contains $bootstrap 'SSH_HOST_IDENTITY_MISMATCH' 'existing known-host conflicts must fail closed'
Assert-Contains $bootstrap 'SSH_AUTH_FAILED' 'authentication failure must remain recoverable and must not enroll a host key without authenticated evidence'
Assert-Contains $bootstrap 'REAL_DEVICE_BASELINE_BUILD_MISMATCH' 'live build mismatch must stop host-key enrollment'
Assert-True (-not $bootstrap.Contains('StrictHostKeyChecking=no')) 'bootstrap must never disable SSH host-key verification'
Assert-True (-not $bootstrap.Contains('ssh-keygen.exe -R')) 'bootstrap must never delete an existing host key automatically'
Assert-True (-not $bootstrap.Contains('Remove-Item $knownHosts')) 'bootstrap must never delete the full known_hosts file'

# The development Runner must be able to bootstrap its own key non-interactively
# from the project's known first-login credential, then return to strict key auth.
foreach ($needle in @(
    'DEFAULT_ROOT_PASSWORD',
    'SSH_ASKPASS',
    'SSH_ASKPASS_REQUIRE',
    'XINZHAO_SSH_BOOTSTRAP_PASSWORD',
    'PreferredAuthentications=password',
    'PubkeyAuthentication=no',
    'NumberOfPasswordPrompts=1',
    'id_ed25519',
    '/etc/dropbear/authorized_keys',
    'BatchMode=yes',
    "-StrictMode 'yes'",
    'SSH_AUTH_BOOTSTRAP=PASS'
)) {
    Assert-Contains $bootstrap $needle "SSH auth bootstrap contract requires $needle"
}
Assert-True (-not $bootstrap.Contains('plink.exe -pw')) 'password must never be exposed on a process command line'
Assert-True (-not $bootstrap.Contains('sshpass -p')) 'password must never be exposed on a process command line'

$workflow = Get-Content -Raw $WorkflowPath
foreach ($needle in @(
    'self-hosted',
    'windows',
    'x64',
    'xinzhaowrt-controller',
    "cron: '*/15 * * * *'",
    'bootstrap-arthur-host-key.ps1',
    'production/real-device-baseline.json'
)) {
    Assert-Contains $workflow $needle "bootstrap workflow requires $needle"
}

$agent = Get-Content -Raw $AgentPath
Assert-Contains $agent 'SSH_HOST_IDENTITY_MISMATCH' 'Production Agent must preserve the hard changed-key stop'

$config = Get-Content -Raw $ConfigPath | ConvertFrom-Json
Assert-True (@($config.human_stop_classes) -contains 'SSH_HOST_IDENTITY_MISMATCH') 'changed host identity must remain a human safety stop'
Assert-True (@($config.human_stop_classes) -notcontains 'SSH_HOST_KEY_UNTRUSTED') 'first-use unknown key must not be frozen before the evidence-gated bootstrap workflow can run'

Write-Host 'ARTHUR_HOST_KEY_CLASSIFICATION_CONTRACT=PASS'
Write-Host 'ARTHUR_HOST_KEY_BOOTSTRAP_CONTRACT=PASS'
Write-Host 'ARTHUR_SSH_AUTH_BOOTSTRAP_CONTRACT=PASS'
