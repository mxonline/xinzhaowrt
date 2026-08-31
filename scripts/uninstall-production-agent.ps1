param([string]$TaskName='XinZhaoWrt-Arthur-Production-Agent')
$ErrorActionPreference='Stop'
$task=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
Write-Host "PRODUCTION_AGENT_UNINSTALL=PASS task=$TaskName"
