# XinZhaoWrt 固件发布策略

## 冻结主原则

本项目唯一主线仍为 `RELEASE-FIRST AUTOMATION MODE`。`PRODUCTION_RELEASED` 只代表固件发布流水线成功终点；整个 Arthur 项目的最高产品终点固定为 `PRODUCT_GOAL_VERIFIED`，其唯一机器权威是 `production/product-goal-contract.json`。任何 Build、Artifact、Release、`PRODUCTION_RELEASED`、静态检查、菜单/包存在或进程同时存在，都不得覆盖或替代该产品目标。

从 2026-09-15 起，新 Arthur 固件生产的默认机器模式固定为 `RELEASE_ONLY`，其权威开关为 `production/release-mode.json`。`RELEASE_ONLY` 的含义是：允许无人值守完成变更影响判断、基线继承、预期 Diff、构建、Artifact 校验、Release Gate 与 GitHub Release；禁止把 `FIRMWARE_RELEASE` 授权解释为路由器写入授权，禁止自动 `sysupgrade`。

默认生产顺序固定为：

`recover current state → CHANGE_IMPACT_GATE → BASELINE_INHERITANCE_GATE → EXPECTED_DIFF_GATE → static/FAST gates → fastest valid build lane → BUILD → ARTIFACT → RELEASE_GATE → RELEASE → PRODUCTION_RELEASED`

固件生产必须保持单一、连续、可恢复。GPT、Codex、Bridge、Runtime、Supervisor、Skill 都只是辅助组件。电脑重启、Codex 崩溃、网络中断或控制器异常后，必须从 durable state、event ledger、GitHub run/artifact/release 与真实证据恢复，不得从聊天猜测阶段。已经完成且证据仍匹配的阶段不得无故重跑。

相同失败 fingerprint 在 `last_progress` 不前进时必须触发 circuit breaker，停止重复同一种 resume/relaunch，改用最小、可验证的解阻路径。任何 UNKNOWN、证据不一致、source lock 漂移、target/profile 变化、非预期 Diff、hash 不一致或权限不明确均 fail closed。

## Change Impact Gate

`CHANGE_IMPACT_GATE` 在长构建前确定变更影响和最短可靠构建路径。同设备、同 target 且 source/toolchain 兼容时，应优先 ImageBuilder、SDK/package-only、有效缓存或 source reuse；只有变更性质或验证证据要求时才进入 Full Build。

不得为了快而放松 target/profile、22 个必需插件、默认配置、主题、source provenance 或安全检查。

## Baseline Inheritance Gate

`BASELINE_INHERITANCE_GATE` 必须证明本轮没有声明改变的产品能力继续继承当前可用基线。继承证据失效、requirement digest 改变或产品目标发生冲突时，相关能力必须重新验证，不允许静默继承。

## Expected Diff Gate

`EXPECTED_DIFF_GATE` 只允许本轮任务明确声明的变化。设备身份、target/profile、存储布局、LAN 默认值、root 凭据策略、必需插件、主题、Web stack 及所有未声明产品状态默认受保护。

出现未声明变化时停止发布，保留证据并进行最小修复；禁止通过扩大 allowlist 来掩盖意外变化。

## Build

Build Gate 必须确认：

- GitHub Actions 构建成功；
- target/subtarget/profile 仍为 Arthur `qualcommax/ipq60xx/jdcloud_re-ss-01`；
- 22 个必需插件配置完整；
- source/feed/toolchain provenance 可追溯；
- first-boot defaults、主题及当前产品要求的静态契约通过；
- 构建过程没有通过删除功能来换取绿色结果。

Build 成功后应立即保存不可变 Candidate/Artifact 身份，后续控制层或验收逻辑失败时优先复用相同 bytes，只有固件本身或其 provenance 被证明无效时才允许重编译。

## Artifact

Artifact Gate 必须确认：

- Arthur 固件文件存在且非空；
- build-info、full.config、required-plugins 等构建信息完整；
- SHA256/manifest 完整且相互一致；
- artifact 与本轮 source/run 身份绑定；
- 不得把 theme/SDK/ImageBuilder 辅助产物误当正式 Production Candidate，除非当前正式 build lane 明确把它定义为可发布产物并提供完整生产证据。

## Release Gate

`RELEASE_ONLY` 下，Release Gate 在 Artifact Gate 之后执行，不要求先刷入真实路由器。

Release Gate 必须至少确认：

- `production/release-mode.json` 为 `RELEASE_ONLY`；
- `automatic_flash=false`；
- 当前 execution 是新的、已授权的 `FIRMWARE_RELEASE` execution，而非复用已关闭 execution；
- CHANGE_IMPACT、BASELINE_INHERITANCE、EXPECTED_DIFF、BUILD、ARTIFACT 全部有匹配当前 subject 的 PASS 证据；
- candidate/manifest/release asset SHA256 一致；
- 版本、tag、source、artifact provenance 无冲突；
- rollback 的上一份真实设备确认 known-good 仍然可用。

