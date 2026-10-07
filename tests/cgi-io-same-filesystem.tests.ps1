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

if ($applyScript -match 'CGI_MAIN|cgi-io/src/main\.c|O_TMPFILE') {
    throw 'Pre-build upload validation must not read cgi-io upstream source before OpenWrt prepares build_dir.'
}
if ($applyScript -notmatch 'CGI_PKG/Makefile' -or
    $applyScript -notmatch 'check-upload-oom-fix\.sh' -or
    $applyScript -notmatch 'ui\.uploadFile\(''/tmp/firmware\.bin''' -or
    $applyScript -notmatch 'luci-mod-system\.json') {
    throw 'Pre-build upload validation must retain package-recipe and LuCI /tmp/firmware.bin handoff checks.'
}
if ($checkScript -notmatch 'official cgi-io implementation' -or
    $buildCheck -notmatch 'open\("/tmp", O_TMPFILE') {
    throw 'Post-build guard must verify the prepared cgi-io /tmp O_TMPFILE implementation.'
}

Write-Host 'PASS: cgi-io temporary files remain on the same /tmp filesystem as /tmp/firmware.bin.'
