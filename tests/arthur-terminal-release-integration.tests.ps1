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
Assert-Contains $completeRelease 'if (Test-ProductionTerminalEvidenceAvailable -State $State -ExecutionId $executionId)' 'available durable evidence must be the only branch that calls the shared reconciler'
Assert-Contains $completeRelease 'TERMINAL_RELEASE_RECONCILE_DEFERRED=PASS' 'missing server-side evidence must be explicitly deferred rather than failing local release completion'
Assert-Contains $completeRelease 'SERVER_SIDE_EVIDENCE_PENDING' 'deferred local release must identify the missing server-side evidence condition'

# Break caught: four JSON files can be structurally valid and terminal-marked while
# describing a different run, tag, source, firmware, or SHA.  That mismatch must
# take the same deferred branch after local Save-State, never invoke the helper.
$availability = Get-FunctionBody -Text $agent -Name 'Test-ProductionTerminalEvidenceAvailable'
Assert-Contains $availability 'Get-ArthurTerminalIdentity' 'availability guard must parse terminal identities rather than trusting flags alone'
Assert-Contains $availability 'Assert-ArthurTerminalIdentityMatch' 'availability guard must compare every durable evidence identity'
Assert-Contains $availability '[long]$State.run_id' 'availability guard must bind evidence to the local production run'
Assert-Contains $availability 'arthur-production-$($State.run_id)' 'availability guard must bind evidence to the local stable tag'
Assert-Contains $availability '$State.source_sha' 'availability guard must bind evidence to the local source commit'
Assert-Contains $availability '$State.artifact_name' 'availability guard must bind evidence to the local firmware filename'
Assert-Contains $availability '$State.candidate_sha256' 'availability guard must bind evidence to the local firmware SHA256'

# Execute the production guard itself against syntactically valid evidence.  A
# run mismatch is intentionally the only mutation: the guard must then return
# false, which leaves Complete-Release on its already-saved local/deferred path.
. (Join-Path $Root 'scripts\arthur-terminal-release-reconciler.ps1')
. ([scriptblock]::Create($availability))
$guardRoot = Join-Path ([IO.Path]::GetTempPath()) ("xinzhaowrt-terminal-availability-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $guardRoot 'production\evidence\execution-123') | Out-Null
$guardState = [pscustomobject]@{ run_id = [long]123; source_sha = ('a' * 40); artifact_name = 'Arthur-test-sysupgrade.bin'; candidate_sha256 = ('b' * 64) }
$guardIdentity = [ordered]@{ run_id=123; stable_tag='arthur-production-123'; project_commit=('a' * 40); source_commit=('a' * 40); firmware='Arthur-test-sysupgrade.bin'; sha256=('b' * 64) }
function Write-GuardEvidence([string]$Path,$Value) { $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM }
try {
    Write-GuardEvidence (Join-Path $guardRoot 'production\status.json') ([ordered]@{ status='PRODUCTION_RELEASED'; known_good=$true } + $guardIdentity)
    Write-GuardEvidence (Join-Path $guardRoot 'production\known-good.json') ([ordered]@{ known_good=$true; verified=$true; verification='real-device-confirmed' } + $guardIdentity)
    Write-GuardEvidence (Join-Path $guardRoot 'production\evidence\execution-123\github-release-evidence.json') ([ordered]@{ verified_by='GITHUB_ACTIONS_GITHUB_TOKEN'; release_exists=$true; draft=$false; prerelease=$false } + $guardIdentity)
    Write-GuardEvidence (Join-Path $guardRoot 'production\evidence\execution-123\real-device-evidence.json') ([ordered]@{ known_good=$true; verified=$true; verification='real-device-confirmed' } + $guardIdentity)
    $previousRoot = $script:Root
    $script:Root = $guardRoot
    Assert-True (Test-ProductionTerminalEvidenceAvailable -State $guardState -ExecutionId 'execution-123') 'matching complete evidence must make the production guard eligible'
    $mismatched = Get-Content -Raw (Join-Path $guardRoot 'production\evidence\execution-123\github-release-evidence.json') | ConvertFrom-Json
    $mismatched.run_id = [long]124
    Write-GuardEvidence (Join-Path $guardRoot 'production\evidence\execution-123\github-release-evidence.json') $mismatched
    Assert-True (-not (Test-ProductionTerminalEvidenceAvailable -State $guardState -ExecutionId 'execution-123')) 'structurally valid mismatched release evidence must defer before helper invocation'
}
finally {
    $script:Root = $previousRoot
    if (Test-Path -LiteralPath $guardRoot) { Remove-Item -LiteralPath $guardRoot -Recurse -Force }
}

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