以上任一项 UNKNOWN 或不一致都禁止 Release。

## Release

Release Gate PASS 后，系统允许无人值守创建正式 GitHub Release，并记录 release id、tag、asset、source SHA、run id、artifact id 与 SHA256。

在 `RELEASE_ONLY` 下：

- 创建 Release 不授权 SSH 上传或 `sysupgrade`；
- 不执行自动刷机；
- 不等待真实设备上线；
- 不以 POST_RELEASE_DEVICE_TEST 是否完成阻塞已经满足 Release Gate 的 GitHub Release；
- 发布后将 `POST_RELEASE_DEVICE_TEST` 标记为 `PENDING_INDEPENDENT`。

## Production Released

GitHub Release 创建成功且其资产、hash 和 provenance 回读一致后，本轮发布流水线进入 `PRODUCTION_RELEASED`。这是发布流水线的成功终点，不是整个项目的产品成功终点。

整个项目只有在 exact Release 的真实 Arthur 上完成所需能力验证，并产生 `POST_RELEASE_VALIDATED` 与 `PRODUCT_GOAL_VERIFIED` 机器证据后，才允许声称最终产品目标达成。`PRODUCTION_RELEASED` 不等于“已成为新的 known-good”，也不等于“固件已长期稳定可用”。未经发布后真实设备测试的 Release 不得覆盖上一份经过真实设备确认的 rollback baseline。

## Post Release Device Test

`POST_RELEASE_DEVICE_TEST` 是发布后的独立整机测试，不属于 Build/Release 前置 Gate，不得阻塞、撤销或重写已完成的 GitHub Release，也不得因为测试失败而自动重跑同一个 Release execution。

测试可覆盖：设备身份、启动、LAN、WAN、DHCP、Internet/DNS、SSH、LuCI、中文、Wi-Fi、22 个插件、主题、AdGuard Home、OpenClash、iStore/QuickStart、Storage/Overlay、系统服务和 Boot Log 等当前产品要求。

测试 PASS 时，只有在 released firmware/hash 与测试对象完全一致的情况下，才允许把该 Release 晋升为新的 `production/known-good.json`。测试 FAIL 时保留 Release 和证据，但禁止 known-good 晋升；修复必须开启新的 execution/source/artifact 身份。

## Legacy Flash And Verify Compatibility

历史执行和事件账本中已有 `PRE_FLASH`、`AUTO_FLASH_SAFETY_GATE`、`FLASH`、`WAIT_DEVICE`、真实设备 Gate 等阶段，这些阶段继续可解析、可审计，不能为了新模式而删除历史。

显式兼容模式名为 `FLASH_AND_VERIFY`。它不是新执行默认值，也不能由 `FIRMWARE_RELEASE` 授权自动推导。任何未来需要恢复这种路由器写入链的任务，必须有独立、明确、当前有效的设备写入授权，并重新通过设备身份、存储布局、rollback、hash 与 at-most-once 写入安全检查。

## Pre Flash

仅用于 `FLASH_AND_VERIFY` 历史兼容模式。`RELEASE_ONLY` 不选择此阶段。

## Auto Flash Safety Gate

仅用于明确授权的 `FLASH_AND_VERIFY`。设备身份、target/profile、存储布局、candidate/cloud/local/remote hash、当前设备健康、LAN 预期、rollback artifact/path 任一 UNKNOWN 都必须停止设备写入。

## Flash

仅允许历史已验证的 Arthur 标准 `/sbin/sysupgrade` 路径，并且只有在独立设备写入授权和 Auto Flash Safety Gate 同时通过时才可执行。

MTD、U-Boot、bootloader、`dd`、raw eMMC/SPI/NAND、原始分区、ART/EEPROM/校准数据写入不属于无人值守路径。

## Wait Device

仅属于显式 `FLASH_AND_VERIFY` 兼容流程。若 sysupgrade 可能已开始，恢复时必须先核对真实设备状态，禁止盲目重复刷写。

## Known Good

`production/known-good.json` 只允许指向真实设备测试已经 PASS 的 exact Release/hash。一个新 GitHub Release 即使已达到 `PRODUCTION_RELEASED`，只要 `POST_RELEASE_DEVICE_TEST` 尚未 PASS，就继续保留上一份已验证 known-good 作为 rollback authority。

## 版本命名

版本号必须从当前正式 Release、仓库 VERSION 与执行目标三者一致地解析。若仓库 VERSION 落后于已发布 Release，属于版本元数据冲突，必须先修复，不得猜测下一版本号后直接发布。

