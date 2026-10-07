# Arthur ZRAM Finalization Design

## Outcome

Add ZRAM to the final Arthur firmware source and prove its kernel/package closure on a GitHub-hosted Linux runner without producing firmware. Continue validating the already-flashed Arthur for every product capability that remains live-testable. Only after fresh product validation and the four ZRAM closure markers pass may the source be frozen and the one permitted Full Build be enabled.

## Binding constraints

- Target: `qualcommax/ipq60xx`, profile `jdcloud_re-ss-01`.
- Source/feed/toolchain identity stays frozen from the current repair source and `build.env` unless a closure failure proves a source-compatible repair is required.
- Add `CONFIG_PACKAGE_kmod-zram=y` and `CONFIG_PACKAGE_zram-swap=y` to `config/arthur.config`.
- The runtime defaults are `zram_size_mb=192` and `zram_comp_algo=lz4`.
- No flash swapfile is created or configured. Existing native swap-partition behavior is not converted into a swapfile and remains separate from ZRAM.
- The current OpenClash and duplicate-core/version-probe OOM repair changes remain in the source.
- Before the closure and live gates pass: `FIRMWARE_BUILD_COUNT_NEW=0`; no firmware image, Candidate, Release, or sysupgrade.
- Closure uses a GitHub-hosted Linux runner and must not execute `make world` or any image-generation target.

## State machine

1. `REPAIR_SOURCE_WITH_ZRAM`: source contains the package selections and runtime defaults.
2. `ZRAM_CLOSURE_PASS`: the Linux runner emits exactly one PASS for each of `ZRAM_CONFIG_INCLUDED`, `KMOD_ZRAM_COMPILE`, `ZRAM_SWAP_PACKAGE_COMPILE`, and `KERNEL_DEPENDENCY_CLOSURE`.
3. `REAL_DEVICE_FULL_VALIDATION`: the current Arthur passes every live-testable product contract, including OpenClash/AdGuardHome coexistence and ordinary reboot persistence.
4. `FINAL_SOURCE_FROZEN`: record the 40-character `FINAL_SOURCE_SHA` only after states 2 and 3 pass.
5. `BUILD_ALLOWED=true`: emit only when the final source SHA, all closure markers, live validation, and exact-source binding agree.
6. `FULL_BUILD_COUNT_NEW=1`: run the single formal Full Build from the frozen SHA, then execute the standard configuration-preserving sysupgrade once and perform final device verification.

Any source change after step 4 invalidates the frozen SHA and returns the process to step 1. A closure or runtime failure remains a repair state; it never authorizes firmware generation.

## Source/runtime design

The package selections live in `config/arthur.config`. A source-owned UCI-defaults script will set the package's supported ZRAM configuration to 192 MiB with LZ4 and will fail closed without creating a swapfile. The implementation must use the actual `zram-swap` package configuration interface present in the frozen ImmortalWrt source rather than inventing an incompatible UCI schema. Static tests will verify both package symbols, the exact defaults, and the absence of flash swapfile creation.

## Minimal Linux closure

The closure script will stage the frozen ImmortalWrt source, apply the final repair overlay and feeds, run `make defconfig`, prepare only the target/kernel/package prerequisites, then compile the kernel package containing `kmod-zram` and the `zram-swap` package. It will inspect `.config` and the produced package/build outputs before emitting markers. It will not invoke `make world`, `target/linux/install`, image-builder, `target/install`, `sysupgrade`, or release tooling. The workflow will fail closed if any forbidden command or firmware artifact is observed.

Required output includes:

```text
ZRAM_CONFIG_INCLUDED=PASS
KMOD_ZRAM_COMPILE=PASS
ZRAM_SWAP_PACKAGE_COMPILE=PASS
KERNEL_DEPENDENCY_CLOSURE=PASS
TARGET=qualcommax/ipq60xx
PROFILE=jdcloud_re-ss-01
FIRMWARE_BUILD_COUNT_NEW=0
```

## Live validation design

Use the existing Arthur repair/live-validation scripts and evidence format. Continue through OpenClash clean-state, import/save/pointer/first-start, lifecycle controls, ports 9090/7874, Controller, Zashboard, providers, rules, real DNS, real HTTPS proxy, AdGuardHome filtering/query log, coexistence, OFF→ON→OFF→ON→OFF, no-loop/no-conflict checks, SSH/LuCI stability, reboot persistence, LAN/WAN/DHCP/DNS/Wi-Fi/iStore/QuickStart, and system health. Runtime repairs are allowed only as source-equivalent live repair and do not trigger a firmware build. ZRAM may remain unavailable on the current kernel during this phase; that is recorded separately and does not invalidate other live checks.

## Final build and verification

After fresh closure and live evidence are source-bound, write `FINAL_SOURCE_SHA`, set `FINAL_SOURCE_FROZEN=PASS`, and emit `BUILD_ALLOWED=true`. The existing Full Build workflow is then invoked exactly once from that SHA. After the single standard sysupgrade, verify `ZRAM_ACTIVE=PASS`, `ZRAM_SIZE_MB=192`, `ZRAM_COMP_ALGO=lz4`, reboot persistence, `SwapTotal>0`, `NO_OOM=PASS`, `MIHOMO_NOT_KILLED=PASS`, and the complete product suite. The terminal marker is `PRODUCT_GOAL_VERIFIED=PASS`.

