$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Helper = Join-Path $Root 'scripts\arthur-candidate-failure-recovery.ps1'
$Gate = Join-Path $Root 'scripts\arthur-control-plane-gate.ps1'

function Assert-Contains([string]$Text,[string]$Needle,[string]$Message) {
    if (-not $Text.Contains($Needle)) { throw "FAIL: $Message (missing: $Needle)" }
}

if (-not (Test-Path -LiteralPath $Helper -PathType Leaf)) {
    throw 'FAIL: scripts/arthur-candidate-failure-recovery.ps1 is missing'
}

$helperText = Get-Content -Raw -LiteralPath $Helper
$gateText = Get-Content -Raw -LiteralPath $Gate
Assert-Contains $helperText 'REPAIR_FAILED_RUN' 'helper must consume the authoritative failed-run action'
Assert-Contains $helperText 'ci-controller-v3.ps1' 'helper must reuse the existing v3 Codex repair controller'
Assert-Contains $helperText "'-Mode','Resume'" 'helper must resume the failed formal Candidate instead of creating a new controller'
Assert-Contains $helperText 'candidate-repair.json' 'helper must persist repair run/PID identity for idempotency'
Assert-Contains $gateText 'arthur-candidate-failure-recovery.ps1' 'control-plane gate must invoke failed Candidate recovery'
Assert-Contains $gateText 'CONTROL_PLANE_REPAIR_ROUTED=PASS' 'control-plane gate must stop competing mutation when repair owns the wakeup'

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

Write-Host 'PASS: Arthur failed Candidate recovery is wired for unattended, idempotent Windows Control Plane repair.'
