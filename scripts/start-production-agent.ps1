param(
    [ValidateSet('Resume','RunOnce','Status')][string]$Mode='Resume',
    [long]$RunId=0
)
$ErrorActionPreference='Stop'
$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Agent=Join-Path $PSScriptRoot 'production-agent.ps1'
if (-not (Test-Path $Agent)) { throw "Production agent missing: $Agent" }

function Resolve-AgentPowerShell {
    $currentHost = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path $currentHost) { return $currentHost }
    $systemPwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($systemPwsh) { return $systemPwsh.Source }
    $portable = Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\PowerShell\current\pwsh.exe'
    if (Test-Path $portable) { return $portable }
    throw 'Production Agent requires PowerShell 7; run install-production-agent.ps1 to bootstrap the private portable runtime automatically.'
}

$ConfigPath=Join-Path $Root 'production\production-agent.json'
$DesiredRunId=$RunId
if ($DesiredRunId -le 0 -and (Test-Path $ConfigPath)) {
    try {
        $cfg=Get-Content -Raw $ConfigPath | ConvertFrom-Json
        $DesiredRunId=[long]$cfg.bootstrap.run_id
    } catch {}
}

# A long-lived agent can survive a runtime/config deployment. If the durable
# state still belongs to a different run, replace that stale process only when
# no flash write/reboot verification is in progress. This preserves release
# safety while ensuring a new active run is actually picked up unattended.
if ($Mode -eq 'Resume' -and $DesiredRunId -gt 0) {
    $Out=Join-Path $Root 'output\production-agent'
    $StatePath=Join-Path $Out 'state.json'
    $LockPath=Join-Path $Out 'production-agent.lock'
    if ((Test-Path $StatePath) -and (Test-Path $LockPath)) {
        try {
            $state=Get-Content -Raw $StatePath | ConvertFrom-Json
            $stateRun=[long]$state.run_id
            $stage=[string]$state.stage
            if ($stateRun -gt 0 -and $stateRun -ne $DesiredRunId) {
                if ($stage -in @('FLASH_STARTED','WAIT_DEVICE','REAL_DEVICE_VERIFY')) {
                    Write-Host "STALE_AGENT_RESTART_DEFERRED safety_stage=$stage old_run=$stateRun desired_run=$DesiredRunId"
                } else {
                    $oldPid=[int](Get-Content -Raw $LockPath)
                    $old=Get-Process -Id $oldPid -ErrorAction SilentlyContinue
                    if ($old) {
                        Stop-Process -Id $oldPid -Force
                        Start-Sleep -Milliseconds 500
                        Write-Host "STALE_AGENT_STOPPED pid=$oldPid old_run=$stateRun desired_run=$DesiredRunId stage=$stage"
                    }
                    Remove-Item -Force -ErrorAction SilentlyContinue $LockPath
                }
            }
        } catch {
            Write-Host "STALE_AGENT_RECONCILE_WARNING=$($_.Exception.Message)"
        }
    }
}

$Pwsh=Resolve-AgentPowerShell
$env:Path="$(Split-Path $Pwsh);$env:Path"
$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Agent,'-Mode',$Mode)
if ($DesiredRunId -gt 0) { $args += @('-RunId',[string]$DesiredRunId) }
if ($Mode -eq 'Status') {
    & $Pwsh @args
    exit $LASTEXITCODE
}
$proc=Start-Process -FilePath $Pwsh -ArgumentList $args -WorkingDirectory $Root -WindowStyle Hidden -PassThru
Write-Host "PRODUCTION_AGENT_STARTED pid=$($proc.Id) mode=$Mode run=$DesiredRunId host=$Pwsh"
