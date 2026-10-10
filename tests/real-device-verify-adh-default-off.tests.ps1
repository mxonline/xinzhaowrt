$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$verifyPath = Join-Path $projectRoot 'scripts\real-device-verify.ps1'
$source = Get-Content -Raw -LiteralPath $verifyPath
$lines = @($source -split "`r?`n" | Where-Object { $_ -match 'Test-Remote\s+"\$Prefix\.adguard_default_off"' })
if ($lines.Count -ne 1) { throw "TEST_FAIL: expected exactly one AdGuardHome default-off remote check, found $($lines.Count)." }
$line = $lines[0]

if ($source.Contains('uci -q get adguardhome.config.enabled')) {
    throw 'TEST_FAIL: verifier still uses the non-authoritative lowercase AdGuardHome UCI namespace.'
}
if ($line -notmatch 'uci -q get AdGuardHome\.AdGuardHome\.enabled') {
    throw 'TEST_FAIL: verifier does not query AdGuardHome.AdGuardHome.enabled.'
}
if ($line -notmatch 'pidof AdGuardHome') {
    throw 'TEST_FAIL: default-off check does not require the AdGuardHome process to be stopped.'
}
if ($line -notmatch 'pidof AdGuardHome >/dev/null 2>&1 && exit 1') {
    throw 'TEST_FAIL: a running AdGuardHome process does not fail the default-off check.'
}
if ($line -notmatch '\[ "\$enabled" = 0 \] \|\| exit 1') {
    throw 'TEST_FAIL: an absent or nonzero authoritative UCI value does not fail the default-off check.'
}
if ($line -notmatch '/etc/rc\.d/S\*AdGuardHome' -or $line -notmatch '/etc/rc\.d/S\*adguardhome') {
    throw 'TEST_FAIL: default-off check does not inspect both historical service symlink casings.'
}
if ($line -notmatch '\[ -L "\$link" \] && exit 1') {
    throw 'TEST_FAIL: service startup check must detect symlinks, including broken symlinks.'
}
if ($line -notmatch 'done; exit 0') {
    throw 'TEST_FAIL: symlink absence loop does not finish with an explicit success status.'
}
if ($line -notmatch '\{ param\(\$o\) \$o -match ''\(\?m\)\^enabled=0\$'' \}') {
    throw 'TEST_FAIL: verifier does not require enabled=0 in the authoritative UCI output.'
}

Write-Output 'REAL_DEVICE_ADGUARD_AUTHORITATIVE_UCI=PASS'
Write-Output 'REAL_DEVICE_ADGUARD_DEFAULT_OFF_TRIPLE_CHECK=PASS'
