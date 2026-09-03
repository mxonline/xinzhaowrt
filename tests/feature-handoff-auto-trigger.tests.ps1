$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "TEST_FAIL: $Message" } }
function Assert-Contains([string]$Text,[string]$Needle,[string]$Message) {
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "TEST_FAIL: $Message missing='$Needle'" }
}

$handoff=Get-Content -Raw (Join-Path $Root 'scripts/feature-handoff.ps1')
$auto=Get-Content -Raw (Join-Path $Root '.github/workflows/arthur-update-v3-auto.yml')
$v3=Get-Content -Raw (Join-Path $Root '.github/workflows/arthur-update-v3.yml')

Assert-Contains $handoff 'production\v3-request.json' 'handoff must reuse the existing durable v3-request control plane'
Assert-Contains $handoff 'Write-HandoffV3Request' 'handoff must create one deterministic production request after accepted source integration'
Assert-Contains $handoff 'Ensure-HandoffSourceTag' 'handoff must bind production to an immutable accepted-source tag'
Assert-Contains $handoff 'request_id' 'handoff state/request must carry a stable idempotency key'
Assert-Contains $handoff 'source_ref' 'handoff request must name the immutable build source ref'
Assert-True ($handoff -notmatch "(?s)'workflow','run','arthur-update-v3\.yml'") 'handoff must not directly workflow_dispatch v3 after durable request integration'

Assert-Contains $auto 'request_id' 'existing v3 auto trigger must consume request idempotency key'
Assert-Contains $auto 'source_ref' 'v3 auto trigger must dispatch the immutable accepted source ref'
Assert-Contains $auto 'displayTitle' 'v3 auto trigger must detect an already-dispatched request before retrying'
Assert-Contains $auto 'V3_AUTO_TRIGGER_ALREADY_DISPATCHED=YES' 'auto trigger must expose duplicate-suppression evidence'
Assert-Contains $auto '-f request_id="$REQUEST_ID"' 'auto trigger must pass request identity into v3'
Assert-Contains $auto '--ref "$SOURCE_REF"' 'auto trigger must build from the immutable accepted source ref'

Assert-Contains $v3 'request_id:' 'v3 workflow must accept a handoff request identity'
Assert-Contains $v3 'run-name:' 'v3 run must expose request identity for duplicate discovery'
Assert-Contains $v3 'inputs.request_id' 'v3 run name must bind the handoff request id'

Write-Host 'FEATURE_HANDOFF_DURABLE_REQUEST_CONTRACT=PASS'
Write-Host 'FEATURE_HANDOFF_GITHUB_IDEMPOTENCY_CONTRACT=PASS'
