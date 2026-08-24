# Windows Runner 一次性门禁

路由固件完整生产 v1.0 在自动生产前必须满足本门禁。

## GitHub Runner

在 `mxonline/xinzhaowrt` 仓库中注册 Windows x64 self-hosted runner，并添加自定义标签：

`xinzhaowrt-controller`

GitHub 默认标签应同时包含：

- self-hosted
- Windows
- X64

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

如果 Runner 未在线，`produce.yml` 会保持 queued；这不是编译错误。
