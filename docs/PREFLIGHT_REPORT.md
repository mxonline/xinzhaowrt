# v0.1.0 first-build preflight report

Status: READY FOR FIRST FULL BUILD

## Locked identity

- Firmware: 新肇网络Wrt-京东云亚瑟固件
- Version: v0.1.0 testing
- Device: JDCloud RE-SS-01 / Arthur
- Target: qualcommax/ipq60xx
- Profile: jdcloud_re-ss-01
- Upstream: VIKINGYFY/immortalwrt main

## Locked first-login defaults

- LAN IP: 192.168.6.1
- User: root
- Initial password: passwort
- A persistent UCI initialization marker prevents these defaults from being re-applied on later config-preserving upgrades.

## Required applications

`config/required-plugins.txt` contains exactly 22 mandatory LuCI applications. `scripts/check-config.sh` fails the build if any requested package disappears after `make defconfig`.

## External source integration

Third-party packages are assembled into a dedicated local OpenWrt feed named `xinzhao`. The build checks for actual package Makefiles before configuration. This avoids relying on arbitrary nested repository layouts.

Selected source families:

- kenzok8/openwrt-packages: iStoreX, Store, QuickStart, QuickFile, Lucky and their local runtime packages
- sbwml/luci-app-diskman
- EasyTier/luci-app-easytier
- sbwml/luci-app-mosdns v5 + sbwml/v2ray-geodata
- vernesong/OpenClash
- destan19/OpenAppFilter

## Web management stack

QuickFile requires `luci-nginx`, therefore LuCI + Nginx is selected as the only primary web stack. The uhttpd-oriented `luci` and `luci-ssl` meta collections are not selected.

## Build protections

- full project static verification before cloning/building
- selected external source validation
- mandatory 22-package verification after `make defconfig`
- source download retry
- ccache enabled
- build logs written to output/logs/build.log in Codex Cloud mode
- concise failure extraction instead of dumping complete compiler logs
- firmware filename normalization
- SHA256 generation
- upstream and third-party Git commit recording

## Known compatibility-sensitive components

These require the first real compile to validate against the current upstream kernel and package APIs:

- luci-app-oaf / OpenAppFilter
- luci-app-openclash
- luci-app-mosdns
- luci-app-diskman
- luci-app-easytier
- iStoreX ecosystem

No project should claim v0.1.0 is build-successful until the full ImmortalWrt compile completes and output artifacts are verified.

## Remaining external step

The intended GitHub repository is `mxonline/xinzhaowrt`. It does not currently exist. The connected GitHub interface can edit existing repositories but cannot create a new repository. Run `scripts/publish-github.sh` locally after authenticating GitHub CLI, or create an empty `mxonline/xinzhaowrt` repository in GitHub and then the connected workflow can continue writing to it.
