$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$AgentPath = Join-Path $Root 'scripts\production-agent.ps1'
$PromotionPath = Join-Path $Root '.github\workflows\promote-stable-v3.yml'
$ControlPlanePath = Join-Path $Root 'scripts\arthur-control-plane.ps1'

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

function Get-FunctionBody {
    param([string]$Text,[string]$Name)
    $start = $Text.IndexOf("function $Name",[System.StringComparison]::OrdinalIgnoreCase)
    if ($start -lt 0) { throw "TEST_FAIL: function $Name is missing" }
    $next = $Text.IndexOf("`nfunction ",$start + 1,[System.StringComparison]::OrdinalIgnoreCase)
    if ($next -lt 0) { $next = $Text.Length }
    return $Text.Substring($start,$next - $start)
}

$agent = Get-Content -Raw -LiteralPath $AgentPath
$promotion = Get-Content -Raw -LiteralPath $PromotionPath
$controlPlane = Get-Content -Raw -LiteralPath $ControlPlanePath

# Break caught: normal local Release completion must retain its existing local
# terminal transition when server-side evidence has not arrived yet; it may only
# invoke the shared reconciler after all durable evidence is available.
Assert-Contains $agent 'arthur-terminal-release-reconciler.ps1' 'Production Agent must load the shared terminal release reconciler'
Assert-Contains $agent 'function Test-ProductionTerminalEvidenceAvailable' 'Production Agent must guard the reconciler with durable evidence availability'
$completeRelease = Get-FunctionBody -Text $agent -Name 'Complete-Release'
$savedEvidence = $completeRelease.IndexOf("Write-ProductionEvidence `$State 'RELEASE' 'GITHUB_RELEASE'",[System.StringComparison]::OrdinalIgnoreCase)
$terminalState = $completeRelease.IndexOf("Save-State `$State 'PRODUCTION_RELEASED'",[System.StringComparison]::OrdinalIgnoreCase)
$evidenceAvailable = $completeRelease.IndexOf('Test-ProductionTerminalEvidenceAvailable',[System.StringComparison]::OrdinalIgnoreCase)
$invokeReconciler = $completeRelease.IndexOf('Invoke-ArthurTerminalReleaseReconcile',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($savedEvidence -ge 0) 'Complete-Release must persist production release evidence'
Assert-True ($terminalState -gt $savedEvidence) 'Complete-Release must preserve local terminal success after release evidence is saved'
Assert-True ($evidenceAvailable -gt $terminalState) 'Complete-Release must evaluate durable evidence only after preserving local terminal success'
Assert-True ($invokeReconciler -gt $evidenceAvailable) 'Complete-Release must invoke the shared reconciler only when durable evidence is available'
Assert-Contains $completeRelease 'if (Test-ProductionTerminalEvidenceAvailable -ExecutionId $executionId)' 'available durable evidence must be the only branch that calls the shared reconciler'
Assert-Contains $completeRelease 'TERMINAL_RELEASE_RECONCILE_DEFERRED=PASS' 'missing server-side evidence must be explicitly deferred rather than failing local release completion'
Assert-Contains $completeRelease 'SERVER_SIDE_EVIDENCE_PENDING' 'deferred local release must identify the missing server-side evidence condition'

# Break caught: server-side promotion could manufacture terminal state without an
# Actions-token verified release record, or commit the record without reconciling it.
Assert-Contains $promotion 'GH_TOKEN: ${{ github.token }}' 'promotion must use the workflow-scoped GitHub token'
Assert-Contains $promotion 'github-release-evidence.json' 'promotion must persist GitHub release evidence as JSON'
Assert-Contains $promotion 'GITHUB_ACTIONS_GITHUB_TOKEN' 'promotion evidence must identify GitHub Actions token verification'
Assert-Contains $promotion 'release_exists=True' 'promotion evidence must record an existing stable release'
Assert-Contains $promotion 'Invoke-ArthurTerminalReleaseReconcile' 'promotion must invoke the same shared PowerShell reconciler'
$promotionEvidence = $promotion.IndexOf('github-release-evidence.json',[System.StringComparison]::OrdinalIgnoreCase)
$promotionInvoke = $promotion.IndexOf('Invoke-ArthurTerminalReleaseReconcile',[System.StringComparison]::OrdinalIgnoreCase)
$promotionCommit = $promotion.IndexOf('git add config/arthur-known-good.lock production/known-good.json production/status.json',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($promotionEvidence -ge 0 -and $promotionInvoke -gt $promotionEvidence) 'promotion must invoke after persisting verified release evidence'
Assert-True ($promotionCommit -gt $promotionInvoke) 'promotion must reconcile in the state-only commit flow before committing'

# Break caught: the control plane resolver could migrate a stale PRE_FLASH
# checkpoint before terminal release evidence has a chance to supersede it.
Assert-Contains $controlPlane 'arthur-terminal-release-reconciler.ps1' 'control plane must load the shared terminal reconciler'
Assert-Contains $controlPlane 'TERMINAL_RELEASE_RECONCILED=PASS' 'control plane must report a terminal reconciliation result'
$controlInvoke = $controlPlane.IndexOf('Invoke-ArthurTerminalReleaseReconcile',[System.StringComparison]::OrdinalIgnoreCase)
$resolver = $controlPlane.IndexOf('Resolve-ArthurResumeState',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($controlInvoke -ge 0 -and $resolver -gt $controlInvoke) 'control plane must reconcile terminal evidence before stale checkpoint resolution'
Assert-Contains $controlPlane "reason -eq 'EXECUTION_ID_MISMATCH'" 'control plane must leave a distinct execution eligible when terminal evidence targets another execution'

Write-Host 'ARTHUR_TERMINAL_RELEASE_INTEGRATION_CONTRACT=PASS'
