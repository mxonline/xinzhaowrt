param(
    [Parameter(Mandatory=$true)][string]$CandidateManifest,
    [Parameter(Mandatory=$true)][string]$SnapshotPath,
    [ValidateSet('forward','rollback')][string]$Operation = 'forward',
    [string]$BaselinePath = '',
    [string]$ExpectedDiffPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'real-device-baseline-lib.ps1')

if (-not $BaselinePath) { $BaselinePath = Join-Path $Root 'production\real-device-baseline.json' }
if (-not $ExpectedDiffPath) { $ExpectedDiffPath = Join-Path $Root 'production\expected-diff.json' }

function Fail([string]$Code,[string]$Message) {
    Write-Error "$Code $Message"
    exit 52
}

foreach ($path in @($CandidateManifest,$SnapshotPath,$BaselinePath,$ExpectedDiffPath)) {
    if (-not (Test-Path $path)) { Fail 'REAL_DEVICE_BASELINE_EVIDENCE_MISSING' "Missing required evidence: $path" }
}

$Candidate = Get-Content -Raw $CandidateManifest | ConvertFrom-Json
$Snapshot = Get-Content -Raw $SnapshotPath | ConvertFrom-Json
$Baseline = Get-Content -Raw $BaselinePath | ConvertFrom-Json
$Expected = Get-Content -Raw $ExpectedDiffPath | ConvertFrom-Json

if ([string]$Snapshot.result -ne 'DEVICE_VERIFIED' -or $Snapshot.machine_verified -ne $true) {
    Fail 'REAL_DEVICE_BASELINE_NOT_MACHINE_VERIFIED' 'Read-only physical device snapshot is not machine-verified.'
}
if ([string]$Snapshot.device.board -notmatch '(?i)jdcloud,re-ss-01|JDCloud\s+RE-SS-01|RE-SS-01') {
    Fail 'DEVICE_IDENTITY_MISMATCH' 'Snapshot board evidence is not the designated Arthur.'
}
if ([string]$Baseline.device.profile -ne 'jdcloud_re-ss-01' -or [string]$Baseline.device.target -ne 'qualcommax/ipq60xx') {
    Fail 'REAL_DEVICE_BASELINE_INVALID' 'Committed baseline does not bind the Arthur target/profile.'
}
if ([string]$Candidate.profile -ne [string]$Baseline.device.profile) {
    Fail 'BASELINE_INHERITANCE_PROFILE_MISMATCH' "Candidate profile $($Candidate.profile) differs from baseline $($Baseline.device.profile)."
}
if ([string]$Candidate.target -ne [string]$Baseline.device.target) {
    Fail 'BASELINE_INHERITANCE_TARGET_MISMATCH' "Candidate target $($Candidate.target) differs from baseline $($Baseline.device.target)."
}

$candidateVersionText = ''
if ($Candidate.PSObject.Properties.Name -contains 'version') { $candidateVersionText = [string]$Candidate.version }
if (-not $candidateVersionText -and $Candidate.PSObject.Properties.Name -contains 'candidate_path') { $candidateVersionText = [string]$Candidate.candidate_path }
$candidateVersion = Get-ArthurVersionFromText $candidateVersionText
$baselineVersion = [string]$Baseline.firmware.version
if (-not $candidateVersion) { Fail 'CANDIDATE_VERSION_UNKNOWN' "Unable to derive Candidate version from '$candidateVersionText'." }
if (-not (Test-ArthurVersionOperation -CandidateVersion $candidateVersion -BaselineVersion $baselineVersion -Operation $Operation)) {
    Fail 'CANDIDATE_VERSION_OLDER_THAN_REAL_DEVICE_BASELINE' "Normal Candidate $candidateVersion cannot replace physical baseline $baselineVersion."
}

$required = @(Get-Content (Join-Path $Root 'config\required-plugins.txt') | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() })
if ($required.Count -ne [int]$Baseline.protected_product_state.required_plugin_count) {
    Fail 'BASELINE_INHERITANCE_PLUGIN_COUNT_MISMATCH' "Required plugin list has $($required.Count) entries; baseline requires $($Baseline.protected_product_state.required_plugin_count)."
}
$arthurConfig = Get-Content -Raw (Join-Path $Root 'config\arthur.config')
foreach ($plugin in $required) {
    if ($arthurConfig -notmatch "(?m)^CONFIG_PACKAGE_$([regex]::Escape($plugin))=y$") {
        Fail 'BASELINE_INHERITANCE_PLUGIN_MISSING' "Protected plugin missing from config: $plugin"
    }
}
foreach ($theme in @($Baseline.protected_product_state.required_themes)) {
    if ($arthurConfig -notmatch "(?m)^CONFIG_PACKAGE_luci-theme-$([regex]::Escape([string]$theme))=y$") {
        Fail 'BASELINE_INHERITANCE_THEME_MISSING' "Protected theme missing from config: $theme"
    }
}

$buildEnv = Get-Content -Raw (Join-Path $Root 'build.env')
$expectedLan = [regex]::Escape([string]$Baseline.protected_product_state.lan_ipv4)
if ($buildEnv -notmatch "(?m)^DEFAULT_LAN_IP=\"$expectedLan\"$") {
    Fail 'BASELINE_INHERITANCE_LAN_MISMATCH' 'Project LAN default no longer matches the physical baseline contract.'
}

if ([string]$Expected.status -eq 'MIGRATION_LOCKED') {
    Fail 'EXPECTED_DIFF_MIGRATION_LOCKED' 'Migration safety lock is active. A future task must declare an explicit expected diff before a new Candidate may write the router.'
}
if ([string]$Expected.status -ne 'READY') {
    Fail 'EXPECTED_DIFF_NOT_READY' "Expected diff status is '$($Expected.status)'."
}

Write-Host "REAL_DEVICE_BASELINE_GATE=PASS baseline_version=$baselineVersion candidate_version=$candidateVersion operation=$Operation"
Write-Host 'BASELINE_INHERITANCE_GATE=PASS'
Write-Host 'EXPECTED_DIFF_GATE=PASS'
