[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RequestPath,
    [long]$PreviousRunId = 38087541420
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-ArthurPriorProductGoalRun {
    param(
        [Parameter(Mandatory=$true)]$Run,
        [Parameter(Mandatory=$true)]$Jobs,
        [long]$ExpectedRunId = 38087541420
    )

    if ([long]$Run.id -ne $ExpectedRunId) { throw 'PRIOR_RUN_ID_MISMATCH' }
    if ([string]$Run.name -ne 'Arthur v0.1.6 Post-Release Device Test') { throw 'PRIOR_RUN_NAME_MISMATCH' }
    if ([string]$Run.path -notmatch '(^|/)arthur-post-release-device-test\.yml(@|$)') { throw 'PRIOR_RUN_WORKFLOW_MISMATCH' }
    if ([string]$Run.event -ne 'workflow_dispatch' -or [string]$Run.head_branch -ne 'main') { throw 'PRIOR_RUN_DISPATCH_IDENTITY_MISMATCH' }
    if ([string]$Run.head_sha -ne '9e792932fc4e56851fd526653b42da79c48adb4c') { throw 'PRIOR_RUN_SOURCE_COMMIT_MISMATCH' }
    if ([string]$Run.status -ne 'completed' -or [string]$Run.conclusion -ne 'failure') { throw 'PRIOR_RUN_TERMINAL_MISMATCH' }

    if ([int]$Jobs.total_count -ne 1) { throw 'PRIOR_RUN_JOB_COUNT_MISMATCH' }
    $job = @($Jobs.jobs | Where-Object { [string]$_.name -eq 'exact-release-device-test' }) | Select-Object -First 1
    if (-not $job -or [string]$job.status -ne 'completed' -or [string]$job.conclusion -ne 'failure') {
        throw 'PRIOR_RUN_JOB_TERMINAL_MISMATCH'
    }
    $flashStep = @($job.steps | Where-Object { [string]$_.name -eq 'Execute exact-release flash and base/file-management acceptance' }) | Select-Object -First 1
    if (-not $flashStep -or [string]$flashStep.conclusion -ne 'skipped') { throw 'FLASH_STEP_NOT_SKIPPED' }
    $postFlashStep = @($job.steps | Where-Object { [string]$_.name -eq 'Execute strictly no-flash PostFlash resume' }) | Select-Object -First 1
    if (-not $postFlashStep -or [string]$postFlashStep.conclusion -ne 'success') { throw 'POSTFLASH_RESUME_NOT_PASS' }
    $persistStep = @($job.steps | Where-Object { [string]$_.name -eq 'Persist independent post-release machine evidence locally' }) | Select-Object -First 1
    if (-not $persistStep -or [string]$persistStep.conclusion -ne 'success') { throw 'POSTFLASH_EVIDENCE_PERSISTENCE_NOT_PASS' }
    $productStep = @($job.steps | Where-Object { [string]$_.name -eq 'Execute exact-release highest product-goal runtime validation' }) | Select-Object -First 1
    if (-not $productStep -or [string]$productStep.conclusion -ne 'failure') { throw 'PRIOR_PRODUCT_GOAL_FAILURE_NOT_CONFIRMED' }
    return $true
}

function Assert-ArthurPostFlashEvidenceBinding {
    param(
        [Parameter(Mandatory=$true)]$Request,
        [Parameter(Mandatory=$true)]$BaseEvidence,
        [Parameter(Mandatory=$true)]$FileEvidence
    )

    if ([string]$BaseEvidence.result -ne 'PASS' -or [string]$BaseEvidence.mode -ne 'PostFlash') { throw 'POSTFLASH_BASE_EVIDENCE_NOT_PASS' }
    if ([string]$BaseEvidence.candidate -ne [string]$Request.candidate_tag) { throw 'BASE_EVIDENCE_CANDIDATE_MISMATCH' }
    if ([string]$BaseEvidence.commit -ne [string]$Request.source_sha) { throw 'BASE_EVIDENCE_SOURCE_SHA_MISMATCH' }
    if ([string]$BaseEvidence.device.model -ne 'JDCloud RE-SS-01' -or
        [string]$BaseEvidence.device.target -ne 'jdcloud_re-ss-01' -or
        [string]$BaseEvidence.device.address -ne [string]$Request.management_ip -or
        [string]$BaseEvidence.device.lan -ne '192.168.6.1') {
        throw 'BASE_EVIDENCE_DEVICE_IDENTITY_MISMATCH'
    }

    if ([string]$FileEvidence.status -ne 'PASS') { throw 'FILE_MANAGEMENT_EVIDENCE_NOT_PASS' }
    if ([string]$FileEvidence.release_tag -ne [string]$Request.release_tag) { throw 'RELEASE_TAG_MISMATCH' }
    if ([string]$FileEvidence.candidate_tag -ne [string]$Request.candidate_tag) { throw 'CANDIDATE_TAG_MISMATCH' }
    if ([string]$FileEvidence.source_sha -ne [string]$Request.source_sha) { throw 'SOURCE_SHA_MISMATCH' }
    if ([long]$FileEvidence.build_run_id -ne [long]$Request.build_run_id) { throw 'BUILD_RUN_ID_MISMATCH' }
    if ([long]$FileEvidence.artifact_id -ne [long]$Request.artifact_id) { throw 'ARTIFACT_ID_MISMATCH' }
    if ([string]$FileEvidence.actions_artifact_sha256 -ne [string]$Request.actions_artifact_sha256) { throw 'ACTIONS_ARTIFACT_SHA256_MISMATCH' }
    if ([string]$FileEvidence.sysupgrade_sha256 -ne [string]$Request.sysupgrade_sha256) { throw 'SYSUPGRADE_SHA256_MISMATCH' }
    if ([string]$FileEvidence.device_build_id -ne [string]$Request.build_run_id) { throw 'DEVICE_BUILD_ID_MISMATCH' }

    $requiredMarkers = [ordered]@{
        DEVICE_EXACT_ARTIFACT_MATCH='PASS'
        POSTFLASH_BASE_VERIFICATION='PASS'
        REBOOT_PERSISTENCE='PASS'
        QUICKSTART_LINKEASE_FILE_MANAGER='PASS'
        LINKEASE_MMCBLK0P27_BROWSE='PASS'
        QUICKFILE_BACKEND='PASS'
        QUICKFILE_UI='PASS'
        NO_FILE_MANAGEMENT_404_502='PASS'
        WAN_8897_RULE_ADDED='NO'
        LINKEASE_ALLOW_PUBLIC='0'
    }
    foreach ($name in $requiredMarkers.Keys) {
        $property = $FileEvidence.markers.PSObject.Properties[$name]
        if ($null -eq $property -or [string]$property.Value -ne [string]$requiredMarkers[$name]) {
            throw "REQUIRED_PRIOR_MARKER_NOT_PASS=$name"
        }
    }
    return $true
}

function Get-ArthurProductGoalResumeApiJson {
    param([Parameter(Mandatory=$true)][string]$Uri)
    $token = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { $env:GITHUB_TOKEN } else { $env:GH_TOKEN }
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'GITHUB_API_AUTH_REQUIRED' }
    $headers = @{
        Authorization = "Bearer $token"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'xinzhaowrt-post-release-resume'
    }
    try { return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -TimeoutSec 30 }
    catch { throw 'PRIOR_RUN_METADATA_UNAVAILABLE' }
}

