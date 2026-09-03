# Arthur LIVE_PREVIEW Routing and Safety

## Purpose

`LIVE_PREVIEW` is the approved pre-Candidate development loop for preview-safe Arthur UI and application-management changes. It restores the fast 0.1.3-style ability to see changes on the real router without rebuilding and flashing a complete firmware image for every UI iteration.

It is not a release stage, not a new production gate, and not formal post-flash evidence.

`LIVE_PREVIEW=PASS` must never be interpreted as `REAL_DEVICE_VERIFY=PASS`.

## Default development loop

For mature AdGuard Home + QuickStart work, use the safe wrapper by default:

`edit -> static tests -> prepare pinned mature source -> safe LIVE_PREVIEW -> authenticated UI check -> fix -> safe LIVE_PREVIEW`

When the intended UI/management experience is confirmed:

`freeze source -> existing production pre-Candidate gates -> Candidate/build -> artifact/hash -> AUTO_FLASH_SAFETY_GATE -> standard sysupgrade -> reboot -> REAL_DEVICE_VERIFY -> Release`

The production order after source freeze remains the existing RELEASE-FIRST order.

## Executors, source lock and policy

- Generic deployment executor: `scripts/live-preview.ps1`
- Mature safe wrapper: `scripts/live-preview-mature-safe.ps1`
- Mature-source preparer: `scripts/prepare-live-preview-sources.ps1`
- Mature-source lock: `production/mature-ui-sources.json`
- Machine policy: `production/live-preview-policy.json`
- Static contract: `tests/test-live-preview-contract.sh`
- Build-scope routing: `scripts/classify-build-scope.sh`

Generated mature-source staging lives under `sources/live-preview-mature/` and is gitignored. The source preparer fetches the pinned upstream commit, copies only the package subtree needed for preview, preserves executable file modes in the generated manifest, and never changes Known-Good source locks.

Current approved preview sources are pinned independently from firmware Known-Good:

- AdGuard Home management: `kenzok8/openwrt-packages@743bb3ad87a7b97fd440d8e334832e25d4f678e0`, package `luci-app-adguardhome`
- QuickStart homepage: official `linkease/nas-packages-luci@7e5083e2ca4cfa4d31f312026f46e5213c5b03f5`, package `luci/luci-app-quickstart`

Do not silently move these preview refs. Re-evaluate the source through Reuse Gate before changing them.

## Safe fallback rule

A safety gate must not convert an already-authorized unattended task into a routine human-confirmation stop when a safer continuation exists.

If a preview action cannot be reliably rolled back, the executor must fail closed on that action and automatically continue with the safest useful subset. The deferred acceptance item moves to formal post-flash `REAL_DEVICE_VERIFY`.

For the mature AdGuard implementation, the upstream init script can modify dnsmasq/DHCP/firewall runtime depending on redirect mode. LIVE_PREVIEW does not have a complete rollback model for those runtime side effects. Therefore the standard mature preview path must not invoke `/etc/init.d/AdGuardHome start`, `stop`, `restart`, `reload`, `enable` or `disable`.

Instead, `scripts/live-preview-mature-safe.ps1`:

1. reuses the generic executor in `Generic` mode to deploy only the approved files;
2. performs authenticated read-only LuCI/UI and state checks;
3. leaves AdGuard Home stopped with UCI `enabled=0` and `redirect=none`;
4. verifies the complete mature manager pages;
5. verifies the complete official QuickStart homepage/assets;
6. automatically emits the deferred runtime acceptance markers;
7. never asks for routine approval merely because the unsafe runtime test was deferred.

The following are explicitly deferred from LIVE_PREVIEW to formal `REAL_DEVICE_VERIFY`:

- AdGuard init start/stop behavior
- DNS ownership/redirect behavior
- dnsmasq mutation/coexistence behavior
- firewall/nftables/iptables mutation behavior
- live AdGuard Web runtime endpoint behavior that requires starting the service

These deferrals do not block UI preview and do not imply release acceptance.

## Approved runtime paths

The deployment policy remains narrow. Normal allowed prefixes include:

- `/www/luci-static/`
- `/usr/share/rpcd/acl.d/`
- `/usr/share/luci/menu.d/`
- `/usr/share/AdGuardHome/`
- AdGuard-specific LuCI model/view paths
- QuickStart-specific LuCI view and helper paths

The user explicitly approved a minimal mature-AdGuard file-deployment exception for:

- `/etc/init.d/AdGuardHome`
- `/etc/config/AdGuardHome`
- `/etc/AdGuardHome.yaml`
- the AdGuard-specific Lua controller/i18n files listed in `production/live-preview-policy.json`

Deploying `/etc/init.d/AdGuardHome` does not authorize executing its mutation commands during LIVE_PREVIEW. The whole `/etc/init.d/` tree remains forbidden except for that exact file destination.

Unknown or unmapped paths fail closed.

## Forbidden preview classes

LIVE_PREVIEW must not modify or reload:

- Wi-Fi UCI, SSIDs, credentials, radios or wireless runtime
- LAN/WAN or management IP
- DHCP core configuration or dnsmasq ownership
- firewall core configuration or DNS redirect ownership
- AdGuard init runtime mutation in the safe mature preview path
- any other init script
- arbitrary system binaries or package databases
- kernel, modules, drivers or firmware blobs
- sysupgrade, MTD, raw eMMC/SPI/NAND or bootloader paths
- Known-Good, Stable or Latest pointers

