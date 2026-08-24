# 固件发布闭环检查

Candidate 自动发布完成时必须满足：
- 编译成功
- RE-SS-01 固件存在且非空
- SHA256 已生成
- GitHub Pre-release 已创建
- 构建信息资产已上传

Stable 晋升前必须满足：
- Candidate Release 存在
- 下载资产 SHA256 校验通过
- 京东云亚瑟 RE-SS-01 实机验证已明确通过

Stable 晋升完成时必须满足：
- Stable GitHub Release 已创建并标记 Latest
- 固件及 SHA256 已上传
- production/known-good.json 已更新

未完成实机验证时，流程必须停留在 Candidate，不允许自动标记为 Stable/known-good。
