# OpenWrt Automated Firmware Pipeline v4.3 Design

## Goal

固化 Release-First + Batched Changeset + Hard Gate。开发阶段允许连续修改与快速检查，但在全部 REQUIRED TASK 完成并冻结 changeset 之前，任何 Candidate Build、自动刷机、实机验证和 Release 都必须被代码级门禁拒绝。

## Production terminal state

唯一成功终点：`PRODUCTION_RELEASED`。

## State model

仓库维护 `production/current-changeset.json`，记录 `changeset_id`、`required_tasks`、`implementation_complete`、`frozen`、`frozen_source_sha`。状态文件是 Candidate Build 的机器可读授权源，不依赖 Codex/GPT 的自然语言判断。

`frozen_source_sha` 不是 freeze commit 自身的 SHA。它固定指向“全部实现代码完成后的最后一个 implementation commit”。随后只允许创建一个 **state-only freeze commit**，该 commit 只修改 `production/current-changeset.json`，把任务置为 PASS、`implementation_complete=true`、`frozen=true`、`allow_candidate_build=true`，并写入前一个 implementation commit 的 SHA。

Candidate 实际 checkout 的是 state-only freeze commit。这样避免“提交内容中存储自身 SHA”的自引用不可能问题，也保证 freeze 后任何新的代码提交都会自动使 Hard Gate 失败。

## Hard gate

`scripts/implementation-complete-gate.sh` 必须验证：

- schema version 为 4.3；
- 所有 REQUIRED TASK 为 `PASS`；
- `implementation_complete=true`；
- `frozen=true`；
- `frozen_source_sha` 等于 Candidate HEAD 的第一父提交；
- freeze commit 从 parent 到 HEAD 只允许修改 `production/current-changeset.json`；
- `candidate_policy.allow_candidate_build=true`；
- 可选输入的 changeset/candidate/implementation SHA 与实际状态一致。

任意条件失败时立即退出非零，输出 `IMPLEMENTATION_COMPLETE_GATE=FAIL`，Candidate 不得继续。

## Batched changeset

当前 Arthur changeset 包含：

- `adguardhome_full_manager`
- `istoreos_original_quickstart`
- `wifi_real_connect_fix`
- `plugin_i18n`
- `argon_compatibility`
- `kucat_compatibility`
- `plugins_menu_cleanup`
- `baseline_regression`

全部完成后才允许 freeze。一个 frozen changeset 对应一次正式 Candidate Build、一次自动 sysupgrade、一次 Full Real Device Verify。实机失败时先收集全部失败，再形成一轮 batch repair。

## Candidate entry protection

当前 Candidate 入口至少包括 `arthur-theme-candidate.yml`、`arthur-fast-candidate.yml`、`build.yml`。所有入口必须在耗时 SDK/ImageBuilder/Full Build 之前执行 Hard Gate。旧的中间 build/artifact 不具备 flash/release 资格。

## Arthur invariants

- Target: `qualcommmax/ipq60xx`
- Profile: `jdcloud_re-ss-01`
- LAN: `192.168.6.1`
- LuCI HTTP: `80`
- 默认语言: `zh_cn`
- Argon 默认，Kucat 第二主题
- 22 个 baseline plugins
- AdGuard Home 安装但默认关闭，最终验收状态必须关闭
- Wi-Fi 必须通过配置、运行时和真实客户端连接三层 Gate
- 标准刷机路径保持 PowerShell → `ssh.exe` → remote SHA256 → `/sbin/sysupgrade`
- 原始 MTD/U-Boot/dd/raw eMMC/SPI/NAND 写入不自动化

## Release invariant

`BUILD_SHA256 = FLASHED_SHA256 = VERIFIED_SHA256 = RELEASE_SHA256`。
