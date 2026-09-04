$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$autoTriggerPath = Join-Path $Root '.github/workflows/arthur-update-v3-auto.yml'
$dedupPath = Join-Path $Root 'scripts/resolve-candidate-dedup.sh'
$deployPath = Join-Path $Root '.github/workflows/production-agent-deploy.yml'
if (-not (Test-Path $autoTriggerPath)) { throw 'TEST_FAIL: Arthur v3 auto-trigger workflow is missing' }
if (-not (Test-Path $dedupPath)) { throw 'TEST_FAIL: Candidate fingerprint dedup script is missing' }
$autoTrigger = Get-Content -Raw $autoTriggerPath
$dedup = Get-Content -Raw $dedupPath
$deploy = Get-Content -Raw $deployPath

function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message (missing '$Needle')"
    }
}

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}

# At-most-once Candidate dispatch is enforced by firmware fingerprint before the write path.
Assert-Contains $autoTrigger 'resolve-candidate-dedup.sh' 'v3 auto-trigger must call the authoritative Candidate fingerprint dedup gate'
Assert-Contains $autoTrigger 'WATCH_EXISTING_RUN' 'running same-fingerprint Candidate must be watched instead of dispatched again'
Assert-Contains $autoTrigger 'REUSE_ARTIFACT' 'completed same-fingerprint Candidate must be reused instead of dispatched again'
Assert-Contains $autoTrigger 'NO_NEW_CANDIDATE' 'no-impact source must not dispatch a Candidate'
Assert-Contains $autoTrigger 'NEW_CANDIDATE' 'only new firmware fingerprint may cross the dispatch write boundary'
Assert-Contains $autoTrigger 'V3_AUTO_TRIGGER_ALREADY_DISPATCHED=YES' 'watch/reuse paths must expose durable no-second-dispatch evidence'
Assert-Contains $autoTrigger 'gh workflow run arthur-update-v3.yml' 'formal Candidate dispatch must remain a single explicit write site'
Assert-Contains $autoTrigger 'CONFIRMED_RUN' 'a new dispatch must capture the concrete replacement run id'
Assert-Contains $autoTrigger 'V3_AUTO_TRIGGER_DISPATCH_ACK_TIMEOUT' 'unconfirmed dispatch must fail closed rather than issuing another blind write in the same run'
Assert-Contains $autoTrigger 'V3_AUTO_TRIGGER_DISPATCHED=YES' 'confirmed new dispatch must expose its run id'

# The dedup resolver itself must bind decisions to a build fingerprint and distinguish existing running/completed candidates.
Assert-Contains $dedup 'BUILD_FINGERPRINT' 'dedup resolver must calculate/expose a stable firmware build fingerprint'
Assert-Contains $dedup 'WATCH_EXISTING_RUN' 'dedup resolver must classify an existing in-flight Candidate'
Assert-Contains $dedup 'REUSE_ARTIFACT' 'dedup resolver must classify a reusable completed Candidate'
Assert-Contains $dedup 'NO_NEW_CANDIDATE' 'dedup resolver must suppress no-change Candidate creation'
Assert-Contains $dedup 'NEW_CANDIDATE' 'dedup resolver must explicitly authorize only a new fingerprint'

# The runner wakeup is not allowed to become a second Candidate writer.
Assert-True ($deploy -notmatch '(?i)gh\s+workflow\s+run\s+arthur-update-v3\.yml') 'runner wakeup must never duplicate the v3 auto-trigger Candidate dispatch'

Write-Host 'REBUILD_DISPATCH_AT_MOST_ONCE_CONTRACT=PASS'
