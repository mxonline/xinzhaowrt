# XinZhaoWrt 固件发布策略

## 冻结主原则

本项目唯一主线为 `RELEASE-FIRST AUTOMATION MODE`，唯一成功终点为 `PRODUCTION_RELEASED`。

固件发布任务必须被维护为单一、连续、可恢复的执行链。GPT、Codex、Bridge、Runtime、Supervisor、Skill 都只是辅助组件；任何组件故障只能做足以恢复当前固件任务的最小修复，不得让自动化平台自身的测试、重构或验证长期阻塞 Arthur 发布。

任务中断后恢复的是 Arthur 发布任务本身。电脑重启、Codex 崩溃、网络中断或控制器异常时，应读取现有 HANDOFF/state/known-good，并核对 GitHub workflow、artifact 与真实设备状态，从最后有效 checkpoint 继续。已经完成或 VERIFIED 的阶段不得无故重跑，已有有效 GitHub build 和已验证 artifact 应继续复用。

真实生产任务中禁止随意插入 probe、Bridge E2E 实验或新的自动化架构。相同故障在 `last_progress` 无变化的情况下重复出现时，必须触发 circuit breaker，停止重复同一种 resume/relaunch 方法，切换 clean execution 或其他最小发布解阻方案。

## Candidate 自动发布

《路由固件完整生产 v1.0》每次生产成功后，默认自动发布 Candidate 预发布版本。

Candidate 发布条件：
- GitHub Actions 编译成功
- 目标设备为 jdcloud_re-ss-01
- 固件文件存在且非空
- 固件 SHA256 生成成功
- full.config / build-info / required-plugins 等构建信息可用

Candidate 只代表“构建与产物检查通过”，不代表已经完成实机刷机验证。

## 自动刷入与实机验证

在 `AUTO_FLASH_SAFETY_GATE` 全部通过时，Arthur 标准 sysupgrade 属于自动发布主链路。

已验证的自动刷入路径固定为：

`GitHub Actions → candidate 完整性与 cloud/local SHA256 → AUTO_FLASH_SAFETY_GATE → Windows PowerShell → OpenSSH ssh.exe 上传 → remote SHA256 → 使用历史已验证参数执行远端 /sbin/sysupgrade → WAIT_DEVICE → REAL_DEVICE_VERIFY → Release Gate`。

自动刷入必须至少确认：
- 设备身份、型号、target/profile、存储布局完全匹配
- candidate 文件完整
- cloud/local/remote/flash-manifest SHA256 一致
- 必需插件、主题和配置门禁通过
- 当前设备健康
- 预期 LAN 配置正确
- Known-Good 与 rollback artifact/path 可用且已验证

不得猜测 sysupgrade 参数。必须复用项目历史已验证的 Arthur 标准升级参数。

MTD、U-Boot、bootloader、`dd`、raw eMMC/SPI/NAND、原始分区写入、ART/EEPROM/校准数据写入不属于自动刷入路径；这些操作继续要求明确人工授权或按项目安全策略禁止自动执行。

如果设备身份、存储布局、rollback、安全 hash 或刷写状态存在 UNKNOWN，必须停止新的自动写入并保留证据。若 sysupgrade 可能已经开始，恢复后先核对真实设备状态，禁止盲目重复刷写。

## Stable 晋升

Stable/Latest 版本必须在 Candidate 基础上完成真实 Arthur 实机验证后再晋升。

实机验证至少确认：
- 设备身份与存储布局正确
- 正常启动
- LAN 为项目预期值
- WAN、DHCP、Internet/DNS 正常
- SSH 正常
- LuCI 正常且默认 HTTP 入口为 80
- 默认语言和主题符合项目目标
- Wi-Fi 正常
- 22 个必需插件全部存在并可用
- 目标主题可正常渲染与切换
- AdGuard Home 等指定服务默认状态符合当前产品要求
- Storage/Overlay、系统服务与 Boot Log 无阻断性异常
- candidate/远端/Release SHA256 一致

任何实机门禁失败都禁止 Release。系统应收集 evidence，经 GPT 分析、Codex 最小修复、云端重编译、新 candidate 验证，再按安全门禁重新进入标准 sysupgrade 与实机验证，直到达到 `PRODUCTION_RELEASED` 或出现必须人工处理的安全阻塞。

只有真实设备验证通过的 Stable 才允许写入 `production/known-good.json`。

## 版本命名

自动 Candidate 标签格式：

v<BASE_VERSION>-rc.<GITHUB_RUN_NUMBER>

其中 BASE_VERSION 读取仓库根目录 VERSION。

正式 Stable 标签由实机验收阶段创建，例如：

v0.1.0
