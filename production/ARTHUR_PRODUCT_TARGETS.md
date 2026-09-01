# Arthur Authoritative Product Targets

Status: ACTIVE SPEC
Updated: 2026-09-02
Scope: JDCloud RE-SS-01 / Arthur (`qualcommax/ipq60xx`, profile `jdcloud_re-ss-01`)

This document is the product-target Source of Truth for Arthur firmware. It complements `production/release-policy.md`, `production/production-agent.json`, `production/arthur-known-good-v1.json`, and runtime HANDOFF/state. When a remembered/chat requirement conflicts with this document, the repository specification wins after the change has been reviewed and merged.

## Source-of-Truth split

- Product intent and acceptance target: `production/ARTHUR_PRODUCT_TARGETS.md`
- Release policy and safety rules: `production/release-policy.md`
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
- SSH, DHCP, WAN and DNS must work after production flash
- Storage/overlay, system services and boot log must have no release-blocking error

## Required LuCI target

- Default language: Simplified Chinese (`zh_cn`)
- Default theme: Argon
- Secondary selectable theme: Kucat
- The default LuCI page must render through the user-facing HTTP entry without requiring a non-standard port
- Theme packages, language packages, static assets and dependencies must be complete

## Required package and application target

- The 22-package baseline remains mandatory unless a reviewed product-target change explicitly replaces it
- iStore/iStoreX and QuickStart are product-visible capabilities, not package-presence-only checks
- QuickStart must expose the intended complete home/dashboard experience in real-device verification; package installation alone is insufficient
- AdGuard Home must remain disabled by default unless an approved product-target change says otherwise
- AdGuard Home verification must cover the intended management experience and service state, not only package presence

## Required Wi-Fi target

- The approved default Wi-Fi SSID is part of the firmware-level product baseline and must persist through the intended first-boot/default configuration path
- Wi-Fi credentials must come from an approved secure configuration source; do not duplicate credentials in public documentation, logs, screenshots or GPT long-term memory
- Real-device verification must confirm both required radios/interfaces, expected SSID broadcast, successful client association using the approved credential, DHCP lease acquisition, LAN reachability and WAN/Internet access
- A verification that only checks that 2.4 GHz / 5 GHz radios exist is insufficient

## Candidate composition rule

Product-target changes that belong to one requested firmware release must be combined into one candidate where technically safe. Do not intentionally force one real-device flash per small product setting when the same candidate can carry all approved changes.

The release loop is:

`target diff -> implementation -> build -> artifact/hash checks -> AUTO_FLASH_SAFETY_GATE -> standard sysupgrade -> REAL_DEVICE_VERIFY -> Release Gate`

If any product-target acceptance item fails, Stable/Latest promotion is blocked. Collect evidence, apply the minimum required fix, rebuild a new candidate, run the normal safety gate and repeat real-device verification.

## Real-device acceptance additions

In addition to the existing release-policy checks, the current product acceptance must explicitly verify:

1. LAN management entry and LuCI HTTP port
2. Simplified Chinese default language
3. Argon default render
4. Kucat selectable render
5. 22-package baseline
6. iStore/iStoreX availability where required by the product baseline
7. QuickStart complete intended home/dashboard behavior
8. AdGuard Home intended management UI/behavior and default-disabled state
9. Wi-Fi expected SSID plus real client association, DHCP and LAN/WAN access
10. Persistence after reboot/configuration path as required by the candidate

## Migration status

Some requirements in this document are newer than older real-device verification artifacts. Historical PASS evidence must not be used to claim the newer acceptance items are already VERIFIED.

The next implementation change should update machine-readable config/checks and the real-device verifier so they enforce this document. Until that is done, these newer acceptance items remain REQUIRED but not automatically enforced by all existing scripts.
