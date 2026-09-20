# Arthur Authoritative Product Targets

Status: ACTIVE SPEC
Updated: 2026-09-16
Scope: JDCloud RE-SS-01 / Arthur (`qualcommax/ipq60xx`, profile `jdcloud_re-ss-01`)

This document is the product-target Source of Truth for Arthur firmware. It
defines the complete application and device acceptance target; package presence
or a running process is not sufficient.

## Source-of-Truth split

- Product intent and acceptance target: `production/ARTHUR_PRODUCT_TARGETS.md`
- Machine-readable coexistence contract: `production/openclash-adguardhome-coexistence.json`
- Release policy and runtime progress remain separate from this target.
- Historical state and old PASS artifacts are not real-time progress without
  current GitHub and device evidence.

## Required device and network target

- Device: JDCloud RE-SS-01 / Arthur
- Target: `qualcommax/ipq60xx`
- Profile: `jdcloud_re-ss-01`
- LAN management address: `192.168.6.1`
- LuCI default HTTP entry: port `80`
- TCP `443` is disabled by default; HTTP must not redirect to HTTPS.
- SSH, DHCP, WAN and DNS must work on the exact released firmware.
- Storage, overlay, system services and boot logs must have no
  Known-Good-promotion-blocking error.

## Required package and application target

- The 22-package baseline remains mandatory unless explicitly reviewed.
- iStore/iStoreX and QuickStart are complete product-visible capabilities.
- AdGuard Home is disabled by default.
- AdGuard Home acceptance covers the intended complete management experience,
  not only package presence.

## Required LuCI target

- Default language: Simplified Chinese (`zh_cn`)
- Default theme: Argon
- Secondary selectable theme: Kucat
- The default LuCI page renders through the user-facing HTTP entry on port 80.
- Theme packages, language packages, static assets and dependencies are complete.

## Complete OpenClash + AdGuardHome target

OpenClash firmware composition must include the complete LuCI application and a
pinned Arthur-compatible local `linux-arm64` Meta/Mihomo core at the runtime
path expected by OpenClash. First start must not require downloading the core.
Acceptance covers configuration import/save, subscription handling, node and
policy-group/rule operation, Start/Stop/Restart, DNS behavior, proxy operation,
logs/status and reboot persistence.

`OPENCLASH_FULLY_USABLE=PASS` is required.

AdGuardHome firmware composition must include the complete accepted LuCI
manager and daemon. Acceptance covers the full management surface, Start/Stop/
Restart, Enable/Disable, Web UI, upstream DNS, filtering/query-log behavior,
configuration persistence and default-disabled state.

`ADGUARDHOME_FULLY_USABLE=PASS` is required.

After both standalone checks pass, acceptance must run both services concurrently
and verify no DNS loop, no port conflict, stable LAN/WAN/DHCP/DNS behavior, no
abnormal service restart, configuration persistence/restore, and that disabling
AdGuardHome leaves OpenClash operating normally.

`OPENCLASH_ADH_COEXISTENCE=PASS` is required before an exact released
firmware/hash may replace Known-Good.

## Required Wi-Fi target

- The approved default Wi-Fi SSID is part of the firmware product baseline.
- Wi-Fi credentials come from an approved secure configuration source and are
  not copied into public evidence.
- Acceptance confirms real client association, DHCP, LAN reachability and
  WAN/Internet access; interface existence alone is insufficient.

## POST_RELEASE_DEVICE_TEST acceptance additions

The independent device acceptance explicitly verifies LAN/LuCI, language and
themes, the 22-package baseline, iStore/QuickStart behavior, AdGuardHome
management/default-disabled state, OpenClash complete usability and bundled-core
first start, OpenClash + AdGuardHome coexistence, Wi-Fi association and reboot
persistence. These checks gate Known-Good promotion, not the preceding
`RELEASE_ONLY` GitHub Release.

## Candidate and release policy

Product-target changes for one requested firmware release are combined into one
candidate where safe. The default route is `RELEASE_ONLY`:

`target diff -> implementation -> build -> artifact/hash/config checks ->
RELEASE_GATE -> GitHub Release -> PRODUCTION_RELEASED`.

`POST_RELEASE_DEVICE_TEST` runs independently after publication and does not
become a build prerequisite. A published release is eligible to replace
Known-Good only after the exact released firmware/hash passes that independent
device acceptance.

If device acceptance fails, preserve the previous Known-Good, keep the release
published, collect evidence and start a separate repair execution.
