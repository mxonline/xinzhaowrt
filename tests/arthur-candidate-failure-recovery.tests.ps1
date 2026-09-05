$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Helper = Join-Path $Root 'scripts\arthur-candidate-failure-recovery.ps1'
$Gate = Join-Path $Root 'scripts\arthur-control-plane-gate.ps1'
$Controller = Join-Path $Root 'scripts\ci-controller-v3.ps1'

function Assert-Contains([string]$Text,[string]$Needle,[string]$Message) {
    if (-not $Text.Contains($Needle)) { throw "FAIL: $Message (missing: $Needle)" }
}

if (-not (Test-Path -LiteralPath $Helper -PathType Leaf)) {
    throw 'FAIL: scripts/arthur-candidate-failure-recovery.ps1 is missing'
}

$helperText = Get-Content -Raw -LiteralPath $Helper
$gateText = Get-Content -Raw -LiteralPath $Gate
$controllerText = Get-Content -Raw -LiteralPath $Controller
Assert-Contains $helperText 'REPAIR_FAILED_RUN' 'helper must consume the authoritative failed-run action'
Assert-Contains $helperText 'ci-controller-v3.ps1' 'helper must reuse the existing v3 Codex repair controller'
Assert-Contains $helperText "'-Mode','Resume'" 'helper must resume the failed formal Candidate instead of creating a new controller'
Assert-Contains $helperText 'candidate-repair.json' 'helper must persist repair run/PID identity for idempotency'
Assert-Contains $helperText 'function Resolve-BashExecutable' 'helper must resolve Bash even when Git for Windows bash is not on PATH'
Assert-Contains $helperText "'bin\\bash.exe'" 'helper must probe the Git for Windows bin/bash.exe sibling path'
Assert-Contains $helperText "'usr\\bin\\bash.exe'" 'helper must probe the Git for Windows usr/bin/bash.exe sibling path'
Assert-Contains $helperText '$bashExe = Resolve-BashExecutable' 'resolver execution must use the resolved Bash executable'
Assert-Contains $helperText '& $bashExe $resolver' 'resolver must invoke the resolved Bash path rather than assuming bash is on PATH'
Assert-Contains $gateText 'arthur-candidate-failure-recovery.ps1' 'control-plane gate must invoke failed Candidate recovery'
Assert-Contains $gateText 'CONTROL_PLANE_REPAIR_ROUTED=PASS' 'control-plane gate must stop competing mutation when repair owns the wakeup'

# A known failed formal Candidate is durable GitHub evidence and must be routed to
# its repair controller before legacy Resume Gate state can block it. The helper
# must operate from the clean current-main control checkout, never a preserved dirty
# task workspace which may still point at an old source SHA.
$repairGateIndex = $gateText.IndexOf('$repairOutput = & $failureRecoveryPath')
$resumeGateIndex = $gateText.IndexOf('$resumeOutput = & $resumeGatePath')
if ($repairGateIndex -lt 0 -or $resumeGateIndex -lt 0) {
    throw 'FAIL: repair/resume gate calls are missing'
}
if ($repairGateIndex -ge $resumeGateIndex) {
    throw 'FAIL: stale Resume Gate can block known failed Candidate auto-repair before it is routed'
}
Assert-Contains $gateText '-Workspace $root' 'failed Candidate recovery must use the clean current-main control checkout'

# The repair controller must never dispatch a replacement Candidate until the exact
# locked source/feed/package/defconfig closure passes. A failed closure must become
# the next Codex evidence source and remain inside the repair lane.
Assert-Contains $controllerText 'function Invoke-BuildClosurePreflight' 'controller must expose exact build-closure orchestration'
Assert-Contains $controllerText 'arthur-fast-preflight.yml' 'closure orchestration must use the existing exact build-closure workflow'
Assert-Contains $controllerText 'build_closure=true' 'closure orchestration must explicitly enable build_closure'
Assert-Contains $controllerText 'BUILD_CLOSURE_PREFLIGHT=PASS' 'closure orchestration must verify the PASS marker, not only workflow success'
Assert-Contains $controllerText 'BUILD_CLOSURE_FAILED_CONTINUE_REPAIR' 'failed closure must continue Codex repair instead of Candidate dispatch'
Assert-Contains $controllerText 'BUILD_CLOSURE_PASS_ALLOW_CANDIDATE' 'Candidate dispatch must have an explicit closure-pass boundary'

