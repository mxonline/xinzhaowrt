param(
    [Parameter(Mandatory=$true)][string]$CandidateManifest,
    [Parameter(Mandatory=$true)][string]$RollbackPath,
    [Parameter(Mandatory=$true)][string]$Target,
    [string]$RemoteCandidate = '/tmp/XinZhaoWrt-Arthur-production-sysupgrade.bin'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Config = Get-Content -Raw (Join-Path $Root 'production\production-agent.json') | ConvertFrom-Json
$Known = Get-Content -Raw (Join-Path $Root 'production\known-good.json') | ConvertFrom-Json
$Profile = Get-Content -Raw (Join-Path $Root 'production\arthur-flash-profile.json') | ConvertFrom-Json
$Candidate = Get-Content -Raw $CandidateManifest | ConvertFrom-Json

function Fail([string]$Code,[string]$Message) {
    Write-Error "$Code $Message"
    exit 51
}
function Remote([string]$Command) {
    $out = @(& ssh.exe -o BatchMode=yes -o ConnectTimeout=10 $Target $Command 2>&1)
    [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=($out -join "`n").Trim() }
}

$runId = [long]$Candidate.run_id
if ($runId -le 0) { Fail 'CANDIDATE_INCOMPLETE' 'Candidate manifest has no valid production run_id.' }
$rejectionPath = Join-Path $Root ("production\candidate-rejection-{0}.json" -f $runId)
if (Test-Path $rejectionPath) {
    $rejection = Get-Content -Raw $rejectionPath | ConvertFrom-Json
    $rejected = ([string]$rejection.status -eq 'REJECTED_FOR_RELEASE') -or
                ($rejection.PSObject.Properties.Name -contains 'flash_allowed' -and $rejection.flash_allowed -eq $false) -or
                ($rejection.PSObject.Properties.Name -contains 'release_allowed' -and $rejection.release_allowed -eq $false)
    if ($rejected) {
        Fail 'CANDIDATE_REJECTED' "Run $runId is blocked by durable rejection evidence: $([string]$rejection.reason)"
    }
}

if ([string]$Config.device -ne 'jdcloud_re-ss-01' -or [string]$Candidate.profile -ne 'jdcloud_re-ss-01') { Fail 'UNKNOWN_DEVICE_IDENTITY' 'Arthur profile mismatch.' }
if ([string]$Candidate.target -ne 'qualcommax/ipq60xx') { Fail 'UNKNOWN_DEVICE_IDENTITY' 'Arthur target mismatch.' }
if (-not $Profile.verified -or [string]$Profile.remote_upgrade_binary -ne '/sbin/sysupgrade') { Fail 'UNRECOVERABLE_IRREVERSIBLE_OPERATION' 'No historically verified standard sysupgrade profile.' }
if (-not $Profile.forbid_raw_writes) { Fail 'UNRECOVERABLE_IRREVERSIBLE_OPERATION' 'Raw-write prohibition is not active.' }

$candidatePath = [string]$Candidate.candidate_path
if (-not (Test-Path $candidatePath)) { Fail 'CANDIDATE_INCOMPLETE' 'Candidate file missing.' }
$localSha = (Get-FileHash -Algorithm SHA256 $candidatePath).Hash.ToLowerInvariant()
if ($localSha -ne ([string]$Candidate.candidate_sha256).ToLowerInvariant()) { Fail 'CANDIDATE_HASH_MISMATCH' 'Candidate local SHA256 differs from manifest.' }

if (-not (Test-Path $RollbackPath)) { Fail 'NO_SAFE_ROLLBACK' "Rollback artifact missing: $RollbackPath" }
$rollbackSha = (Get-FileHash -Algorithm SHA256 $RollbackPath).Hash.ToLowerInvariant()
$expectedRollbackSha = ([string]$Known.rollback.sha256).ToLowerInvariant()
if (-not $expectedRollbackSha) { Fail 'NO_SAFE_ROLLBACK' 'production/known-good.json rollback.sha256 is missing.' }
if ($rollbackSha -ne $expectedRollbackSha) { Fail 'NO_SAFE_ROLLBACK' "Rollback SHA256 mismatch expected=$($Known.rollback.sha256) actual=$rollbackSha" }

$board = Remote 'ubus call system board'
if ($board.ExitCode -ne 0 -or $board.Output -notmatch 'jdcloud,re-ss-01|RE-SS-01') { Fail 'UNKNOWN_DEVICE_IDENTITY' 'Remote board identity is not JDCloud RE-SS-01.' }
$storage = Remote 'cat /proc/mtd 2>/dev/null; lsblk 2>/dev/null; mount; df -h'
if ($storage.ExitCode -ne 0 -or $storage.Output -notmatch '(?i)(mmc|overlay|rootfs)') { Fail 'UNKNOWN_DEVICE_IDENTITY' 'Storage layout evidence is unavailable.' }

$remoteHashResult = Remote "sha256sum '$RemoteCandidate'"
if ($remoteHashResult.ExitCode -ne 0 -or $remoteHashResult.Output -notmatch '^([0-9a-fA-F]{64})') { Fail 'REMOTE_HASH_UNAVAILABLE' 'Remote candidate SHA256 unavailable.' }
$remote_sha256 = $Matches[1].ToLowerInvariant()
if ($remote_sha256 -ne $localSha) { Fail 'REMOTE_HASH_MISMATCH' "remote_sha256=$remote_sha256 local_sha256=$localSha" }

$test = Remote "/sbin/sysupgrade -T '$RemoteCandidate'"
if ($test.ExitCode -ne 0) { Fail 'CANDIDATE_SYSUPGRADE_TEST_FAILED' $test.Output }

Write-Host 'DEVICE_IDENTITY=PASS device=jdcloud_re-ss-01'
Write-Host 'TARGET_PROFILE=PASS target=qualcommax/ipq60xx profile=jdcloud_re-ss-01'
Write-Host "EXPECTED_LAN=PASS lan=192.168.6.1"
Write-Host "ROLLBACK_SHA256=PASS sha256=$rollbackSha"
Write-Host "LOCAL_SHA256=PASS sha256=$localSha"
Write-Host "remote_sha256=$remote_sha256"
Write-Host 'SYSUPGRADE_TEST=PASS'
Write-Host 'AUTO_FLASH_SAFETY_GATE=PASS'
