# 新肇网络Wrt｜京东云亚瑟固件

这是给 **JDCloud RE-SS-01（京东云亚瑟 / Arthur）** 整理的一套 ImmortalWrt 固件。重点不是追求“什么都装”，而是把家用路由里常用的功能先配好，再经过真实设备刷机确认后发布。

当前正式版是 `v0.1.3`，已经在京东云亚瑟实机上完成刷机和功能验收。正常使用时，优先下载 Releases 页面标记为 **Latest** 的正式版。

## 先说明源码来源

这套固件并不是从零写出来的，底层直接继承自 **VIKINGYFY/immortalwrt**：

`https://github.com/VIKINGYFY/immortalwrt.git`

我是在这套源码的基础上，针对京东云亚瑟重新整理设备配置、默认网络、中文 LuCI、插件组合、QuickStart / iStoreX、AdGuardHome，以及 Nginx 的访问方式。

正式版不会每次编译都临时追上游最新代码。能发布出来的版本，会把已经验证过的源码和依赖固定下来，避免今天能用、明天因为上游变化又出现不同结果。

当前 `v0.1.3` 使用的上游版本是：

- 上游仓库：`VIKINGYFY/immortalwrt`
- 上游 commit：`27e26e324bee0b0c2a4eb58e2e9121fea5d43194`
- 本项目发布 commit：`2f4d9a70e5675955bddaf51eb134131fac61bfc3`
- Target：`qualcommax/ipq60xx`
- Profile：`jdcloud_re-ss-01`

感谢 VIKINGYFY、ImmortalWrt / OpenWrt 社区以及各插件作者提供的上游源码。本仓库主要做的是京东云亚瑟这一台设备的整合、默认配置、编译和实机验证。

## 当前正式版

- 版本：`v0.1.3`
- 正式 Release：`arthur-production-34268801985`
- 设备：`JDCloud RE-SS-01`
- 构建日期：`2026-09-08`
- 管理地址：`http://192.168.6.1`
- 用户名：`root`
- 初始密码：`password`

第一次登录后建议先把 root 密码改掉。

## 固件里预装了哪些插件

当前正式版固定带 **22 个 LuCI 插件**。这里直接把名字全部列出来，下载之前就能看清楚里面有什么。

| 插件 | 软件包名 | 主要用途 |
| --- | --- | --- |
| AdGuard Home | `luci-app-adguardhome` | 广告过滤与 DNS 管理 |
| 定时重启 | `luci-app-autoreboot` | 按计划自动重启路由器 |
| DiskMan | `luci-app-diskman` | 磁盘和分区管理 |
| EasyTier | `luci-app-easytier` | 异地组网 |
| 防火墙 | `luci-app-firewall` | LuCI 防火墙管理 |
| iStoreX | `luci-app-istorex` | iStoreX 管理入口 |
| Lucky | `luci-app-lucky` | DDNS、反向代理等网络服务管理 |
| MosDNS | `luci-app-mosdns` | DNS 分流与解析优化 |
| OAF / OpenAppFilter | `luci-app-oaf` | 应用访问控制 |
| 软件包管理 | `luci-app-package-manager` | 在 LuCI 中管理软件包 |
| OpenClash | `luci-app-openclash` | Clash 代理管理 |
| PBR | `luci-app-pbr` | 策略路由 |
| QuickFile | `luci-app-quickfile` | 网页文件管理 |
| QuickStart | `luci-app-quickstart` | 常用功能快捷首页 |
| Samba4 | `luci-app-samba4` | 局域网文件共享 |
| SmartDNS | `luci-app-smartdns` | DNS 解析优化 |
| SQM QoS | `luci-app-sqm` | 带宽整形、降低排队延迟 |
| iStore | `luci-app-store` | iStore 应用商店 |
| TTYD | `luci-app-ttyd` | 浏览器终端 |
| UPnP | `luci-app-upnp` | 自动端口映射 |
| KMS | `luci-app-vlmcsd` | vlmcsd 管理 |
| Wake on LAN | `luci-app-wol` | 网络唤醒局域网设备 |

这 22 个包的正式清单以 `config/required-plugins.txt` 为准。构建时会检查数量和包名，少一个就不会当成合格的正式固件继续发布。

另外，iStore 的正确包名是 `luci-app-store`，不是 `luci-app-istore`。

## 这一版实际确认过什么

这次不是只看编译成功就发布。`v0.1.3` 已经实际刷进京东云亚瑟，并确认 LAN 为 `192.168.6.1/24`，Windows 能正常拿到 DHCP 地址，网关和 DNS 正常；2.4GHz、5GHz Wi-Fi 都能正常工作，LuCI 中文界面、QuickStart、iStoreX、iStore、QuickFile 和 AdGuardHome 管理页面都能打开。

Web 管理继续使用 Nginx，但只开放 HTTP 80。访问地址就是 `http://192.168.6.1`，不会再自动跳到 HTTPS，TCP 443 也不监听。AdGuardHome 已经集成完整管理页面，但默认保持关闭，需要时再自己开启。

## 下载哪个文件

如果路由器已经在运行 OpenWrt / ImmortalWrt / 新肇网络Wrt，通常使用：

`XinZhaoWrt-Arthur-v0.1.3-20260908-sysupgrade.bin`

SHA256：

`f048a7063c7fa89774f628d252f9709d5cee2801f36066ebefb61cc65ea1b557`

factory 固件是：

`XinZhaoWrt-Arthur-v0.1.3-20260908-factory.bin`

SHA256：

`060f3e100aabc02f3542466e802f049789343aba1969ccb75a19484df459311d`

factory 主要给对应的首次刷入场景使用。如果不确定自己该用哪个，不要直接试，先确认当前系统和刷机方式。

## 刷机前看一下

本固件只适用于 **JDCloud RE-SS-01**，不要拿去刷其他型号。

升级前建议先跑一次：

```sh
sysupgrade -T <固件文件>
```

检查不通过就不要继续，也不要使用 `-F` 强制刷入。U-Boot、ART/EEPROM、原始 eMMC/SPI/NAND 分区也不要在没有确认的情况下直接写入。

## 回滚版本

目前保留 `v0.1.0` 作为回滚备用。正常使用不需要下载旧版，只有当前正式版出现明确兼容问题、已经决定回退时才使用它。

Releases 页面以后只保留当前正式版、当前正式版对应的构建留档，以及明确指定的回滚版本。旧测试包和过期构建不会长期留在下载页。

## 开发和验证资料

需要看更详细的构建、锁定和实机验收记录，可以继续查看：

- `production/known-good.json`
- `production/release-policy.md`
- `config/required-plugins.txt`
- `docs/PROJECT_SPEC.md`
- `docs/OPENWRT_CI_V3.md`
- `docs/BUILD.md`
- `docs/FLASH.md`
- `docs/GITHUB.md`
