$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$fetchScriptPath = Join-Path $projectRoot 'scripts\fetch-immortalwrt-source.sh'
$buildScriptPath = Join-Path $projectRoot 'scripts\build.sh'
$buildEnvPath = Join-Path $projectRoot 'build.env'
$workflowPath = Join-Path $projectRoot '.github\workflows\known-good-fastlane.yml'

if (-not (Test-Path -LiteralPath $fetchScriptPath)) {
    throw 'Expected the dedicated official-source fetch strategy script to exist.'
}

$fetchScript = Get-Content -Raw -LiteralPath $fetchScriptPath
$buildScript = Get-Content -Raw -LiteralPath $buildScriptPath
$buildEnv = Get-Content -Raw -LiteralPath $buildEnvPath
$workflow = Get-Content -Raw -LiteralPath $workflowPath

if ($buildEnv -notmatch 'SOURCE_REPO="https://github.com/immortalwrt/immortalwrt.git"') {
    throw 'build.env must select the official immortalwrt/immortalwrt remote.'
}
if ($buildEnv -notmatch 'SOURCE_REF="27e26e324bee0b0c2a4eb58e2e9121fea5d43194"') {
    throw 'build.env must lock SOURCE_REF to the required exact commit.'
}
if ($workflow -notmatch [regex]::Escape('output/source-fetch.env')) {
    throw 'The Ubuntu fallback artifact must retain source-fetch metadata.'
}

foreach ($required in @(
    'fsck --no-progress',
    'http.version=HTTP/1.1',
    '--depth=1',
    '--filter=blob:none',
    'http.maxRequests=1',
    '--no-tags',
    'https://github.com/immortalwrt/immortalwrt',
    'VERIFIED_SOURCE_CACHE=',
    'SOURCE_COMMIT='
)) {
    if ($fetchScript -notmatch [regex]::Escape($required)) {
        throw "Missing required official source-fetch safeguard: $required"
    }
}

foreach ($forbidden in @(
    'http.sslBackend=',
    'codeload.github.com',
    'fetch_official_archive',
    'official_archive',
    'VIKINGYFY/immortalwrt'
)) {
    if ($fetchScript -match [regex]::Escape($forbidden)) {
        throw "Forbidden source-fetch fallback or remote remains: $forbidden"
    }
}

if ($fetchScript -notmatch 'git\s+-C.*\sinit') {
    throw 'Missing required git init step for official shallow fetch.'
}

if ($buildScript -match 'git clone --filter=blob:none --no-checkout') {
    throw 'build.sh must delegate source acquisition; it must not retain the full-clone fallback.'
}

if ($buildScript -notmatch 'fetch-immortalwrt-source\.sh') {
    throw 'build.sh must use the dedicated official source-fetch strategy.'
}

if ($buildScript -notmatch 'Source method: \$SOURCE_METHOD' -or
    $buildScript -notmatch 'Source integrity: \$SOURCE_INTEGRITY') {
    throw 'build-info must record source method and integrity.'
}

Write-Host 'PASS: source fetch uses verified reuse and official shallow/partial Git fetch only; archive and third-party mirror fallback are forbidden.'
