# Arthur Authoritative Product Targets

Status: ACTIVE SPEC
Updated: 2026-09-16
Scope: JDCloud RE-SS-01 / Arthur (`qualcommax/ipq60xx`, profile `jdcloud_re-ss-01`)

This document is the product-target Source of Truth for Arthur firmware. It complements `production/release-policy.md`, `production/release-mode.json`, `production/production-agent.json`, `production/arthur-known-good-v1.json`, and runtime HANDOFF/state. When a remembered/chat requirement conflicts with this document, the repository specification wins after the change has been reviewed and merged.

## Source-of-Truth split

- Product intent and acceptance target: `production/ARTHUR_PRODUCT_TARGETS.md`
- Release policy and safety rules: `production/release-policy.md`
- Release/flash separation policy: `production/release-mode.json`
- Machine-readable production defaults/gates: `production/production-agent.json`
- Frozen verified rollback baseline: `production/arthur-known-good-v1.json` and `production/known-good.json`
- Runtime progress: current HANDOFF/state plus GitHub workflow/artifact/device evidence

A historical state file must not be treated as real-time progress without cross-checking current GitHub and device evidence.

## Required device and network target

- Device: JDCloud RE-SS-01 / Arthur
- Target: `qualcommax/ipq60xx`
- Profile: `jdcloud_re-ss-01`
- LAN management address: `192.168.6.1`
- LuCI default HTTP entry: port `80`
- SSH, DHCP, WAN and DNS must work when the exact released firmware is exercised by independent `POST_RELEASE_DEVICE_TEST`
- Storage/overlay, system services and boot log must have no Known-Good-promotion-blocking error during that post-release device acceptance

## Required LuCI target

- Default language: Simplified Chinese (`zh_cn`)
- Default theme: Argon
- Secondary selectable theme: Kucat
- The default LuCI page must render through the user-facing HTTP entry without requiring a non-standard port
- Theme packages, language packages, static assets and dependencies must be complete

## Required package and application target

- The 22-package baseline remains mandatory unless a reviewed product-target change explicitly replaces it
- iStore/iStoreX and QuickStart are product-visible capabilities, not package-presence-only checks
- QuickStart must expose the intended complete home/dashboard experience in `POST_RELEASE_DEVICE_TEST`; package installation alone is insufficient
- AdGuard Home must remain disabled by default unless an approved product-target change says otherwise
- AdGuard Home device acceptance must cover the intended management experience and service state, not only package presence

## Complete OpenClash + AdGuardHome target

Package presence, a visible menu, or a running process is not sufficient for either application.

OpenClash firmware composition must include the complete LuCI application and a pinned Arthur-compatible `linux-arm64` Meta/Mihomo core at the runtime path expected by OpenClash. First start must not require downloading the core. Independent post-release acceptance must cover configuration import/save, subscription handling, node and policy-group/rule operation, Start/Stop/Restart, DNS behavior, proxy operation, logs/status and reboot persistence.

`OPENCLASH_FULLY_USABLE=PASS` is the required OpenClash product endpoint.

AdGuardHome firmware composition must include the complete accepted mature LuCI manager and the AdGuardHome daemon in the final rootfs. Independent post-release acceptance must cover the full management surface, Start/Stop/Restart, Enable/Disable, Web UI, upstream DNS, filtering/query-log behavior, configuration persistence and the required default-disabled state.

`ADGUARDHOME_FULLY_USABLE=PASS` is the required AdGuardHome product endpoint.

After both standalone checks pass, the independent post-release test must run them concurrently and verify no DNS loop, no port conflict, stable LAN/WAN/DHCP/DNS behavior, no abnormal service restart, configuration persistence/restore, and that disabling AdGuardHome leaves OpenClash operating normally.

`OPENCLASH_ADH_COEXISTENCE=PASS` is required before the exact released firmware/hash may replace the current Known-Good.

## Required Wi-Fi target

- The approved default Wi-Fi SSID is part of the firmware-level product baseline and must persist through the intended first-boot/default configuration path
- Wi-Fi credentials must come from an approved secure configuration source; do not duplicate credentials in public documentation, logs, screenshots or GPT long-term memory
- `POST_RELEASE_DEVICE_TEST` must confirm both required radios/interfaces, expected SSID broadcast, successful client association using the approved credential, DHCP lease acquisition, LAN reachability and WAN/Internet access
- A verification that only checks that 2.4 GHz / 5 GHz radios exist is insufficient

## Candidate composition and RELEASE_ONLY rule

Product-target changes that belong to one requested firmware release must be combined into one candidate where technically safe. Do not intentionally force one real-device flash per small product setting when the same candidate can carry all approved changes.

The default production route is `RELEASE_ONLY`:

`target diff -> implementation -> build -> artifact/hash/config/plugin/theme/provenance checks -> RELEASE_GATE -> GitHub Release -> PRODUCTION_RELEASED`

`POST_RELEASE_DEVICE_TEST` runs independently after publication. It does not block or undo GitHub Release, and it must not trigger an implicit rebuild. A release becomes eligible to replace `production/known-good.json` only after the exact released firmware/hash passes that independent device test.

If a product-target device acceptance item fails after Release, the published release remains published but is not eligible for Known-Good promotion. Preserve the previous real-device-confirmed Known-Good as rollback authority, collect evidence, and start a separate repair execution when required.

`FLASH_AND_VERIFY` remains compatibility-only. It is never implicitly selected by `FIRMWARE_RELEASE` authorization and requires separate device-write authorization.

## POST_RELEASE_DEVICE_TEST acceptance additions

The independent post-release product acceptance must explicitly verify:

1. LAN management entry and LuCI HTTP port
2. Simplified Chinese default language
3. Argon default render
4. Kucat selectable render
5. 22-package baseline
6. iStore/iStoreX availability where required by the product baseline
7. QuickStart complete intended home/dashboard behavior
8. AdGuard Home intended management UI/behavior and default-disabled state
9. OpenClash complete usability, bundled-core first start and runtime operation
10. OpenClash + AdGuardHome coexistence without DNS/port/runtime conflicts
11. Wi-Fi expected SSID plus real client association, DHCP and LAN/WAN access
12. Persistence after reboot/configuration path as required by the released candidate

These checks gate Known-Good promotion, not the preceding `RELEASE_ONLY` GitHub Release.

## Migration status

Some requirements in this document are newer than older real-device verification artifacts. Historical PASS evidence must not be used to claim the newer acceptance items are already VERIFIED.

Machine-readable release routing must enforce `RELEASE_ONLY` independently of device-write state. Device-test tooling may continue to use legacy real-device verification markers internally, but those markers belong to `POST_RELEASE_DEVICE_TEST` and must not become GitHub Release prerequisites.