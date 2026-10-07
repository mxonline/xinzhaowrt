$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'scripts\ensure-arthur-unattended-access.ps1')

# Characterizes the route.exe format seen on the control host: the device route
# is on-link on the Ethernet source address, even when Get-NetRoute is denied.
$routePrint = @'
IPv4 Route Table
===========================================================================
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
      192.168.6.0    255.255.255.0         On-link     192.168.6.152    281
    192.168.6.152  255.255.255.255         On-link     192.168.6.152    281
      192.168.2.0    255.255.255.0         On-link     192.168.2.108    281
===========================================================================
'@

$routes = @(ConvertFrom-ArthurRoutePrint -Text $routePrint -DeviceIp '192.168.6.1')
if ($routes.Count -ne 1) { throw "Expected one direct Arthur subnet route, got $($routes.Count)." }
if ($routes[0].DestinationPrefix -ne '192.168.6.0/24') { throw 'The parsed route must be the Arthur /24 route.' }
if ($routes[0].NextHop -ne '0.0.0.0') { throw 'The parsed Arthur route must be on-link.' }
if ($routes[0].InterfaceAddress -ne '192.168.6.152') { throw 'The parsed route must retain its source interface address.' }

$unsafeText = $routePrint.Replace('On-link     192.168.6.152', '192.168.6.254 192.168.6.152')
$unsafeRoutes = @(ConvertFrom-ArthurRoutePrint -Text $unsafeText -DeviceIp '192.168.6.1')
if ($unsafeRoutes.Count -ne 0) { throw 'A routed next-hop must never be accepted as a direct Ethernet route.' }

if (-not (Test-ArthurOnLinkRouteForDevice -DestinationPrefix '192.168.6.0/24' -NextHop '0.0.0.0' -DeviceIp '192.168.6.1')) {
    throw 'The NetRoute path must accept an on-link route containing Arthur.'
}
if (Test-ArthurOnLinkRouteForDevice -DestinationPrefix '192.168.7.0/24' -NextHop '0.0.0.0' -DeviceIp '192.168.6.1') {
    throw 'An unrelated on-link subnet must not satisfy Arthur direct-route validation.'
}
if (Test-ArthurOnLinkRouteForDevice -DestinationPrefix '192.168.6.0/24' -NextHop '192.168.6.254' -DeviceIp '192.168.6.1') {
    throw 'A gateway route must not satisfy Arthur direct-route validation.'
}

Write-Output 'ARTHUR_ROUTE_PRINT_TEST=PASS'
