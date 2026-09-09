# 新肇网络Wrt｜京东云亚瑟固件

这是给 **JDCloud RE-SS-01（京东云亚瑟 / Arthur）** 使用的 ImmortalWrt 固件。这里主要放已经在真实设备上刷机确认过的正式版本，测试包和中间构建不会长期堆在 Releases 页面。

## 当前正式版

- 版本：`v0.1.3`
- 正式 Release：`arthur-production-34268801985`
- 设备：`JDCloud RE-SS-01`
- Target：`qualcommax/ipq60xx`
- Profile：`jdcloud_re-ss-01`
- 构建日期：`2026-09-08`
- 管理地址：`http://192.168.6.1`
- 用户名：`root`
- 初始密码：`password`

这版已经在真实的京东云亚瑟上实际刷入并完成验收。

## 源码从哪里来

本项目直接基于 **VIKINGYFY/immortalwrt** 进行编译和定制：

`https://github.com/VIKINGYFY/immortalwrt.git`

默认跟随上游 `main` 分支，但正式固件不会在发布时临时追最新代码，而是把已经验证过的源码版本锁定下来。

当前 `v0.1.3` 正式版对应：

- 上游仓库：`VIKINGYFY/immortalwrt`
- 上游 commit：`27e26e324bee0b0c2a4eb58e2e9121fea5d43194`
- 本项目发布 commit：`2f4d9a70e5675955bddaf51eb134131fac61bfc3`

设备配置、插件清单、默认网络设置、中文 LuCI、QuickStart / iStoreX、AdGuardHome、Nginx 80 端口策略等是在这个上游源码基础上由本项目追加并固定的。

## 下载哪个文件

日常从已有 OpenWrt / 新肇Wrt 升级，使用：

`XinZhaoWrt-Arthur-v0.1.3-20260908-sysupgrade.bin`

SHA256：

`f048a7063c7fa89774f628d252f9709d5cee2801f36066ebefb61cc65ea1b557`

`factory.bin` 主要留给对应的首次刷入场景：

`XinZhaoWrt-Arthur-v0.1.3-20260908-factory.bin`

SHA256：

`060f3e100aabc02f3542466e802f049789343aba1969ccb75a19484df459311d`

不确定自己该用哪个文件时，不要直接尝试 factory，先确认当前系统和刷机方式。

## 固件包含的 22 个 LuCI 插件

下面是当前正式版的强制插件清单。这个清单来自 `config/required-plugins.txt`，构建时 22 个必须全部存在，少一个都会判定为构建检查失败。

1. `luci-app-adguardhome`
2. `luci-app-autoreboot`
3. `luci-app-diskman`
4. `luci-app-easytier`
5. `luci-app-firewall`
6. `luci-app-istorex`
7. `luci-app-lucky`
8. `luci-app-mosdns`
9. `luci-app-oaf`
10. `luci-app-package-manager`
11. `luci-app-openclash`
12. `luci-app-pbr`
13. `luci-app-quickfile`
14. `luci-app-quickstart`
15. `luci-app-samba4`
16. `luci-app-smartdns`
17. `luci-app-sqm`
18. `luci-app-store`
19. `luci-app-ttyd`
20. `luci-app-upnp`
21. `luci-app-vlmcsd`
22. `luci-app-wol`

其中 iStore 的规范包名是 `luci-app-store`；项目不会使用不存在的 `luci-app-istore` 包名。

## 这版已经确认正常

- LAN 使用 `192.168.6.1/24`，DHCP、网关和 DNS 正常
- 2.4GHz、5GHz Wi-Fi 正常
- LuCI 中文界面正常
- LuCI 使用 Nginx，只开放 HTTP 80
- TCP 443 不监听，也不会从 HTTP 跳转到 HTTPS
- QuickStart 正常
- iStoreX / iStore 正常
- QuickFile 正常
- AdGuardHome 管理页面完整，默认关闭
- 22 个强制 LuCI 插件已经完整编入

## 刷机前

本固件只适用于 **JDCloud RE-SS-01**。刷机前请先核对设备型号和固件 SHA256。

升级前建议先执行兼容性检查：

```sh
sysupgrade -T <固件文件>
```

不要使用 `-F` 强制刷入。不要对 U-Boot、ART/EEPROM、原始 eMMC/SPI/NAND 分区做未经确认的写入。

首次登录后请尽快修改默认 root 密码。

## 回滚

当前保留的回滚版本是 `v0.1.0`。

它用于当前正式版出现明确兼容问题时回退。正常使用请下载 Releases 页面标记为 **Latest** 的正式版。

## Releases 页面怎么保留

以后 Releases 页面只保留三类内容：当前正式版、当前正式版对应的 Candidate 构建留档，以及明确指定的回滚版本。旧测试包、失败构建、过期 Candidate 和草稿 Release 会按这个规则整理，避免下载页越来越乱。

## 开发资料

构建、验收和发布的详细规则仍保留在仓库文档中：

- `production/known-good.json`
- `production/release-policy.md`
- `config/required-plugins.txt`
- `docs/PROJECT_SPEC.md`
- `docs/OPENWRT_CI_V3.md`
- `docs/BUILD.md`
- `docs/FLASH.md`
- `docs/GITHUB.md`
