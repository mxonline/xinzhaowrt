$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$workflowPath = Join-Path $projectRoot '.github\workflows\arthur-post-release-device-test.yml'
$resumeScriptPath = Join-Path $projectRoot 'scripts\arthur-postflash-resume.ps1'
$workflow = Get-Content -Raw -LiteralPath $workflowPath
if (-not (Test-Path -LiteralPath $resumeScriptPath -PathType Leaf)) {
    throw 'TEST_FAIL: the workflow must dispatch to a dedicated resume-only verifier.'
}

foreach ($required in @(
    'workflow_dispatch:',
    'resume_postflash_only:',
    'ARTHUR_ROOT_PASSWORD: ${{ secrets.ARTHUR_ROOT_PASSWORD }}',
    "if: github.event_name == 'push' || inputs.resume_postflash_only == 'true'",
    '- name: Load exact current workflow source',
    "'-C',`$sourceRoot,'remote','get-url','origin'",
    "'-c','http.sslBackend=openssl'",
    "'-c','http.connectTimeout=30'",
    "'-c','http.lowSpeedLimit=1024'",
    "'-c','http.lowSpeedTime=30'",
    "'-c','credential.interactive=never'",
    "'fetch','--no-tags','--depth=1','origin',`$env:GITHUB_SHA",
    "'-C',`$sourceRoot,'checkout','--detach','FETCH_HEAD'",
    "`$env:GIT_TERMINAL_PROMPT = '0'",
    "`$env:GCM_INTERACTIVE = 'Never'",
    'SOURCE_FETCH_ATTEMPT attempt=$attempt/$maxAttempts',
    'WORKFLOW_SOURCE_LOCAL_REUSE=PASS',
    'SOURCE_FETCH_RETRY_CLASSIFICATION=PASS',
    'SOURCE_FETCH_TRANSIENT_EXHAUSTED',
    "'worktree','add','--detach',`$sourceRoot,`$env:GITHUB_SHA",
    '$retryDelaysSeconds = @(5,10,20,30)',
    '基础连接已经关闭',
    '远程方已关闭传输流',
    '[System.IO.File]::AppendAllText($env:GITHUB_ENV',
    'ARTHUR_SOURCE_ROOT',
    '- self-hosted',
    '- windows',
    '- x64',
    '- xinzhaowrt-controller',
    "if: github.event_name == 'push'",
    "if: github.event_name == 'workflow_dispatch' && inputs.resume_postflash_only == 'true'",
    'scripts\arthur-postflash-resume.ps1'
)) {
    if (-not $workflow.Contains($required)) {
        throw "TEST_FAIL: guarded PostFlash dispatch is missing required workflow behavior: $required"
    }
}
if ($workflow -match '(?m)^\s*uses:\s*actions/') {
    throw 'TEST_FAIL: the postflash resume workflow must not depend on downloading an external GitHub Action.'
}

$resume = Get-Content -Raw -LiteralPath $resumeScriptPath
foreach ($required in @(
    'Assert-ArthurEthernetIdentity',
    'STOP=POSTFLASH_EXACT_RELEASE_IDENTITY_LOST',
    'SECOND_FLASH_EXECUTED=NO',
    "Version -eq '0.1.6'",
    "BuildId -eq '38000704263'",
    'Invoke-ArthurSshProbe',
    '-PasswordAuth',
    'ExpectedVersion ''0.1.6''',
    'ExpectedBuildId ''38000704263''',
    'real-device-verify-v3.ps1',
    "-Mode','PostFlash'",
    '/cgi-bin/luci/admin/system/quickfile',
    '/cgi-bin/luci/admin/services/linkease/file/?path=/data_mmcblk0p27',
    'v016-file-management-postflash.json'
)) {
    if (-not $resume.Contains($required)) {
        throw "TEST_FAIL: PostFlash-only verifier is missing required release or product proof: $required"
    }
}

