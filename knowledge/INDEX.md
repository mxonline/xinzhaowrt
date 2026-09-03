# XinZhaoWrt Agent Knowledge Router

## Purpose

This directory is the routing layer for the JDCloud Arthur firmware build system. Agents must load only the knowledge required for the current task instead of treating every document in the repository as active context.

## Mandatory startup order

For every non-trivial firmware task:

1. Read `AGENTS.md`.
2. Read `knowledge/PROJECT-STATE.md`.
3. Verify the live Git branch/HEAD and relevant workflow/release state. Live evidence overrides stale documentation.
4. Read this router and load the task-specific knowledge below.
5. Read `knowledge/BUILD-ROUTING.md` before deciding whether a full OpenWrt build is required.
6. For **any new feature development**, read `knowledge/V013-DEVELOPMENT-LOOP.md` first and default to the v0.1.3-style real-router development loop unless the change is inherently non-previewable.
7. For preview-safe LuCI/static/ACL/service-integration work, also read `knowledge/LIVE-PREVIEW.md` before deciding to build or flash.
8. If the task changes an upstream/feed/package source, fork, patch strategy or build-system component, execute `knowledge/REUSE-GATE.md` before adopting the change.
9. Make the smallest change from the current verified baseline.
10. During feature development, prefer fast real-router HOT/LIVE deployment and authenticated inspection over a Candidate build. Build only after the feature is accepted on the running router, unless the change inherently requires new firmware bytes.
11. Route frozen source through `Arthur Fast Preflight` and the normal classifier-selected Candidate lane.
12. On failure, classify the failure and consult `knowledge/KNOWN-FAILURES.md` before inventing a new repair.
13. Record newly verified failure patterns or baseline changes back into the knowledge layer.

The Reuse Gate is prospective. It does not move the current source lock, invalidate a Candidate/Stable result, restart an active build, or weaken existing acceptance gates.

The Fast Preflight routing layer is also prospective. It must not cancel or restart an active Candidate. It decides the build lane; unknown paths fail closed to `FULL_BUILD`.

The user-approved v0.1.3 development rule is the default **development** route. `LIVE_PREVIEW`/HOT deployment is not a production release stage. A preview PASS never replaces Candidate build/flash or post-flash `REAL_DEVICE_VERIFY`.

## Routing table

### Any new Arthur/OpenWrt feature
Read first:
- `knowledge/V013-DEVELOPMENT-LOOP.md`
- `knowledge/BUILD-ROUTING.md`
- then the feature-specific documents below

Default development order:

`requirement -> reuse mature implementation when appropriate -> smallest implementation -> static sanity -> backup -> deploy directly to the running router -> inspect authenticated real behavior -> fix -> redeploy`

Do **not** start with a firmware Candidate/build/sysupgrade merely to see whether a new UI, plugin integration, theme, service-management page or configuration feature works. After the feature works on the running router, freeze source and enter the formal production sequence.

If one preview action is unsafe but the rest can continue safely, automatically defer only that action to formal `REAL_DEVICE_VERIFY`; do not stop for routine user approval. Only a genuine blocker with no safe continuation may stop the chain.

### Preview-safe LuCI / AdGuard / QuickStart UI work
Read:
- `knowledge/V013-DEVELOPMENT-LOOP.md`
- `knowledge/LIVE-PREVIEW.md`
- `production/live-preview-policy.json`
- `scripts/live-preview.ps1`
- `tests/test-live-preview-contract.sh`

Use the loop `edit -> static test -> HOT/LIVE deploy -> authenticated live check -> fix -> HOT/LIVE deploy` when the changed runtime files fall inside the preview policy. The current Arthur Wi-Fi result stays `WIFI=VERIFIED_FROZEN`; the preview path must not modify or reload Wi-Fi, LAN/WAN, firewall core state, system binaries, packages or flash/storage state except for an explicitly approved, safely recoverable feature-specific mapping.

After the intended behavior is confirmed, freeze source and return to the existing production release order. `LIVE_PREVIEW=PASS` must still report `REAL_DEVICE_VERIFY=NOT_RUN` and `RELEASE_ALLOWED=false`.

### Decide whether a full build is required
Read:
- `knowledge/BUILD-ROUTING.md`
- `scripts/classify-build-scope.sh`
- `.github/workflows/arthur-fast-preflight.yml`

Run Fast Preflight before a long OpenWrt compile. Documentation-only changes do not compile firmware. CI/verifier/test/control-plane changes use static gates. Firmware-affecting or unknown changes use the classifier-selected Candidate lane **after source freeze**. A safe HOT/LIVE preview may be used before source freeze, but it never lowers the formal build scope of the firmware change.

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
- `knowledge/BUILD-ROUTING.md`
- `knowledge/REUSE-GATE.md` only if the proposed repair changes source/fork/build architecture
- `scripts/build.sh`
- `scripts/extract-build-error.sh`
- relevant workflow file

Classify the first real failure as one of: `SOURCE`, `FEED`, `DEPENDENCY`, `CONFIG`, `PATCH`, `TOOLCHAIN`, `PACKAGE`, `KERNEL`, `IMAGE`, `CI`.

A CI/verifier-only repair must pass Fast Preflight before considering any full rebuild. Do not use a full firmware compile as a syntax checker or verifier test.

### Firmware promotion / release
Read:
- `knowledge/PROJECT-STATE.md`
- `knowledge/KNOWN-GOOD.md`
- `production/known-good.json`
- `docs/OPENWRT_CI_V3.md`
- `.github/workflows/promote-stable-v3.yml`

A cloud build PASS is only a Candidate PASS. Stable promotion requires the project-defined real-device verification gate. HOT/LIVE preview evidence is never accepted as promotion evidence.

### Large-upload OOM regression
Read:
- `knowledge/KNOWN-FAILURES.md`
- `knowledge/BUILD-ROUTING.md`
- `knowledge/REUSE-GATE.md` if replacing the current fix with an upstream/fork implementation
- `scripts/apply-upload-oom-fix.sh`
- `scripts/check-upload-oom-fix.sh`
- the compiled-source verification script used by v3

The fix must be verified in the compiled source tree and in the firmware acceptance gate, not only by checking repository text.

Verifier-only corrections are `FAST_GATE`; changes to the actual OOM patch/application path are `FULL_BUILD`.

## Authority order

When information conflicts, use this order:

1. Explicit current user requirements and real device verification evidence/current GitHub workflow state.
2. `knowledge/V013-DEVELOPMENT-LOOP.md` for the user-approved default feature-development route.
3. `production/known-good.json` for the last promoted Stable.
4. `config/arthur-known-good.lock` for pinned source/feed/plugin refs.
5. `VERSION` for the firmware version used by `scripts/build.sh`.
6. Current repository code and workflow definitions.
7. `knowledge/PROJECT-STATE.md` as the human/agent state summary.
8. Older docs and historical workflow reports.

`build.env` contains project identity/defaults, but `scripts/build.sh` intentionally overrides `FIRMWARE_VERSION` from `VERSION`; do not infer a version conflict without reading that behavior.

## Safety boundary

Knowledge routing, Fast Preflight, HOT/LIVE development and Reuse Gate decisions never authorize bootloader writes, eMMC partition changes, ART/EEPROM/calibration changes, U-Boot modification or raw storage writes. Formal automated standard sysupgrade remains governed only by the existing `AUTO_FLASH_SAFETY_GATE` production path.
