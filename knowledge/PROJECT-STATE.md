# XinZhaoWrt Arthur Project State

## 2026-09-03 execution override — default new-feature development route

For every new Arthur feature that can be safely exercised on the running router, the default development route is now the user-approved v0.1.3-style real-router loop documented in `knowledge/V013-DEVELOPMENT-LOOP.md`.

This is a mandatory routing rule, not an optional optimization:

`requirement -> Reuse Gate when needed -> smallest implementation -> static sanity check -> back up affected runtime targets -> HOT/LIVE deploy to the running Arthur -> authenticated real-router check -> inspect/fix -> repeat HOT/LIVE deploy`

Do not make PR creation, a Candidate build, a full firmware build or sysupgrade the default first step for ordinary new-feature development. The goal is to make the requested feature appear and work on the currently running Arthur as quickly as safely possible, iterate there until accepted, and only then freeze the accepted source for the normal production path.

After the feature is visibly and functionally accepted on Arthur, continue through the existing release sequence:

`freeze accepted source -> CHANGE_IMPACT_GATE -> BASELINE_INHERITANCE_GATE -> EXPECTED_DIFF_GATE -> fastest valid Candidate build lane -> artifact/hash checks -> AUTO_FLASH_SAFETY_GATE -> sysupgrade -> reboot -> REAL_DEVICE_VERIFY -> Release -> PRODUCTION_RELEASED`

If one preview action has side effects that cannot be reliably rolled back, do not stop for routine human approval when a safer continuation exists. Automatically execute the safe preview subset, defer only the unsafe acceptance item to formal `REAL_DEVICE_VERIFY`, and continue unattended. Normal recoverable failures should trigger root-cause diagnosis, rollback/repair and retry.

Current Arthur Wi-Fi remains `WIFI=VERIFIED_FROZEN`; ordinary new-feature development must not change or reload it.

Only inherently non-previewable changes such as kernel/modules/drivers, boot-critical components, unsafe ABI-dependent binaries, partition/storage layout or bootloader work bypass the HOT/LIVE loop and go directly to the shortest safe build lane.

The sections below contain older project-state history and must not override this 2026-09-03 execution rule. Live GitHub/device evidence still overrides stale historical state.

Updated from live GitHub evidence on 2026-08-26.

## Project

- Repository: `mxonline/xinzhaowrt`
- Default branch: `main`
- Device: JDCloud RE-SS-01 / Arthur
- Target: `qualcommax/ipq60xx`
- Profile: `jdcloud_re-ss-01`
- Required LuCI applications: 22
- Current firmware version source: `VERSION`

## Last verified Stable

`production/known-good.json` is authoritative for the promoted baseline.

- Stable tag: `v0.1.0`
- Firmware: `XinZhaoWrt-Arthur-v0.1.0-20260825-sysupgrade.bin`
- Firmware SHA256: `9557593696c7bb07a1f0b259859140b4096ba71c675847aaf5ba5015118a7c2d`
- Upstream ImmortalWrt commit: `27e26e324bee0b0c2a4eb58e2e9121fea5d43194`
- Source-lock SHA256: `1f38f596607346d12097b89f5ab92341172ffbe7a6424c22231b212efbbcc3c1`
- Verification: real-device-confirmed
- Verified at: 2026-08-25

This is the rollback/reference baseline until a newer Candidate passes real-device verification and Stable promotion.

## Current Candidate

Latest functional build baseline observed before the knowledge-layer bootstrap:

- Project commit: `256b18667e5b2423cf235303dec5877957d6fd4a`
- Version: `0.1.1`
- Workflow: `Arthur Known-Good Update v3`
- Workflow run: `32943895389`
- Mode: `rebuild_known_good`
- Result: build-candidate PASS
- Candidate tag: `arthur-update-32943895389`
- Release type: prerelease / Candidate
- Source lock delta: none; the verified lock remained frozen
- Candidate lock SHA256: `1f38f596607346d12097b89f5ab92341172ffbe7a6424c22231b212efbbcc3c1`
- Required plugins: 22/22 PASS
- Large-upload OOM compiled-source/acceptance guard: PASS
- Firmware checksum verification: PASS
- Candidate artifacts include factory, sysupgrade, initramfs, manifest, profiles and verification material

## Current hard gate

`v0.1.1` is not yet Stable.

Next hard gate:

1. Install/test the Candidate on a real JDCloud RE-SS-01 using the project's human-reviewed flashing procedure.
2. Verify boot, LAN/WAN, LuCI/Nginx, Wi-Fi, persistent configuration and required runtime functions.
3. Verify large firmware upload / sysupgrade preparation does not reproduce the prior tmpfs/OOM failure.
4. Record real-device evidence using the project's v3 verification mechanism.
5. Only then run Stable promotion.

Do not call `arthur-update-32943895389` Known-Good Stable until these gates pass.

## Pre-promotion verification gap discovered 2026-08-26

The existing `scripts/real-device-verify-v3.ps1` / `scripts/real-device-verify.ps1` gate verifies SSH, board identity, storage, LAN/WAN, Internet/DNS, 2.4G/5G, LuCI, 22 required plugins, logs, reboot recovery and persistence.

It does **not** currently execute an actual large LuCI firmware upload or otherwise produce explicit real-device evidence that the previous duplicate tmpfs upload/OOM failure has been exercised on hardware.

At the same time, the `arthur-update-32943895389` Candidate release explicitly says the next hard gate includes real-device large firmware upload without OOM. Therefore:

- do not promote `v0.1.1` solely from the current generic real-device script;
- before Stable promotion, add or execute a non-destructive real-device large-upload/OOM verification step;
- that step must exercise the relevant Nginx/cgi-io upload buffering path without invoking `sysupgrade` or writing firmware;
- archive evidence and make the promotion gate require it.

Until this gap is closed, `v0.1.1` promotion state is `BLOCKED_BY_REAL_DEVICE_UPLOAD_GATE` even if the existing generic real-device script passes.

## Build state interpretation

The repository may receive documentation/control commits after the functional Candidate commit. Agents must therefore distinguish:

- live repository HEAD;
- last functional build baseline;
- last real-device-confirmed Stable.

Always inspect live GitHub state at task start. Never roll back a newer valid HEAD merely because this file records an older functional baseline.

## Current workflow architecture

- `arthur-update-v3.yml`: locked Candidate build/update pipeline
- `arthur-update-v3-auto.yml`: dispatches v3 only when `production/v3-request.json` changes
- `known-good-fastlane.yml`: Known-Good fast lane
- `promote-stable-v3.yml`: Stable promotion gate
- `produce.yml`: production controller path triggered by `production/request.json`
- `controller-v3-preflight.yml`: controller preflight

Normal knowledge/documentation commits must not be treated as firmware rebuild requests.

## Release state

- Stable: `v0.1.0`
- Candidate: `arthur-update-32943895389`
- Candidate build: PASS
- Candidate generic real-device verification: NOT YET RECORDED
- Candidate large-upload/OOM real-device verification: MISSING / REQUIRED
- Candidate Stable promotion: BLOCKED

## Next execution

For firmware progression, first close the non-destructive real-device large-upload/OOM verification gap, then run the full real-device gate for the current `v0.1.1` Candidate. Do not run Stable promotion before both evidence sets pass.