$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\scripts\real-device-upload-oom.ps1'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw 'Expected Stage M runner is missing: scripts/real-device-upload-oom.ps1'
}

$source = Get-Content -Raw -LiteralPath $scriptPath

foreach ($required in @(
    'scriptname',
    'cgi-upload',
    'sessionid',
    'filename',
    'filedata',
    'SMALL_UPLOAD_PREFLIGHT=PASS',
    'AUTO_FLASH_SAFETY_GATE'
)) {
    if (-not $source.Contains($required)) {
        throw "Stage M runner is missing required guard or protocol marker: $required"
    }
}

if ($source -match '-Endpoint\s+["'']?/cgi-bin/luci/cgi-upload') {
    throw 'Stage M runner must not use the incorrect /cgi-bin/luci/cgi-upload endpoint for a request.'
}
if ($source -notmatch '\$endpoint\s+-eq\s+["'']/cgi-bin/luci/cgi-upload') {
    throw 'Stage M runner must reject the legacy endpoint if runtime discovery ever returns it.'
}
if ($source -notmatch '-LocalFile \$smallFile -Destination ''/tmp/firmware.bin''') {
    throw 'Stage M small-file preflight must use the same ACL-authorized /tmp/firmware.bin handoff path as the large upload.'
}

if ($source -notmatch 'AUTO_FLASH_SAFETY_GATE') {
    throw 'Stage M runner must identify the production AUTO_FLASH_SAFETY_GATE handoff.'
}

Write-Host 'PASS: Stage M runner contains runtime endpoint discovery and automatic safety-gate handoff.'
