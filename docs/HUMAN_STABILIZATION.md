# 人工稳定化流程

当前停止“完整固件失败一次就自动改一次”的循环。

本阶段只验证 QuickStart 与 iStore 依赖链：

1. 固定 ImmortalWrt 到 `b193c19dee5ebed962091088080397030c90dfb2`。
2. 确认 `qualcommax` 使用 `ARCH:=aarch64`、`CPU_TYPE:=cortex-a53`。
3. 不修改 Kenzok8 QuickStart 的架构声明，不再强制安装 `quickstart.arm`。
4. 先执行 `make defconfig` 并核对 22 个必选 LuCI 包。
5. 仅编译 `quickstart`、`luci-app-quickstart`、`luci-app-store`、`luci-app-istorex`。
6. 这一组通过后，再人工进入下一组高风险插件测试。
7. 所有关键组通过前，不执行完整固件编译。
