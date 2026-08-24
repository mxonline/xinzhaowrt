# OpenWrt 自动编译流程 v2.0

## 目标

本流程用于 `mxonline/xinzhaowrt` 的 JDCloud RE-SS-01（Arthur）固件自动构建。

核心原则：

- GitHub Actions 负责真正的 OpenWrt / ImmortalWrt 云端编译。
- Windows 持久控制器负责触发、轮询、下载 Artifact、状态记录和重试。
- `codex exec` 负责失败后的非交互诊断和最小修复。
- Codex 桌面对话只负责启动控制器、查看状态和处理 `blocked` 决策，不再承担 30 分钟以上的常驻监控。
- 不要求用户手动点击 Run workflow、搬运日志、下载诊断包或反复截图。
- `config/required-plugins.txt` 中的 22 个 LuCI 插件属于硬性约束，不得为了让编译通过而删除、注释或绕过。
- 设备目标固定为 `qualcommax/ipq60xx/jdcloud_re-ss-01`，除非用户明确要求更换设备。

持久控制器的实现与操作细节见 `docs/PERSISTENT_CI_CONTROLLER.md`。

## 为什么不再依赖聊天窗口持续监控

Codex 对话不是持久事件监听器。即使某一轮启动了 `gh run watch`，对话结束、网络 `unexpected EOF`、GitHub API 临时异常或 rate limit 后，后续 GitHub 状态不会自动重新唤醒已经结束的 Codex 回合。

因此 v2.0 默认执行模型改为：

```text
用户 / Codex 启动一次任务
        ↓
Windows 持久控制器
        ↓
GitHub Actions 云端编译
        ↓
每 60 秒短轮询状态
        ↓
失败 → 下载 diagnostics / failed logs
        ↓
codex exec 非交互分析和修改工作区
        ↓
控制器校验硬约束
        ↓
commit + push main
        ↓
重新触发 GitHub Actions
        ↓
最多自动修复 3 轮
```

## 用户命令语义

### 更新编译

执行：

1. 恢复仓库当前状态。
2. 检查 `gh auth status`，确认 GitHub CLI 已认证。
3. 保留 22 个必选插件和设备配置。
4. 通过持久控制器触发 GitHub Actions `workflow_dispatch`。
5. GitHub Actions 在云端重新获取当前配置的上游 ref 并构建。
6. 控制器持续跟踪 Run 到最终 `success` / `failure` / `cancelled`。
7. 成功后下载并验证固件 Artifact。
8. 失败后自动读取日志和 diagnostics Artifact，调用 `codex exec` 按真实根因修复并再次触发，默认最多 3 轮。

启动入口：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-ci-controller.ps1 -Mode UpdateBuild
```

### 重新编译

不主动修改本地项目配置，使用当前 `main` 再触发 GitHub Actions：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-ci-controller.ps1 -Mode Rebuild
```

### 接管已有 Run

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-ci-controller.ps1 -Mode Resume -RunId <RUN_ID>
```

不会重新盲跑；先接管原 Run，失败后再进入自动诊断。

### 查看状态

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ci-status.ps1
```

持续刷新：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ci-status.ps1 -Follow
```

### 检查最新失败

优先由持久控制器读取最新 Run、失败 Job、失败 Step、日志和 Artifact，不要求用户截图。

### 发布 vX.Y.Z

只在用户明确要求发布时创建 tag / Release。普通“更新编译”成功后只保留 Actions Artifact，不自动发布正式版本。

## 标准执行链

```text
用户：更新编译
    ↓
Codex 启动持久控制器
    ↓
控制器检查 git / gh / codex
    ↓
同步 main
    ↓
触发 GitHub Actions
    ↓
获取 Run ID
    ↓
每 60 秒短轮询
    ↓
┌──────────── success ────────────┐
│ 下载 firmware Artifact          │
│ 校验设备 / 文件 / SHA256        │
│ 写入 success 状态               │
└────────────────────────────────┘
    ↓ failure
下载 failed logs + diagnostics
    ↓
codex exec 定位第一个真实根因
    ↓
只修复确定的根因
    ↓
保护文件 / git diff --check
    ↓
commit + push main
    ↓
重新触发 GitHub Actions
    ↓
