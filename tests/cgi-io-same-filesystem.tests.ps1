$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$patchPath = Join-Path $projectRoot 'patches\cgi-io\950-xinzhao-disk-upload-temp.patch'
$applyScript = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'scripts\apply-upload-oom-fix.sh')
$checkScript = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'scripts\check-upload-oom-fix.sh')
$buildCheck = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'scripts\verify-upload-oom-build.sh')

if (Test-Path -LiteralPath $patchPath) {
    throw 'cgi-io must use the upstream /tmp O_TMPFILE implementation; no XinZhao cgi-io temporary-directory patch may be present.'
}

foreach ($source in @($applyScript, $buildCheck)) {
    if ($source -match 'XINZHAO_UPLOAD_TMPDIR|cgi-io/950-xinzhao-disk-upload-temp\.patch|\.xinzhao-upload/cgi-io') {
        throw 'Build logic must not redirect cgi-io temporary files away from /tmp/firmware.bin''s filesystem.'
    }
}

if ($applyScript -notmatch 'official cgi-io implementation' -or
    $checkScript -notmatch 'official cgi-io implementation' -or
    $buildCheck -notmatch 'open\("/tmp", O_TMPFILE') {
    throw 'Build guards must explicitly verify the current upstream cgi-io /tmp O_TMPFILE implementation.'
}

Write-Host 'PASS: cgi-io temporary files remain on the same /tmp filesystem as /tmp/firmware.bin.'