$processStart = $controllerText.IndexOf('function Process-V3Run')
if ($processStart -lt 0) { throw 'FAIL: Process-V3Run function is missing' }
$processText = $controllerText.Substring($processStart)

$failureCircuit = $processText.IndexOf('if ($round -ge $MaxRepairRounds)')
$repairEvidence = $processText.IndexOf('$repairEvidenceRunId = $currentRunId')
if ($failureCircuit -lt 0 -or $repairEvidence -lt 0 -or $failureCircuit -ge $repairEvidence) {
    throw 'FAIL: failure-path circuit breaker or repair evidence boundary is missing'
}
$preRepairCircuitText = $processText.Substring($failureCircuit, $repairEvidence - $failureCircuit)
if ($preRepairCircuitText.Contains('Start-V3Run -RequestedMode $RequestedMode')) {
    throw 'FAIL: MaxRepairRounds circuit breaker can bypass build closure and dispatch a Candidate directly'
}

$repairStart = $processText.IndexOf("elseif (`$action -eq 'repaired')")
if ($repairStart -lt 0) { throw 'FAIL: repaired branch is missing from Process-V3Run' }
$closureIndex = $processText.IndexOf('Invoke-BuildClosurePreflight', $repairStart)
$candidateIndex = $processText.IndexOf('Start-V3Run -RequestedMode $RequestedMode', $repairStart)
if ($closureIndex -lt 0) { throw 'FAIL: repaired branch does not invoke build closure' }
if ($candidateIndex -lt 0) { throw 'FAIL: replacement Candidate dispatch is missing' }
if ($closureIndex -ge $candidateIndex) { throw 'FAIL: replacement Candidate can start before build closure runs' }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("arthur-repair-contract-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $watch = @"
ACTION=WATCH_EXISTING_RUN
RUN_ID=33970000001
BUILD_FINGERPRINT=arthur-build-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SOURCE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
"@
    $watchOut = (& $Helper -Repository 'mxonline/xinzhaowrt' -Workspace $Root -ControlRoot $tmp -DecisionOnly -ResolverOutput $watch 2>&1 | Out-String).Trim()
    Assert-Contains $watchOut 'CANDIDATE_FAILURE_REPAIR=NOT_REQUIRED' 'active Candidate must remain watched without launching repair'

    $failed = @"
ACTION=REPAIR_FAILED_RUN
RUN_ID=33969443771
BUILD_FINGERPRINT=arthur-build-v1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SOURCE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
RUN_CONCLUSION=failure
"@
    $wouldStart = (& $Helper -Repository 'mxonline/xinzhaowrt' -Workspace $Root -ControlRoot $tmp -DecisionOnly -ResolverOutput $failed 2>&1 | Out-String).Trim()
    Assert-Contains $wouldStart 'CANDIDATE_FAILURE_REPAIR=WOULD_START' 'failed Candidate must route to the existing repair controller'
    Assert-Contains $wouldStart 'run_id=33969443771' 'repair decision must preserve the failed formal run identity'

    $stateDir = Join-Path $tmp 'state'
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    [ordered]@{
        schema_version = 1
        run_id = 33969443771
        pid = $PID
        status = 'RUNNING'
    } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $stateDir 'candidate-repair.json')

    $already = (& $Helper -Repository 'mxonline/xinzhaowrt' -Workspace $Root -ControlRoot $tmp -DecisionOnly -ResolverOutput $failed 2>&1 | Out-String).Trim()
    Assert-Contains $already 'CANDIDATE_FAILURE_REPAIR=ALREADY_RUNNING' 'five-minute wakeups must not duplicate the same live repair process'
}
finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
}

$scope = @(
    'scripts/arthur-candidate-failure-recovery.ps1',
    'tests/arthur-candidate-failure-recovery.tests.ps1'
) -join "`n"
$scopeOut = ($scope | bash (Join-Path $Root 'scripts/classify-build-scope.sh') | Out-String).Trim()
if ($scopeOut -ne 'FAST_GATE') { throw "FAIL: failed Candidate recovery control change classified as $scopeOut" }

Write-Host 'PASS: Arthur failed Candidate recovery is wired for unattended, idempotent Windows Control Plane repair with mandatory build closure before replacement Candidate.'
