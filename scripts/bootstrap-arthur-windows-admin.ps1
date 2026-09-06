[CmdletBinding()]
param(
    [string]$RunnerUser = "$env:COMPUTERNAME\xinzhaowrt-runner",
    [string]$RunnerLocalBase = 'C:\Users\xinzhaowrt-runner\AppData\Local\XinZhaoWrt',
    [string]$SupervisorTaskName = 'XinZhaoWrt-Arthur-Persistent-Supervisor',
    [string]$RepairTaskName = 'XinZhaoWrt-Arthur-Repair-Controller',
    [int]$ProbeTimeoutSeconds = 75,
    [int]$RecoveryTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$Message) {
    throw $Message
}

function Quote-PsLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-GitChecked {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string[]]$Arguments
    )
    $safe = "safe.directory=$Root"
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -c $safe -C $Root @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    $text = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if ($code -ne 0) {
        Fail ("ADMIN_BOOTSTRAP_GIT_FAILED: git {0}; exit={1}; output={2}" -f ($Arguments -join ' '),$code,$text)
    }
    return $text
}

function Resolve-AccountSid {
    param([Parameter(Mandatory=$true)][string]$Account)
    $nt = New-Object System.Security.Principal.NTAccount($Account)
    return [string]$nt.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function Grant-DirectoryModify {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Account
    )
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    $acl = Get-Acl -LiteralPath $Path
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Account,
        [System.Security.AccessControl.FileSystemRights]::Modify,
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Wait-ForFile {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

# This one-time bootstrap is intentionally the only elevated step in the Arthur recovery design.
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'ADMIN_BOOTSTRAP_REQUIRES_ELEVATED_POWERSHELL: reopen PowerShell with Run as administrator.'
}
Write-Host "ADMIN_BOOTSTRAP_ELEVATED=PASS user=$($currentIdentity.Name)"

$runnerSid = Resolve-AccountSid -Account $RunnerUser
Write-Host "ADMIN_BOOTSTRAP_RUNNER_IDENTITY=PASS user=$RunnerUser sid=$runnerSid"

$controlRoot = [IO.Path]::GetFullPath((Join-Path $RunnerLocalBase 'ControlPlane\control-runtime'))
$stateDir = [IO.Path]::GetFullPath((Join-Path $RunnerLocalBase 'ControlPlane\state'))
$pythonExe = [IO.Path]::GetFullPath((Join-Path $RunnerLocalBase 'HeadlessPython\.venv\Scripts\python.exe'))
$runtimeState = Join-Path $stateDir 'runtime-state.json'
$probePath = Join-Path $controlRoot 'scripts\arthur-codex-runtime-probe.py'
$supervisorHelper = Join-Path $controlRoot 'scripts\ensure-arthur-persistent-supervisor.ps1'
$repairHelper = Join-Path $controlRoot 'scripts\ensure-arthur-windows-repair-controller.ps1'
$expectedModel = 'gpt-5.6-terra'

foreach ($required in @($controlRoot,$stateDir)) {
    if (-not (Test-Path -LiteralPath $required -PathType Container)) {
        Fail "ADMIN_BOOTSTRAP_REQUIRED_DIRECTORY_MISSING: $required"
    }
}
if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
    Fail "ADMIN_BOOTSTRAP_PYTHON_MISSING: $pythonExe"
}
if (-not (Test-Path -LiteralPath $runtimeState -PathType Leaf)) {
    Fail "ADMIN_BOOTSTRAP_RUNTIME_STATE_MISSING: $runtimeState"
}

