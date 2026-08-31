# OpenWrt Automated Firmware Pipeline v4.3 Design

## Goal

Make `PRODUCTION_RELEASED` the only success state while preventing partial feature work from producing a flashable Arthur candidate.

## Core model

The pipeline is release-first and batched:

`RESTORE_STATE -> COLLECT_CHANGESET -> REUSE_GATE -> IMPLEMENT -> STATIC_VERIFY -> IMPLEMENTATION_COMPLETE_GATE -> CHANGESET_FREEZE -> PRODUCTION_BUILD -> CANDIDATE_GATE -> AUTO_FLASH_SAFETY_GATE -> AUTO_SYSUPGRADE -> WAIT_DEVICE -> FULL_REAL_DEVICE_VERIFY -> RELEASE_GATE -> GITHUB_RELEASE -> PRODUCTION_RELEASED`

A failed real-device verification enters one batch-repair cycle: collect all failures, repair them together, freeze a new repair changeset, rebuild once, reflash once, and fully reverify.

## Hard-gate invariant

A production candidate is eligible only when all of the following are true in the checked-out source revision:

- every required task in `production/current-changeset.json` is `PASS`;
- `implementation_complete` is `true`;
- `frozen` is `true`;
- workflow input `changeset_id` matches the state file;
- workflow input `source_sha` matches the checked-out `HEAD`.

If any condition fails, the workflow must terminate before SDK, ImageBuilder, Full Build, candidate artifact generation, flashing, or release.

## Current Arthur required tasks

- `adguardhome_full_manager`
- `istoreos_original_quickstart`
- `wifi_real_connect_fix`
- `plugin_i18n`
- `argon_compatibility`
- `kucat_compatibility`
- `plugins_menu_cleanup`
- `baseline_regression`

The initial state is intentionally incomplete and unfrozen. Development commits therefore cannot produce a production candidate.

## Candidate workflow contract

Every Arthur workflow that can produce a flashable sysupgrade candidate must accept:

- `source_sha`
- `changeset_id`
- `confirm=BUILD_FROZEN_CHANGESET`

It must checkout `source_sha`, run `scripts/implementation-complete-gate.sh`, and only then enter any firmware build step.

Development/preflight workflows may run without this production gate only when they cannot produce a flashable candidate.

## Runtime and release invariants

- Arthur target/profile remains `qualcommax/ipq60xx` / `jdcloud_re-ss-01`.
- LAN remains `192.168.6.1`, public LuCI HTTP remains port `80`.
- Argon remains the default theme; Kucat remains the second theme.
- Wi-Fi must pass config, runtime, and real-client association gates; config presence alone is insufficient.
- AdGuard Home is installed with the full manager but is disabled and stopped by default and must be disabled again after controlled real-device verification.
- The final artifact identity must satisfy `BUILD_SHA256 = FLASHED_SHA256 = VERIFIED_SHA256 = RELEASE_SHA256`.
- Standard verified Arthur flashing remains PowerShell -> `ssh.exe` -> remote SHA256 -> `/sbin/sysupgrade`; raw MTD/U-Boot/bootloader/dd/eMMC/SPI/NAND writes are outside automatic execution.

## Failure behavior

A failed implementation gate returns non-zero and prints the specific missing/inconsistent condition. A candidate workflow must not silently downgrade this failure or continue with `|| true`.

## Migration rule

Existing intermediate artifacts produced before v4.3 remain non-production. In particular, workflow run `33396664381` is not eligible for flash or release because it predates the implementation-complete/freeze hard gate.