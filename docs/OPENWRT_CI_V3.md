# OpenWrt 自动编译流程 v3.0 — 稳定化流水线

目标：先得到第一份可重复构建的 JDCloud RE-SS-01 / Arthur `known-good` 固件，再进入自动更新阶段。当前停止“完整固件失败一次就修一次再重跑完整编译”的低效率循环。

## 稳定化阶段

1. Freeze Sources：固定 ImmortalWrt 与第三方插件源码版本，避免测试过程中上游变化。
2. Baseline：验证 `qualcommax/ipq60xx/jdcloud_re-ss-01` 基础目标可正常配置与构建。
3. Package Resolution：确认 22 个必选 LuCI 应用及其依赖全部存在，`make defconfig` 后仍保持启用。
4. Compatibility Smoke Tests：按风险分组真实编译插件，而不是只检查 Makefile/Kconfig。
   - Phase 1：QuickStart + iStoreX/Store
   - Phase 2：OAF / OpenAppFilter
   - Phase 3：OpenClash + MosDNS
   - Phase 4：EasyTier + DiskMan + 其余外部插件
   - Phase 5：标准 LuCI 应用组
5. Full Build Gate：只有所有关键 Smoke Test 通过后才运行完整固件编译。
6. Firmware Verify：检查目标/profile、22/22 插件、固件镜像、profiles.json、SHA256、full.config 与 build-info。
7. Promote Known-Good：首次成功后锁定源码版本、配置和产物元数据，作为后续“重新编译”的固定基线。

## 后续两种模式

### 重新编译

只使用当前 known-good 锁定版本，不更新上游。目标是高可重复成功率。

### 更新编译

更新候选源码版本后，先跑完整稳定化检查；只有全部通过并完成 Full Build 与 Firmware Verify 后，才晋升新的 known-good。失败时保留上一份 known-good 不变。

## 自动化原则

- v3.0 仍然是自动流水线，不是人工逐步点击流程。
- 自动化负责触发、并行/分组测试、收集失败、修复后的重试、状态记录和最终验证。
- 不再用聊天窗口 `gh run watch` 作为持久控制器。
- 不允许为了通过编译静默删除、关闭或替换 `config/required-plugins.txt` 中的 22 个插件。
- 不允许改变 Arthur 目标或涉及刷机、eMMC 分区、Bootloader 的高风险操作。
- 只有涉及功能取舍、硬约束冲突或刷机风险时才需要人工确认。

## 当前状态

当前 PR 正在执行 v3.0 Phase 1：固定 ImmortalWrt 到 `b193c19dee5ebed962091088080397030c90dfb2`，先验证 QuickStart 与 iStore 依赖链。Phase 1 通过后继续扩展 Phase 2-5；全部通过后再启动第一轮完整固件构建并生成 known-good。
