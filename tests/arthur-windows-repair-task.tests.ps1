$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$InstallerPath = Join-Path $Root 'scripts\ensure-arthur-windows-repair-controller.ps1'

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

Assert-True (Test-Path -LiteralPath $InstallerPath -PathType Leaf) 'Arthur Windows Repair Controller task installer must exist'
$installer = Get-Content -Raw -LiteralPath $InstallerPath
Assert-Contains $installer 'XinZhaoWrt-Arthur-Repair-Controller' 'repair task name must be stable'
Assert-Contains $installer 'XinZhaoWrt-Arthur-Persistent-Supervisor' 'repair task principal must be inherited from supervisor task'
Assert-Contains $installer 'Principal.UserId' 'repair task must read the approved Supervisor principal user directly'
Assert-Contains $installer 'Principal.LogonType' 'repair task must inherit Supervisor logon type so runner-owned S4U remains S4U'
Assert-Contains $installer 'Principal.RunLevel' 'repair task must inherit Supervisor run level instead of inventing elevation'
Assert-Contains $installer '-LogonType $runtimeLogonType' 'repair task principal must use inherited logon type'
Assert-Contains $installer '-RunLevel $runtimeRunLevel' 'repair task principal must use inherited run level'
Assert-Contains $installer 'MultipleInstances IgnoreNew' 'repair task must be single-instance'
Assert-Contains $installer 'invoke-arthur-windows-repair-controller.ps1' 'task must invoke the durable repair controller wrapper'
Assert-Contains $installer 'XinZhaoWrt\RepairController' 'launcher must live under canonical ProgramData RepairController directory'
Assert-Contains $installer 'ARTHUR_CONTROL_PLANE_CODE_ROOT' 'repair launcher must bind clean control-runtime'
Assert-Contains $installer 'ARTHUR_CONTROL_PLANE_STATE_DIR' 'repair launcher must bind canonical state directory'
Assert-Contains $installer 'HEADLESS_PYTHON_EXE' 'repair launcher must bind managed Python'
Assert-Contains $installer 'HEADLESS_CODEX_MODEL' 'repair launcher must bind explicit Codex model'
Assert-Contains $installer 'gpt-5.6-terra' 'repair launcher must use the approved explicit model'
Assert-Contains $installer 'REPAIR_CONTROLLER_TASK_REREGISTERED=PASS' 'drifted repair task must be re-registered under the same name'
Assert-Contains $installer 'repairTaskDrift' 'repair installer must compare existing action with canonical action'
Assert-Contains $installer 'runtimeLogonType' 'principal drift must include logon type'
Assert-Contains $installer 'runtimeRunLevel' 'principal drift must include run level'
Assert-NotContains $installer 'sysupgrade' 'task installer must not gain firmware authority'
Assert-NotContains $installer 'arthur-update' 'task installer must not dispatch firmware builds'

$env:ARTHUR_REPAIR_TASK_IMPORT_ONLY = '1'
try {
    . $InstallerPath -StateDir $Root -ControlRoot $Root -HeadlessPythonExe ([Diagnostics.Process]::GetCurrentProcess().Path)
    $same = [pscustomobject]@{
        Execute = 'powershell.exe'
        Arguments = '-NoProfile -File "C:\ProgramData\XinZhaoWrt\RepairController\run-arthur-repair-controller.ps1"'
        WorkingDirectory = 'C:\ProgramData\XinZhaoWrt\RepairController'
    }
    Assert-True (-not (Test-ArthurRepairTaskActionDrift -ExistingAction $same -ExpectedExecute $same.Execute -ExpectedArguments $same.Arguments -ExpectedWorkingDirectory $same.WorkingDirectory)) 'matching repair task action must not drift'
    $drift = [pscustomobject]@{
        Execute = 'powershell.exe'
        Arguments = '-NoProfile -File "C:\old\repair.ps1"'
        WorkingDirectory = 'C:\old'
    }
    Assert-True (Test-ArthurRepairTaskActionDrift -ExistingAction $drift -ExpectedExecute $same.Execute -ExpectedArguments $same.Arguments -ExpectedWorkingDirectory $same.WorkingDirectory) 'changed repair task action must be detected as drift'
}
finally {
    Remove-Item Env:ARTHUR_REPAIR_TASK_IMPORT_ONLY -ErrorAction SilentlyContinue
}

Write-Host 'ARTHUR_WINDOWS_REPAIR_TASK_CONTRACT=PASS'
Write-Host 'ARTHUR_WINDOWS_REPAIR_TASK_PRINCIPAL_INHERITANCE_CONTRACT=PASS'
Write-Host 'ARTHUR_WINDOWS_REPAIR_TASK_DRIFT_CONTRACT=PASS'
