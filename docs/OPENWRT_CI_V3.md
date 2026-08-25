# OpenWrt 自动编译流程 v3.0

## 定位

v3.0 以已经通过 JDCloud RE-SS-01 实机验证的 Stable / Known-Good 为唯一基准，不再从浮动源码状态直接开始正式更新。

当前首个正式基准：

- Stable：`v0.1.0`
- Device：`jdcloud_re-ss-01`
- Target：`qualcommax/ipq60xx`
- Required LuCI plugins：22/22
- Real-device verification：PASS

`production/known-good.json` 保存正式基准元数据，`config/arthur-known-good.lock` 保存 14 个精确源码 / feed / 插件提交。

## v3.0 主流程

```text
Verified Known-Good Stable
        ↓
选择更新范围
        ↓
生成临时 Candidate source lock
        ↓
GitHub Actions 完整编译
        ↓
22/22 编译包 + firmware manifest 门禁
        ↓
固件 + SHA256 门禁
        ↓
arthur-update-<run_id> Candidate Release
        ↓
人工刷入 Candidate
        ↓
Codex Desktop / 本机 PowerShell SSH 实机验收
        ↓
REAL DEVICE VERIFICATION PASS
        ↓
归档 real-device-verification.json / md
        ↓
Promote Arthur Update Candidate to Stable v3
        ↓
新的 Stable Release
        ↓
Candidate lock 晋升为 config/arthur-known-good.lock
        ↓
production/known-good.json 更新
```

刷机本身保持人工确认，不允许自动执行 `sysupgrade`、`mtd`、`dd`、U-Boot 或 eMMC 分区写入。

## 更新模式

工作流：`.github/workflows/arthur-update-v3.yml`

支持五种模式：

- `rebuild_known_good`：完全复现当前 Known-Good，所有 14 个 ref 不变。
- `update_immortalwrt`：只更新 `VIKINGYFY/immortalwrt` HEAD，其余保持 Known-Good。
- `update_feeds`：只更新 packages / luci / routing / telephony / video。
- `update_plugins`：只更新外部插件源。
- `update_all`：更新全部 14 个 ref；仅在确有需要时使用，排障成本最高。

稳定更新默认优先采用单一更新域，避免一次移动过多依赖导致无法快速定位回归。

## Candidate lock 原则

`scripts/prepare-update-lock.sh` 从 `config/arthur-known-good.lock` 复制出临时锁文件，再根据更新模式移动指定 ref。

Candidate 编译期间：

- 不覆盖正式 `config/arthur-known-good.lock`；
- Candidate lock 会随 Release 归档；
- 只有 Candidate 完整编译、22/22 通过、实机验证通过并晋升 Stable 后，Candidate lock 才成为新的正式 Known-Good lock。

因此失败 Candidate 不会污染已验证基准。

## 编译硬门禁

Candidate 必须同时满足：

1. `production/known-good.json` 当前为 `verified=true`。
2. 设备仍为 `jdcloud_re-ss-01`。
3. `config/required-plugins.txt` 仍为 22 个必选 LuCI 插件。
4. Candidate lock 包含 14 个 40 位 Git SHA。
5. 完整固件编译成功。
6. 22/22 插件均生成实际 `.apk` / `.ipk`。
7. 22/22 插件均进入最终 firmware manifest。
8. `plugin-verification.txt` 出现最终 PASS 标记。
9. Arthur `sysupgrade.bin` 非空。
10. `SHA256SUMS.local` 校验通过。
11. Candidate lock 与构建时实际 lock 完全一致。

任何一项失败均不得发布为可晋升 Stable 的结果。

## Candidate Release

成功构建后自动创建：

```text
arthur-update-<github_run_id>
```

Release 至少归档：

- Arthur firmware
- `plugin-verification.txt`
- `arthur-known-good.lock`
- `build-info.txt`
- `required-plugins.txt`
- `update-lock.diff`
- `update-metadata.json`

Candidate 永远不是 Stable。

## 本机实机验收

刷入 Candidate 后，在 Codex Desktop 打开的本地仓库中执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\real-device-verify-v3.ps1 `
  -Candidate arthur-update-<run_id> `
  -Commit <candidate-project-commit> `
  -Target root@192.168.1.1
```

`real-device-verify-v3.ps1` 会参数化已经实际验证过的 `real-device-verify.ps1`，保持同一套硬门禁。

必须验证：

- SSH
- 设备型号
- 系统启动
- storage / overlay / eMMC
- LAN / WAN
- Internet / DNS
- 2.4G / 5G
- LuCI
- 22/22 必选插件
- logread / dmesg 严重错误
- 一次正常 reboot
- reboot 后 SSH / LuCI / 网络恢复
- overlay 持久化
- reboot 后 22/22 再验证

只有输出：

```text
REAL DEVICE VERIFICATION PASS
```

才能进入 Stable promotion。

## Stable promotion v3

工作流：`.github/workflows/promote-stable-v3.yml`

必须满足：

- Candidate tag 格式为 `arthur-update-<run_id>`；
- `stable_tag` 与仓库 `VERSION` 完全一致；
- 已归档实机报告中的 Candidate 和 project commit 与 Release 一致；
- 实机 22/22、网络、Wi-Fi、LuCI、reboot、persistence 全 PASS；
- 严重日志错误为 0；
- Candidate firmware、SHA256、plugin verification、Candidate lock 和 update metadata 全部一致。

通过后：

1. 创建新的 Stable Release；
2. 将 Candidate lock 覆盖为新的 `config/arthur-known-good.lock`；
3. 更新 `production/known-good.json`；
4. 分开记录 `project_commit`、`upstream_commit`、`lock_sha256` 和 `lock_refs`；
5. 更新 `production/status.json`；
6. 新 Stable 成为下一轮唯一正式基准。

## 版本规则

`VERSION` 和 `build.env` 中的固件版本在准备新 Stable 前必须保持一致。

例如从 `v0.1.0` 发布下一补丁版本，应先明确版本为 `0.1.1`，再生成该版本 Candidate。不得用旧 `VERSION` 创建新的 Stable tag。

## 失败处理

Candidate 编译失败：

- 保持当前 Known-Good 不变；
- 下载 diagnostics；
- 定位第一个真实错误；
- 只修复确定根因；
- 不删除 22 个必选插件；
- 不自动修改设备 target；
- 不更新正式 Known-Good lock。

Candidate 实机失败：

- 不运行 Stable promotion；
- 当前 Stable 继续作为回退版本；
- 根据实机报告定位回归；
- 修复后生成新的 Candidate。

## 一句话操作语义

以后“更新编译”默认理解为：从已验证 Known-Good 出发，生成受控 Candidate，而不是直接覆盖正式基准。

以后“重新编译”默认使用 `rebuild_known_good`，用于验证当前基准仍可复现。

以后“发布 Stable”必须先有对应 Candidate 的真实设备 PASS 证据。
