$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'scripts\arthur-product-goal-resume.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw 'TEST_FAIL: the product-goal resume evidence binder is missing.'
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "TEST_FAIL: product-goal resume binder syntax is invalid: $(($parseErrors | ForEach-Object Message) -join '; ')"
}
$functions = $ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @('Assert-ArthurPriorProductGoalRun','Assert-ArthurPostFlashEvidenceBinding')
},$true)
foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
if ($functions.Count -ne 2) { throw 'TEST_FAIL: evidence binder must expose both pure identity assertion functions.' }

$request = [pscustomobject]@{
    release_tag='v0.1.6'; candidate_tag='arthur-update-38000704263'
    source_sha='b4448e62ab1e767f9a60221b0600c60c355baf56'
    build_run_id=38000704263; artifact_id=11655711894
    actions_artifact_sha256='sha256:29b3e95051501c16076a0ec1c4d1ce4ec9d27293faccddfa7e24b2838fe690c7'
    sysupgrade_sha256='e175fc88d32ea9308aab40b84fbcc8e84a6bf3dc32bbe7e3a17894361cc89b39'
    management_ip='192.168.6.1'; management_mac='dc:d8:7c:45:91:99'
}
$base = [pscustomobject]@{
    result='PASS';mode='PostFlash';candidate=$request.candidate_tag;commit=$request.source_sha
    device=[pscustomobject]@{model='JDCloud RE-SS-01';target='jdcloud_re-ss-01';address='192.168.6.1';lan='192.168.6.1'}
}
$markers = [ordered]@{
    DEVICE_EXACT_ARTIFACT_MATCH='PASS'; POSTFLASH_BASE_VERIFICATION='PASS'; REBOOT_PERSISTENCE='PASS'
    QUICKSTART_LINKEASE_FILE_MANAGER='PASS'; LINKEASE_MMCBLK0P27_BROWSE='PASS'
    QUICKFILE_BACKEND='PASS'; QUICKFILE_UI='PASS'; NO_FILE_MANAGEMENT_404_502='PASS'
    WAN_8897_RULE_ADDED='NO'; LINKEASE_ALLOW_PUBLIC='0'
}
$fileEvidence = [pscustomobject]@{
    status='PASS'; release_tag=$request.release_tag; candidate_tag=$request.candidate_tag
    source_sha=$request.source_sha; build_run_id=$request.build_run_id; artifact_id=$request.artifact_id
    actions_artifact_sha256=$request.actions_artifact_sha256; sysupgrade_sha256=$request.sysupgrade_sha256
    device_build_id='38000704263'; markers=[pscustomobject]$markers
}
$steps = @(
    [pscustomobject]@{name='Execute exact-release flash and base/file-management acceptance';conclusion='skipped'},
    [pscustomobject]@{name='Execute strictly no-flash PostFlash resume';conclusion='success'},
    [pscustomobject]@{name='Execute exact-release highest product-goal runtime validation';conclusion='failure'},
    [pscustomobject]@{name='Persist independent post-release machine evidence locally';conclusion='success'}
)
$run = [pscustomobject]@{
    id=38087541420; name='Arthur v0.1.6 Post-Release Device Test'
    path='.github/workflows/arthur-post-release-device-test.yml@refs/heads/main'
    event='workflow_dispatch'; status='completed'; conclusion='failure'; head_branch='main'
    head_sha='9e792932fc4e56851fd526653b42da79c48adb4c'
}
$jobs = [pscustomobject]@{
    total_count=1
    jobs=@([pscustomobject]@{name='exact-release-device-test';status='completed';conclusion='failure';steps=$steps})
}

Assert-ArthurPriorProductGoalRun -Run $run -Jobs $jobs -ExpectedRunId 38087541420 | Out-Null
Assert-ArthurPostFlashEvidenceBinding -Request $request -BaseEvidence $base -FileEvidence $fileEvidence | Out-Null

$badFileEvidence = $fileEvidence | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$badFileEvidence.source_sha = '0e'.PadRight(40,'0')
$rejected = $false
try { Assert-ArthurPostFlashEvidenceBinding -Request $request -BaseEvidence $base -FileEvidence $badFileEvidence | Out-Null }
catch { $rejected = $_.Exception.Message -match 'SOURCE_SHA_MISMATCH' }
if (-not $rejected) { throw 'TEST_FAIL: a mismatched evidence source SHA was not rejected.' }

