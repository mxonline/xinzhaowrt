$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$controllerPath = Join-Path $root 'scripts\ci-controller-v3.ps1'
if (-not (Test-Path -LiteralPath $controllerPath -PathType Leaf)) {
    throw 'FAIL: scripts/ci-controller-v3.ps1 is missing'
}

$text = Get-Content -Raw -LiteralPath $controllerPath

function Assert-Contains([string]$Needle,[string]$Message) {
    if (-not $text.Contains($Needle)) { throw "FAIL: $Message (missing: $Needle)" }
}

Assert-Contains 'function Invoke-BuildClosurePreflight' 'controller must expose an exact build-closure gate'
Assert-Contains 'arthur-fast-preflight.yml' 'closure gate must dispatch the dedicated closure mode of Fast Preflight'
Assert-Contains 'build_closure=true' 'closure dispatch must explicitly enable build_closure'
Assert-Contains 'BUILD_CLOSURE_PREFLIGHT=PASS' 'closure gate must verify the closure PASS marker, not only workflow conclusion'
Assert-Contains 'BUILD_CLOSURE_FAILED_CONTINUE_REPAIR' 'failed closure must return to Codex repair instead of Candidate dispatch'
Assert-Contains 'BUILD_CLOSURE_PASS_ALLOW_CANDIDATE' 'Candidate dispatch must have an explicit closure-pass boundary'

$processStart = $text.IndexOf('function Process-V3Run')
if ($processStart -lt 0) { throw 'FAIL: Process-V3Run function is missing' }
$processText = $text.Substring($processStart)
$repairStart = $processText.IndexOf("elseif (`$action -eq 'repaired')")
if ($repairStart -lt 0) { throw 'FAIL: repaired branch is missing from Process-V3Run' }

$closureIndex = $processText.IndexOf('Invoke-BuildClosurePreflight', $repairStart)
$candidateIndex = $processText.IndexOf('Start-V3Run -RequestedMode $RequestedMode', $repairStart)
if ($closureIndex -lt 0) { throw 'FAIL: repaired branch does not invoke build closure' }
if ($candidateIndex -lt 0) { throw 'FAIL: replacement Candidate dispatch is missing' }
if ($closureIndex -ge $candidateIndex) {
    throw 'FAIL: replacement Candidate can start before build closure runs'
}

$failureMarker = $processText.IndexOf('BUILD_CLOSURE_FAILED_CONTINUE_REPAIR', $closureIndex)
$passMarker = $processText.IndexOf('BUILD_CLOSURE_PASS_ALLOW_CANDIDATE', $closureIndex)
if ($failureMarker -lt 0 -or $passMarker -lt 0 -or $failureMarker -ge $candidateIndex -or $passMarker -ge $candidateIndex) {
    throw 'FAIL: closure failure/pass routing is not enforced before replacement Candidate dispatch'
}

echo 'PASS: Codex repair is gated by exact build closure before any replacement Candidate.'
