$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$scripts = @(
    (Join-Path $projectRoot 'scripts\check-config.sh'),
    (Join-Path $projectRoot 'scripts\verify-project.sh'),
    (Join-Path $projectRoot 'scripts\check-package-existence.sh')
)

foreach ($scriptPath in $scripts) {
    $source = Get-Content -Raw -LiteralPath $scriptPath
    if ($source -notmatch "pkg=\u0022\$\{pkg%\$'\\r'\}\u0022") {
        throw "$(Split-Path -Leaf $scriptPath) must remove a CRLF trailing carriage return before forming mandatory plugin symbols."
    }
}

Write-Host 'PASS: mandatory-plugin guards normalize CRLF input before validating =y symbols.'
