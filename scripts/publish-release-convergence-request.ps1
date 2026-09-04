param(
    [string]$EvidencePath = '',
    [string]$Repository = 'mxonline/xinzhaowrt',
    [string]$RequestPath = 'production/v3-request.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'fast-safe-release-lib.ps1')

if (-not $EvidencePath) {
    if ($env:LOCALAPPDATA) {
        $EvidencePath = Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\FeatureHandoff\release-convergence.json'
    } else {
        $EvidencePath = Join-Path $Root 'output/release-convergence/release-convergence.json'
    }
}

function Invoke-NativeChecked([string]$File,[string[]]$Arguments) {
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = @(& $File @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    if ($code -ne 0) { throw "$File failed ($code): $text" }
    return $text.Trim()
}

$evidence = Load-ReleaseConvergenceEvidence -Path $EvidencePath
if (-not $evidence) { throw "RELEASE_CONVERGENCE_EVIDENCE_MISSING=$EvidencePath" }

$requestRaw = Invoke-NativeChecked gh @(
    'api',
    "repos/$Repository/contents/$RequestPath`?ref=main",
    '-H','Accept: application/vnd.github.raw+json'
)
try { $request = $requestRaw | ConvertFrom-Json -Depth 30 }
catch { throw "V3_REQUEST_INVALID: $($_.Exception.Message)" }

foreach ($field in @('request_id','source_ref','source_sha','mode')) {
    if ($request.PSObject.Properties.Name -notcontains $field -or -not [string]$request.$field) {
        throw "V3_REQUEST_FIELD_MISSING=$field"
    }
}
$sourceRef = [string]$request.source_ref
$sourceSha = [string]$request.source_sha
if ($sourceSha -notmatch '^[0-9a-f]{40}$') { throw 'V3_REQUEST_SOURCE_SHA_INVALID' }

Invoke-NativeChecked git @('-C',$Root,'fetch','origin','--tags','--prune') | Out-Null
$resolved = Invoke-NativeChecked git @('-C',$Root,'rev-parse',"$sourceRef^{commit}")
if ($resolved -ne $sourceSha) { throw "V3_REQUEST_SOURCE_REF_MISMATCH expected=$sourceSha actual=$resolved" }

$fingerprint = Invoke-NativeChecked bash @((Join-Path $Root 'scripts/get-firmware-input-fingerprint.sh'),$sourceRef)
if ($fingerprint -notmatch '^[0-9a-f]{64}$') { throw "FIRMWARE_INPUT_FINGERPRINT_INVALID=$fingerprint" }
$dispatch = Get-ConvergenceDispatchInputs -Evidence $evidence -CurrentFirmwareInputFingerprint $fingerprint

$fields = [ordered]@{
    failure_set_state = [string]$dispatch.failure_set_state
    failure_set_fingerprint = [string]$dispatch.failure_set_fingerprint
    verification_contract_fingerprint = [string]$dispatch.verification_contract_fingerprint
    rootfs_offline_passed = [string]$dispatch.rootfs_offline_passed
    contract_gap_state = [string]$dispatch.contract_gap_state
    firmware_input_fingerprint = [string]$dispatch.firmware_input_fingerprint
}

$changed = $false
foreach ($entry in $fields.GetEnumerator()) {
    if ($request.PSObject.Properties.Name -notcontains $entry.Key) {
        Add-Member -InputObject $request -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
        $changed = $true
    } elseif ([string]$request.($entry.Key) -ne [string]$entry.Value) {
        $request.($entry.Key) = $entry.Value
        $changed = $true
    }
}

if (-not $changed) {
    Write-Host "CONVERGENCE_REQUEST=UNCHANGED request_id=$($request.request_id) source_ref=$sourceRef"
    exit 0
}

$json = ($request | ConvertTo-Json -Depth 30) + "`n"
$blobSha = Invoke-NativeChecked gh @('api',"repos/$Repository/contents/$RequestPath`?ref=main",'--jq','.sha')
if ($blobSha -notmatch '^[0-9a-f]{40}$') { throw "V3_REQUEST_BLOB_SHA_INVALID=$blobSha" }
$base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
$commitSha = Invoke-NativeChecked gh @(
    'api','--method','PUT',"repos/$Repository/contents/$RequestPath",
    '-f',"message=chore: bind $($request.request_id) to resolved convergence evidence",
    '-f',"content=$base64",
    '-f',"sha=$blobSha",
    '-f','branch=main',
    '--jq','.commit.sha'
)
if ($commitSha -notmatch '^[0-9a-f]{40}$') { throw "CONVERGENCE_REQUEST_COMMIT_INVALID=$commitSha" }

Write-Host "CONVERGENCE_REQUEST=PASS request_id=$($request.request_id) source_ref=$sourceRef commit=$commitSha"
Write-Host "failure_set_state=$($fields.failure_set_state)"
Write-Host "failure_set_fingerprint=$($fields.failure_set_fingerprint)"
Write-Host "verification_contract_fingerprint=$($fields.verification_contract_fingerprint)"
Write-Host "rootfs_offline_passed=$($fields.rootfs_offline_passed)"
Write-Host "contract_gap_state=$($fields.contract_gap_state)"
Write-Host "firmware_input_fingerprint=$($fields.firmware_input_fingerprint)"
