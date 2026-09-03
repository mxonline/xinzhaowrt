# Arthur LIVE_PREVIEW + RELEASE_CANDIDATE 双通道设计

Status: PROPOSED / USER-APPROVED DIRECTION
Date: 2026-09-03
Scope: JDCloud RE-SS-01 / Arthur

## 目标

Arthur 后续所有功能开发统一采用双通道流程：

1. `LIVE_PREVIEW`：在不重新编译整份固件的情况下，把允许热部署的安全变更临时同步到正在运行的 Arthur，快速确认真实页面和功能行为。
2. `RELEASE_CANDIDATE`：功能确认后再生成正式 Candidate，执行构建、产物校验、刷机、重启和全量实机验证，只有该通道可以进入 Release。

`LIVE_PREVIEW_PASS` 永远不能等同于 `REAL_DEVICE_VERIFY_PASS`。

## 核心流程

### LIVE_PREVIEW

`source change -> static gate -> preview scope gate -> runtime backup -> hot deploy -> cache/service reload -> authenticated live check -> preview evidence`

目标是让 LuCI、AdGuard Home 管理页面、QuickStart/iStore 首页等可安全热部署的 UI/配置改动在几十秒内出现在 Arthur 实机上。

LIVE_PREVIEW 必须使用当前已验证的 SSH 控制路径，并在任何写入前完成设备身份、LAN 地址、版本/基线与控制路径检查。

### RELEASE_CANDIDATE

`confirmed source -> Candidate -> build -> artifact/hash gate -> AUTO_FLASH_SAFETY_GATE -> standard sysupgrade -> reboot -> REAL_DEVICE_VERIFY -> Release Gate`

只有正式 Candidate 刷入后的全量实机验证可以产生发布资格。

## LIVE_PREVIEW 允许范围

默认白名单：

- LuCI JavaScript / HTML / CSS / 静态资源
- LuCI 菜单与视图文件
- rpcd ACL 文件
- AdGuard Home LuCI manager 前端及其安全管理接口配置
- QuickStart/iStore 的可热部署静态前端资源
- 明确标记为 preview-safe 的应用级配置文件
- 为使上述页面生效所必需的 rpcd/LuCI 缓存刷新和非破坏性服务 reload/restart

任何未命中白名单的变更默认进入 RELEASE_CANDIDATE，不允许自动扩大 LIVE_PREVIEW 权限。

## LIVE_PREVIEW 禁止范围

以下内容禁止通过 LIVE_PREVIEW 修改：

- Wi-Fi UCI、SSID、密码、radio、network/wireless runtime
- LAN/WAN、管理 IP、DHCP、路由、firewall 核心网络配置
- kernel、内核模块、驱动、firmware blobs
- bootloader、U-Boot、分区表
- MTD、raw eMMC/SPI/NAND、ART/EEPROM/calibration
- 系统软件包二进制替换或 ABI 相关变更
- libc、busybox、ubus、rpcd 等基础系统二进制
- package manager 数据库
- known-good、Stable/Latest 指针
- 任何需要重启整机才能证明正确性的变更

Wi-Fi 已通过的项目状态使用 `WIFI=VERIFIED_FROZEN`。LIVE_PREVIEW 不得重新验证或修改 Wi-Fi，除非用户明确开启新的 Wi-Fi 变更任务。

## 备份与自动回滚

LIVE_PREVIEW 在首次 runtime mutation 前必须：

- 记录设备身份、当前 build identity 与目标文件 hash
- 把所有将被覆盖的文件备份到路由器独立 timestamp 目录
- 记录文件原本不存在的情况
- 保存需要恢复的应用级 UCI 配置

任意 deploy、reload、认证页面检查或功能检查失败时：

1. 立即停止后续 preview mutation；
2. 恢复全部备份文件和配置；
3. 清理 LuCI/rpcd 缓存；
4. 恢复相关服务到原始状态；
5. 输出 `LIVE_PREVIEW=FAIL_ROLLED_BACK`；
6. 禁止把失败 preview 证据用于 Candidate/Release。

如果控制路径丢失，必须 fail-closed，并把设备状态标为需要人工恢复确认，不得继续写入。

