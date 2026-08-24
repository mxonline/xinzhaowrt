# OpenWrt 自动编译流程 v2.0

## 目标

本流程用于 `mxonline/xinzhaowrt` 的 JDCloud RE-SS-01（Arthur）固件自动构建。

核心原则：

- Codex 负责总控、修改、提交、触发、监控、分析和修复。
- GitHub Actions 负责真正的 OpenWrt/ImmortalWrt 云端编译。
- 不要求用户手动点击 Run workflow、搬运日志、下载诊断包或反复截图。
- `config/required-plugins.txt` 中的 22 个 LuCI 插件属于硬性约束，不得为了让编译通过而删除、注释或绕过。
- 设备目标固定为 `qualcommax/ipq60xx/jdcloud_re-ss-01`，除非用户明确要求更换设备。

## 用户命令语义

### 更新编译

执行：

1. 恢复仓库当前状态。
2. 检查 `gh auth status`，确认 GitHub CLI 已认证且具备 `repo` / `workflow` 权限。
3. 更新允许更新的上游源码和第三方插件来源。
4. 保留 22 个必选插件和设备配置。
5. 执行静态检查。
6. commit + push `main`。
7. 通过 GitHub Actions `workflow_dispatch` 触发云端构建。
8. 持续监控 Run，直到最终 `success` / `failure` / `cancelled`。
9. 成功后下载并验证固件 Artifact。
10. 失败后自动读取日志和 diagnostics Artifact，按真实根因修复并再次触发，默认最多 3 轮。

### 重新编译

不主动更新上游源码或插件版本，使用当前 `main` 的配置和来源重新触发 GitHub Actions。

### 检查最新失败

Codex 直接读取最新 Run、失败 Job、失败 Step、日志和 Artifact，不要求用户截图。

### 发布 vX.Y.Z

只在用户明确要求发布时创建 tag / Release。普通“更新编译”成功后只保留 Actions Artifact，不自动发布正式版本。

## 标准执行链

```text
用户：更新编译
    ↓
Codex 检查 GitHub CLI 权限
    ↓
读取 / 更新源码与配置
    ↓
静态检查
    ↓
commit + push main
    ↓
触发 GitHub Actions
    ↓
获取 Run ID
    ↓
前台持续监控
    ↓
┌──────────── success ────────────┐
│ 下载 firmware Artifact          │
│ 校验设备 / 文件 / SHA256        │
│ 输出成功报告                    │
└────────────────────────────────┘
    ↓ failure
读取 failed logs + diagnostics
    ↓
定位第一个真实根因
    ↓
只修复确定的根因
    ↓
commit + push
    ↓
重新触发 GitHub Actions
    ↓
最多自动循环 3 轮
```

## 持续监控规则

### 禁止后台或隐藏 `gh run watch`

不得使用后台、隐藏、`Start-Process`、`&` 等方式启动：

```bash
gh run watch <RUN_ID> --exit-status
```

原因：后台进程即使发现 GitHub Run 已结束，也不会自动唤醒已经结束的 Codex 回合，界面会停留在过时状态。

正确要求：

- Run 处于 `queued` / `in_progress` 时，当前 Codex 任务不得结束。
- 监控必须属于当前总控任务的一部分。
- GitHub Run 到达最终状态后，才进入成功验收或失败分析。

### 正确处理 `gh run watch` 的非零退出码

GitHub 构建失败时：

```bash
gh run watch <RUN_ID> --exit-status
```

会返回非零退出码。控制器不能因为 `set -e` 直接终止，必须用 `if/else` 捕获结果：

```bash
if gh run watch "$RUN_ID" --exit-status -R mxonline/xinzhaowrt; then
    # success path
else
    # failure path: read logs / artifacts and continue diagnosis
fi
```

## GitHub API 限流规则

### 禁止高频轮询

OpenWrt 编译时间较长，不得每几秒持续调用：

```text
gh run view
gh api
gh run list
```

否则容易触发：

```text
HTTP 403: API rate limit exceeded
```

### 默认轮询间隔

- 普通状态查询：建议 60 秒一次。
- 不因为没有即时状态变化而提高轮询频率。
- 同一轮构建优先复用已取得的 Run ID，不重复搜索最新 Run。

### 遇到 API Rate Limit

API 403 只代表 Codex 暂时无法继续查询 GitHub，不代表 GitHub Runner 停止编译。

处理规则：

1. 不取消当前 Run。
2. 不重新触发重复构建。
3. 读取 rate limit 信息（可用时）。
4. 等待 reset 时间，或采用较长退避后再查询。
5. 恢复查询后继续跟踪原 Run ID。

推荐退避策略：

```text
正常：60 秒
API 临时异常：120 秒
Rate limit：等待到 reset；无法读取 reset 时至少等待 10 分钟
```

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

## 自动修复循环

默认最多 3 轮：

```text
Run #1 → 根因 → 修复 → commit → Run #2
Run #2 → 根因 → 修复 → commit → Run #3
Run #3 → 仍失败 → 停止自动修改并重新评估
```

以下情况立即暂停并询问用户：

- 必须删除或关闭 22 个必选插件之一。
- 必须更换目标设备或改变核心固件功能。
- 涉及 eMMC 分区、刷机、bootloader 等不可逆风险。
- GitHub 权限不足或 Actions 额度不足。
- 两种修复方案存在明显功能取舍。
- 连续 3 轮仍无法确定新的真实根因。

## 成功验收

不能只以 `exit code 0` 判断成功。成功后至少检查：

- Target：`qualcommax/ipq60xx`
- Device/Profile：`jdcloud_re-ss-01`
- 必选插件：22/22
- 固件文件实际存在且非空
- `profiles.json` 存在（上游生成时）
- `full.config` 保存成功
- SHA256 校验文件生成成功
- 构建来源和 commit 信息可追踪

通过验收后才向用户报告“编译成功”。

## 总控原则

以后凡涉及 GitHub Actions 的开发、测试和编译任务，应优先检查现有 CLI / Connector / CI 能力。只要 `gh` 已认证且权限满足，就默认采用自动执行链，不让用户承担可以自动化的日志搬运和按钮操作。
