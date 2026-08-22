# Plugin plan

This build intentionally includes the following LuCI applications.

| Package | Main use | Source strategy | Operational note |
|---|---|---|---|
| luci-app-adguardhome | DNS filtering / ad blocking | ImmortalWrt feeds | Do not let it bind port 53 at the same time as another DNS front-end. |
| luci-app-autoreboot | Scheduled reboot | ImmortalWrt LuCI | Maintenance feature. |
| luci-app-diskman | Disk/partition management | sbwml/luci-app-diskman | Be careful with the internal eMMC; never format router system partitions. |
| luci-app-easytier | EasyTier mesh VPN | EasyTier official repo | kmod-tun is included. |
| luci-app-firewall | Firewall4 GUI | ImmortalWrt LuCI | Core networking UI. |
| luci-app-istorex | iStoreX entry UI | selected Kenzok8 packages | Pulls QuickStart/Store/taskd dependencies. |
| luci-app-lucky | DDNS/reverse proxy/port forwarding | selected Kenzok8 package | Avoid duplicate port listeners with UPnP/manual forwards. |
| luci-app-mosdns | Programmable DNS forwarding | sbwml v5 | Installed together with v2ray-geodata. |
| luci-app-oaf | OpenAppFilter application filtering | destan19/OpenAppFilter | Kernel-facing component; first suspect if a future kernel bump breaks the build. |
| luci-app-package-manager | Web package manager | ImmortalWrt LuCI | Matches the build system package manager. |
| luci-app-openclash | Mihomo/OpenClash proxy | vernesong/OpenClash | dnsmasq-full, TUN and nft tproxy dependencies included. |
| luci-app-pbr | Policy-based routing | standard feeds | Do not make PBR and OpenClash manage the same traffic rules blindly. |
| luci-app-quickfile | Quick file manager | selected Kenzok8 package | File-management UI. |
| luci-app-quickstart | QuickStart dashboard | selected Kenzok8 package | iStore ecosystem dependency. |
| luci-app-samba4 | SMB file sharing | standard feeds | Useful with USB/eMMC data partitions. |
| luci-app-smartdns | SmartDNS | ImmortalWrt LuCI | Pick one DNS topology before enabling with MosDNS/AdGuard Home. |
| luci-app-sqm | SQM/QoS | standard feeds | Useful when WAN bottleneck control is needed. |
| luci-app-store | iStore app store | selected Kenzok8 package | Supports IPK/APK-aware package flow. |
| luci-app-ttyd | Browser terminal | standard feeds | Restrict exposure to LAN/VPN. |
| luci-app-upnp | UPnP/NAT-PMP GUI | standard feeds | Do not expose UPnP to WAN. |
| luci-app-vlmcsd | Vlmcsd service GUI | ImmortalWrt LuCI | Only use in environments where you are authorized to provide KMS service. |
| luci-app-wol | Wake-on-LAN | standard feeds | LAN wake tool. |

## DNS coexistence rule

AdGuard Home, MosDNS and SmartDNS are all compiled in so the firmware is flexible. That does not mean they should all listen on port 53 simultaneously. A sane deployment is to choose one front-end and, if needed, chain the others on different localhost ports.

## Routing coexistence rule

OpenClash and PBR can coexist as installed packages, but both are capable of changing routing policy. Decide which component owns the traffic path before enabling both.


## Web management stack

`luci-app-quickfile` currently depends on `luci-nginx`, so this firmware intentionally uses the LuCI + Nginx stack. The default `luci` / `luci-ssl` collections are not selected to avoid simultaneously enabling uhttpd and Nginx on the same management ports.
