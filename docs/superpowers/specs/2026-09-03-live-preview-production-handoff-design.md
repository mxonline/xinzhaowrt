# Arthur LIVE_PREVIEW → Production Handoff 持久闭环设计

Status: USER-APPROVED DESIGN / READY FOR IMPLEMENTATION PLAN
Date: 2026-09-03
Scope: JDCloud RE-SS-01 / Arthur, with reusable pattern for future OpenWrt devices

## 1. Problem

Arthur 当前已经具备两段能力：

1. v0.1.3-style HOT/LIVE 实机开发：新功能优先复用成熟方案，安全热部署到正在运行的 Arthur，快速迭代直到 `LIVE_PREVIEW=PASS`。
2. RELEASE-FIRST 后半段：`ci-controller-v3.ps1` 负责 Candidate 构建/自动修复，`production-agent.ps1` 负责 artifact、AUTO_FLASH_SAFETY_GATE、标准 sysupgrade、REAL_DEVICE_VERIFY、Release，最终到 `PRODUCTION_RELEASED`。

真实缺口是两段之间没有持久执行 handoff。`live-preview-mature-safe.ps1` 在输出 `LIVE_PREVIEW=PASS` 后正常退出；如果 Codex 会话同时结束，就没有常驻执行者主动保存本地修改、冻结已接受源码并启动现有 v3 production chain。

因此不能再依赖聊天指令、人工刷新页面或一个仍然存活的 Codex 会话维持闭环。

## 2. Goal

新增一个最小的、持久化的 Feature Handoff 层，把已经存在的两段能力连接起来：

`mandatory Reuse Gate -> HOT/LIVE implementation -> LIVE_PREVIEW=PASS -> durable handoff -> accepted-source freeze -> Git/CI integration -> ci-controller-v3 -> Candidate -> production-agent -> flash -> REAL_DEVICE_VERIFY -> Release -> PRODUCTION_RELEASED`

默认行为：只要用户已经要求“实施/继续”，且没有明确要求“先让我看一下”，`LIVE_PREVIEW=PASS` 只能是 checkpoint，不能是 terminal state。

## 3. Non-goals

- 不重写现有 `ci-controller-v3.ps1` 的 Candidate/repair 能力。
- 不重写 `production-agent.ps1` 的 flash/release 能力。
- 不让 Codex 自身成为必须常驻的 orchestrator。
- 不在 handoff 中新增 raw MTD/U-Boot/dd/partition write 能力。
- 不改变 `WIFI=VERIFIED_FROZEN`。
- 不绕过 Reuse Gate、CHANGE_IMPACT_GATE、BASELINE_INHERITANCE_GATE、EXPECTED_DIFF_GATE 或 AUTO_FLASH_SAFETY_GATE。

## 4. Architecture

新增 `scripts/feature-handoff.ps1`，职责仅限于把已通过 preview 的功能安全交给现有 production chain。

### Inputs

- `feature_id`
- preview manifest / accepted feature metadata
- `accepted_preview_source_sha`（当前源码 checkpoint）
- preview status evidence：至少 `LIVE_PREVIEW=PASS`，功能级状态按任务写入
- `WIFI=VERIFIED_FROZEN`
- deferred acceptance items（例如 ADH network mutation tests）

### Durable state

持久状态写入固定 runtime 目录，例如：

`%LOCALAPPDATA%\XinZhaoWrt\FeatureHandoff\handoff.json`

状态至少包含：

- schema_version
- feature_id
- source_worktree/path
- accepted_preview_source_sha
- current_stage
- stage_status
- preview_evidence
- changed_paths
- branch / PR / merge SHA
- selected build lane / v3 mode
- dispatched run_id
- production stage
- last_error / retry_count
- timestamps

`feature_id + accepted_preview_source_sha` 作为幂等键，同一 accepted state 不允许重复 dispatch。

## 5. Handoff stages

建议固定 stage machine：

