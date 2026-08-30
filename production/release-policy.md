# XinZhaoWrt 固件发布策略

## Candidate 自动发布

《路由固件完整生产 v1.0》每次生产成功后，默认自动发布 Candidate 预发布版本。

Candidate 发布条件：
- GitHub Actions 编译成功
- 目标设备为 jdcloud_re-ss-01
- 固件文件存在且非空
- 固件 SHA256 生成成功
- full.config / build-info / required-plugins 等构建信息可用

Candidate 只代表“构建与产物检查通过”，不代表已经完成实机刷机验证。

## Stable 晋升

Stable/Latest 版本必须在 Candidate 基础上完成实机验证后再晋升。

标准 sysupgrade 自动化：
- `AUTO_FLASH_SAFETY_GATE` 全部通过后，标准 configuration-preserving sysupgrade 自动执行；不设置人工刷机门禁。
- 自动完成 `WAIT_DEVICE`、设备身份、固件身份、LAN/WAN/DNS、22 个插件、Argon/Kucat、服务、存储、Overlay、Boot Log 与实机验收。
- 只有身份无法确认、无安全 rollback 或请求 raw/bootloader/partition 写入时才进入安全阻断。

实机验证建议至少确认：
- 正常启动
- LAN/WAN 正常
- LuCI 正常
- Wi-Fi 正常
- 必需插件可打开
- sysupgrade 固件路径正确

只有 Stable 才允许写入 production/known-good.json。

## 版本命名

自动 Candidate 标签格式：

v<BASE_VERSION>-rc.<GITHUB_RUN_NUMBER>

其中 BASE_VERSION 读取仓库根目录 VERSION。

正式 Stable 标签由实机验收阶段创建，例如：

v0.1.0