if ($PreviousRunId -ne 38087541420) { throw 'UNAPPROVED_PRIOR_RUN_ID' }
$Request = Get-Content -Raw -LiteralPath $RequestPath | ConvertFrom-Json
if ([string]$Request.release_tag -ne 'v0.1.6' -or
    [string]$Request.source_sha -ne 'b4448e62ab1e767f9a60221b0600c60c355baf56' -or
    [long]$Request.build_run_id -ne 38000704263 -or
    [long]$Request.artifact_id -ne 11655711894 -or
    [string]$Request.sysupgrade_sha256 -ne 'e175fc88d32ea9308aab40b84fbcc8e84a6bf3dc32bbe7e3a17894361cc89b39' -or
    [string]$Request.management_mac -ne 'dc:d8:7c:45:91:99') {
    throw 'PRODUCT_GOAL_RESUME_REQUEST_IDENTITY_MISMATCH'
}

$apiBase = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_API_URL)) { $env:GITHUB_API_URL.TrimEnd('/') } else { 'https://api.github.com' }
$repo = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) { $env:GITHUB_REPOSITORY } else { 'mxonline/xinzhaowrt' }
if ($repo -ne 'mxonline/xinzhaowrt') { throw 'GITHUB_REPOSITORY_IDENTITY_MISMATCH' }
$priorRunUri = "$apiBase/repos/$repo/actions/runs/$PreviousRunId"
$priorJobsUri = "$apiBase/repos/$repo/actions/runs/$PreviousRunId/jobs?per_page=100"
$priorRun = Get-ArthurProductGoalResumeApiJson -Uri $priorRunUri
$priorJobs = Get-ArthurProductGoalResumeApiJson -Uri $priorJobsUri
Assert-ArthurPriorProductGoalRun -Run $priorRun -Jobs $priorJobs -ExpectedRunId $PreviousRunId | Out-Null

