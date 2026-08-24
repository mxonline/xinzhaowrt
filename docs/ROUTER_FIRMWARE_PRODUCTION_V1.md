# 路由固件完整生产 v1.0

## 目标

把 XinZhaoWrt 从“手工触发编译 + 人工查看日志”升级为“提交生产请求后自动编译、自动诊断、Codex 自动修复、自动重试、产物验证”的完整生产流水线。

## 固定设备

- Device: jdcloud_re-ss-01
- Target: qualcommax
- Subtarget: ipq60xx
- Source: VIKINGYFY/immortalwrt

## 生产入口

生产请求保存在 `production/request.json`。

当 `action` 为 `produce` 且 `request_id` 发生变化后，GitHub Actions 的 `produce.yml` 会把任务派发给标签为 `xinzhaowrt-controller` 的 Windows self-hosted runner。

Windows runner 直接运行现有 `scripts/ci-controller.ps1`。

控制器负责：

1. 同步仓库。
2. 触发云端 `build.yml`。
3. 持续读取 GitHub Actions 状态。
4. 编译失败后下载诊断日志。
5. 调用本机 Codex 做最小安全修复。
6. 保护 `config/arthur.config` 与 `config/required-plugins.txt`。
7. 自动提交修复并重新触发编译。
8. 最多自动修复指定轮数。
9. 编译成功后下载并验证 `jdcloud_re-ss-01` 固件产物。
10. 生成 SHA256 验证记录。

## 状态协议

`production/status.json` 是生产状态协议文件。

状态值建议：

- idle
- queued
- building
- repairing
- verifying
- success
- blocked
- failed

GitHub Actions 的实际运行状态仍以 Actions Run 为准。状态文件用于给 ChatGPT、Notion 或其他控制层提供统一接口。

## Known-good 规则

`production/known-good.json` 用来保存已验证固件基线。

只有同时满足以下条件时才允许将 `verified` 改为 `true`：

- GitHub Actions 编译成功。
- 目标设备正确。
- 固件文件存在且非空。
- SHA256 已生成。
- 编译配置已保存。
- 已在京东云亚瑟 RE-SS-01 实机验证启动、网络和核心功能正常。

云端编译成功不能自动等同于实机验证成功。

## 自动修复边界

允许自动处理：

- feeds 兼容问题
- 包源错误
- 下载失败
- 普通依赖变化
- patch 兼容问题
- CI/workflow/script 错误
- 上游源码变化造成的最小兼容修复

必须停止并标记 BLOCKED：

- 修改 bootloader
- 修改分区布局
- 修改设备目标
- 删除或绕过强制插件要求
- 自动修复超过最大轮数
- 需要用户做产品决策
- 需要真实设备刷写或高风险操作

## 用户使用方式

正常情况下只需要提交一个生产目标，例如：

`生产亚瑟固件`

控制层把 `production/request.json` 更新为新的 `request_id` 且 `action=produce`，后续流程自动执行到成功或 BLOCKED。

