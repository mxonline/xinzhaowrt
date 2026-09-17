$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BootstrapPath = Join-Path $Root 'scripts\arthur-fresh-execution-bootstrap.ps1'
$GatePath = Join-Path $Root 'scripts\arthur-control-plane-gate.ps1'
$WorkflowPath = Join-Path $Root '.github\workflows\arthur-control-plane.yml'
$KnownGoodPath = Join-Path $Root 'production\known-good.json'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
}
function Assert-Equal {
    param($Actual,$Expected,[string]$Message)
    if ($Actual -ne $Expected) { throw "TEST_FAIL: $Message (actual='$Actual' expected='$Expected')" }
}
function Assert-Contains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "TEST_FAIL: $Message (missing '$Needle')"
    }
}
function Assert-NotContains {
    param([string]$Text,[string]$Needle,[string]$Message)
    if ($Text.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "TEST_FAIL: $Message (unexpected '$Needle')"
    }
}
function Assert-ThrowsLike {
    param([scriptblock]$Action,[string]$Needle,[string]$Message)
    try { & $Action; throw "TEST_FAIL: $Message (did not throw)" }
    catch {
        if ($_.Exception.Message -like 'TEST_FAIL:*') { throw }
        if ($_.Exception.Message.IndexOf($Needle,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "TEST_FAIL: $Message (actual='$($_.Exception.Message)' expected contains '$Needle')"
        }
    }
}
function Copy-JsonObject($Value) {
    return (($Value | ConvertTo-Json -Depth 40) | ConvertFrom-Json)
}
function New-TestRoot {
    param([string]$Name)
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("arthur-bootstrap-$Name-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Force -Path (Join-Path $temp 'production') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $temp 'scripts') | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root 'scripts\arthur-state-contract.ps1') -Destination (Join-Path $temp 'scripts\arthur-state-contract.ps1')
    Copy-Item -LiteralPath (Join-Path $Root 'scripts\arthur-evidence-index.ps1') -Destination (Join-Path $temp 'scripts\arthur-evidence-index.ps1')
    Copy-Item -LiteralPath (Join-Path $Root 'scripts\arthur-firmware-event-ledger.ps1') -Destination (Join-Path $temp 'scripts\arthur-firmware-event-ledger.ps1')
    Copy-Item -LiteralPath $BootstrapPath -Destination (Join-Path $temp 'scripts\arthur-fresh-execution-bootstrap.ps1')
    return $temp
}
function Write-JsonFile([string]$Path,$Value) {
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 40) + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
}

# Static architecture contract: this intentionally fails first while the helper is absent.
Assert-True (Test-Path -LiteralPath $BootstrapPath -PathType Leaf) 'fresh execution bootstrap helper must exist'
$bootstrap = Get-Content -Raw -LiteralPath $BootstrapPath
Assert-NotContains $bootstrap 'run-host-main-push.ps1' 'fresh bootstrap must never use the failed host push bridge'
Assert-NotContains $bootstrap 'github-app-bridge' 'fresh bootstrap must never use the GitHub App host bridge'
Assert-NotContains $bootstrap 'DPAPI' 'fresh bootstrap must never depend on CurrentUser DPAPI'
Assert-NotContains $bootstrap 'C:\Users\chenz' 'fresh bootstrap must never depend on a user-specific worktree'
Assert-NotContains $bootstrap 'force push' 'fresh bootstrap must never force push'
Assert-NotContains $bootstrap '--force' 'fresh bootstrap must never force push'
Assert-Contains $bootstrap 'Invoke-ArthurFreshExecutionBootstrap' 'bootstrap helper must expose the fresh execution entrypoint'

$gate = Get-Content -Raw -LiteralPath $GatePath
$bootstrapCall = $gate.IndexOf('Invoke-ArthurFreshExecutionBootstrap',[StringComparison]::OrdinalIgnoreCase)
$resumeCall = $gate.IndexOf('& $resumeGatePath',[StringComparison]::OrdinalIgnoreCase)
Assert-True ($bootstrapCall -ge 0 -and $resumeCall -gt $bootstrapCall) 'fresh bootstrap must run before Resume Gate'

$workflow = Get-Content -Raw -LiteralPath $WorkflowPath
Assert-Contains $workflow "production/operator-intent.json" 'fresh operator authorization must wake Arthur Control Plane'
Assert-Contains $workflow 'contents: write' 'Arthur Control Plane must retain GitHub-native state publication permission'
Assert-Contains $workflow 'xinzhaowrt-controller' 'Arthur Control Plane must remain on the controller runner'

# Behavioral contract uses the helper in pure (-Apply:$false) mode.
. $BootstrapPath

$oldExecution = 'arthur-final-release-5f41c4e-20260908'
$newExecution = 'arthur-v0-1-5-release-e037750-20260918'
$repoHead = ('d' * 40)
$productSource = ('e' * 40)
$digest = ('a' * 64)

$terminalResume = [pscustomobject][ordered]@{
    schema_version = 2
    execution_id = $oldExecution
    status = 'PRODUCTION_RELEASED'
    instruction_allowed = $false
    release = 'v0.1.4'
    source = [pscustomobject][ordered]@{ repository_head=('b'*40); accepted_source_sha=('b'*40); accepted_release='v0.1.4'; accepted_firmware='old.bin'; accepted_firmware_sha256=('1'*64); accepted_factory_sha256=('2'*64) }
    production = [pscustomobject][ordered]@{ github_run_id=1; artifact_id=2; release_id=3; release='v0.1.4'; release_url='https://example.invalid/v0.1.4'; firmware='old.bin'; candidate_sha256=('1'*64); factory_sha256=('2'*64) }
    device = [pscustomobject][ordered]@{ version='0.1.3'; build_id='33462873812'; git_commit='aaaaaaa'; evidence='BASELINE' }
    gates = [pscustomobject][ordered]@{
        WIFI = [pscustomobject][ordered]@{ gate_id='WIFI'; status='PASS'; requirement_ref='x#wifi'; requirement_digest=$digest; subject=[pscustomobject]@{ source_sha=('b'*40) }; evidence_refs=@('evidence:wifi-old'); inherited=$false; inherited_from=''; verified_at='2026-09-01T00:00:00Z' }
        LUCI_CHINESE = [pscustomobject][ordered]@{ gate_id='LUCI_CHINESE'; status='PASS'; requirement_ref='x#luci'; requirement_digest=$digest; subject=[pscustomobject]@{ source_sha=('b'*40) }; evidence_refs=@('evidence:luci-old'); inherited=$false; inherited_from=''; verified_at='2026-09-01T00:00:00Z' }
        QUICKSTART = [pscustomobject][ordered]@{ gate_id='QUICKSTART'; status='PASS'; requirement_ref='x#quick'; requirement_digest=$digest; subject=[pscustomobject]@{ source_sha=('b'*40) }; evidence_refs=@('evidence:quick-old'); inherited=$false; inherited_from=''; verified_at='2026-09-01T00:00:00Z' }
        CHANGE_IMPACT = [pscustomobject][ordered]@{ gate_id='CHANGE_IMPACT'; status='PASS'; requirement_ref='x#impact'; requirement_digest=$digest; subject=[pscustomobject]@{ source_sha=('b'*40) }; evidence_refs=@('evidence:impact-old'); inherited=$false; inherited_from=''; verified_at='2026-09-01T00:00:00Z' }
        BASELINE_INHERITANCE = [pscustomobject][ordered]@{ gate_id='BASELINE_INHERITANCE'; status='PASS'; requirement_ref='x#inherit'; requirement_digest=$digest; subject=[pscustomobject]@{}; evidence_refs=@('evidence:inherit-old'); inherited=$false; inherited_from=''; verified_at='2026-09-01T00:00:00Z' }
        EXPECTED_DIFF = [pscustomobject][ordered]@{ gate_id='EXPECTED_DIFF'; status='PASS'; requirement_ref='x#diff'; requirement_digest=$digest; subject=[pscustomobject]@{ source_sha=('b'*40) }; evidence_refs=@('evidence:diff-old'); inherited=$false; inherited_from=''; verified_at='2026-09-01T00:00:00Z' }
        BUILD = [pscustomobject][ordered]@{ gate_id='BUILD'; status='PASS'; requirement_ref='x#build'; requirement_digest=$digest; subject=[pscustomobject]@{ source_sha=('b'*40); github_run_id=1 }; evidence_refs=@('evidence:build-old'); inherited=$false; inherited_from=''; verified_at='2026-09-01T00:00:00Z' }
        ARTIFACT = [pscustomobject][ordered]@{ gate_id='ARTIFACT'; status='PASS'; requirement_ref='x#artifact'; requirement_digest=$digest; subject=[pscustomobject]@{ source_sha=('b'*40); github_run_id=1; artifact_id=2 }; evidence_refs=@('evidence:artifact-old'); inherited=$false; inherited_from=''; verified_at='2026-09-01T00:00:00Z' }
        RELEASE_GATE = [pscustomobject][ordered]@{ gate_id='RELEASE_GATE'; status='PASS'; requirement_ref='x#release'; requirement_digest=$digest; subject=[pscustomobject]@{}; evidence_refs=@('evidence:release-old'); inherited=$false; inherited_from=''; verified_at='2026-09-01T00:00:00Z' }
    }
}

$intent = [pscustomobject][ordered]@{
    schema_version='1.1'; project='Arthur'; intent_type='EXECUTE_FIRMWARE'; authorization_scope='FIRMWARE_RELEASE'; firmware_execution_authorized=$true;
    execution_id=$newExecution; release_mode='RELEASE_ONLY'; target_release='v0.1.5'; device_write_authorized=$false;
    firmware_state=[pscustomobject][ordered]@{ current_stage='CHANGE_IMPACT'; next_stage='BASELINE_INHERITANCE'; active_run_id=0; active_source_sha=$productSource; verified_frozen=@('WIFI','LUCI_CHINESE','QUICKSTART'); preserve=@(); source='TEST'; active_artifact_id=$null; candidate_release_conclusion=$null };
    guardrails=[pscustomobject][ordered]@{ release_only=$true; automatic_flash=$false; sysupgrade_forbidden=$true }
}
$policy = [pscustomobject][ordered]@{ mode='RELEASE_ONLY'; unattended_release=$true; automatic_flash=$false }

$temp = New-TestRoot -Name 'valid'
try {
    Write-JsonFile (Join-Path $temp 'production\operator-intent.json') $intent
    Write-JsonFile (Join-Path $temp 'production\release-mode.json') $policy
    Write-JsonFile (Join-Path $temp 'production\resume-state.json') $terminalResume
    [IO.File]::WriteAllText((Join-Path $temp 'production\firmware-events.jsonl'),'',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $temp 'production\known-good.json'),'{"sentinel":"unchanged"}' + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $temp 'VERSION'),'0.1.5' + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    $knownGoodBefore = [IO.File]::ReadAllText((Join-Path $temp 'production\known-good.json'))

    $result = Invoke-ArthurFreshExecutionBootstrap -Root $temp -RepositoryHead $repoHead -RemoteMainHead $repoHead -SourceAncestorConfirmed $true -Apply:$false
    Assert-Equal $result.action 'BOOTSTRAP_REQUIRED' 'valid fresh authorization must require bootstrap'
    Assert-Equal $result.execution_id $newExecution 'bootstrap must bind authorized execution id'
    Assert-Equal $result.resume_state.status 'RESUME_SAFE' 'fresh execution must be resume-safe'
    Assert-True ([bool]$result.resume_state.instruction_allowed) 'fresh execution must allow control-plane continuation'
    Assert-Equal $result.resume_state.current_gate 'CHANGE_IMPACT' 'fresh execution must start at change impact'
    Assert-Equal $result.resume_state.next_action 'CHANGE_IMPACT' 'fresh execution must run change impact first'
    Assert-Equal $result.resume_state.source.repository_head $repoHead 'control-plane repository head must be recorded'
    Assert-Equal $result.resume_state.source.accepted_source_sha $productSource 'product source identity must come from operator intent'
    Assert-Equal ([long]$result.resume_state.production.github_run_id) 0 'fresh execution must not inherit an old build run'
    Assert-Equal ([long]$result.resume_state.production.artifact_id) 0 'fresh execution must not inherit an old artifact'
    Assert-Equal $result.resume_state.gates.BUILD.status 'PENDING' 'BUILD must never be inherited PASS into a fresh execution'
    Assert-Equal $result.resume_state.gates.ARTIFACT.status 'PENDING' 'ARTIFACT must never be inherited PASS into a fresh execution'
    Assert-Equal $result.resume_state.gates.RELEASE_GATE.status 'PENDING' 'RELEASE_GATE must never be inherited PASS into a fresh execution'
    Assert-Equal $result.resume_state.gates.WIFI.status 'PASS' 'explicitly frozen WIFI may be inherited'
    Assert-True ([bool]$result.resume_state.gates.WIFI.inherited) 'frozen WIFI inheritance must be explicit'
    Assert-Equal $result.resume_state.gates.WIFI.inherited_from $oldExecution 'inherited gate must name prior execution'
    Assert-Equal $result.evidence_index.execution_id $newExecution 'fresh evidence index must share execution id'
    Assert-Equal @($result.evidence_index.evidence).Count 0 'bootstrap itself must not fabricate gate PASS evidence'
    Assert-Equal $result.event.event 'EXECUTION_STARTED' 'bootstrap must append an execution-aware start event'
    Assert-Equal $result.event.data.execution_id $newExecution 'bootstrap event must bind new execution'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $temp 'production\known-good.json'))) $knownGoodBefore 'pure bootstrap must not modify known-good'

    $sameResume = Copy-JsonObject $result.resume_state
    Write-JsonFile (Join-Path $temp 'production\resume-state.json') $sameResume
    $same = Invoke-ArthurFreshExecutionBootstrap -Root $temp -RepositoryHead $repoHead -RemoteMainHead $repoHead -SourceAncestorConfirmed $true -Apply:$false
    Assert-Equal $same.action 'NOOP_CURRENT_EXECUTION' 'same execution rerun must be idempotent'
}
finally { Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue }

$temp = New-TestRoot -Name 'unauthorized'
try {
    $unauthorized = Copy-JsonObject $intent
    $unauthorized.firmware_execution_authorized = $false
    Write-JsonFile (Join-Path $temp 'production\operator-intent.json') $unauthorized
    Write-JsonFile (Join-Path $temp 'production\release-mode.json') $policy
    Write-JsonFile (Join-Path $temp 'production\resume-state.json') $terminalResume
    [IO.File]::WriteAllText((Join-Path $temp 'production\firmware-events.jsonl'),'',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $temp 'production\known-good.json'),'{}' + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $temp 'VERSION'),'0.1.5' + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    $result = Invoke-ArthurFreshExecutionBootstrap -Root $temp -RepositoryHead $repoHead -RemoteMainHead $repoHead -SourceAncestorConfirmed $true -Apply:$false
    Assert-Equal $result.action 'NOOP_NOT_AUTHORIZED' 'unauthorized intent must not bootstrap'
}
finally { Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue }

$temp = New-TestRoot -Name 'failclosed'
try {
    Write-JsonFile (Join-Path $temp 'production\operator-intent.json') $intent
    Write-JsonFile (Join-Path $temp 'production\release-mode.json') $policy
    Write-JsonFile (Join-Path $temp 'production\resume-state.json') $terminalResume
    [IO.File]::WriteAllText((Join-Path $temp 'production\firmware-events.jsonl'),'',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $temp 'production\known-good.json'),'{}' + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $temp 'VERSION'),'0.1.4' + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    Assert-ThrowsLike { Invoke-ArthurFreshExecutionBootstrap -Root $temp -RepositoryHead $repoHead -RemoteMainHead $repoHead -SourceAncestorConfirmed $true -Apply:$false } 'VERSION_TARGET_MISMATCH' 'version mismatch must fail closed'

    [IO.File]::WriteAllText((Join-Path $temp 'VERSION'),'0.1.5' + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    Assert-ThrowsLike { Invoke-ArthurFreshExecutionBootstrap -Root $temp -RepositoryHead $repoHead -RemoteMainHead ('f'*40) -SourceAncestorConfirmed $true -Apply:$false } 'REMOTE_HEAD_MISMATCH' 'remote head drift must fail closed'
    Assert-ThrowsLike { Invoke-ArthurFreshExecutionBootstrap -Root $temp -RepositoryHead $repoHead -RemoteMainHead $repoHead -SourceAncestorConfirmed $false -Apply:$false } 'SOURCE_NOT_ANCESTOR' 'product source outside current main lineage must fail closed'

    $unsafeIntent = Copy-JsonObject $intent
    $unsafeIntent.device_write_authorized = $true
    Write-JsonFile (Join-Path $temp 'production\operator-intent.json') $unsafeIntent
    Assert-ThrowsLike { Invoke-ArthurFreshExecutionBootstrap -Root $temp -RepositoryHead $repoHead -RemoteMainHead $repoHead -SourceAncestorConfirmed $true -Apply:$false } 'DEVICE_WRITE_FORBIDDEN' 'fresh RELEASE_ONLY bootstrap must reject device-write authorization'
}
finally { Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue }

Write-Host 'ARTHUR_FRESH_EXECUTION_BOOTSTRAP=PASS'
