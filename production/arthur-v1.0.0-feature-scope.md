# Arthur v1.0.0 | Tailscale LuCI integration and MosDNS removal

Status: OPERATOR-REQUESTED NEXT-RELEASE PRODUCT SCOPE / NOT IMPLEMENTED
Project: XinZhaoWrt Arthur (JDCloud RE-SS-01, qualcommax/ipq60xx, profile jdcloud_re-ss-01)
Recorded: 2026-10-12
Release target: v1.0.0
Scope: next major firmware feature release; NOT a change to the published v0.1.6 artifact, device, or historical Known-Good

## Operator-approved functional delta

1. Bundle a maintained Tailscale daemon/client, plus a **complete, Chinese-localized LuCI management experience**. A CLI binary, a visible menu entry, or a service PID alone is NOT accepted.
2. Remove **MosDNS** from the *v1.0.0 firmware product* and its package/source/configuration/dependency checks. Do not delete historical manifests or alter the frozen rollback lock.
3. Keep OpenClash, AdGuardHome, iStore/iStoreX, full QuickStart and file management, Argon/Kucat, Wi-Fi, LAN/WAN/DHCP/SSH, SmartDNS, and existing management address and security properties unless separately authorized.
4. Keep AdGuardHome default-disabled and preserve its verified coexistence topology and behavior with OpenClash. Tailscale MUST NOT silently take over local DNS, port 53, default routes, NAT/firewall ownership, or LAN management reachability.
5. New feature is **off by default** (Tailscale service disabled/not logged in, no advertised subnet/exit node, no WAN-exposed admin listener). Do not embed credentials, enrollment keys, user identity or Tailnet state in image, source, logs, or default configuration.

## Reuse Gate / upstream candidate

Decision: **USE + REUSE, CONDITIONAL ON SOURCE AND SECURITY VERIFICATION**.
- USE the OpenWrt/ImmortalWrt compatible official `tailscale` package for the daemon/client; pin actual compatible source/revision for the selected upstream and architecture.
- REUSE an appropriately maintained full LuCI package, preferentially official LuCI `luci-app-tailscale-community`, after checking source pin, compatibility with the actual ImmortalWrt/LuCI/ucode tree, translation files, dependencies, integration, feature completeness, and security backports. The pinned baseline LUCI_REF may predate the package or security fixes. Installing a floating latest branch is prohibited.
- Security finding: official OpenWrt advisory GHSA-xwc5-mx58-rh35 (2026-06-11) documents a critical command injection in `luci-app-tailscale-community`. Upstream OpenWrt 25.12.5 release notes report this vulnerability fixed in the maintained release. **Before selecting any pin, verify the actual checked-out code and commit contain the repair; fail closed if uncertain.** No delegable RPC shell interpolation or uncontrolled root execution.
- Do NOT select archived `asvow/luci-app-tailscale`: upstream archived in 2025, replaces ownership of standard `/etc/init.d/tailscale` and `/etc/config/tailscale`, and may break the standard package on uninstall. Do not use `--force-overwrite` as an integration shortcut.
- Alternative if standard feed lacks a compatible full manager: evaluate maintained non-invasive LuCI integrations (e.g. `vad-b/luci-app-tailscale-ng`) with same checks. Its current documented firewall/interface automation is incomplete and must not be assumed to satisfy the full acceptance target.
- Record source URL, 40-hex source commit, license, package dependencies, security decision, effective package file ownership, package-manager choice (OPKG/APK) and exact build provenance before adoption. Never alter the frozen known-good lock in place.

Public references:
- https://github.com/openwrt/luci/pull/8018
- https://github.com/openwrt/luci/security/advisories/GHSA-xwc5-mx58-rh35
- https://openwrt.org/releases/25.12/notes-25.12.5
- https://github.com/asvow/luci-app-tailscale
- https://github.com/vad-b/luci-app-tailscale-ng
- https://openwrt.org/docs/guide-user/services/vpn/tailscale/start

## Effective v1.0.0 package/build delta