## AdGuard Home 验收

LIVE_PREVIEW 可用于快速确认 AdGuard Home 成熟 manager 的真实页面效果和管理行为，但至少要覆盖：

- 认证后的 LuCI 页面能完整渲染
- 服务状态读取
- 启动、停止、重启调用
- 配置读取与保存路径
- 日志读取
- 打开 AdGuard Home Web 管理入口
- 核心版本读取/检查
- preview 结束时恢复产品要求的默认关闭状态

正式发布仍必须在新 Candidate 刷机后重新运行同等或更严格的 `ADGUARD_REAL_DEVICE` 检查。

## QuickStart / iStore 验收

LIVE_PREVIEW 必须验证的是完整目标首页，不接受仅检查路由、socket、包存在或配置项：

- 认证后完整首页/dashboard 实际渲染
- 官方/锁定来源的主要静态资源加载成功
- 关键首页组件存在
- 不得退化为占位页、空壳页或登录重定向

正式发布必须在新 Candidate 刷机后重新执行 `QUICKSTART_REAL_DEVICE`。

## 状态模型

开发阶段至少区分：

- `STATIC_VALIDATION=PASS|FAIL`
- `LIVE_PREVIEW=NOT_RUN|PASS|FAIL_ROLLED_BACK|BLOCKED`
- `ADGUARD_PREVIEW=...`
- `QUICKSTART_PREVIEW=...`
- `WIFI=VERIFIED_FROZEN`（当前适用）
- `CANDIDATE=NOT_CREATED|CREATED`
- `BUILD=NOT_RUN|PASS|FAIL`
- `FLASH=NOT_RUN|PASS|FAIL`
- `ADGUARD_REAL_DEVICE=NOT_RUN|PASS|FAIL`
- `QUICKSTART_REAL_DEVICE=NOT_RUN|PASS|FAIL`
- `REAL_DEVICE_VERIFY=NOT_RUN|PASS|FAIL`
- `RELEASE_ALLOWED=true|false`

严禁把 `STATIC_VALIDATION` 或 `LIVE_PREVIEW` 的 PASS 文案称作“正式实机验证通过”。

## 自动化行为

默认开发循环：

`edit -> test -> LIVE_PREVIEW -> live check -> fix -> LIVE_PREVIEW`

开发者/用户确认功能符合目标后：

`freeze source -> Candidate -> build -> hash/safety -> sysupgrade -> reboot -> REAL_DEVICE_VERIFY -> Release`

正常 git push、Actions、构建、Candidate 生成和已经授权的标准 sysupgrade 不应逐步重新请求确认。安全红线、高风险写入、凭证不可用或所有已授权写入路径真实失败时才允许 BLOCKED。

## 与旧 0.1.3 热部署的关系

恢复 0.1.3 的“快速实机看到功能变化”能力，但不恢复其危险行为。旧脚本曾直接修改 wireless UCI；新 LIVE_PREVIEW 必须通过严格 scope gate 阻止 Wi-Fi 和核心网络 mutation。

旧流程中的 runtime backup、SCP 热部署、LuCI/rpcd 缓存刷新和失败回滚思想保留并收紧。

## 未来设备复用

双通道模型可复用于其他 OpenWrt/ImmortalWrt 设备，但每个设备必须单独声明：

- 设备身份 gate
- 管理地址/控制路径
- preview 文件白名单
- 禁止 mutation 范围
- rollback 目录与恢复规则
- Candidate 刷机策略
- REAL_DEVICE_VERIFY 验收项

不得把 Arthur 的 IP、profile 或设备特有路径硬编码为所有设备的通用规则。

## 完成标准

该流程落地后，Arthur 开发应满足：

- UI/安全应用层修改可快速在真实路由器上预览；
- LIVE_PREVIEW 不碰已经冻结的 Wi-Fi 和核心网络基线；
- preview 失败可自动恢复；
- preview PASS 不产生 Release 权限；
- 只有新 Candidate 刷机后的 REAL_DEVICE_VERIFY PASS 才允许 Release；
- AdGuard Home 和 QuickStart/iStore 都以真实完整页面与功能行为作为验收依据。
