# Arthur v3 持久自动修复控制器

## 目标

`scripts/ci-controller-v3.ps1` 把 OpenWrt 自动编译 v3 的失败处理补成闭环：

```text
Arthur v3 GitHub Actions
        ↓
成功 ───────────────→ Candidate 验收与 Release
        ↓ 失败
下载 failed logs + diagnostics
        ↓
本机 Codex 自动定位第一个真实根因
        ↓
安全边界检查
        ↓
最小修复
        ↓
git diff / 22 插件 / Known-Good 保护检查
        ↓
commit + push main
        ↓
自动重新触发 Arthur v3
        ↓
最多 3 轮
        ↓
仍失败或需产品决策 → BLOCKED
```

## 持久 Watch 模式

推荐首次在 Windows 本机运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-ci-controller-v3.ps1 -Mode Watch
```

启动器会注册 Windows 计划任务：

```text
XinZhaoWrt-CI-v3-Watch
```

Watch 模式会：

- 当前立即启动；
- Windows 登录后自动启动；
- 自动发现最新 `Arthur Known-Good Update v3` Run；
- Run 成功时自动下载并复核 Candidate；
- Run 失败时自动进入 Codex 安全修复闭环；
- 新的修复提交推送后自动重新触发同一更新模式；
- 最多自动修复 3 轮。

因此 GitHub 侧由 `production/v3-request.json` 自动触发的新 Run，也可以被本机 Watch 控制器接管失败处理。

## 当前 Run 接管

例如接管已有 Run：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-ci-controller-v3.ps1 `
  -Mode Resume `
  -RunId 32879332348 `
  -UpdateMode rebuild_known_good
```

如果 Watch 模式已经运行，不需要再启动 Resume。

## 主动重新编译

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-ci-controller-v3.ps1 -Mode Rebuild
```

这会使用：

```text
rebuild_known_good
```

不移动当前正式 Known-Good 的 14 个源码 ref。

## 主动更新编译

例如只更新 ImmortalWrt：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-ci-controller-v3.ps1 `
  -Mode Update `
  -UpdateMode update_immortalwrt
```

可选范围：

```text
update_immortalwrt
update_feeds
update_plugins
update_all
```

稳定维护优先一次只移动一个更新域。

## 自动修复允许范围

Codex 自动修改只允许：

```text
scripts/
.github/workflows/
patches/
files/
package/
```

以下文件属于硬保护，自动修复禁止修改：

```text
config/required-plugins.txt
config/arthur.config
config/arthur-known-good.lock
production/known-good.json
production/status.json
VERSION
build.env
```

如果 Codex 触碰硬保护文件或允许范围之外的路径，控制器会恢复本轮修改并进入 `blocked`。

## Codex 决策

每轮失败后，Codex 只能返回三种决策：

- `repaired`：有确定根因并完成最小代码修复；控制器复核后 commit/push/rebuild。
- `retry`：明确属于临时网络/Runner/下载异常，不应改代码；直接重新运行同一模式。
- `blocked`：证据不足、需要修改硬保护文件、涉及功能取舍或无法安全自动修复；停止自动循环。

Codex 不负责 git commit、git push、Release、Stable 晋升或路由器操作，这些边界由控制器和既有 v3 流程保持分离。

## 每轮修复后的安全门禁

提交前至少检查：

1. 7 个硬保护文件 SHA256 未变化。
2. `config/required-plugins.txt` 仍为 22 项。
3. 22 个插件在 `config/arthur.config` 中仍全部为 `=y`。
4. `production/known-good.json` 仍为 `verified=true` 且 Stable 未变化。
5. 正式 `config/arthur-known-good.lock` 未变化。
6. 所有修改路径都在允许范围。
7. `git diff --check` 通过。
8. 修改的 PowerShell 文件通过 PowerShell Parser 语法检查。

任一失败都进入 `blocked`，不得为了继续编译降低门禁。

## Candidate 成功复核

GitHub Run 显示 success 后，控制器仍会本地复核：

- Arthur `sysupgrade.bin` 存在且非空；
- 22/22 每个插件在 `plugin-verification.txt` 中均有 PASS；
- 最终总 PASS 标记存在；
- `SHA256SUMS.local` 可校验；
- Candidate lock 与 `update-metadata.json` 的 SHA256 一致；
- `rebuild_known_good` 模式下 Candidate lock 必须与当前正式 Known-Good lock 完全一致；
- `arthur-update-<run_id>` Candidate Release 已创建且仍为 prerelease。

只有这些条件全部满足，状态才会写为：

```text
success / candidate_published
```

## 查看状态

单次查看：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ci-v3-status.ps1
```

持续查看：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ci-v3-status.ps1 -Follow
```

状态文件：

```text
state/ci-v3-state.json
```

日志：

```text
output/controller-v3/controller.log
```

## 安全边界

自动修复流程永远不能执行：

```text
sysupgrade
mtd
dd
U-Boot / fw_setenv
eMMC 分区写入
修改 LAN/WAN/Wi-Fi 生产配置
自动 Stable 晋升
```

Candidate 的标准 sysupgrade 在完整 `AUTO_FLASH_SAFETY_GATE` 通过后自动执行；实机验收通过后自动进入 `promote-stable-v3.yml`。原始分区、U-Boot、bootloader 和校准数据写入仍然安全阻断。
