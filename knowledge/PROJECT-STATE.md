# XinZhaoWrt Arthur Project State

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
- Candidate real-device verification: NOT YET RECORDED
- Candidate Stable promotion: NOT YET PERFORMED

## Next execution

For firmware progression, continue with real-device verification of the current `v0.1.1` Candidate. For build-system work, load `knowledge/INDEX.md` and route the requested task from this state.