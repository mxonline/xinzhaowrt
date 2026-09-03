$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "TEST_FAIL: $Message" } }
function Assert-Contains([string]$Text,[string]$Needle,[string]$Message) {
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "TEST_FAIL: $Message missing='$Needle'" }
}

$handoff=Get-Content -Raw (Join-Path $Root 'scripts/feature-handoff.ps1')
$auto=Get-Content -Raw (Join-Path $Root '.github/workflows/arthur-update-v3-auto.yml')

Assert-Contains $handoff 'production\v3-request.json' 'handoff must reuse the existing durable v3-request control plane'
Assert-Contains $handoff 'Write-HandoffV3Request' 'handoff must create one deterministic production request after accepted source integration'
Assert-Contains $handoff 'Ensure-HandoffSourceTag' 'handoff must bind production to an immutable accepted-source tag'
Assert-Contains $handoff 'request_id' 'handoff state/request must carry a stable idempotency key'
Assert-Contains $handoff 'source_ref' 'handoff request must name the immutable build source ref'
Assert-Contains $handoff 'arthur-update-v3-auto.yml' 'handoff must monitor/recover the existing v3 auto-trigger workflow'
Assert-Contains $handoff 'headBranch' 'handoff must discover the v3 run by its immutable source ref'
Assert-Contains $handoff 'mergeCommit' 'accepted build source must bind to the actual merged source PR commit, not whichever main SHA is newest later'
Assert-Contains $handoff 'start-ci-controller-v3.ps1' 'handoff must reuse the existing v3 controller launcher'
Assert-Contains $handoff "'-Mode','Resume'" 'tag-based v3 run must be handed to controller Resume by exact RunId'
Assert-Contains $handoff "'-RunId'" 'controller resume must bind the discovered v3 run id'
Assert-True ($handoff -notmatch "(?s)'workflow','run','arthur-update-v3\.yml'") 'handoff must not directly workflow_dispatch v3 after durable request integration'

Assert-Contains $auto 'request_id' 'existing v3 auto trigger must consume request idempotency key'
Assert-Contains $auto 'source_ref' 'v3 auto trigger must dispatch the immutable accepted source ref'
Assert-Contains $auto 'headBranch' 'v3 auto trigger must detect an existing run by immutable source ref'
Assert-Contains $auto 'V3_AUTO_TRIGGER_ALREADY_DISPATCHED=YES' 'auto trigger must expose duplicate-suppression evidence'
Assert-Contains $auto '--ref "$SOURCE_REF"' 'auto trigger must build from the immutable accepted source ref'
Assert-True ($auto -notmatch '--ref main\s') 'handoff-triggered v3 production must not race against a moving main ref'

Write-Host 'FEATURE_HANDOFF_DURABLE_REQUEST_CONTRACT=PASS'
Write-Host 'FEATURE_HANDOFF_GITHUB_IDEMPOTENCY_CONTRACT=PASS'
Write-Host 'FEATURE_HANDOFF_EXACT_MERGE_SOURCE_CONTRACT=PASS'
Write-Host 'FEATURE_HANDOFF_RUNID_RESUME_CONTRACT=PASS'
