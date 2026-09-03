# Arthur LIVE_PREVIEW Routing and Safety

## Purpose

`LIVE_PREVIEW` is the approved pre-Candidate development loop for preview-safe Arthur UI and application-management changes. It restores the fast 0.1.3-style ability to see changes on the real router without rebuilding and flashing a complete firmware image for every UI iteration.

It is not a release stage, not a new production gate, and not formal post-flash evidence.

`LIVE_PREVIEW=PASS` must never be interpreted as `REAL_DEVICE_VERIFY=PASS`.

## Default development loop

For a preview-safe change:

`edit -> static tests -> prepare pinned mature source -> LIVE_PREVIEW -> authenticated live check -> fix -> LIVE_PREVIEW`

When the intended behavior is confirmed:

`freeze source -> existing production pre-Candidate gates -> Candidate/build -> artifact/hash -> AUTO_FLASH_SAFETY_GATE -> standard sysupgrade -> reboot -> REAL_DEVICE_VERIFY -> Release`

The production order after source freeze remains the existing RELEASE-FIRST order.

## Executor, source lock and policy

- Executor: `scripts/live-preview.ps1`
- Mature-source preparer: `scripts/prepare-live-preview-sources.ps1`
- Mature-source lock: `production/mature-ui-sources.json`
- Machine policy: `production/live-preview-policy.json`
- Static contract: `tests/test-live-preview-contract.sh`
- Build-scope routing: `scripts/classify-build-scope.sh`

Generated mature-source staging lives under `sources/live-preview-mature/` and is gitignored. The source preparer fetches the pinned upstream commit, copies only the package subtree needed for preview, preserves executable file modes in the generated manifest, and never changes Known-Good source locks.

Current approved preview sources are pinned independently from firmware Known-Good:

- AdGuard Home management: `kenzok8/openwrt-packages`, package `luci-app-adguardhome`
- QuickStart homepage: official `linkease/nas-packages-luci`, package `luci/luci-app-quickstart`

Do not silently move these preview refs. Re-evaluate the source through Reuse Gate before changing them.

## Approved runtime paths

The default policy remains narrow. Normal allowed prefixes include:

- `/www/luci-static/`
- `/usr/share/rpcd/acl.d/`
- `/usr/share/luci/menu.d/`
- `/usr/share/AdGuardHome/`
- AdGuard-specific LuCI model/view paths
- QuickStart-specific LuCI view and helper paths

The user explicitly approved a minimal mature-AdGuard exception for these exact files:

- `/etc/init.d/AdGuardHome`
- `/etc/config/AdGuardHome`
- `/etc/AdGuardHome.yaml`
- the AdGuard-specific Lua controller/i18n files listed in `production/live-preview-policy.json`

The whole `/etc/init.d/` tree remains forbidden. No other init script is allowed through LIVE_PREVIEW.

Unknown or unmapped paths fail closed.

## Forbidden preview classes

LIVE_PREVIEW must not modify or reload:

- Wi-Fi UCI, SSIDs, credentials, radios or wireless runtime
- LAN/WAN or management IP
- DHCP core configuration or dnsmasq ownership
- firewall core configuration or DNS redirect ownership
- any init script other than the exact approved `/etc/init.d/AdGuardHome` preview file
- arbitrary system binaries or package databases
- kernel, modules, drivers or firmware blobs
- sysupgrade, MTD, raw eMMC/SPI/NAND or bootloader paths
- Known-Good, Stable or Latest pointers

Current Arthur Wi-Fi state is `WIFI=VERIFIED_FROZEN`. A new Wi-Fi task requires an explicit user request and remains outside LIVE_PREVIEW.

The mature AdGuard preview config must remain `enabled=0` and `redirect=none` before temporary start. The executor verifies the safe redirect state before starting the preview service. Preview acceptance must finish with AdGuard Home stopped and disabled.

## Backup and rollback

Before the first preview file is installed, the executor creates a timestamped router-side backup under `/root/xinzhaowrt-live-preview/` and records each destination's prior existence and SHA256.

If deployment, cache reload or feature validation fails after mutation starts, the executor stops the preview AdGuard process when applicable, restores or removes every changed destination, refreshes rpcd/LuCI state as required, and emits:

`LIVE_PREVIEW=FAIL_ROLLED_BACK`

A lost control path is fail-closed.

## Authentication and device checks

Non-validate preview execution requires:

- BatchMode SSH to `root@192.168.6.1`
- board identity matching JDCloud RE-SS-01 / Arthur
- LAN management address `192.168.6.1`
- Windows route to Arthur through a non-wireless adapter

AdGuard or QuickStart preview modes also require `ARTHUR_ROOT_PASSWORD` so LuCI checks are authenticated.

## Mature AdGuard preview acceptance

`-Feature AdGuard` or `-Feature Both` must prove the mature manager, not the old simplified JS page. Acceptance includes:

- mature `/etc/init.d/AdGuardHome`, UCI config and YAML are present
- UCI default remains `enabled=0`
- redirect mode remains `none` before temporary start
- AdGuard core version is readable
- authenticated overview, base settings, operations, log and manual/YAML pages render
- status endpoint reports stopped before start
- temporary start succeeds and process/status become running
- local AdGuard Web endpoint responds on the configured preview port
- log-read path works
- service is stopped and disabled at the end
- final UCI enabled state is `0` and status reports stopped

Success emits `ADGUARD_PREVIEW=PASS` only. Formal release still requires `ADGUARD_REAL_DEVICE=PASS` after the new Candidate is flashed.

## Official QuickStart preview acceptance

`-Feature QuickStart` or `-Feature Both` requires the existing QuickStart backend process plus the authenticated official homepage. The page/assets must prove the complete application, not only route/socket/package presence:

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
pwsh ./scripts/live-preview.ps1 -Feature Both -ManifestPath ./sources/live-preview-mature/manifest.json -ValidateOnly
```

Run the actual preview from the approved Windows/ethernet control host after `ARTHUR_ROOT_PASSWORD` is available:

```powershell
pwsh ./scripts/live-preview.ps1 -Feature Both -ManifestPath ./sources/live-preview-mature/manifest.json
```

## Required status semantics

A successful preview must retain these meanings:

- `STATIC_VALIDATION=PASS`
- `ADGUARD_PREVIEW=PASS` when AdGuard was selected
- `QUICKSTART_PREVIEW=PASS` when QuickStart was selected
- `LIVE_PREVIEW=PASS`
- `WIFI=VERIFIED_FROZEN`
- `REAL_DEVICE_VERIFY=NOT_RUN`
- `RELEASE_ALLOWED=false`

Never write `REAL_DEVICE_VERIFY=PASS`, `ADGUARD_REAL_DEVICE=PASS`, `QUICKSTART_REAL_DEVICE=PASS` or release eligibility from the preview path.

## Build routing

Changes to the LIVE_PREVIEW executor, policy, source-lock/preparation scripts, tests and related control-plane wiring are `FAST_GATE` changes. They must not trigger a firmware build solely to validate the control-plane implementation.

Changes to firmware content keep their normal build classification. LIVE_PREVIEW can preview a safe runtime subset, but it does not lower the required Candidate build scope once source is frozen for release.