$evidenceDirectory = Join-Path $env:LOCALAPPDATA "XinZhaoWrt\PostReleaseDeviceTest\run-$PreviousRunId\evidence"
if (-not (Test-Path -LiteralPath $evidenceDirectory -PathType Container)) { throw 'POSTFLASH_EVIDENCE_DIRECTORY_MISSING' }
$basePath = Join-Path $evidenceDirectory 'real-device-verification.json'
$filePath = Join-Path $evidenceDirectory 'v016-file-management-postflash.json'
if (-not (Test-Path -LiteralPath $basePath -PathType Leaf) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
    throw 'POSTFLASH_EXACT_EVIDENCE_MISSING'
}
try {
    $baseEvidence = Get-Content -Raw -LiteralPath $basePath | ConvertFrom-Json -Depth 30
    $fileEvidence = Get-Content -Raw -LiteralPath $filePath | ConvertFrom-Json -Depth 30
}
catch { throw 'POSTFLASH_EXACT_EVIDENCE_INVALID_JSON' }
Assert-ArthurPostFlashEvidenceBinding -Request $Request -BaseEvidence $baseEvidence -FileEvidence $fileEvidence | Out-Null

$outputDirectory = Join-Path $Root 'output\real-device'
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
foreach ($name in @('real-device-verification.json','v016-file-management-postflash.json')) {
    $destination = Join-Path $outputDirectory $name
    if (Test-Path -LiteralPath $destination) { throw "POSTFLASH_EVIDENCE_DESTINATION_ALREADY_EXISTS=$name" }
    Copy-Item -LiteralPath (Join-Path $evidenceDirectory $name) -Destination $destination
    $sourceHash = (Get-FileHash -LiteralPath (Join-Path $evidenceDirectory $name) -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($sourceHash -ne $destinationHash) { throw "POSTFLASH_EVIDENCE_COPY_HASH_MISMATCH=$name" }
}

$AccessHelper = Join-Path $PSScriptRoot 'ensure-arthur-unattended-access.ps1'
. $AccessHelper
$policy = Get-ArthurAccessPolicy
if ([string]$policy.device.management_ip -ne [string]$Request.management_ip -or
    [string]$policy.device.verified_management_mac -ne [string]$Request.management_mac) {
    throw 'ARTHUR_CONTROL_POLICY_IDENTITY_MISMATCH'
}
$ethernet = Assert-ArthurEthernetIdentity -DeviceIp ([string]$Request.management_ip) -Policy $policy
$fields = Get-ArthurBuildIdentityFields -Build $ethernet.Build
if ([string]$fields.Version -ne '0.1.6' -or [string]$fields.BuildId -ne '38000704263') {
    throw 'PRODUCT_GOAL_RESUME_HTTP_IDENTITY_MISMATCH'
}

$sshDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh'
$knownHosts = Join-Path $sshDirectory 'known_hosts'
if (-not (Test-Path -LiteralPath $knownHosts -PathType Leaf)) { throw 'PRODUCT_GOAL_RESUME_SSH_HOST_TRUST_MISSING' }
$strictIdentity = Invoke-ArthurSshProbe -DeviceIp ([string]$Request.management_ip) -KnownHostsFile $knownHosts -StrictMode yes -Command (Get-ArthurReadOnlyIdentityCommand)
if (-not (Test-ArthurReadOnlyAuthenticatedEvidence -Probe $strictIdentity -Policy $policy -ExpectedVersion '0.1.6' -ExpectedBuildId '38000704263')) {
    throw 'PRODUCT_GOAL_RESUME_SSH_IDENTITY_MISMATCH'
}

Write-Host 'FLASH_ALREADY_CONSUMED=YES'
Write-Host 'FLASH_CAPABLE_STEP=SKIPPED'
Write-Host 'SECOND_FLASH_EXECUTED=NO'
Write-Host 'POSTFLASH_EVIDENCE_REUSE=PASS run_id=38087541420'
Write-Host 'POSTFLASH_BASE_VERIFICATION=PASS'
Write-Host 'QUICKFILE_BACKEND=PASS'
Write-Host 'QUICKFILE_UI=PASS'
Write-Host 'QUICKSTART_LINKEASE_FILE_MANAGER=PASS'
Write-Host 'LINKEASE_MMCBLK0P27_BROWSE=PASS'
Write-Host 'NO_FILE_MANAGEMENT_404_502=PASS'
Write-Host 'CURRENT_VERSION=0.1.6'
Write-Host 'CURRENT_BUILD_ID=38000704263'
Write-Host "CURRENT_MANAGEMENT_MAC=$([string]$Request.management_mac)"
Write-Host 'PRODUCT_GOAL_RESUME_IDENTITY=PASS'
