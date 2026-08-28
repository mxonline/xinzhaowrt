# OpenWrt 固件生产流程 v4.0

## 目标

把亚瑟固件生产从“任何改动都触发完整源码编译”改成“Known-Good 稳定基线 + 变更分类 + 最小构建通道 + 自动验收”。

v4.0 不推翻现有稳定成果。`production/known-good.json` 中已通过实机验证的 v0.1.0 继续作为 Stable 基线，直到新的 Candidate 完成同等级验证后才允许晋升。

## 固定流程

GitHub / 官方生态检索 → Reuse Gate → Known-Good Lock → Change Detector → DOC_ONLY / FAST_GATE / IMAGEBUILDER / SDK_BUILD / FULL_BUILD 分流 → GitHub Actions → Artifact Check → Candidate → 实机验证 → Stable Promotion。

## 通道定义

### DOC_ONLY

文档、知识库等不会改变固件产物的修改。只做静态检查，不编译固件。

### FAST_GATE

CI、测试、校验器、控制器等控制面修改。只运行快速测试和静态校验，不启动固件编译。

### IMAGEBUILDER

只改变用户态包组合、默认配置、文件覆盖层、预置脚本等，并且所有依赖都有与 Known-Good ABI 匹配的预编译包时，使用 ImageBuilder 组装新固件。

若依赖不满足，禁止强行使用 ImageBuilder，升级到 SDK_BUILD 或 FULL_BUILD。

### SDK_BUILD

只需要重新编译用户态软件包或可独立构建的软件包时，使用匹配 Known-Good 的 SDK 构建包，再交给 ImageBuilder 组装固件。

涉及内核 ABI、kmod、NSS、DTS、target、toolchain、内核 patch 或无法证明 ABI 兼容的变化时，禁止停留在 SDK_BUILD，升级到 FULL_BUILD。

### FULL_BUILD

内核、NSS、DTS、驱动、target、toolchain、底层 patch、分区布局、内核模块 ABI 或任何无法安全分类的变化，继续使用完整源码构建。

未知变化默认 FULL_BUILD，保持 fail-closed。

## Known-Good 规则

Stable 当前锁定为：

- 设备：JDCloud RE-SS-01 / Arthur
- Stable：v0.1.0
- 固件：XinZhaoWrt-Arthur-v0.1.0-20260825-sysupgrade.bin
- SHA256：9557593696c7bb07a1f0b259859140b4096ba71c675847aaf5ba5015118a7c2d
- 上游：VIKINGYFY/immortalwrt
- 上游 commit：27e26e324bee0b0c2a4eb58e2e9121fea5d43194
- 状态：real-device-confirmed

任何 Candidate 失败都回到该 Stable，不重新猜测基础环境。

## 迁移原则

1. 现有 DOC_ONLY / FAST_GATE / FULL_BUILD 行为继续有效。
2. 新增 IMAGEBUILDER 和 SDK_BUILD 必须以显式目录/请求文件启用，不能把旧路径一次性重新分类。
3. 22 个必选插件、默认管理地址、校验和、OOM 防护和实机验证门禁不得削弱。
4. 旧的长时间 Full Build 可以继续完成，但只作为 Candidate 证据，不阻塞 v4.0 控制面迁移。
5. v4.0 未验证完成前，`main` 和 Stable Known-Good 均保持不变。
6. 自动刷机仍受项目现有人工审核安全门约束。构建、下载、校验可以自动化，写入路由器前必须经过人工确认，除非项目规则被用户明确修改。

## 当前迁移阶段

- Reuse Gate：DONE
- Known-Good Lock：VERIFIED
- v4 隔离分支：DONE
- 五通道分类器：IN_PROGRESS
- ImageBuilder 执行器：NOT_STARTED
- SDK 执行器：NOT_STARTED
- v4 GitHub Actions 编排：NOT_STARTED
- Candidate Artifact Gate：复用现有门禁并待接线
- 实机验证：复用现有流程
- Stable Promotion：复用现有流程

状态以 `production/v4-state.json` 为准。
