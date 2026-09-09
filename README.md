# 新肇网络Wrt｜京东云亚瑟固件

这是给 **JDCloud RE-SS-01（京东云亚瑟 / Arthur）** 使用的 ImmortalWrt 固件。这里把已经在真实设备上刷机确认过的正式版放在最前面，测试包和中间构建不会长期堆在 Releases 页面。

## 当前正式版

- 版本：`v0.1.3`
- 正式 Release：`arthur-production-34268801985`
- 设备：`JDCloud RE-SS-01`
- Target：`qualcommax/ipq60xx`
- 构建日期：`2026-09-08`
- 管理地址：`http://192.168.6.1`
- 用户名：`root`
- 初始密码：`password`

这版已经在真实的京东云亚瑟上实际刷入并完成验收。

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
- 固件内 22 个必选 LuCI 插件已经完整编入

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

以后 Releases 页面只保留三类内容：

1. 当前正式版
2. 当前正式版对应的 Candidate 构建留档
3. 明确指定的回滚版本

旧测试包、失败构建、过期 Candidate 和草稿 Release 会按这个规则整理，避免下载页越来越乱。

## 开发资料

构建、验收和发布的详细规则仍保留在仓库文档中：

- `production/known-good.json`
- `production/release-policy.md`
- `docs/OPENWRT_CI_V3.md`
- `docs/BUILD.md`
- `docs/FLASH.md`
- `docs/GITHUB.md`