Candidate/临时标签若仍由现有 workflow 使用，可继续包含 run identity；正式 Stable/Release tag 必须在 Release Gate 中证明唯一、未占用并与本轮版本目标一致。


## VNext 最高发布执行规则

本节受 `production/product-goal-contract.json` 直接约束。若本文其它历史规则与最高机器契约冲突，以最高机器契约为准。

Arthur 后续版本固定采用 **REAL-DEVICE-FIRST / SAME-IMPLEMENTATION / SINGLE-BUILD / EXACT-ARTIFACT** 路径：

`读取最高契约 → 恢复 durable state → 声明唯一变更目标 → Reuse/Change Impact → 能安全实机验证的运行时变化先实机验证 → 只修第一个真实失败 → 将同一已证明实现固化源码 → 静态与语义 Gate → 冻结 candidate → 默认只 Build 一次 → exact artifact 身份校验 → 刷 exact candidate → 最小实机复验 → 最终候选必要时只做一次 clean flash → 同一 artifact Candidate→Stable → 同步状态与证据 → 清理被取代 Candidate`

### Build 不是调试器

能够在现有 Arthur 上安全证明的运行时行为，必须优先在实机证明。不得通过连续 Build 猜测运行时行为。只有当实机证明后的同一实现需要固化，或固件 payload / provenance 因真实修复发生变化时，才允许新的 Build。

同一冻结 candidate 默认最多一次 Build。发布控制面、Candidate/Stable promotion、证据整理、GitHub 下载失败、Codex/SSE 重连均不得触发重复 Build。

### 证据失效规则

已有运行时 PASS 只有在以下变化发生时才失效：固件 payload、相关 runtime config、Core 二进制、相关 provider/rule、DNS/firewall runtime 逻辑改变；或者该证据明确要求连续同一 boot 而设备实际重启。

以下事件不得使已有 PASS 失效：Codex/聊天重连、SSE 断流、本地证据脚本修改、只读 GitHub 查询、证据文件重排、纯控制面变更、有效配置完全一致的注释变化。

### Exact Artifact

必须形成并保存：`SOURCE_SHA → BUILD_RUN_ID → ACTIONS_ARTIFACT_ID → ACTIONS_ARTIFACT_SHA256 → SYSUPGRADE_SHA256 → DEVICE_BUILD_ID → RELEASE_TAG`。

真实 Arthur 验证过的 bytes 必须就是 Stable 发布的 bytes。相同版本号、相近配置或重新 Build 出来的“等价固件”不能替代 exact artifact 证据。

Validation Build 经 exact artifact 实机 PASS 后，必须优先直接 promotion 同一 artifact；Candidate/Stable recovery 不得修改 firmware payload，也不得因为旧发布控制面条件而重 Build。

### Clean Flash

Clean flash 用于排除历史配置继承，只针对最终 candidate 或明确需要证明 first-boot 的情形。默认每个 exact candidate 最多一次。

刷前必须有设备身份、target/profile、MAC/独立身份、固件 hash、`sysupgrade -T`、rollback 可用等证据。clean flash 使用标准 `sysupgrade -n`，禁止 `-F`。若写入可能已经发生，恢复后禁止盲目第二次刷机。

### 语义 Gate

Gate 必须判断有效配置和行为语义，不能只按“文件是否变化”判定。注释变化不得使无关 ZRAM/运行时证据失效；真实 CONFIG、target/profile、包、网络、凭据策略变化必须 fail closed。

默认 root 明文密码必须通过 SHA-512 crypt 计算后与 `DEFAULT_ROOT_PASSWORD_HASH` 完全一致；仅检查 hash 字符串是否存在不再构成 PASS。

### 失败范围

单个代理节点 timeout、节点 DNS 失败、外部 endpoint 故障、Codex/SSE 断线不得直接升级为固件级失败。先隔离为 provider/node/network/control-plane 问题。

固件级失败包括：Core 异常退出/重启、全局 DNS 链失败、全局真实代理失败、管理面丢失、OOM/设备异常重启、重启持久化失败。

### 状态同步与清理

Stable promotion 后必须同步 `resume-state.json`、`status.json`、`known-good.json` 和 `product-goal-verification.json`，并保持“发布成功”和“产品目标成功”两个状态独立。

只有 exact release 的最高契约全部真实设备能力通过后，才允许 `PRODUCT_GOAL_VERIFIED`。未验证的 ADH/共存能力必须明确保持 pending，不得用 Smart/OpenClash 局部 PASS 替代。

新 Stable 确认后可清理被取代的临时 Candidate Release；必须保留当前 Stable、当前 provenance Candidate、最近真实设备确认 rollback 和机器证据。清理不得触发 Build 或设备写入。
