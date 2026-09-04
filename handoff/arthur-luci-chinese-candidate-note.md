# Arthur LuCI Chinese handoff

## Corrected task semantics

The former `ADH_CHINESE` interpretation is retired. The current checkpoint meaning is `LUCI_CHINESE / ROUTER_ADMIN_CHINESE`: restore the Chinese language of the whole Arthur/OpenWrt LuCI router administration UI. AdGuard Home itself is not the Chinese-language target.

## 0.1.3 live evidence

- Device identity: `XinZhaoWrt 0.1.3`, `JDCloud RE-SS-01`, `jdcloud,re-ss-01`, target `qualcommax/ipq60xx`.
- Management address: `192.168.6.1`.
- `luci.main.lang=zh_cn`; `luci.main.homepage=admin/quickstart`.
- Authenticated LuCI pages load with `lang="zh-cn"`, but the main navigation and common router-admin labels remain English on Status/Overview, Network, System, and Services pages.
- Runtime package check: `luci-i18n-base-zh-cn` is missing and `/usr/lib/lua/luci/i18n/base.zh-cn.lmo` is missing.
- The source config already declares `CONFIG_PACKAGE_luci-i18n-base-zh-cn=y`; this is a firmware package-content requirement, not a runtime UCI-only repair.

## Preview acceptance at this handoff

- `ADGUARD_UI_PREVIEW=PASS`
- `ADGUARD_PREVIEW=PASS`
- `QUICKSTART_PREVIEW=PASS`
- `WIFI=VERIFIED_FROZEN`
- `REAL_DEVICE_VERIFY=NOT_RUN`
- `RELEASE_ALLOWED=false`
- `LUCI_CHINESE_PREVIEW=BLOCKED_FIRMWARE_CONTENT`
- `LIVE_PREVIEW=NOT_ACCEPTED_FOR_LUCI_CHINESE`

The mature ADH package remains the pinned REUSE source, with its complete management routes restored and the obsolete custom overlay removed. QuickStart remains the accepted complete official homepage. No Wi-Fi operation was performed.

## Required final Candidate change

The final Candidate must include the matching standard ImmortalWrt LuCI package content for `luci-i18n-base-zh-cn` (including `base.zh-cn.lmo`) and preserve the existing `zh_cn` default-language configuration. After that firmware-affecting change is built, the authenticated multi-page LuCI Chinese check must be repeated before acceptance.

No BUILD, Candidate creation, ImageBuilder, SDK build, Full Build, Flash, REAL_DEVICE_VERIFY, Release, or source freeze was performed at this handoff.
