# Arthur ZRAM Finalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add and verify Arthur ZRAM source support, complete the non-image Linux closure and real-device gates, then permit exactly one final Full Build only after all source-bound PASS markers exist.

**Architecture:** Keep package selection in the Arthur config, keep runtime defaults in a source-owned first-boot overlay, and isolate the package/kernel closure in a GitHub-hosted Linux workflow that cannot produce firmware. Aggregate closure and live evidence by exact source SHA; only the final gate can set `BUILD_ALLOWED=true`.

**Tech Stack:** ImmortalWrt/OpenWrt Kconfig and make targets, POSIX shell, GitHub Actions, Python 3.10+, UCI/procd, existing Arthur OpenClash/AdGuardHome live-validation scripts.

**Spec:** `docs/superpowers/specs/2026-09-23-arthur-zram-finalization-design.md`

## Global Constraints

- Keep `TARGET=qualcommax/ipq60xx` and `PROFILE=jdcloud_re-ss-01`.
- Keep the current OpenClash and duplicate-core/version-probe OOM repair changes.
- Add `CONFIG_PACKAGE_kmod-zram=y` and `CONFIG_PACKAGE_zram-swap=y`.
- Use `zram_size_mb=192` and `zram_comp_algo=lz4`.
- Do not create or flash a swapfile.
- Before the final gate, keep `FIRMWARE_BUILD_COUNT_NEW=0`.
- Do not execute `make world`, firmware image generation, Candidate, Release, or sysupgrade during closure/live repair.
- Closure runs only on a GitHub-hosted Linux runner with frozen source/feed/toolchain identity.

## Review Focus

- The package's actual configuration interface must receive the 192 MiB/LZ4 values; the test must fail if a guessed schema is used.
- Closure must compile the kernel/package dependency chain without reaching an image target; the workflow must fail if forbidden make targets or firmware artifacts appear.
- `make defconfig` must preserve both ZRAM package symbols and the exact Arthur target/profile.
- Existing native swap-partition behavior must not be silently changed into a swapfile or confused with ZRAM.
- Final source binding must reject stale live/closure evidence after any source change and must never emit `BUILD_ALLOWED=true` with missing markers.

### Task 1: Source package selections and ZRAM defaults

**Files:**
- Modify: `config/arthur.config`
- Create or modify: the source-owned ZRAM UCI-defaults overlay discovered from the frozen package source
- Test: `tests/test-arthur-zram-source.sh`

**Interfaces:**
- Consumes: `build.env`, `config/arthur.config`, and the frozen `zram-swap` package source.
- Produces: source containing both package symbols, exact defaults, no swapfile creation, and a static test contract.

- [ ] Write `tests/test-arthur-zram-source.sh` to assert both package symbols, the exact `192`/`lz4` defaults, target/profile preservation, and no `dd`/raw file-backed swapfile path.
- [ ] Run the new test and observe the expected failure because the package symbols/defaults are not yet present.
- [ ] Inspect the frozen `zram-swap` package Makefile/init/config interface and implement the smallest source-owned default overlay using that interface.
- [ ] Add the two config symbols and source defaults with `apply_patch`, preserving all existing unrelated changes.
- [ ] Run the focused test, `scripts/check-defaults.sh`, `scripts/check-config.sh`, and `git diff --check`.

### Task 2: Linux-only minimal ZRAM closure runner

**Files:**
- Create: `scripts/zram-closure.sh`
- Create: `.github/workflows/arthur-zram-closure.yml`
- Create: `tests/test-zram-closure-script.sh`

**Interfaces:**
- Consumes: the repair source, `build.env`, frozen source/feed/toolchain lock files, and the package overlay from Task 1.
- Produces: a marker file with `ZRAM_CONFIG_INCLUDED`, `KMOD_ZRAM_COMPILE`, `ZRAM_SWAP_PACKAGE_COMPILE`, `KERNEL_DEPENDENCY_CLOSURE`, `TARGET`, `PROFILE`, and `FIRMWARE_BUILD_COUNT_NEW=0`.

- [ ] Write a script contract test that rejects `make world`, firmware/image/sysupgrade targets, missing target/profile checks, and missing required PASS markers.
- [ ] Run it and observe the expected failure because the closure script/workflow does not exist.
- [ ] Implement `scripts/zram-closure.sh` with `set -Eeuo pipefail`, frozen identity checks, `make defconfig`, target/kernel preparation, the exact kernel/package compile targets, `.config` checks, package artifact checks, and forbidden-artifact checks.
- [ ] Implement the GitHub-hosted Linux workflow with checkout, the existing project setup path, the closure script, and artifact upload of only logs/markers/source identity; do not call any full-build or release action.
- [ ] Run the shell contract tests and safe local static checks; the actual closure must run on GitHub Linux.

### Task 3: Source-bound closure gate and live-validation ledger

