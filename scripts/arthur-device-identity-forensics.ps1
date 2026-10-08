param(
    [string]$DeviceIp = '192.168.6.1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'ensure-arthur-unattended-access.ps1')
$evidence = Invoke-ArthurReadOnlyIdentityForensics -DeviceIp $DeviceIp

if ($evidence.FormalKnownHostsChanged) {
    throw 'UNSAFE_FORENSICS_RESULT: formal known_hosts must remain unchanged.'
}

Write-Output "ARTHUR_CONTROL_PATH=$($evidence.EthernetRoute)"
Write-Output "SELECTED_ETHERNET_INTERFACE_INDEX=$($evidence.SelectedEthernetInterfaceIndex)"
Write-Output "SELECTED_ETHERNET_INTERFACE=$($evidence.SelectedEthernetInterface)"
Write-Output "CURRENT_ETHERNET_NEIGHBOR_MAC=$($evidence.LocalEthernetMac)"
Write-Output "OLD_FROZEN_MAC=$($evidence.FrozenManagementMac)"
Write-Output "FROZEN_MANAGEMENT_MAC_STATUS=$($evidence.FrozenManagementMacStatus)"
Write-Output "ARTHUR_HTTP_IDENTITY=$($evidence.HttpIdentity)"
Write-Output "HTTP_VERSION=$($evidence.HttpVersion)"
Write-Output "HTTP_BUILD_ID=$($evidence.HttpBuildId)"
Write-Output "TEMP_SSH_EXISTING_RUNNER_KEY_AUTH=$($evidence.RunnerKeyAuth)"
Write-Output "SSH_BOARD_IDENTITY=$($evidence.SshBoardIdentity)"
Write-Output "SSH_BUILD_IDENTITY=$($evidence.SshBuildIdentity)"
Write-Output "REMOTE_BR_LAN_MAC=$($evidence.RemoteBrLanMac)"
Write-Output "FORMAL_KNOWN_HOSTS_CHANGED=$($evidence.FormalKnownHostsChanged)"
