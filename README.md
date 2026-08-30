# 新肇网络Wrt-京东云亚瑟固件

面向 **JDCloud RE-SS-01（京东云亚瑟 / Arthur）** 的定制 ImmortalWrt 固件工程。当前正式 Known-Good 版本为 **v0.1.0 Stable**，后续更新统一从已验证基准派生 Candidate，不再直接用浮动源码覆盖正式基准。

设备配置固定为：

```text
qualcommax/ipq60xx/jdcloud_re-ss-01
```

64G 表示设备 eMMC 容量，不是独立 OpenWrt target。

## 当前 Known-Good

- Stable：`v0.1.0`
- Device：`JDCloud RE-SS-01`
- Target：`qualcommax/ipq60xx`
- Required LuCI plugins：`22/22 PASS`
- Real-device verification：`PASS`
- Canonical source lock：`config/arthur-known-good.lock`
- Known-Good metadata：`production/known-good.json`

## 首次登录默认值

- 管理地址：`192.168.6.1`
- 用户：`root`
- 初始密码：`passwort`

这是公开的初始密码。刷入固件并首次登录后，应立即在 LuCI 的系统管理页面修改 root 密码。

## 22 个硬性必选 LuCI 插件

构建以 `config/required-plugins.txt` 为唯一必选清单。`make defconfig` 后缺少任何一个，`scripts/check-config.sh` 会直接终止构建；完整编译后还必须验证 22 个插件均存在实际安装包并进入最终 firmware manifest。

```text
luci-app-adguardhome
luci-app-autoreboot
luci-app-diskman
luci-app-easytier
luci-app-firewall
luci-app-istorex
luci-app-lucky
luci-app-mosdns
luci-app-oaf
luci-app-package-manager
luci-app-openclash
luci-app-pbr
luci-app-quickfile
luci-app-quickstart
luci-app-samba4
luci-app-smartdns
luci-app-sqm
luci-app-store
luci-app-ttyd
luci-app-upnp
luci-app-vlmcsd
luci-app-wol
```

## LuCI Web 栈

由于 `luci-app-quickfile` 当前依赖 `luci-nginx`，本固件统一使用 **LuCI + Nginx** 作为管理 Web 栈，不同时选择默认 uhttpd 的 `luci` / `luci-ssl` collections。

## Known-Good 自动编译 v3

正式更新入口：`.github/workflows/arthur-update-v3.yml`。

更新模式：

```text
rebuild_known_good
update_immortalwrt
update_feeds
update_plugins
update_all
```

v3 的原则是：先复制当前 `config/arthur-known-good.lock` 生成临时 Candidate lock，只移动本次允许更新的 ref；Candidate 编译失败不会覆盖正式 Known-Good。

成功 Candidate 自动创建：

```text
arthur-update-<run_id>
```

Candidate 必须经过 JDCloud RE-SS-01 实机验证，只有输出：

```text
REAL DEVICE VERIFICATION PASS
```

并归档验收报告后，才能运行 `.github/workflows/promote-stable-v3.yml` 晋升新的 Stable。Stable 晋升成功后，Candidate lock 才会替换正式 `config/arthur-known-good.lock`。

完整规则见 `docs/OPENWRT_CI_V3.md`。

## Codex 本机实机验收

刷入 Candidate 后，在与亚瑟同一局域网的 Windows / Codex Desktop 环境执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\real-device-verify-v3.ps1 `
  -Candidate arthur-update-<run_id> `
  -Commit <candidate-project-commit> `
  -Target root@192.168.1.1
```

实机流程会验证 SSH、设备型号、存储、LAN/WAN、Internet、DNS、2.4G/5G、LuCI、22/22 插件、日志、正常重启和 overlay 持久化。

标准 OpenWrt/ImmortalWrt `sysupgrade` 已纳入正式自动生产流水线：`AUTO_FLASH_SAFETY_GATE` 全部通过后自动上传、远端 SHA256 复核、执行标准 sysupgrade、等待设备恢复并继续实机验证与 Release。标准 sysupgrade 不再设置人工刷机门禁。MTD raw write、U-Boot/bootloader、`dd` 原始分区、raw eMMC/SPI/NAND 以及 ART/EEPROM/calibration 写入仍禁止自动执行。

## Codex Cloud / GitHub Actions 编译

环境初始化：

```bash
./scripts/codex-setup.sh
```

静态检查：

```bash
./scripts/verify-project.sh
```

完整云编译：

```bash
./scripts/codex-cloud-build.sh
```

失败时优先读取 `output/logs/build.log`、`output/logs/build-diagnostic.log` 和 diagnostics Artifact，不把普通 WARNING 或最终 exit code 当根因。

## Windows 持久控制器

旧 v2 控制器仍保留用于已有 Build / Controller 任务的兼容和排障：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-ci-controller.ps1 -Mode UpdateBuild
```

查看状态：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ci-status.ps1
```

新固件更新与 Stable 发布优先按 Known-Good v3 流程执行。

## 本地编译

```bash
./scripts/build.sh main
```

## 固件命名

标准输出：

```text
XinZhaoWrt-Arthur-vX.Y.Z-YYYYMMDD-sysupgrade.bin
XinZhaoWrt-Arthur-vX.Y.Z-YYYYMMDD-factory.bin
```

实际是否同时生成 factory / sysupgrade，由当前 RE-SS-01 image recipe 决定。

## 运行时注意

AdGuard Home、MosDNS、SmartDNS、OpenClash 可以同时编进固件，但不要让多个 DNS 服务同时占用 53 端口。OpenClash 与 PBR 可以共存为软件包，但实际启用时要避免两套策略路由同时接管同一批流量。

OAF 带有内核相关组件。上游发生较大的 Linux 内核变化时，如果编译失败，优先检查 OAF 的内核 API 兼容性，不得为了让构建通过直接删除 `luci-app-oaf`。

## 文档

- `AGENTS.md`：Codex 项目硬规则
- `docs/OPENWRT_CI_V3.md`：当前 Known-Good 自动编译、Candidate、实机验收与 Stable 晋升流程
- `docs/OPENWRT_CI_V2.md`：旧版持久控制器流程，保留作为历史兼容
- `docs/PERSISTENT_CI_CONTROLLER.md`：Windows 持久控制器与 `codex exec`
- `docs/CODEX_CLOUD.md`：Codex Cloud 全编译流程
- `docs/BUILD.md`：本地/手工编译
- `docs/PLUGINS.md`：插件说明
- `docs/FLASH.md`：刷机安全说明
- `docs/GITHUB.md`：GitHub Actions / Release
