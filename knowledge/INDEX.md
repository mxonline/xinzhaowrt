# XinZhaoWrt Agent Knowledge Router

## Purpose

This directory is the routing layer for the JDCloud Arthur firmware build system. Agents must load only the knowledge required for the current task instead of treating every document in the repository as active context.

## Mandatory startup order

For every non-trivial firmware task:

1. Read `AGENTS.md`.
2. Read `knowledge/PROJECT-STATE.md`.
3. Verify the live Git branch/HEAD and relevant workflow/release state. Live evidence overrides stale documentation.
4. Read this router and load the task-specific knowledge below.
5. If the task changes an upstream/feed/package source, fork, patch strategy or build-system component, execute `knowledge/REUSE-GATE.md` before adopting the change.
6. Make the smallest change from the current verified baseline.
7. Run the appropriate preflight/build/acceptance gates.
8. On failure, classify the failure and consult `knowledge/KNOWN-FAILURES.md` before inventing a new repair.
9. Record newly verified failure patterns or baseline changes back into the knowledge layer.

The Reuse Gate is prospective. It does not move the current source lock, invalidate a Candidate/Stable result, restart an active build, or weaken existing acceptance gates.

## Routing table

### Device, target or image questions
Read:
- `knowledge/DEVICE-PROFILE.md`
- `build.env`
- `config/arthur.config`
- `AGENTS.md`

Do not invent a `jdcloud_re-ss-01-64g` profile. The supported profile is `jdcloud_re-ss-01`.

### Rebuild the current Known-Good baseline
Read:
- `knowledge/KNOWN-GOOD.md`
- `knowledge/SOURCE-LOCK.md`
- `config/arthur-known-good.lock`
- `production/known-good.json`
- `.github/workflows/arthur-update-v3.yml`

Use `rebuild_known_good`. Do not move source refs. Rebuilding the exact locked baseline does not require a new Reuse Gate.

### Update ImmortalWrt, feeds or plugins
Read:
- `knowledge/KNOWN-GOOD.md`
- `knowledge/SOURCE-LOCK.md`
- `knowledge/REUSE-GATE.md`
- `config/arthur-known-good.lock`
- `scripts/prepare-update-lock.sh`
- `.github/workflows/arthur-update-v3.yml`

Before adopting a new source/ref/fork, record `USE / REUSE / FORK / BUILD`. Change one source family at a time unless the user explicitly requests a broader update. Candidate must pass all build acceptance gates before real-device verification.

### Package source / fork / patch selection
Read:
- `knowledge/REUSE-GATE.md`
- `knowledge/KNOWN-FAILURES.md`
- `knowledge/SOURCE-LOCK.md`
- affected package upstream/fork evidence

Search official OpenWrt/ImmortalWrt first, then same-device/same-target recent successful GitHub Actions baselines, then maintained package upstreams/forks. Never pick a source by Star count alone.

### Package missing / feed / dependency failure
Read:
- `knowledge/KNOWN-FAILURES.md`
- `knowledge/REUSE-GATE.md` when the repair changes source/fork/patch strategy
- `config/required-plugins.txt`
- `scripts/add-custom-packages.sh`
- `scripts/check-package-sources.sh`
- `scripts/check-package-existence.sh`

Never fix a package failure by silently removing one of the 22 mandatory LuCI applications.

### Compile / toolchain / memory / CI failure
Read:
- `knowledge/KNOWN-FAILURES.md`
- `knowledge/REUSE-GATE.md` only if the proposed repair changes source/fork/build architecture
- `scripts/build.sh`
- `scripts/extract-build-error.sh`
- relevant workflow file

Classify the first real failure as one of: `SOURCE`, `FEED`, `DEPENDENCY`, `CONFIG`, `PATCH`, `TOOLCHAIN`, `PACKAGE`, `KERNEL`, `IMAGE`, `CI`.

### Firmware promotion / release
Read:
- `knowledge/PROJECT-STATE.md`
- `knowledge/KNOWN-GOOD.md`
- `production/known-good.json`
- `docs/OPENWRT_CI_V3.md`
- `.github/workflows/promote-stable-v3.yml`

A cloud build PASS is only a Candidate PASS. Stable promotion requires the project-defined real-device verification gate.

### Large-upload OOM regression
Read:
- `knowledge/KNOWN-FAILURES.md`
- `knowledge/REUSE-GATE.md` if replacing the current fix with an upstream/fork implementation
- `scripts/apply-upload-oom-fix.sh`
- `scripts/check-upload-oom-fix.sh`
- the compiled-source verification script used by v3

The fix must be verified in the compiled source tree and in the firmware acceptance gate, not only by checking repository text.

## Authority order

When information conflicts, use this order:

1. Real device verification evidence and current GitHub workflow/release state.
2. `production/known-good.json` for the last promoted Stable.
3. `config/arthur-known-good.lock` for pinned source/feed/plugin refs.
4. `VERSION` for the firmware version used by `scripts/build.sh`.
5. Current repository code and workflow definitions.
6. `knowledge/PROJECT-STATE.md` as the human/agent state summary.
7. Older docs and historical workflow reports.

`build.env` contains project identity/defaults, but `scripts/build.sh` intentionally overrides `FIRMWARE_VERSION` from `VERSION`; do not infer a version conflict without reading that behavior.

## Safety boundary

Knowledge routing and Reuse Gate decisions never authorize automatic flashing, bootloader writes, eMMC partition changes, ART/EEPROM/calibration changes or U-Boot modification. Those remain human-reviewed operations.
