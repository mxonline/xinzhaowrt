$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "TEST_FAIL: $Message" } }
function Assert-Contains([string]$Text,[string]$Needle,[string]$Message) {
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "TEST_FAIL: $Message missing='$Needle'" }
}

$handoff=Get-Content -Raw (Join-Path $Root 'scripts/feature-handoff.ps1')
$auto=Get-Content -Raw (Join-Path $Root '.github/workflows/arthur-update-v3-auto.yml')
$publisherPath=Join-Path $Root 'scripts/publish-release-convergence-request.ps1'
Assert-True (Test-Path -LiteralPath $publisherPath -PathType Leaf) 'convergence request publisher must exist'
$publisher=Get-Content -Raw $publisherPath

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

# Existing request ownership is preserved. The auto-trigger/publisher add the hard convergence lock before any expensive build.
foreach ($field in @('failure_set_state','failure_set_fingerprint','verification_contract_fingerprint','rootfs_offline_passed','contract_gap_state','firmware_input_fingerprint')) {
    Assert-Contains $auto $field "v3 auto trigger must consume convergence field $field"
    Assert-Contains $publisher $field "publisher must persist convergence field $field into the durable request"
}
Assert-Contains $publisher 'Load-ReleaseConvergenceEvidence' 'publisher must load machine convergence evidence'
Assert-Contains $publisher 'Get-ConvergenceDispatchInputs' 'publisher must reject unresolved/rootfs-unaccepted evidence'
Assert-Contains $publisher 'production/v3-request.json' 'publisher must enrich the existing durable request rather than create a second control plane'

Assert-Contains $auto 'request_id' 'existing v3 auto trigger must consume request idempotency key'
Assert-Contains $auto 'source_ref' 'v3 auto trigger must dispatch the immutable accepted source ref'
Assert-Contains $auto 'headBranch' 'v3 auto trigger must detect an existing run by immutable source ref'
Assert-Contains $auto 'V3_AUTO_TRIGGER_ALREADY_DISPATCHED=YES' 'auto trigger must expose duplicate-suppression evidence'
Assert-Contains $auto 'V3_AUTO_TRIGGER_WAIT_CONVERGENCE=YES' 'unresolved/missing convergence must stop before build without creating another workflow owner'
Assert-Contains $auto "'run','cancel'" 'auto trigger must cancel active invalid builds when convergence is unresolved'
Assert-Contains $auto 'conclusion,cancelled' 'auto trigger must confirm cancellation instead of merely requesting it'
Assert-Contains $auto '--ref "$SOURCE_REF"' 'auto trigger must build from the immutable accepted source ref'
Assert-True ($auto -notmatch '--ref main\s') 'handoff-triggered v3 production must not race against a moving main ref'
Assert-Contains $auto '-f failure_set_state="$FAILURE_SET_STATE"' 'auto trigger must forward resolved failure-set state to production workflow'
Assert-Contains $auto '-f failure_set_fingerprint="$FAILURE_SET_FINGERPRINT"' 'auto trigger must forward failure-set fingerprint'
Assert-Contains $auto '-f verification_contract_fingerprint="$VERIFICATION_CONTRACT_FINGERPRINT"' 'auto trigger must forward verification contract identity'
Assert-Contains $auto '-f rootfs_offline_passed="$ROOTFS_OFFLINE_PASSED"' 'auto trigger must forward rootfs acceptance'
Assert-Contains $auto '-f contract_gap_state="$CONTRACT_GAP_STATE"' 'auto trigger must forward contract-gap state'
Assert-Contains $auto '-f firmware_input_fingerprint="$FIRMWARE_INPUT_FINGERPRINT"' 'auto trigger must bind build to accepted firmware inputs'

Write-Host 'FEATURE_HANDOFF_DURABLE_REQUEST_CONTRACT=PASS'
Write-Host 'FEATURE_HANDOFF_GITHUB_IDEMPOTENCY_CONTRACT=PASS'
Write-Host 'FEATURE_HANDOFF_EXACT_MERGE_SOURCE_CONTRACT=PASS'
Write-Host 'FEATURE_HANDOFF_RUNID_RESUME_CONTRACT=PASS'
Write-Host 'FEATURE_HANDOFF_CONVERGENCE_BOUND_DISPATCH_CONTRACT=PASS'
Write-Host 'FEATURE_HANDOFF_INVALID_BUILD_CANCEL_CONTRACT=PASS'