# Keep control code current without touching the mutable task workspace.
$dirty = Invoke-GitChecked -Root $controlRoot -Arguments @('status','--porcelain')
if (-not [string]::IsNullOrWhiteSpace($dirty)) {
    Fail "ADMIN_BOOTSTRAP_CONTROL_RUNTIME_DIRTY: fail closed; files=$dirty"
}
$null = Invoke-GitChecked -Root $controlRoot -Arguments @('fetch','origin','main')
$currentHead = Invoke-GitChecked -Root $controlRoot -Arguments @('rev-parse','HEAD')
$originMain = Invoke-GitChecked -Root $controlRoot -Arguments @('rev-parse','origin/main')
if ($currentHead -ne $originMain) {
    $safe = "safe.directory=$controlRoot"
    & git -c $safe -C $controlRoot merge-base --is-ancestor $currentHead $originMain *> $null
    if ($LASTEXITCODE -ne 0) {
        Fail "ADMIN_BOOTSTRAP_CONTROL_RUNTIME_NOT_FAST_FORWARD: local=$currentHead origin=$originMain"
    }
    $null = Invoke-GitChecked -Root $controlRoot -Arguments @('merge','--ff-only','origin/main')
}
$controlHead = Invoke-GitChecked -Root $controlRoot -Arguments @('rev-parse','HEAD')
Write-Host "ADMIN_BOOTSTRAP_CONTROL_RUNTIME=PASS head=$controlHead"

# The persistent Supervisor helper runtime-syntax fix must be present before touching Windows tasks.
$requiredSupervisorFix = 'bd4d6483d12478fdedb887315c1e8b858faa0b2a'
$safe = "safe.directory=$controlRoot"
& git -c $safe -C $controlRoot merge-base --is-ancestor $requiredSupervisorFix $controlHead *> $null
if ($LASTEXITCODE -ne 0) {
    Fail "ADMIN_BOOTSTRAP_REQUIRED_SUPERVISOR_FIX_MISSING: required=$requiredSupervisorFix head=$controlHead"
}

foreach ($requiredFile in @($probePath,$supervisorHelper,$repairHelper)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        Fail "ADMIN_BOOTSTRAP_REQUIRED_FILE_MISSING: $requiredFile"
    }
}