最多自动循环 3 轮
```

## 持久状态

控制器持续写入：

```text
state/ci-state.json
output/controller/controller.log
```

`state/ci-state.json` 至少包含：

```text
status
stage
conclusion
run_id
repair_round
message
updated_at
```

常见状态：

```text
queued
in_progress
failed
repairing
verifying
success
blocked
```

这些状态不依赖 Codex 聊天消息是否自动刷新。

## GitHub API 与网络异常

### 禁止高频轮询

OpenWrt 编译时间较长，不得每几秒持续调用：

```text
gh run view
gh api
gh run list
```

默认：

```text
正常状态查询：60 秒
临时网络 / API 错误：120 秒
Rate limit：600 秒
```

### 自动处理的异常

包括：

```text
unexpected EOF
timeout / connection error
GitHub HTTP 5xx
HTTP 403: API rate limit exceeded
```

这些异常只影响“查看状态”，不代表 GitHub Runner 停止。处理规则：

1. 不取消当前 Run。
2. 不重新触发重复构建。
3. 保留原 Run ID。
4. 退避后继续查询原 Run。

## 前置检查阶段

GitHub Actions 正式编译前至少验证：

1. 项目结构完整。
2. ImmortalWrt 目标支持 `jdcloud_re-ss-01`。
3. Feed 可以正常更新和安装。
4. 22 个 required packages 均存在真实 Makefile。
5. `make defconfig` 后 22 个 `CONFIG_PACKAGE_*` 仍全部为 `y`。
6. 不允许通过删除插件或绕过检查进入编译。

只有前置检查通过后才进入正式 Build firmware。

## 失败诊断

失败时优先读取：

```text
output/logs/feed-check.log
output/logs/feed-error.txt
output/logs/build.log
output/logs/error-summary.txt
output/logs/error-context.txt
output/logs/failure-report.txt
```

规则：

- Feed Check 失败时优先分析 `feed-error.txt`，不要错误读取空的 `build.log`。
- Build firmware 失败时分析 `build.log`。
- 不把 `Process completed with exit code 1` 当根因。
- 不把普通 WARNING 当根因。
- 优先定位第一个真实 package / dependency / compiler / linker / config 错误。
- 每轮只针对已经确认的根因修改。

## codex exec 自动修复边界

`codex exec` 只负责：

- 阅读失败日志和 Artifact。
- 定位真实根因。
- 修改脚本、feed、workflow、兼容性代码。
- 执行轻量静态检查。

`codex exec` 不负责：

- 完整本地 OpenWrt 编译。
- `git commit` / `git push`。
- 触发或重跑 GitHub Actions。
- 刷机、分区或 bootloader 操作。

提交、推送和 Actions 控制由持久控制器统一执行。

## 硬约束保护

自动修复前后必须保护：

```text
config/required-plugins.txt
config/arthur.config
```

若自动修复尝试修改这些文件，控制器恢复改动并进入 `blocked`。

禁止自动修复：

- 删除或关闭 22 个必选插件之一。
- 更换目标设备。
- 改变核心固件功能。
- 绕过 required package / defconfig 校验。

## 自动修复循环

默认最多 3 轮：

```text
Run #1 → 根因 → codex exec修复 → commit → Run #2
Run #2 → 根因 → codex exec修复 → commit → Run #3
Run #3 → 仍失败 → blocked
```

以下情况立即暂停并进入 `blocked`：

- 必须删除或关闭 22 个必选插件之一。
- 必须更换目标设备或改变核心固件功能。
- 涉及 eMMC 分区、刷机、bootloader 等不可逆风险。
- GitHub 权限不足或 Actions 额度不足。
- Codex CLI 无法完成安全修改。
- 两种修复方案存在明显功能取舍。
- 连续 3 轮仍未成功。

## 成功验收

不能只以 `exit code 0` 判断成功。成功后至少检查：

- Target：`qualcommax/ipq60xx`
- Device/Profile：`jdcloud_re-ss-01`
- 必选插件：22/22
- 固件文件实际存在且非空
- `profiles.json` 存在（上游生成时）
- `full.config` 保存成功
- SHA256 校验记录生成成功
- 构建来源和 commit 信息可追踪

通过验收后状态才写为 `success`。

## 总控原则

以后凡涉及 GitHub Actions 的开发、测试和编译任务，应优先检查现有 CLI / Connector / CI 能力。只要 `gh` 和 `codex` 已认证可用，就默认采用“持久控制器 + GitHub Actions + codex exec”的自动执行链，不让用户承担可以自动化的按钮操作、日志搬运和截图排障。
