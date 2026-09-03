# Arthur LIVE_PREVIEW Routing and Safety

## Purpose

`LIVE_PREVIEW` is the approved pre-Candidate development loop for preview-safe Arthur UI and application-management changes. It restores the fast 0.1.3-style ability to see changes on the real router without rebuilding and flashing a complete firmware image for every UI iteration.

It is not a release stage, not a new production gate, and not formal post-flash evidence.

`LIVE_PREVIEW=PASS` must never be interpreted as `REAL_DEVICE_VERIFY=PASS`.

## Default development loop

For a preview-safe change:

`edit -> static tests -> LIVE_PREVIEW -> authenticated live check -> fix -> LIVE_PREVIEW`

When the intended behavior is confirmed:

`freeze source -> existing production pre-Candidate gates -> Candidate/build -> artifact/hash -> AUTO_FLASH_SAFETY_GATE -> standard sysupgrade -> reboot -> REAL_DEVICE_VERIFY -> Release`

The production order after source freeze remains the existing RELEASE-FIRST order.

## Executor and policy

- Executor: `scripts/live-preview.ps1`
- Machine policy: `production/live-preview-policy.json`
- Static contract: `tests/test-live-preview-contract.sh`
- Build-scope routing: `scripts/classify-build-scope.sh`

The executor may auto-map approved repository overlays or consume an explicit JSON manifest containing `source` and `remote` file pairs.

## Allowed preview classes

The default policy is intentionally narrow:

- LuCI static resources under `/www/luci-static/`
- rpcd ACL files under `/usr/share/rpcd/acl.d/`
- LuCI menu files under `/usr/share/luci/menu.d/`
- approved QuickStart static/package-source paths that resolve only into those runtime prefixes

Unknown or unmapped paths fail closed.

## Forbidden preview classes

LIVE_PREVIEW must not modify or reload:

- Wi-Fi UCI, SSIDs, credentials, radios or wireless runtime
- LAN/WAN, management IP, DHCP or firewall core configuration
- init scripts or system binaries
- kernel, modules, drivers or firmware blobs
- package databases or package binaries
- sysupgrade, MTD, raw eMMC/SPI/NAND or bootloader paths
- Known-Good, Stable or Latest pointers

Current Arthur Wi-Fi state is `WIFI=VERIFIED_FROZEN`. A new Wi-Fi task requires an explicit user request and remains outside LIVE_PREVIEW.

## Backup and rollback

Before the first preview file is installed, the executor creates a timestamped router-side backup under `/root/xinzhaowrt-live-preview/` and records each destination's prior existence and SHA256.

If deployment, cache reload or feature validation fails after mutation starts, the executor restores or removes every changed destination, refreshes rpcd/LuCI state as needed, forces AdGuard Home back to stopped/disabled for AdGuard preview modes, and emits:

`LIVE_PREVIEW=FAIL_ROLLED_BACK`

A lost control path is fail-closed.

## Authentication and device checks

Non-validate preview execution requires:

- BatchMode SSH to `root@192.168.6.1`
- board identity matching JDCloud RE-SS-01 / Arthur
- LAN management address `192.168.6.1`
- Windows route to the Arthur device through a non-wireless adapter

AdGuard or QuickStart preview modes also require `ARTHUR_ROOT_PASSWORD` so LuCI checks are authenticated.

## AdGuard preview acceptance

`-Feature AdGuard` or `-Feature Both` checks:

- authenticated AdGuard LuCI page rendering
- AdGuard core version
- authenticated rpcd ACL access for service status/action and AdGuard config read/write
- temporary start and process health
- local AdGuard Web endpoint on the configured preview port
- log-read path
- final stopped and disabled state

Success emits `ADGUARD_PREVIEW=PASS` only. Formal release still requires `ADGUARD_REAL_DEVICE=PASS` after the new Candidate is flashed.

## QuickStart preview acceptance

`-Feature QuickStart` or `-Feature Both` requires the authenticated QuickStart homepage to contain the official application markers used by formal verification:

- `luci-static/quickstart/index.js`
- the application mount element with `id="app"`
- `QuickStart`
- no login-page marker

Success emits `QUICKSTART_PREVIEW=PASS` only. Formal release still requires `QUICKSTART_REAL_DEVICE=PASS` after Candidate flash.

## Required status semantics

A successful preview must retain these meanings:

- `STATIC_VALIDATION=PASS`
- `LIVE_PREVIEW=PASS`
- `WIFI=VERIFIED_FROZEN`
- `REAL_DEVICE_VERIFY=NOT_RUN`
- `RELEASE_ALLOWED=false`

Never write `REAL_DEVICE_VERIFY=PASS`, `ADGUARD_REAL_DEVICE=PASS`, `QUICKSTART_REAL_DEVICE=PASS` or release eligibility from the preview path.

## Build routing

Changes to the LIVE_PREVIEW executor, policy, tests and related control-plane wiring are `FAST_GATE` changes. They must not trigger a firmware build solely to validate the control-plane implementation.

Changes to firmware content keep their normal build classification. LIVE_PREVIEW can preview a safe subset of those source changes on the running device, but it does not lower the required Candidate build scope once source is frozen for release.
