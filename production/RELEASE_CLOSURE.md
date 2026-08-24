# 《路由固件完整生产 v1.0》发布闭环

完整生产的终点不是“make 成功”，而是 Candidate Release 已发布，并等待实机验证。

完整链路：

生产请求 -> GitHub 云编译 -> 自动诊断 -> Codex 自动修复 -> 重试 -> 固件校验 -> SHA256 -> Candidate Release -> 实机验证 -> Stable Release -> known-good

Candidate：自动生成，属于预发布版本，不代表实机验证。

Stable：必须显式确认实机验证通过后，使用 Promote XinZhaoWrt Candidate to Stable 工作流晋升。Stable 发布完成后自动更新 production/known-good.json。

自动发布资产至少包含：
- JDCloud RE-SS-01 sysupgrade 固件
- sha256sums.txt
- full.config（存在时）
- build-info.txt（存在时）
- required-plugins.txt（存在时）

安全门禁：未完成实机验证的 Candidate 不得自动标记为 Stable 或 known-good。