1. `PREVIEW_ACCEPTED`
2. `LOCAL_CHANGES_CAPTURED`
3. `STATIC_VERIFIED`
4. `SOURCE_FROZEN`
5. `REMOTE_INTEGRATED`
6. `BUILD_DISPATCHED`
7. `CONTROLLER_ATTACHED`
8. `PRODUCTION_RUNNING`
9. `PRODUCTION_RELEASED`

每一 stage 完成后立即持久化。进程退出、Windows 重启或 Codex 会话结束后，从 durable state 的第一个未完成 stage 恢复。

## 6. Capturing local preview changes

HOT/LIVE 开发可能在 preview 成功后留下未提交修改；这些修改不能被 `reset --hard`、`clean` 或 branch switching 静默丢失。

Handoff 必须在任何 destructive Git operation 前：

1. `git status --porcelain` 和 `git diff`；
2. 记录 changed paths；
3. 拒绝提交 `work/`, `output/`, `build_dir/`, `staging_dir/`, `dl/`, `tmp/` 等构建产物；
4. 确认 frozen Wi-Fi / protected files 未被修改；
5. 对 preview 修复运行对应静态检查；
6. 创建 focused commit，保留真实 preview 改动。

如果工作区包含与当前 feature 无关、无法安全归属的修改，不能删除它们；应隔离当前 feature 修改（优先 worktree/明确 path set）。只有无法安全分离且继续会有覆盖风险时才允许 `BLOCKED`。

## 7. Accepted-source identity rule

最终 Candidate 必须来自与成功 preview 等价的源码。

Handoff 在 `SOURCE_FROZEN` 阶段必须建立 accepted source identity，记录：

- project commit SHA
- adopted upstream/package repo + exact refs
- preview manifest hash
- relevant package/source lock delta
- feature-specific local adaptation files

如果 LIVE_PREVIEW 使用了新的成熟 upstream，而正式 build 仍指向旧 Known-Good ref，则不得直接进入 Candidate。必须先通过 Reuse Gate 已有决策和 change-impact logic 固化新 ref/适配，再构建。

因此 `rebuild_known_good` 不能作为机械默认值；构建模式必须由 accepted source diff 决定，例如 source lock 未变可走现有最短 lane，plugin/source ref 变化则进入对应 update mode。

## 8. Git / PR integration

Handoff 不允许 force push、reset 覆盖远端或丢弃他人提交。

默认行为：

- 普通 feature branch：同步最新 `main`，安全 reconcile，push focused commit，PR CI，通过后正常 merge。
- 若 current workflow 已允许直接集成且当前提交已经在 `main`：验证 `main` 包含 accepted source identity 后跳过重复 PR。

任何远端分叉先判定 ancestry；无法自动安全合并时才 `BLOCKED`。普通 CI 失败进入既有 diagnose/repair/retry，而不是询问用户。

## 9. Dispatch to existing v3 production chain

Handoff 不自己实现 build/flash。

`REMOTE_INTEGRATED` 后：

1. 执行 `CHANGE_IMPACT_GATE`；
2. 执行 `BASELINE_INHERITANCE_GATE`；
3. 执行 `EXPECTED_DIFF_GATE`；
4. 选择最快可靠 Candidate lane / v3 update mode；
5. 启动或唤醒现有 persistent `XinZhaoWrt-Arthur-v3-Controller`；
6. 获取并持久化实际 GitHub run_id；
7. 进入 `CONTROLLER_ATTACHED`。

随后由现有 `ci-controller-v3` 完成 build / auto-repair / Candidate verification，并由现有 `production-agent` 完成 flash 与 release。

Handoff 只监视最终状态；不得再实现第二套生产 controller。

## 10. Trigger model

### Immediate trigger

成功 preview 执行器在确认所有客观 preview acceptance markers 后启动一次：

`feature-handoff.ps1 -Mode Resume -FeatureId <id> ...`