$runtimeHashBefore = (Get-FileHash -LiteralPath $runtimeState -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "RUNTIME_STATE_BASELINE_SHA256=$runtimeHashBefore"

# Grant only the right needed by passwordless S4U Scheduled Tasks. Do not add the runner to Administrators.
$lsaSource = @'
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class ArthurAdminLsa {
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_OBJECT_ATTRIBUTES {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_UNICODE_STRING {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }
    const uint POLICY_CREATE_ACCOUNT = 0x00000010;
    const uint POLICY_LOOKUP_NAMES = 0x00000800;
    [DllImport("advapi32.dll")]
    static extern uint LsaOpenPolicy(IntPtr SystemName, ref LSA_OBJECT_ATTRIBUTES ObjectAttributes, uint DesiredAccess, out IntPtr PolicyHandle);
    [DllImport("advapi32.dll")]
    static extern uint LsaAddAccountRights(IntPtr PolicyHandle, IntPtr AccountSid, LSA_UNICODE_STRING[] UserRights, uint CountOfRights);
    [DllImport("advapi32.dll")]
    static extern uint LsaNtStatusToWinError(uint Status);
    [DllImport("advapi32.dll")]
    static extern uint LsaClose(IntPtr ObjectHandle);

    public static void Grant(string sidText, string rightName) {
        var attrs = new LSA_OBJECT_ATTRIBUTES();
        attrs.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr policy;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attrs, POLICY_CREATE_ACCOUNT | POLICY_LOOKUP_NAMES, out policy);
        if (status != 0) throw new System.ComponentModel.Win32Exception((int)LsaNtStatusToWinError(status), "LsaOpenPolicy failed");
        try {
            var sid = new SecurityIdentifier(sidText);
            byte[] bytes = new byte[sid.BinaryLength];
            sid.GetBinaryForm(bytes,0);
            IntPtr sidPtr = Marshal.AllocHGlobal(bytes.Length);
            IntPtr rightPtr = IntPtr.Zero;
            try {
                Marshal.Copy(bytes,0,sidPtr,bytes.Length);
                rightPtr = Marshal.StringToHGlobalUni(rightName);
                var right = new LSA_UNICODE_STRING();
                right.Buffer = rightPtr;
                right.Length = (ushort)(rightName.Length * 2);
                right.MaximumLength = (ushort)((rightName.Length + 1) * 2);
                status = LsaAddAccountRights(policy,sidPtr,new LSA_UNICODE_STRING[] { right },1);
                if (status != 0) throw new System.ComponentModel.Win32Exception((int)LsaNtStatusToWinError(status), "LsaAddAccountRights failed");
            }
            finally {
                if (rightPtr != IntPtr.Zero) Marshal.FreeHGlobal(rightPtr);
                Marshal.FreeHGlobal(sidPtr);
            }
        }
        finally { LsaClose(policy); }
    }
}
'@
if (-not ('ArthurAdminLsa' -as [type])) {
    Add-Type -TypeDefinition $lsaSource -ErrorAction Stop
}
[ArthurAdminLsa]::Grant($runnerSid,'SeBatchLogonRight')
Write-Host "ADMIN_BOOTSTRAP_SEBATCHLOGONRIGHT=PASS user=$RunnerUser sid=$runnerSid"

$programRoot = Join-Path $env:ProgramData 'XinZhaoWrt'
Grant-DirectoryModify -Path $programRoot -Account $RunnerUser
Write-Host "ADMIN_BOOTSTRAP_PROGRAMDATA_ACL=PASS path=$programRoot user=$RunnerUser right=Modify"

# Stop the old Supervisor instance only to freeze the durable handoff during the ownership migration.
$oldSupervisor = Get-ScheduledTask -TaskName $SupervisorTaskName -ErrorAction SilentlyContinue
$oldSupervisorWasRunning = ($oldSupervisor -and [string]$oldSupervisor.State -eq 'Running')
if ($oldSupervisorWasRunning) {
    Stop-ScheduledTask -TaskName $SupervisorTaskName -ErrorAction Stop
    Start-Sleep -Seconds 2
    Write-Host "ADMIN_BOOTSTRAP_OLD_SUPERVISOR_QUIESCED=PASS task=$SupervisorTaskName"
}

$probeTaskName = 'XinZhaoWrt-Arthur-S4U-Bootstrap-Probe'
$probeRoot = Join-Path $programRoot 'AdminBootstrapProbe'
$probeLauncher = Join-Path $probeRoot 'run-codex-probe.ps1'
$probeResult = Join-Path $probeRoot 'result.json'
New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
Grant-DirectoryModify -Path $probeRoot -Account $RunnerUser
Remove-Item -LiteralPath $probeResult -Force -ErrorAction SilentlyContinue

$probeLauncherText = @(
    '$ErrorActionPreference = ''Continue''',
    '$env:PYTHONDONTWRITEBYTECODE = ''1''',
    ('$env:ARTHUR_CONTROL_PLANE_CODE_ROOT = ' + (Quote-PsLiteral $controlRoot)),
    ('$env:ARTHUR_CONTROL_PLANE_STATE_DIR = ' + (Quote-PsLiteral $stateDir)),
    ('$env:HEADLESS_CODEX_MODEL = ' + (Quote-PsLiteral $expectedModel)),
    ('Set-Location -LiteralPath ' + (Quote-PsLiteral $controlRoot)),
    ('$raw = (& ' + (Quote-PsLiteral $pythonExe) + ' ' + (Quote-PsLiteral $probePath) + ' 2>&1 | Out-String).Trim()'),
    '$probeExit = $LASTEXITCODE',
    'try {',
    '  $p = $raw | ConvertFrom-Json',
    '  $out = [ordered]@{ parse_ok=$true; exit_code=$probeExit; exit_class=[string]$p.exit_class; account_preflight_ok=[bool]$p.account_preflight_ok; model_catalog_skipped=[bool]$p.model_catalog_skipped; effective_model=[string]$p.effective_model; ai_orchestrator_file=[string]$p.ai_orchestrator_file }',
    '} catch {',
    '  $out = [ordered]@{ parse_ok=$false; exit_code=$probeExit; exit_class=''PROBE_JSON_ERROR''; account_preflight_ok=$false; model_catalog_skipped=$false; effective_model=$null; ai_orchestrator_file=$null; raw=$raw }',
    '}',
    ('$out | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath ' + (Quote-PsLiteral $probeResult) + ' -Encoding UTF8'),
    'exit 0'
) -join [Environment]::NewLine
[IO.File]::WriteAllText($probeLauncher,$probeLauncherText + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))

