# 新肇网络Wrt-京东云亚瑟固件 v0.1.0 项目规格

## 项目身份

- 正式中文名称：新肇网络Wrt-京东云亚瑟固件
- 英文内部标识：XinZhaoWrt-Arthur
- 当前版本：v0.1.0
- 发布通道：testing

## 硬件目标

- 品牌：JDCloud
- 型号：RE-SS-01
- 代号：Arthur
- SoC：Qualcomm IPQ6000
- 存储：64G eMMC（容量差异，不创建独立 target）
- Target：qualcommax
- Subtarget：ipq60xx
- Profile：jdcloud_re-ss-01

## 上游

- Source: VIKINGYFY/immortalwrt
- Branch: main

## 固件默认管理信息

- LAN IP：192.168.6.1
- 管理员：root
- 初始密码：password

初始密码是公开固定值，只用于首次登录。正式使用前必须修改。

## 强制插件

权威清单位于 `config/required-plugins.txt`，共 22 个。构建流程必须在 `make defconfig` 之后执行 `scripts/check-config.sh`，任意一个插件没有保持 `=y` 即视为构建前检查失败。

## 标准输出名称

- `XinZhaoWrt-Arthur-v0.1.0-YYYYMMDD-sysupgrade.bin`
- `XinZhaoWrt-Arthur-v0.1.0-YYYYMMDD-factory.bin`

实际输出类型取决于上游 RE-SS-01 image recipe。

## Codex Cloud 成功标准

Codex Cloud 只有同时满足以下条件才可以声明构建成功：

1. `scripts/verify-project.sh` 通过；
2. `make defconfig` 后 22 个插件全部启用；
3. `qualcommax/ipq60xx/jdcloud_re-ss-01` 未被改变；
4. 至少生成一个 RE-SS-01 可刷写固件；
5. `output/full.config` 存在；
6. `output/build-info.txt` 存在；
7. `output/firmware/SHA256SUMS.local` 存在；
8. 首次启动 defaults overlay 被复制进源码 `files/etc/uci-defaults/`；
9. Cloud 构建任务本身不直接刷写真实路由器；真实刷写与实机验证由冻结的 RELEASE-FIRST 主线在 `AUTO_FLASH_SAFETY_GATE` 后执行。
