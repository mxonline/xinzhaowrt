# 发布状态定义

- idle：没有生产任务
- building：云端编译中
- repairing：Codex 自动修复中
- candidate_published：Candidate GitHub Release 已发布，等待实机验证
- stable_published：Stable GitHub Release 已发布
- verified：Stable 已通过实机验证并写入 known-good
- blocked：自动流程无法安全继续，需要人工处理

Candidate 不等于 known-good。只有 real-device verification 完成并通过 Stable 晋升后，才允许写入 known-good。