它必须以独立于当前 Codex 会话生命周期的进程启动。

### Recovery trigger

安装 Windows Scheduled Task，例如：

`XinZhaoWrt-Arthur-Feature-Handoff`

职责：登录后/系统恢复后执行 `feature-handoff.ps1 -Mode Watch/Resume`，发现存在未完成 durable handoff 时继续执行。

Task 只负责恢复 handoff；不取代已经存在的 v3 Controller 和 Production Agent tasks。

## 11. Pause semantics

默认无人值守继续。

只有当用户本次任务明确设置：

`pause_after_live_preview=true`

才允许在 `PREVIEW_ACCEPTED` 停止，等待人工视觉确认。

没有该显式 flag 时，任何“等用户刷新后台看看”“等用户确认页面”均视为错误终点。

## 12. Failure handling

普通可恢复错误：

`diagnose -> rollback/repair where needed -> retry same durable stage`

典型 recoverable：GitHub transient error、CI ordinary failure、runner temporary unavailable、Codex repair timeout、build retry、SSH temporarily unavailable before write path。

真正允许 `BLOCKED` 的边界包括：

- wrong/unknown device identity；
- control path lost with no authorized recovery；
- accepted local changes cannot be safely separated without risking data loss；
- rollback artifact/evidence missing；
- AUTO_FLASH_SAFETY_GATE hard failure；
- source identity cannot be proven between preview and Candidate；
- any required irreversible product-authority decision。

## 13. Flash idempotency / no duplicate writes

Handoff 一旦观察到 production state 已处于：

`FLASH_STARTED`, `WAIT_DEVICE`, `REAL_DEVICE_VERIFY`

必须禁止重新 dispatch build 或启动第二次 flash chain。

恢复逻辑优先 reconcile existing production state，而不是重新开始。

如果 `PRODUCTION_RELEASED` 已存在且对应 accepted source identity，则 handoff 直接进入 terminal success。

## 14. Security boundaries

- `WIFI=VERIFIED_FROZEN` 继续强制。
- LIVE_PREVIEW 白名单和 rollback 规则保持不变。
- Handoff 不直接修改 router network/firewall/wireless。
- Flash 仍只能由现有 `AUTO_FLASH_SAFETY_GATE` 后的标准 Arthur sysupgrade path 执行。
- raw storage / bootloader 操作仍禁止自动化。

## 15. Testing requirements

实现前按 TDD 增加测试，至少覆盖：

1. `LIVE_PREVIEW=PASS` 触发 durable handoff，而不是正常结束全任务；
2. `pause_after_live_preview=true` 才允许暂停；
3. 未提交 preview 修改被捕获而不是 reset/clean 丢失；
4. protected/Wi-Fi path 变化 fail closed；
5. accepted source SHA/ref mismatch 时禁止 dispatch；
6. 相同 `feature_id + accepted_preview_source_sha` 不重复 build dispatch；
7. 已处于 FLASH_STARTED/WAIT_DEVICE/REAL_DEVICE_VERIFY 时不重复触发；
8. process restart 后从第一个 incomplete stage 恢复；
9. ordinary recoverable failure 自动 retry；
10. production-agent `PRODUCTION_RELEASED` 被正确映射为 handoff terminal success。

## 16. Success criteria

完成后，用户说“实施/继续”一个 preview-safe 新功能时，默认行为应为：

`Reuse mature solution -> fast real-router HOT/LIVE loop -> LIVE_PREVIEW PASS -> no human wait -> preserve/freeze accepted source -> CI/integration -> Candidate -> build -> flash -> REAL_DEVICE_VERIFY -> Release -> PRODUCTION_RELEASED`

Codex 对话结束、终端关闭或 Windows 重启不能使任务停在 `LIVE_PREVIEW=PASS`。

只有用户明确要求暂停，或者出现真实安全 blocker，任务才允许在 `PRODUCTION_RELEASED` 之前停止。
