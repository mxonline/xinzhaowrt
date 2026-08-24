# 新肇网络Wrt-京东云亚瑟固件

面向 **JDCloud RE-SS-01（京东云亚瑟 / Arthur）** 的定制 ImmortalWrt 固件工程。当前项目版本为 **v0.1.0 testing**，上游默认使用 `VIKINGYFY/immortalwrt` 的 `main` 高通分支。

64G 表示设备 eMMC 容量，不是独立 OpenWrt target。设备配置始终使用：

```text
qualcommax/ipq60xx/jdcloud_re-ss-01
```

## 首次登录默认值

- 管理地址：`192.168.6.1`
- 用户：`root`
- 初始密码：`passwort`

这是公开的初始密码。刷入固件并首次登录后，应立即在 LuCI 的系统管理页面修改 root 密码。

## 22 个硬性必选 LuCI 插件

构建以 `config/required-plugins.txt` 为唯一必选清单。`make defconfig` 后缺少任何一个，`scripts/check-config.sh` 会直接终止构建。

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

由于 `luci-app-quickfile` 当前依赖 `luci-nginx`，本固件统一使用 **LuCI + Nginx** 作为管理 Web 栈，不同时选择默认 uhttpd 的 `luci` / `luci-ssl` collections。这样可以避免两套 Web 服务同时监听管理端口。

## Codex Cloud 全量编译

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

为减少 Codex 读取海量 OpenWrt 日志，Cloud 入口默认把完整编译日志保存到 `output/logs/build.log`。失败时只输出错误匹配和最后 220 行。详细操作见 `docs/CODEX_CLOUD.md`。

GitHub Actions 自动触发、监控、API 限流退避、失败自动诊断与最多 3 轮自动修复的总控规则，统一以 `docs/OPENWRT_CI_V2.md` 为准。

## Windows 持久自动编译控制器

正式自动开发不再依赖 Codex 聊天窗口长期保持活动。Windows 端通过持久控制器独立跟踪 GitHub Actions，失败后自动下载诊断资料并调用 `codex exec` 修复，再由控制器提交、推送并重新触发云端构建。

启动“更新编译”：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-ci-controller.ps1 -Mode UpdateBuild
```

查看真实状态：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ci-status.ps1
```

持续查看：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ci-status.ps1 -Follow
```

控制器默认每 60 秒查询一次 GitHub 状态，遇到 `unexpected EOF`、网络错误、GitHub 5xx 或 API rate limit 会退避后继续原 Run，不会盲目重复触发。失败后最多自动修复 3 轮；修改 22 个必选插件清单、设备配置或需要产品决策时才进入 `blocked`。

完整说明见 `docs/PERSISTENT_CI_CONTROLLER.md`。

## 本地编译

```bash
./scripts/build.sh main
```

## 固件命名

成功后标准文件名为：

```text
XinZhaoWrt-Arthur-v0.1.0-YYYYMMDD-sysupgrade.bin
XinZhaoWrt-Arthur-v0.1.0-YYYYMMDD-factory.bin
```

实际是否同时生成 factory/sysupgrade 两种镜像，由当前上游 RE-SS-01 image recipe 决定。

## 运行时注意

AdGuard Home、MosDNS、SmartDNS、OpenClash 可以同时编进固件，但不要让多个 DNS 服务同时占用 53 端口。OpenClash 与 PBR 同时存在也没问题，实际启用时要避免两套策略路由同时接管同一批流量。

OAF 带有内核相关组件。上游发生较大的 Linux 内核变化时，如果编译失败，优先检查 OAF 的内核 API 兼容性，不得为了让构建通过直接删除 `luci-app-oaf`。

## 文档

- `AGENTS.md`：Codex 项目硬规则
- `docs/OPENWRT_CI_V2.md`：OpenWrt 自动编译流程 v2.0，总控、监控、限流与自动修复规则
- `docs/PERSISTENT_CI_CONTROLLER.md`：Windows 持久控制器、`codex exec` 自动修复和状态管理
- `docs/CODEX_CLOUD.md`：Codex Cloud 全编译流程
- `docs/BUILD.md`：本地/手工编译
- `docs/PLUGINS.md`：插件说明
- `docs/FLASH.md`：刷机安全说明
- `docs/GITHUB.md`：GitHub Actions / Release