**Files:**
- Modify: the smallest existing prebuild/live gate entrypoint needed to consume the new closure markers
- Create or modify: `scripts/check-arthur-final-gates.sh`
- Create: `tests/test-arthur-final-gates.sh`
- Create: `.superpowers/sdd/2026-09-23-arthur-zram-finalization/progress.md`

**Interfaces:**
- Consumes: closure markers, current `git rev-parse HEAD`, and the existing real-device evidence bundle.
- Produces: fail-closed `FINAL_SOURCE_FROZEN`, `EXACT_SOURCE_BINDING`, and `BUILD_ALLOWED` markers; retains `FIRMWARE_BUILD_COUNT_NEW=0` until the final gate.

- [ ] Write the gate test with missing markers, stale SHA, changed HEAD, and forbidden build-count values; assert `BUILD_ALLOWED=false` in every case.
- [ ] Run the test and observe the expected failure because the new aggregate gate is absent.
- [ ] Implement exact-once marker parsing and SHA binding; require `REAL_DEVICE_FULL_VALIDATION=PASS`, all four ZRAM markers, `FINAL_SOURCE_FROZEN=PASS`, and `EXACT_SOURCE_BINDING=PASS` before `BUILD_ALLOWED=true`.
- [ ] Run the gate test and existing prebuild/source-parity tests; record all failures as evidence rather than weakening mandatory plugin or runtime gates.

### Task 4: Execute closure and continue current Arthur live validation

**Files:**
- Read/execute: `.github/workflows/arthur-zram-closure.yml`
- Read/execute: existing `post-release-tests/arthur-v0.1.5-20260919/live-repair/` scripts and current device evidence scripts
- Create: a new source-bound evidence bundle outside firmware output

**Interfaces:**
- Consumes: the final repair source and Task 2 closure workflow.
- Produces: fresh closure markers plus complete non-ZRAM real-device validation, with runtime repair allowed but no firmware build.

- [ ] Dispatch the GitHub-hosted closure workflow from the exact repair source and read the marker/log artifacts; if compile fails, repair source and rerun closure without firmware build.
- [ ] Run the current Arthur live checks for OpenClash clean-state, import/save/pointer/first-start, lifecycle, ports, Controller/Zashboard, providers/rules, DNS/HTTPS proxy, AdGuardHome, coexistence, reboot, network/UI/services, and system health.
- [ ] Apply only source-equivalent live repairs for fixable runtime issues and rerun the affected checks; do not attempt ZRAM loading on the current non-ZRAM kernel and do not sysupgrade.
- [ ] Write `REAL_DEVICE_FULL_VALIDATION=PASS` only when every currently live-testable product item passes and bind the evidence to the current source SHA.

### Task 5: Freeze source and authorize the one formal build

**Files:**
- Modify: source-bound final gate/evidence only
- Read/execute: existing formal Full Build workflow after the gate passes

**Interfaces:**
- Consumes: Task 3 gate and Task 4 fresh closure/live evidence.
- Produces: `FINAL_SOURCE_SHA`, `FINAL_SOURCE_FROZEN=PASS`, `EXACT_SOURCE_BINDING=PASS`, `BUILD_ALLOWED=true`, then exactly one Full Build authorization.

- [ ] Run the final gate and verify all required markers and `FIRMWARE_BUILD_COUNT_NEW=0` before authorization.
- [ ] Record the exact 40-character `FINAL_SOURCE_SHA` and rerun the gate against that immutable SHA.
- [ ] Invoke the formal Full Build exactly once from the frozen SHA; do not rerun it for ordinary diagnostics or package/runtime fixes.
- [ ] Verify the build outputs and source identity before the single standard sysupgrade; any mismatch blocks and does not authorize a retry.

### Task 6: Final one-time flash and product verification

**Files:**
- Read/execute: existing standard configuration-preserving sysupgrade and Arthur final verification workflows
- Create: final evidence record with the requested terminal markers

**Interfaces:**
- Consumes: the one verified Full Build artifact and `FINAL_SOURCE_SHA`.
- Produces: ZRAM active/persistence/no-OOM markers, all product PASS markers, and `PRODUCT_GOAL_VERIFIED=PASS`.

- [ ] Execute the standard sysupgrade once only after the exact candidate passes the safety gate.
- [ ] Verify `ZRAM_ACTIVE=PASS`, `ZRAM_SIZE_MB=192`, `ZRAM_COMP_ALGO=lz4`, `ZRAM_REBOOT_PERSISTENCE=PASS`, `SwapTotal>0`, `NO_OOM=PASS`, and `MIHOMO_NOT_KILLED=PASS`.
- [ ] Rerun the complete product validation suite and require `REAL_DEVICE_FULL_VALIDATION=PASS` on the final image.
- [ ] Set `FIRMWARE_BUILD_COUNT_NEW=1` exactly once and report the terminal `PRODUCT_GOAL_VERIFIED=PASS` only after fresh verification evidence.