if ($resume -match '(?i)/sbin/sysupgrade|sysupgrade(\.exe)?\s+-[Tn]\b|Invoke-StrictScp|(^|\W)scp(\.exe)?(\W|$)|gh\s+release\s+download|firmware.*download|download.*firmware|gh\s+release\s+create') {
    throw 'TEST_FAIL: resume-only verifier must not download firmware, upload firmware, build, release, or invoke any sysupgrade path.'
}

$resumeStepStart = $workflow.IndexOf('      - name: Execute strictly no-flash PostFlash resume',[StringComparison]::Ordinal)
$resumeStepEnd = if ($resumeStepStart -ge 0) { $workflow.IndexOf("`n      - name:",$resumeStepStart + 1,[StringComparison]::Ordinal) } else { -1 }
if ($resumeStepStart -lt 0 -or $resumeStepEnd -lt 0) { throw 'TEST_FAIL: the resume-only workflow step must be a separate gated step.' }
$resumeStep = $workflow.Substring($resumeStepStart,$resumeStepEnd-$resumeStepStart)
if (-not $resumeStep.Contains("if: github.event_name == 'workflow_dispatch' && inputs.resume_postflash_only == 'true'")) {
    throw 'TEST_FAIL: the no-flash verifier must run only for an explicit true resume dispatch.'
}
if (-not $resumeStep.Contains('ARTHUR_ROOT_PASSWORD: ${{ secrets.ARTHUR_ROOT_PASSWORD }}')) {
    throw 'TEST_FAIL: the runner secret must be scoped to the authenticated resume step.'
}
if ($resumeStep -match '(?i)arthur-post-release-v016-device-test|sysupgrade|scp|firmware') {
    throw 'TEST_FAIL: the resume dispatch must bypass the flash-capable release device-test script.'
}
if ($workflow -match '(?m)^      ARTHUR_ROOT_PASSWORD:') {
    throw 'TEST_FAIL: the root password secret must not be exposed to every job step.'
}

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($resumeScriptPath,[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) {
    throw "TEST_FAIL: PostFlash-only verifier PowerShell syntax is invalid: $(($errors | ForEach-Object Message) -join '; ')"
}

$workflowLines = Get-Content -LiteralPath $workflowPath
$runBlockCount = 0
for ($i = 0; $i -lt $workflowLines.Count; $i++) {
    if ([string]$workflowLines[$i] -ne '        run: |') { continue }
    $scriptLines = @()
    for ($j = $i + 1; $j -lt $workflowLines.Count; $j++) {
        $line = [string]$workflowLines[$j]
        if ($line.Length -gt 0 -and $line -notmatch '^ {10}') { break }
        if ($line.Length -gt 0) { $scriptLines += $line.Substring(10) } else { $scriptLines += '' }
    }
    $temporaryScript = Join-Path ([System.IO.Path]::GetTempPath()) ("arthur-postflash-workflow-parse-{0}-{1}.ps1" -f $PID,$i)
    try {
        [System.IO.File]::WriteAllLines($temporaryScript,$scriptLines,[Text.UTF8Encoding]::new($false))
        $workflowTokens = $null
        $workflowErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($temporaryScript,[ref]$workflowTokens,[ref]$workflowErrors)
        if ($workflowErrors.Count -gt 0) {
            throw "TEST_FAIL: workflow PowerShell block at line $($i+1) is invalid: $(($workflowErrors | ForEach-Object Message) -join '; ')"
        }
        $runBlockCount++
    }
    finally { Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $temporaryScript }
}
if ($runBlockCount -lt 5) { throw 'TEST_FAIL: workflow PowerShell blocks were not parsed.' }

Write-Output 'ARTHUR_POSTFLASH_RESUME_ONLY_WORKFLOW=PASS'
Write-Output 'ARTHUR_POSTFLASH_RESUME_NO_FLASH_BOUNDARY=PASS'
