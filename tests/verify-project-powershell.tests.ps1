$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$verifierPath = Join-Path $projectRoot 'scripts\verify-project.ps1'
if (-not (Test-Path -LiteralPath $verifierPath -PathType Leaf)) {
    throw 'TEST_FAIL: native PowerShell project verification entrypoint is missing.'
}

$source = Get-Content -Raw -LiteralPath $verifierPath
foreach ($required in @(
    '22 mandatory LuCI plugins',
    'tests/test-version-identity-gate.sh',
    'tests/test-expected-diff-gate.sh',
    'tests/test-adguard-source-of-truth.sh',
    'tests/test-openclash-adguardhome-coexistence.py',
    'scripts/check-product-goal-contract.py',
    'Python 3.10',
    'VERIFY_PROJECT=PASS'
)) {
    if ($source -notmatch [regex]::Escape($required)) {
        throw "TEST_FAIL: PowerShell project verifier does not preserve the canonical check: $required"
    }
}
if ($source -match 'bash\s+scripts/verify-project\.sh|wsl\.exe') {
    throw 'TEST_FAIL: native PowerShell verification must not invoke the failing nested Bash entrypoint or require WSL.'
}

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($verifierPath,[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) {
    throw "TEST_FAIL: invalid PowerShell syntax: $(($errors | ForEach-Object Message) -join '; ')"
}

Write-Output 'VERIFY_PROJECT_POWERSHELL_CONTRACT=PASS'
