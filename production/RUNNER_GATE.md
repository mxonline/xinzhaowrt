# Cloud-First Production Runner Gate

路由固件完整生产 v1.0 在自动生产前必须满足本门禁。Windows 只运行控制平面；不得把本机 Linux 工具缺失解释为云端构建失败。

## Control plane: Windows

在 `mxonline/xinzhaowrt` 仓库中注册 Windows x64 self-hosted runner，并添加自定义标签：

`xinzhaowrt-controller`

GitHub 默认标签应同时包含：

- self-hosted
- Windows
- X64

本机控制器通过 `produce.yml` 调度和监控云端构建，不承担 ImageBuilder、SDK 或 Full Source Build。

## Build plane: GitHub-hosted Linux

正式构建优先使用 GitHub-hosted `ubuntu-24.04`。现有 Arthur workflow 必须保持以下约束：

- `qualcommax/ipq60xx`
- `jdcloud_re-ss-01`
- Known-Good baseline 与 22-plugin baseline
- Argon 与 Kucat
- expected LAN `192.168.6.1`

优先 SDK/ImageBuilder；只有改动需要时才进入 Full Source Build。

## 本机控制器工具

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

如果控制平面 Runner 未在线，`produce.yml` 会保持 queued；这不是编译错误。Windows 本机缺少 WSL、`make`、Docker 或 Podman 同样不是 `BUILD_BLOCKED`。
