$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BootstrapPath = Join-Path $Root 'scripts\bootstrap-arthur-windows-admin.ps1'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "TEST_FAIL: $Message" }
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

Assert-True (Test-Path -LiteralPath $BootstrapPath -PathType Leaf) 'one-time Arthur Windows administrator bootstrap must exist'
$source = Get-Content -Raw -LiteralPath $BootstrapPath

Assert-Contains $source 'WindowsBuiltInRole]::Administrator' 'bootstrap must fail closed unless PowerShell is elevated'
Assert-Contains $source 'xinzhaowrt-runner' 'bootstrap must migrate runtime ownership to the dedicated runner account'
Assert-Contains $source 'SeBatchLogonRight' 'bootstrap must grant only the batch-logon right required for S4U Scheduled Tasks'
Assert-Contains $source 'LsaAddAccountRights' 'batch-logon grant must use the Windows LSA API rather than broad local-admin membership'
Assert-Contains $source 'S4U' 'bootstrap must validate a passwordless runner-owned Scheduled Task context'
Assert-Contains $source 'arthur-codex-runtime-probe.py' 'bootstrap must run the isolated Codex runtime probe before task migration'
Assert-Contains $source 'PROBE_OK' 'bootstrap must require a successful Codex runtime probe before migration'
Assert-Contains $source 'model_catalog_skipped' 'bootstrap must require the model-catalog bypass to be active'
Assert-Contains $source 'gpt-5.6-terra' 'bootstrap must require the approved explicit Codex model'
Assert-Contains $source 'runtime-state.json' 'bootstrap must explicitly preserve the durable runtime handoff'
Assert-Contains $source 'RUNTIME_STATE_PRESERVED=PASS' 'bootstrap must emit evidence that the durable runtime file was unchanged before recovery starts'
Assert-Contains $source 'XinZhaoWrt-Arthur-Persistent-Supervisor' 'bootstrap must migrate the stable Supervisor task name, not create a competing name'
Assert-Contains $source 'XinZhaoWrt-Arthur-Repair-Controller' 'bootstrap must install the independent Repair Controller under the runner-owned context'
Assert-Contains $source 'FullRecovery' 'after safe migration the bootstrap must hand off to bounded FullRecovery'
Assert-Contains $source 'CODEX_RUNTIME_RECOVERED' 'bootstrap must wait for the existing recovery gate result rather than claim success early'

$probeIndex = $source.IndexOf('PROBE_OK',[System.StringComparison]::OrdinalIgnoreCase)
$migrationIndex = $source.IndexOf('PERSISTENT_SUPERVISOR_RUNNER_OWNED=PASS',[System.StringComparison]::OrdinalIgnoreCase)
Assert-True ($probeIndex -ge 0 -and $migrationIndex -ge 0 -and $probeIndex -lt $migrationIndex) 'disposable S4U Codex probe must pass before Supervisor ownership migration'

Assert-NotContains $source 'net localgroup administrators' 'bootstrap must never grant local administrator membership to the runner account'
Assert-NotContains $source 'Add-LocalGroupMember' 'bootstrap must never add the runner account to Administrators'
Assert-NotContains $source 'reset --hard' 'bootstrap must not destructively reset control-runtime'
Assert-NotContains $source 'git clean' 'bootstrap must not clean repositories'
Assert-NotContains $source 'git stash' 'bootstrap must not stash mutable work'
Assert-NotContains $source 'Remove-Item $runtimeState' 'bootstrap must never delete runtime-state.json'
Assert-NotContains $source 'sysupgrade' 'administrator bootstrap must have no firmware flashing authority'
Assert-NotContains $source 'arthur-update' 'administrator bootstrap must not dispatch firmware builds'

Write-Host 'ARTHUR_ADMIN_BOOTSTRAP_PRIVILEGE_BOUNDARY=PASS'
Write-Host 'ARTHUR_ADMIN_BOOTSTRAP_S4U_PROBE_FIRST=PASS'
Write-Host 'ARTHUR_ADMIN_BOOTSTRAP_RUNTIME_STATE_PRESERVATION=PASS'
Write-Host 'ARTHUR_ADMIN_BOOTSTRAP_NO_FIRMWARE_AUTHORITY=PASS'