Current Arthur Wi-Fi state is `WIFI=VERIFIED_FROZEN`. A new Wi-Fi task requires an explicit user request and remains outside LIVE_PREVIEW.

## Backup and rollback

The generic deploy executor creates a timestamped router-side backup under `/root/xinzhaowrt-live-preview/` and records destination existence/SHA256 before deployment.

The mature safe wrapper captures that backup path. If authenticated UI verification fails, it restores or removes every deployed destination from the manifest, restarts rpcd only when an ACL was replaced, clears LuCI caches, and emits:

`LIVE_PREVIEW=FAIL_ROLLED_BACK`

Because the safe wrapper never executes the mature AdGuard init mutation path, rollback does not need to reconstruct dnsmasq/firewall runtime side effects.

## Authentication and device checks

Non-validate preview execution requires:

- BatchMode SSH to `root@192.168.6.1`
- board identity matching JDCloud RE-SS-01 / Arthur
- LAN management address `192.168.6.1`
- Windows route to Arthur through a non-wireless adapter
- `ARTHUR_ROOT_PASSWORD` for authenticated LuCI checks

## Mature AdGuard UI preview acceptance

The safe wrapper must prove the mature manager, not the old simplified JS page. Acceptance includes:

- mature `/etc/init.d/AdGuardHome`, UCI config and YAML are present
- UCI default remains `enabled=0`
- redirect mode remains `none`
- AdGuard core version is readable
- AdGuard process remains stopped
- authenticated overview page renders
- authenticated base/settings page renders
- authenticated operations/tools page renders
- authenticated log page renders
- authenticated manual/YAML page renders
- authenticated status endpoint reports stopped

Success emits:

- `ADGUARD_UI_PREVIEW=PASS`
- `ADGUARD_NETWORK_MUTATION_TEST=DEFERRED_TO_REAL_DEVICE_VERIFY`
- `ADGUARD_WEB_RUNTIME_TEST=DEFERRED_TO_REAL_DEVICE_VERIFY`
- `ADGUARD_PREVIEW=PASS`

This is product-visible preview evidence only. Formal release still requires the deferred runtime checks plus `ADGUARD_REAL_DEVICE=PASS` after the Candidate is flashed.

## Official QuickStart preview acceptance

The safe wrapper requires the existing QuickStart backend process plus the authenticated official homepage. It must prove the complete application, not only route/socket/package presence:

- QuickStart backend process is running
- `luci-static/quickstart/index.js`
- `luci-static/quickstart/style.css`
- `luci-static/quickstart/vendor.js`
- the application mount element with `id="app"`
- no login-page marker
- large official assets return HTTP 200 and exceed minimum size checks

Success emits `QUICKSTART_PREVIEW=PASS` only. Formal release still requires `QUICKSTART_REAL_DEVICE=PASS` after Candidate flash.

## Standard commands

Prepare the pinned mature sources and generated manifest:

```powershell
pwsh ./scripts/prepare-live-preview-sources.ps1 -Feature Both
```

Validate mapping/policy without touching Arthur:

```powershell
pwsh ./scripts/live-preview-mature-safe.ps1 -ManifestPath ./sources/live-preview-mature/manifest.json -ValidateOnly
```

Run the actual safe preview from the approved Windows/ethernet control host:

```powershell
pwsh ./scripts/live-preview-mature-safe.ps1 -ManifestPath ./sources/live-preview-mature/manifest.json
```

Do not use `scripts/live-preview.ps1 -Feature AdGuard` or `-Feature Both` for the mature AdGuard preview. Those legacy feature modes include runtime start/stop checks and are not the approved mature safe path.

## Required status semantics

A successful mature safe preview must retain these meanings:

- `STATIC_VALIDATION=PASS` from the underlying generic deploy validation
- `ADGUARD_UI_PREVIEW=PASS`
- `ADGUARD_NETWORK_MUTATION_TEST=DEFERRED_TO_REAL_DEVICE_VERIFY`
- `ADGUARD_WEB_RUNTIME_TEST=DEFERRED_TO_REAL_DEVICE_VERIFY`
- `ADGUARD_PREVIEW=PASS`
- `QUICKSTART_PREVIEW=PASS`
- `LIVE_PREVIEW=PASS`
- `WIFI=VERIFIED_FROZEN`
- `REAL_DEVICE_VERIFY=NOT_RUN`
- `RELEASE_ALLOWED=false`

Never write `REAL_DEVICE_VERIFY=PASS`, `ADGUARD_REAL_DEVICE=PASS`, `QUICKSTART_REAL_DEVICE=PASS` or release eligibility from the preview path.

## Unattended continuation rule

Routine safety deferral is not a human gate. After static validation succeeds, Codex/runner must automatically use the safe wrapper and continue.

A real `BLOCKED` state is allowed only when continuation cannot be made safe or useful, for example:

- device identity cannot be established
- ethernet control path is unavailable
- SSH/authentication cannot be recovered from already-authorized credentials
- deployment rollback evidence is missing
- router becomes unreachable
- Candidate/flash safety evidence is insufficient later in the production path

For an unsafe optional preview behavior test with a defined formal verification stage, defer it and continue instead of asking the user to approve the unsafe action.

## Build routing

Changes to the LIVE_PREVIEW executors, policy, source-lock/preparation scripts, tests and related control-plane wiring are `FAST_GATE` changes. They must not trigger a firmware build solely to validate the control-plane implementation.

Changes to firmware content keep their normal build classification. LIVE_PREVIEW can preview a safe runtime subset, but it does not lower the required Candidate build scope once source is frozen for release.
