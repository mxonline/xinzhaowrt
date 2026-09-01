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

$Pwsh=Resolve-AgentPowerShell
$env:Path="$(Split-Path $Pwsh);$env:Path"
$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Agent,'-Mode',$Mode)
if ($RunId -gt 0) { $args += @('-RunId',[string]$RunId) }
if ($Mode -eq 'Status') {
    & $Pwsh @args
    exit $LASTEXITCODE
}
$proc=Start-Process -FilePath $Pwsh -ArgumentList $args -WorkingDirectory $Root -WindowStyle Hidden -PassThru
Write-Host "PRODUCTION_AGENT_STARTED pid=$($proc.Id) mode=$Mode run=$RunId host=$Pwsh"
