# Stable 晋升硬门禁

Stable Release 必须满足：

1. 来源 Candidate Release 已存在。
2. Candidate 中的 RE-SS-01 固件存在且非空。
3. Candidate 的 sha256sums.txt 校验全部通过。
4. 已明确完成京东云亚瑟 RE-SS-01 实机验证。
5. Stable 标签必须与被晋升 Candidate 指向同一构建提交，禁止直接指向后来变化的 main。
6. Stable 成功发布后才能更新 production/known-good.json。

任何一项不满足都应 BLOCKED，不得自动降级门禁。