$badJobs = $jobs | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$badJobs.jobs[0].steps[0].conclusion = 'success'
$rejected = $false
try { Assert-ArthurPriorProductGoalRun -Run $run -Jobs $badJobs -ExpectedRunId 38087541420 | Out-Null }
catch { $rejected = $_.Exception.Message -match 'FLASH_STEP_NOT_SKIPPED' }
if (-not $rejected) { throw 'TEST_FAIL: prior evidence was accepted without proof that the flash-capable step was skipped.' }

$badPersist = $jobs | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$badPersist.jobs[0].steps[3].conclusion = 'failure'
$rejected = $false
try { Assert-ArthurPriorProductGoalRun -Run $run -Jobs $badPersist -ExpectedRunId 38087541420 | Out-Null }
catch { $rejected = $_.Exception.Message -match 'POSTFLASH_EVIDENCE_PERSISTENCE_NOT_PASS' }
if (-not $rejected) { throw 'TEST_FAIL: prior evidence was accepted when the runner evidence persistence step failed.' }

$badRun = $run | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$badRun.head_sha = '0e'.PadRight(40,'0')
$rejected = $false
try { Assert-ArthurPriorProductGoalRun -Run $badRun -Jobs $jobs -ExpectedRunId 38087541420 | Out-Null }
catch { $rejected = $_.Exception.Message -match 'PRIOR_RUN_SOURCE_COMMIT_MISMATCH' }
if (-not $rejected) { throw 'TEST_FAIL: prior evidence was accepted from an unexpected control-plane commit.' }

$badMarkers = $fileEvidence | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$badMarkers.markers.QUICKFILE_UI = 'FAIL'
$rejected = $false
try { Assert-ArthurPostFlashEvidenceBinding -Request $request -BaseEvidence $base -FileEvidence $badMarkers | Out-Null }
catch { $rejected = $_.Exception.Message -match 'REQUIRED_PRIOR_MARKER_NOT_PASS=QUICKFILE_UI' }
if (-not $rejected) { throw 'TEST_FAIL: a failed prior file-management marker was accepted.' }

$badBase = $base | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$badBase.device.address = '192.168.1.1'
$rejected = $false
try { Assert-ArthurPostFlashEvidenceBinding -Request $request -BaseEvidence $badBase -FileEvidence $fileEvidence | Out-Null }
catch { $rejected = $_.Exception.Message -match 'BASE_EVIDENCE_DEVICE_IDENTITY_MISMATCH' }
if (-not $rejected) { throw 'TEST_FAIL: PostFlash evidence was accepted for a different management address.' }

$binder = Get-Content -Raw -LiteralPath $scriptPath
if ($binder -match '(?i)Ensure-ArthurUnattendedAccess|PasswordAuth|Ensure-ArthurRunnerKey|ssh-keygen\s+-R|/sbin/sysupgrade|sysupgrade(\.exe)?\s+-[Tn]\b|\breboot\b|Invoke-StrictScp') {
    throw 'TEST_FAIL: product-goal evidence binding must not recover SSH, write the device, flash, or reboot.'
}
foreach ($required in @('Get-ArthurReadOnlyIdentityCommand','StrictMode yes','Test-ArthurReadOnlyAuthenticatedEvidence','Assert-ArthurEthernetIdentity','SECOND_FLASH_EXECUTED=NO','PRODUCT_GOAL_RESUME_IDENTITY=PASS')) {
    if (-not $binder.Contains($required)) { throw "TEST_FAIL: product-goal resume is missing read-only identity guard: $required" }
}

Write-Output 'ARTHUR_PRODUCT_GOAL_RESUME_EVIDENCE_BINDING=PASS'
Write-Output 'ARTHUR_PRODUCT_GOAL_RESUME_NO_FLASH_NO_REBOOT=PASS'
Write-Output 'ARTHUR_PRODUCT_GOAL_RESUME_READ_ONLY_IDENTITY=PASS'