$probePassed = $false
try {
    Unregister-ScheduledTask -TaskName $probeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    $probeAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$probeLauncher`"" -WorkingDirectory $probeRoot
    $probePrincipal = New-ScheduledTaskPrincipal -UserId $RunnerUser -LogonType S4U -RunLevel Limited
    $probeSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
    $probeTask = New-ScheduledTask -Action $probeAction -Principal $probePrincipal -Settings $probeSettings -Description 'Disposable Arthur S4U Codex runtime probe. No firmware authority.'
    Register-ScheduledTask -TaskName $probeTaskName -InputObject $probeTask -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $probeTaskName -ErrorAction Stop

    if (-not (Wait-ForFile -Path $probeResult -TimeoutSeconds $ProbeTimeoutSeconds)) {
        $probeInfo = Get-ScheduledTaskInfo -TaskName $probeTaskName -ErrorAction SilentlyContinue
        $lastResult = if ($probeInfo) { [string]$probeInfo.LastTaskResult } else { 'UNKNOWN' }
        Fail "ADMIN_BOOTSTRAP_S4U_PROBE_TIMEOUT: task=$probeTaskName last_result=$lastResult"
    }
    $probePayload = Get-Content -Raw -LiteralPath $probeResult | ConvertFrom-Json
    $modulePath = [string]$probePayload.ai_orchestrator_file
    $moduleRootOk = -not [string]::IsNullOrWhiteSpace($modulePath) -and $modulePath.StartsWith($controlRoot,[StringComparison]::OrdinalIgnoreCase)
    if (
        -not [bool]$probePayload.parse_ok -or
        [int]$probePayload.exit_code -ne 0 -or
        [string]$probePayload.exit_class -ne 'PROBE_OK' -or
        -not [bool]$probePayload.account_preflight_ok -or
        -not [bool]$probePayload.model_catalog_skipped -or
        [string]$probePayload.effective_model -cne $expectedModel -or
        -not $moduleRootOk
    ) {
        Fail ("ADMIN_BOOTSTRAP_S4U_PROBE_FAILED: payload={0}" -f ($probePayload | ConvertTo-Json -Depth 20 -Compress))
    }
    $probePassed = $true
    Write-Host "ADMIN_BOOTSTRAP_S4U_CODEX_PROBE=PASS class=PROBE_OK account=true model_catalog_skipped=true model=$expectedModel module=$modulePath"
}
finally {
    Stop-ScheduledTask -TaskName $probeTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $probeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $probePassed -and $oldSupervisorWasRunning) {
        try { Start-ScheduledTask -TaskName $SupervisorTaskName -ErrorAction Stop } catch { Write-Warning "ADMIN_BOOTSTRAP_OLD_SUPERVISOR_RESTART_FAILED: $($_.Exception.Message)" }
    }
}
if (-not $probePassed) { Fail 'ADMIN_BOOTSTRAP_S4U_PROBE_NOT_CONFIRMED' }

# Canonicalize the existing launcher while the old task principal is still available to the elevated session.
& $supervisorHelper -StateDir $stateDir -ControlRoot $controlRoot -HeadlessPythonExe $pythonExe -TaskName $SupervisorTaskName -DoNotStart
if ($LASTEXITCODE -ne 0) { Fail "ADMIN_BOOTSTRAP_SUPERVISOR_HELPER_FAILED: exit=$LASTEXITCODE" }
$currentSupervisor = Get-ScheduledTask -TaskName $SupervisorTaskName -ErrorAction Stop
$currentAction = @($currentSupervisor.Actions | Select-Object -First 1)[0]
if (-not $currentAction) { Fail "ADMIN_BOOTSTRAP_SUPERVISOR_ACTION_MISSING: $SupervisorTaskName" }

# Migrate the SAME stable task name to the runner-owned S4U context; do not create a competing Supervisor.
if ([string]$currentSupervisor.State -eq 'Running') {
    Stop-ScheduledTask -TaskName $SupervisorTaskName -ErrorAction Stop
}
$supervisorAction = New-ScheduledTaskAction -Execute ([string]$currentAction.Execute) -Argument ([string]$currentAction.Arguments) -WorkingDirectory ([string]$currentAction.WorkingDirectory)
$supervisorTrigger = New-ScheduledTaskTrigger -AtStartup
$supervisorPrincipal = New-ScheduledTaskPrincipal -UserId $RunnerUser -LogonType S4U -RunLevel Limited
$supervisorSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 1)
$runnerOwnedSupervisor = New-ScheduledTask `
    -Action $supervisorAction `
    -Trigger $supervisorTrigger `
    -Principal $supervisorPrincipal `
    -Settings $supervisorSettings `
    -Description 'Runner-owned persistent Arthur GPT-Codex recovery supervisor. No firmware authority outside the existing durable release gates.'
Register-ScheduledTask -TaskName $SupervisorTaskName -InputObject $runnerOwnedSupervisor -Force -ErrorAction Stop | Out-Null

$supervisorNow = Get-ScheduledTask -TaskName $SupervisorTaskName -ErrorAction Stop
if (
    [string]$supervisorNow.Principal.UserId -ine $RunnerUser -or
    [string]$supervisorNow.Principal.LogonType -ine 'S4U' -or
    [string]$supervisorNow.Principal.RunLevel -ine 'Limited'
) {
    Fail "ADMIN_BOOTSTRAP_SUPERVISOR_PRINCIPAL_MISMATCH: user=$($supervisorNow.Principal.UserId) logon=$($supervisorNow.Principal.LogonType) runlevel=$($supervisorNow.Principal.RunLevel)"
}
Write-Host "PERSISTENT_SUPERVISOR_RUNNER_OWNED=PASS task=$SupervisorTaskName user=$RunnerUser logon=S4U runlevel=Limited"

# The repair task inherits the Supervisor principal; prepare it first without starting recovery.
& $repairHelper -StateDir $stateDir -ControlRoot $controlRoot -HeadlessPythonExe $pythonExe -Mode FullRecovery -SupervisorTaskName $SupervisorTaskName -RepairTaskName $RepairTaskName
if ($LASTEXITCODE -ne 0) { Fail "ADMIN_BOOTSTRAP_REPAIR_HELPER_PREPARE_FAILED: exit=$LASTEXITCODE" }
$repairNow = Get-ScheduledTask -TaskName $RepairTaskName -ErrorAction Stop
if (
    [string]$repairNow.Principal.UserId -ine $RunnerUser -or
    [string]$repairNow.Principal.LogonType -ine 'S4U' -or
    [string]$repairNow.Principal.RunLevel -ine 'Limited'
) {
    Fail "ADMIN_BOOTSTRAP_REPAIR_PRINCIPAL_MISMATCH: user=$($repairNow.Principal.UserId) logon=$($repairNow.Principal.LogonType) runlevel=$($repairNow.Principal.RunLevel)"
}
Write-Host "REPAIR_CONTROLLER_RUNNER_OWNED=PASS task=$RepairTaskName user=$RunnerUser logon=S4U runlevel=Limited"

# Prove the administrator migration itself did not alter the durable BUILD handoff.
$runtimeHashAfterMigration = (Get-FileHash -LiteralPath $runtimeState -Algorithm SHA256).Hash.ToLowerInvariant()
if ($runtimeHashAfterMigration -cne $runtimeHashBefore) {
    Fail "ADMIN_BOOTSTRAP_RUNTIME_STATE_CHANGED_BEFORE_RECOVERY: before=$runtimeHashBefore after=$runtimeHashAfterMigration"
}
Write-Host "RUNTIME_STATE_PRESERVED=PASS path=$runtimeState sha256=$runtimeHashAfterMigration"

# Start only the bounded runtime-recovery controller. It alone may restart the Supervisor and must earn CODEX_RUNTIME_RECOVERED.
$recoveryStartedAt = [DateTimeOffset]::UtcNow
& $repairHelper -StateDir $stateDir -ControlRoot $controlRoot -HeadlessPythonExe $pythonExe -Mode FullRecovery -SupervisorTaskName $SupervisorTaskName -RepairTaskName $RepairTaskName -Start
if ($LASTEXITCODE -ne 0) { Fail "ADMIN_BOOTSTRAP_FULLRECOVERY_TRIGGER_FAILED: exit=$LASTEXITCODE" }
Write-Host "ADMIN_BOOTSTRAP_FULLRECOVERY_TRIGGERED=PASS started=$($recoveryStartedAt.ToString('o'))"

$statusPath = Join-Path $stateDir 'repair-status.json'
$deadline = (Get-Date).AddSeconds($RecoveryTimeoutSeconds)
$lastSummary = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { continue }
    try { $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json }
    catch { continue }

    $statusName = [string]$status.status
    $finalResult = [string]$status.final_result
    $modeName = [string]$status.mode
    $evidenceTimestamp = [string]$status.evidence_timestamp
    $lastSummary = "status=$statusName final=$finalResult mode=$modeName evidence=$evidenceTimestamp"

    $isFresh = $false
    if (-not [string]::IsNullOrWhiteSpace($evidenceTimestamp)) {
        try {
            $evidenceTime = [DateTimeOffset]::Parse($evidenceTimestamp)
            $isFresh = ($evidenceTime -ge $recoveryStartedAt.AddSeconds(-2))
        }
        catch { $isFresh = $false }
    }
    if (-not $isFresh -or $modeName -ne 'FullRecovery') { continue }

    if ($statusName -eq 'CODEX_RUNTIME_RECOVERED' -or $finalResult -eq 'CODEX_RUNTIME_RECOVERED') {
        $healthySeconds = [double]$status.heartbeat_observations.healthy_seconds
        $heartbeatAdvances = [int]$status.heartbeat_observations.heartbeat_advances
        if ($healthySeconds -lt 120 -or $heartbeatAdvances -lt 2) {
            Fail "ADMIN_BOOTSTRAP_RECOVERY_GATE_INVALID: seconds=$healthySeconds heartbeat_advances=$heartbeatAdvances"
        }
        Write-Host "CODEX_RUNTIME_RECOVERED=PASS seconds=$([int]$healthySeconds) heartbeat_advances=$heartbeatAdvances evidence=$statusPath"
        Write-Host 'ARTHUR_WINDOWS_ADMIN_BOOTSTRAP=PASS'
        exit 0
    }
    if ($statusName -like 'REPAIR_BLOCKED_*' -or $finalResult -like 'REPAIR_BLOCKED_*' -or $statusName -eq 'REPAIR_EXHAUSTED' -or $finalResult -eq 'REPAIR_EXHAUSTED') {
        Fail "ADMIN_BOOTSTRAP_RECOVERY_BLOCKED: $lastSummary evidence=$statusPath"
    }
}

Fail "ADMIN_BOOTSTRAP_RECOVERY_TIMEOUT: timeout_seconds=$RecoveryTimeoutSeconds last=$lastSummary evidence=$statusPath"
