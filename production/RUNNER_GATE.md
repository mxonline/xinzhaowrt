# Windows Runner 一次性门禁

路由固件完整生产 v1.0 在自动生产前必须满足本门禁。

## GitHub Runner

在 `mxonline/xinzhaowrt` 仓库中注册 Windows x64 self-hosted runner，并添加自定义标签：

`xinzhaowrt-controller`

GitHub 默认标签应同时包含：

- self-hosted
- Windows
- X64

Windows Runner 必须作为 Windows Service 运行。仓库不允许自动删除、重新注册或替换既有 Runner 身份。

## Runner 自愈

已注册且 `.runner` / `.service` 完整的 Runner，使用以下脚本恢复并固化自愈：

```powershell
cd C:\actions-runner\_work\xinzhaowrt\xinzhaowrt
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\repair-github-runner.ps1
```

必须使用“以管理员身份运行”的 PowerShell。脚本会：

- 从 `C:\actions-runner\.service` 或现有 `actions.runner.*` 服务找到既有 Runner Service；
- 保持原 Runner 身份，不做 remove / re-register；
- 设置 Windows Service 为 Automatic；
- 设置服务崩溃后的自动重启策略；
- 启动并确认 Service 达到 Running；
- 检查 git、gh、codex 和 GitHub 登录；
- 最终输出 `RUNNER_SELF_HEAL=PASS`。

如果 Windows Runner 从未被配置成 Service，脚本会以 `RUNNER_SERVICE_MISSING_RECONFIG_REQUIRED` 失败关闭；这种情况需要按 GitHub 官方流程保留目标仓库和标签重新配置服务，不允许脚本静默创建新 Runner 身份。

## 本机工具

以下命令必须可直接执行：

```powershell
git --version
gh --version
codex --version
gh auth status --hostname github.com
```

## 自动生产验证

Runner 在线后，把 `production/request.json` 的 `action` 改为 `produce`，并换一个新的 `request_id`。

预期链路：

`produce.yml -> Windows runner -> ci-controller.ps1 -> build.yml -> failure diagnostics -> Codex repair -> commit/push -> rebuild -> artifact verification`

如果 Runner 未在线，`produce.yml` 会保持 queued；这不是编译错误。Runner 恢复在线后，已有 queued job 会自动被领取，不需要重新构建或重新发起固件任务。