- Change `config/arthur.config` and `config/required-plugins.txt`: remove `CONFIG_PACKAGE_luci-app-mosdns=y` / `luci-app-mosdns`; add `CONFIG_PACKAGE_tailscale=y` and selected verified LuCI manager (plus genuine runtime dependencies). The existing 22-LuCI package baseline requires an explicit product-target **replacement**, not silent removal: 22 remains a target if the chosen manager replaces MosDNS on the official required-app list.
- Adjust `scripts/add-custom-packages.sh`, `scripts/prepare-update-lock.sh`, `scripts/check-package-sources.sh`, `scripts/check-package-existence.sh`, `scripts/check-config.sh`, package-selection and image/rootfs validation tests, and any active CI / i18n source fetch steps depending on MosDNS or mandatory package counts. Historical artifacts and verification records are immutable.
- Retire *only* MosDNS-specific source pins and dependencies after reverse-dependency checks. Do not drop `v2ray-geodata`, `geo2txt`, `SmartDNS`, or other shared packages merely by name without package graph evidence; orphaned components should be excluded from the new image if proved unused.
- Validate no MosDNS executable/service/LuCI app or automatic DNS ownership remains in the **effective v1.0.0 image/rootfs**. Do not delete any MosDNS data on a running device as part of planning; for upgrades, safely disable/retire only actual affected services while preserving user backup and recovery.
- Update *new* v1.0.0 package manifest, version identity, matching required-package checks and exact artifact metadata. Historical `production/known-good.json`, `production/arthur-known-good-v1.json`, `config/arthur-known-good.lock` remain frozen until existing authorized promotion policies allow a separate new record.

## Full LuCI acceptance target

End users must be able to manage Tailscale from a working Chinese LuCI interface without mandatory SSH:
- Show installed/daemon/online/login status, Tailnet/device identity, assigned IPv4/IPv6 where available, peers and connectivity.
- Enable/disable/start/stop/restart and configure boot autostart, log in via a secure authorization flow, disconnect/log out.
- Read/modify accepted Tailscale settings; configure subnet advertisements/route acceptance, exit node and DNS policy where supported, with clear choices and state that matches actual backend. Do not expose authorization keys in the UI/logs/CI.
- Changes persist appropriately across service restart and router reboot. Remove/uninstall UI does not delete core files or corrupt other services.
- Default `accept-dns=false` and no automatic advertised routes, exit node, subnet accept, or forwarding. DNS-control or routing features can only be enabled by deliberate action plus conflict checks.
- Firewall/interface rules must be functional and confined; avoid automatic WAN administrative exposure. Support remote encrypted access without breaking local management, clients or LuCI.
- Resource usage must be safe on the Arthur RAM/storage profile; verify no OOM, unexpected restart or interference with OpenClash+AdGuardHome.

Minimum real-device evidence for the exact v1.0.0 release:
`TAILSCALE_LUCI_MANAGER_FULLY_USABLE=PASS`;
`TAILSCALE_REMOTE_PEER_CONNECTIVITY=PASS`;
`TAILSCALE_SUBNET_ROUTING=PASS` when explicitly enabled;
`TAILSCALE_DEFAULT_DISABLED=PASS`;
`TAILSCALE_DNS_FIREWALL_COEXISTENCE=PASS`;
`MOSDNS_ABSENT_FROM_NEW_IMAGE=PASS`;
and revalidate all required `ARTHUR_PRODUCT_GOAL_V1` capabilities and post-release markers for **this exact release hash**. Menu presence, package install and PID are not enough.

## Process authorization and non-regression

- Highest authority: `production/product-goal-contract.json` (`ARTHUR_PRODUCT_GOAL_V1`), current operator intent, GitHub machine runtime/evidence, `production/release-policy.md`.
- At scope capture, `production/operator-intent.json` is `PROCESS_GOVERNANCE`, `GOVERNANCE_RULES_ONLY`, `firmware_execution_authorized=false`; `production/resume-state.json` is `PRODUCTION_RELEASED`, `instruction_allowed=false`, for v0.1.6. This document **does not** grant or silently mutate firmware execution, real-device write, reboot, build, release, or production permissions.
- A new firmware execution requires the project's existing durable operator-intent authorization and machine Resume Gate to become valid for v1.0.0, with a new distinct execution identity. No reuse of v0.1.6 executed identity as if v1.0.0 were built.
- Preserve the published v0.1.6 release, existing real-device rollback and Known-Good; no reflash, reset, sysupgrade, change to active device, or change to production runtime from this scope document.
- Once authorized, reuse the established single-change-objective, official-source-first, source-pinned, impact / semantic verification, live-when-safe, one frozen candidate Build, exact SHA artifact, RELEASE_ONLY, independent post-release real-device test, and existing Candidate-to-Stable controls. Never make whole-device testing an unapproved Build/Release gate.
- `PRODUCTION_RELEASED` is not `PRODUCT_GOAL_VERIFIED`; only exact-release real-device evidence can support the latter.

Next engineering action **after valid new authorization and Resume Gate**: trace the effective current release branch/config+feed dependency graph; verify an upstream secured LuCI source and Tailscale core against pinned ImmortalWrt/LuCI; implement the complete v1.0.0 delta as one controlled candidate without disturbing v0.1.6.
