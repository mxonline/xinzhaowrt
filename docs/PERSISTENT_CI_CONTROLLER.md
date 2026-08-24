# OpenWrt 持久自动编译控制器

这是 `OpenWrt 自动编译流程 v2.0` 的默认执行层。

## 为什么需要持久控制器

Codex 桌面对话不是常驻事件监听器。即使某一轮对话启动了 `gh run watch`，对话结束、网络出现 `unexpected EOF`、GitHub API 临时异常或 rate limit 后，后续 GitHub Actions 状态不会自动重新唤醒已经结束的 Codex 回合。

因此正式自动开发不再依赖“聊天窗口一直保持处理中”，而使用本机持久 PowerShell 控制器：

```text
用户 / Codex 发起一次任务
        ↓
Windows 持久控制器
        ↓
GitHub Actions 云端编译
        ↓
每 60 秒查询一次状态
        ↓
失败 → 下载 diagnostics / failed logs
        ↓
codex exec 非交互分析并修改工作区
        ↓
控制器检查硬约束
        ↓
git commit + push main
        ↓
重新触发 GitHub Actions
        ↓
最多自动修复 3 轮
```

真正的 OpenWrt 编译始终在 GitHub Actions Runner 中进行，本机控制器不执行完整固件编译。

## 文件

```text
scripts/ci-controller.ps1        持久状态机和自动修复循环
scripts/start-ci-controller.ps1  通过 Windows Task Scheduler 启动控制器
scripts/ci-status.ps1            查看当前真实状态和最近日志
state/ci-state.json              当前机器状态，不提交 Git
output/controller/controller.log 持久运行日志，不提交 Git
```

## 启动“更新编译”

在仓库根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-ci-controller.ps1 -Mode UpdateBuild
```

当前工程的上游和自定义插件脚本使用配置的 `main/master` 等浮动 ref，因此每次 GitHub Actions 新构建会重新取得这些 ref 的当前版本。后续如果启用 `sources.lock`，再把“更新编译”切换为显式更新 lock 后构建。

## 重新编译

不做额外本地源码修改，只使用当前 `main` 再跑云端构建：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-ci-controller.ps1 -Mode Rebuild
```

## 接管已有 Run

GitHub Actions 已经有一个运行中的或失败 Run 时：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-ci-controller.ps1 -Mode Resume -RunId 32754936887
```

控制器不会重新盲跑，而是继续跟踪该 Run；如果失败会下载诊断资料并进入自动修复。

## 查看状态

一次查看：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ci-status.ps1
```

持续刷新：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ci-status.ps1 -Follow
```

状态文件中的核心字段：

```text
status
stage
conclusion
run_id
repair_round
message
updated_at
```

常见状态包括：

```text
queued
in_progress
failed
repairing
verifying
success
blocked
```

## GitHub API 与网络异常

控制器不使用高频 `gh run watch` 长连接作为唯一状态来源，而是默认每 60 秒执行一次短查询。

自动处理：

- `unexpected EOF`
- timeout / connection error
- GitHub 5xx
- `HTTP 403: API rate limit exceeded`

处理原则：

```text
普通轮询：60 秒
临时网络/API 错误：120 秒后重试
Rate limit：600 秒后重试
```

这些错误只会暂停“查看状态”，不会取消 GitHub Runner 上正在执行的构建，也不会重复触发同一个构建。

## codex exec 自动修复

构建失败后控制器会下载当前 Run 的失败日志和 Artifact，然后调用非交互 Codex CLI：

```text
codex exec
```

Codex 只负责：

- 阅读失败日志
- 定位第一个真实根因
- 修改仓库中的脚本 / feed / workflow / 兼容性代码
- 做轻量静态检查

Codex 不负责：

- `git commit`
- `git push`
- 触发 GitHub Actions
- 完整 OpenWrt 本地编译

这些动作由持久控制器统一执行，防止多个代理同时操作 CI 状态。

## 硬约束保护

自动修复前后控制器会校验：

```text
config/required-plugins.txt
config/arthur.config
```

如果 Codex 尝试修改这些受保护文件，控制器会恢复改动并进入 `blocked`，不会为了编译通过而偷偷删除插件、修改设备目标或改变核心固件配置。

固定目标仍然是：

```text
qualcommax/ipq60xx/jdcloud_re-ss-01
```

22 个 LuCI 必选插件仍然属于不可删除约束。

## 自动修复次数

默认：

```text
MAX_REPAIR_ROUNDS = 3
```

每轮：

```text
Run失败
→ 下载诊断
→ codex exec修复
→ git diff --check
→ commit
→ push main
→ 新Run
```

超过 3 轮、Codex 无法产生安全修改、修改硬约束、CLI 超时或需要产品决策时，状态变为：

```text
blocked
```

此时才需要人工介入。

## 成功条件

GitHub Actions `success` 还不是最终成功。控制器会下载 Artifact，并确认存在非空的：

```text
*jdcloud_re-ss-01*
```

然后生成本地 SHA256 验证记录。只有云端构建成功且固件 Artifact 验收通过，状态才会变为：

```text
success
```

## Codex 桌面端的职责

以后 Codex 桌面端主要用于：

- 用户说“更新编译”时启动持久控制器
- 用户说“查看状态”时读取 `state/ci-state.json`
- 遇到 `blocked` 时协助做需要人工判断的决策

不再要求 Codex 对话窗口本身持续守候 30 分钟以上的 GitHub Actions Run，也不再要求用户手动截图、搬日志或重复点击 `Run workflow`。
