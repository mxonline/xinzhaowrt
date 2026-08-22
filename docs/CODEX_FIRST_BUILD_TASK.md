# Codex Cloud first full-build task

Use the following task after connecting the GitHub repository to Codex Cloud:

```text
Read AGENTS.md, build.env, docs/PROJECT_SPEC.md and config/required-plugins.txt before making changes.

Perform the first full build of 新肇网络Wrt-京东云亚瑟固件 v0.1.0 for JDCloud RE-SS-01.

Run:
1. ./scripts/verify-project.sh
2. ./scripts/codex-setup.sh if the environment has not been prepared
3. ./scripts/codex-cloud-build.sh

All 22 LuCI applications in config/required-plugins.txt are mandatory. Never delete or disable one merely to make the build pass.

If make defconfig drops a required package, find and fix the selected package source or dependency first.

If compilation fails, do not read or print the entire OpenWrt build log. Use scripts/extract-build-error.sh output/logs/build.log, identify the first real package/compiler failure, inspect only the relevant package and nearby log section, patch the project or package integration, rerun validation, and resume the build.

Treat OAF, OpenClash, MosDNS, DiskMan and EasyTier as external compatibility-sensitive components.

Success requires:
- target qualcommax/ipq60xx/jdcloud_re-ss-01;
- all 22 required package symbols enabled in output/full.config;
- at least one Arthur firmware image under output/firmware;
- output/build-info.txt;
- output/firmware/SHA256SUMS.local;
- first-boot defaults included: 192.168.6.1, root, initial password passwort;
- no flashing or eMMC/bootloader write operation is executed.

When successful, summarize the resulting image names, upstream ImmortalWrt commit, external source commits, kernel version if available, and any compatibility patches applied.
```
