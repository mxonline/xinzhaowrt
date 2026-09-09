$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$WorkflowPath = Join-Path $Root '.github\workflows\arthur-production-state-sync.yml'

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

$workflow = Get-Content -Raw -LiteralPath $WorkflowPath

# A manual reconciliation of an already promoted release must evaluate the
# terminal evidence before it considers a stale PRE_FLASH execution binding.
# Otherwise an exit-0 SKIP can be misreported as a successful reconciliation.
Assert-Contains $workflow 'terminal_eligible' 'state sync must recognize a terminal production release path'
$terminalCheck = $workflow.IndexOf('terminal_eligible',[System.StringComparison]::OrdinalIgnoreCase)
$staleBinding = $workflow.IndexOf("resume.get('production', {}).get('github_run_id'",[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($terminalCheck -ge 0 -and $staleBinding -gt $terminalCheck) 'terminal evidence must take priority over stale resume run binding'

# The server-side terminal path is deliberately evidence-only.  It verifies
# the Stable Release with the workflow token, recovers the durable device
# report, and invokes the shared reconciler rather than rebuilding or releasing.
Assert-Contains $workflow 'GH_TOKEN: ${{ github.token }}' 'state sync must use the Actions-scoped GitHub token'
Assert-Contains $workflow 'releases/tags/' 'state sync must verify the existing Stable Release server-side'
Assert-Contains $workflow "'release', 'download'" 'state sync must recover durable real-device evidence from existing Release assets'
Assert-Contains $workflow 'real-device-verification.json' 'state sync must require the durable real-device report'
Assert-Contains $workflow 'GITHUB_ACTIONS_GITHUB_TOKEN' 'persisted release evidence must record token verification'
Assert-Contains $workflow 'Invoke-ArthurTerminalReleaseReconcile' 'state sync must invoke the shared terminal reconciler'
Assert-Contains $workflow 'TERMINAL_RELEASE_EVIDENCE=PASS' 'terminal evidence validation must report explicit success'

# known-good.json is the frozen manifest: its terminal assertion is
# `verified=true`, not a non-existent `known_good` field.  Requiring that
# missing field would silently bypass the terminal path and reintroduce the
# false-positive stale-run SKIP.
Assert-Contains $workflow "known_good.get('verified') is True" 'terminal eligibility must use the frozen known-good verified field'
Assert-True (-not $workflow.Contains("known_good.get('known_good') is True")) 'terminal eligibility must not require a missing known-good.json field'

# A repeated dispatch must be an observable no-op: the reconciler owns ledger
# duplicate detection and the workflow must not turn an empty diff into a new
# reconciliation commit.
Assert-Contains $workflow 'ALREADY_RECONCILED=PASS NO_OP=PASS' 'second terminal dispatch must explicitly report its no-op result'
Assert-Contains $workflow 'TERMINAL_MODE' 'commit step must distinguish terminal no-op from a generic empty diff'

Write-Host 'ARTHUR_PRODUCTION_STATE_SYNC_CONTRACT=PASS'
