# JDCloud Arthur Device Profile

## Identity

- Product: JDCloud RE-SS-01 / Arthur
- SoC: Qualcomm IPQ6000
- OpenWrt/ImmortalWrt target: `qualcommax`
- Subtarget: `ipq60xx`
- Device profile: `jdcloud_re-ss-01`
- Project firmware ID: `XinZhaoWrt`

The 64G designation refers to eMMC capacity. It is not a different OpenWrt device profile. Never create or select a fictional `jdcloud_re-ss-01-64g` target.

## Authoritative project files

- Project identity/defaults: `build.env`
- Target and package seed: `config/arthur.config`
- Mandatory apps: `config/required-plugins.txt`
- First-boot defaults: `files/etc/uci-defaults/99-xinzhao-defaults`
- Build logic: `scripts/build.sh`

## Required target invariants

A valid Arthur build must retain:

- target `qualcommax`
- subtarget `ipq60xx`
- profile `jdcloud_re-ss-01`
- all 22 required LuCI applications after `make defconfig`
- project first-boot defaults overlay

Do not repair an unrelated package/build failure by changing target/subtarget/profile.

## Project first-boot defaults

Current intentional defaults:

- LAN IP: `192.168.6.1`
- administrator: `root`
- initial password: defined by the project defaults and must be changed by the user after first login

Do not change defaults unless the task explicitly requests it.

## Web stack

The project uses LuCI on Nginx because QuickFile requires `luci-nginx`. Avoid adding the generic `luci`/`luci-ssl` meta collections unless a verified requirement justifies the uhttpd stack.

## Runtime coexistence constraints

Packages may coexist in the image without being configured to own the same runtime resource:

- AdGuard Home, MosDNS, SmartDNS and OpenClash must not all bind DNS port 53 by default.
- OpenClash and PBR must not both own the same policy-routing flows by default.
- OpenAppFilter is kernel-facing and deserves early compatibility checks after upstream kernel changes.

## Flashing safety boundary

Build agents may compile, checksum, inspect images and prepare human-reviewed flashing instructions. They must not automatically:

- flash the router;
- write U-Boot/bootloader;
- repartition eMMC;
- alter ART/EEPROM/calibration data;
- perform destructive storage operations.

Real-device promotion evidence must come from an explicitly executed device test, not a simulated claim.