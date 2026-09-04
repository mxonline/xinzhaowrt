$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$wakeup = Get-Content -Raw (Join-Path $Root '.github/workflows/production-agent-deploy.yml')
$auto = Get-Content -Raw (Join-Path $Root '.github/workflows/arthur-update-v3-auto.yml')
$pipeline = Get-Content -Raw (Join-Path $Root 'ai_orchestrator/arthur.py')

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

# The runner wakeup never owns Candidate dispatch. Exactly-once dispatch is delegated to the existing fingerprint gate.
Assert-True ($wakeup -notmatch "'workflow','run'") 'runner wakeup must not independently issue workflow_dispatch writes'
Assert-True ($wakeup -notmatch 'REBUILD_DISPATCH_ACCEPTED') 'runner wakeup must not own a second Candidate-dispatch acknowledgement state machine'
Assert-Contains $pipeline '.github/workflows/arthur-update-v3.yml' 'Arthur pipeline must bind formal production Candidate evidence to arthur-update-v3.yml'

Assert-Contains $auto 'resolve-candidate-dedup.sh' 'auto trigger must use the existing fingerprint Candidate dedup resolver'
Assert-Contains $auto 'WATCH_EXISTING_RUN' 'same fingerprint in-flight Candidate must be watched instead of redispatched'
Assert-Contains $auto 'REUSE_ARTIFACT' 'same fingerprint successful Candidate must be reused'
Assert-Contains $auto 'NO_NEW_CANDIDATE' 'non-firmware-impact change must not create a Candidate'
Assert-Contains $auto 'NEW_CANDIDATE' 'only a genuinely new fingerprint may dispatch a Candidate'
Assert-Contains $auto 'BUILD_FINGERPRINT' 'Candidate decision must expose the durable build fingerprint'
Assert-Contains $auto 'V3_AUTO_TRIGGER_ALREADY_DISPATCHED=YES' 'watch/reuse routes must expose that no second dispatch is needed'
Assert-Contains $auto 'V3_AUTO_TRIGGER_DISPATCHED=YES' 'new Candidate dispatch must be acknowledged with a concrete run id'
Assert-Contains $auto 'headSha' 'dispatch acknowledgement must bind to the exact source SHA'
Assert-Contains $auto 'gh workflow run arthur-update-v3.yml' 'only the dedup-gated NEW_CANDIDATE branch may issue the formal build dispatch'

$dedupIndex = $auto.IndexOf('resolve-candidate-dedup.sh',[System.StringComparison]::OrdinalIgnoreCase)
$dispatchIndex = $auto.IndexOf('gh workflow run arthur-update-v3.yml',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($dedupIndex -ge 0 -and $dispatchIndex -gt $dedupIndex) 'fingerprint resolution must occur before any Candidate dispatch write'
$preDispatch = $auto.Substring($dedupIndex, $dispatchIndex - $dedupIndex)
foreach ($route in @('WATCH_EXISTING_RUN','REUSE_ARTIFACT','NO_NEW_CANDIDATE','NEW_CANDIDATE')) {
    Assert-Contains $preDispatch $route "dedup decision must handle route $route before dispatch"
}
Assert-Contains $preDispatch 'exit 0' 'all reuse/watch/no-build routes must exit before the workflow_dispatch write'

Write-Host 'REBUILD_DISPATCH_AT_MOST_ONCE_CONTRACT=PASS'
Write-Host 'FINGERPRINT_CANDIDATE_DEDUP_CONTRACT=PASS'