# OpenWrt Automated Firmware Pipeline v4.3

## Success state

The only successful terminal state is `PRODUCTION_RELEASED`.

## Required order

`RESTORE_STATE -> COLLECT_CHANGESET -> REUSE_GATE -> IMPLEMENT -> STATIC_VERIFY -> IMPLEMENTATION_COMPLETE_GATE -> CHANGESET_FREEZE -> PRODUCTION_BUILD -> CANDIDATE_GATE -> AUTO_FLASH_SAFETY_GATE -> AUTO_SYSUPGRADE -> WAIT_DEVICE -> FULL_REAL_DEVICE_VERIFY -> RELEASE_GATE -> GITHUB_RELEASE -> PRODUCTION_RELEASED`

## Batched changeset rule

Development work is collected into one changeset. Do not build/flash after each individual feature. The normal cycle is:

`all implementation -> all static/config/dependency checks -> hard gate -> freeze -> one production candidate -> one flash -> one full real-device verification`.

If real-device verification fails, collect all related failures and repair them as one repair changeset before rebuilding and reflashing.

## Hard gate

`production/current-changeset.json` is authoritative for production eligibility. Candidate-producing workflows are blocked until all required tasks are `PASS`, `implementation_complete=true`, `frozen=true`, and `build_class=FROZEN_PRODUCTION` (or `PRODUCTION`).

The gate is implemented by:

- `scripts/implementation-complete-gate.sh`
- `scripts/production-build-entry-gate.sh`
- `scripts/check-defaults.sh` as the shared early entry point used by the active Arthur candidate lanes.

Development/preflight workflows are not blocked by the production entry gate.

## Current Arthur changeset

The current required tasks are:

- AdGuard Home full manager
- iStoreOS original QuickStart reuse
- Wi-Fi real-connect fix
- plugin zh_cn verification
- Argon compatibility
- Kucat compatibility
- empty Plugins-menu cleanup
- baseline regression protection

The checked-in state intentionally starts `DEVELOPMENT`, incomplete, and unfrozen. A production candidate is therefore denied until the whole batch is actually complete.

## Runtime acceptance

Configuration presence is not runtime proof. Wi-Fi must pass config, runtime, association, DHCP, gateway, DNS, and Internet checks. AdGuard Home must be installed and fully manageable but remain disabled/stopped by default and again at the end of verification.

## Arthur flash path

After all gates pass, keep the validated standard path:

`GitHub Actions -> candidate/hash checks -> AUTO_FLASH_SAFETY_GATE -> PowerShell -> ssh.exe -> remote SHA256 -> /sbin/sysupgrade -> WAIT_DEVICE -> FULL_REAL_DEVICE_VERIFY`.

Raw MTD/U-Boot/bootloader/dd/eMMC/SPI/NAND writes are not part of automatic execution.

## Artifact identity

The production invariant remains:

`BUILD_SHA256 = FLASHED_SHA256 = VERIFIED_SHA256 = RELEASE_SHA256`.

## Migration note

GitHub Actions run `33396664381` is `INTERMEDIATE_NON_PRODUCTION`; it was produced before the v4.3 hard gate and must not be flashed or released.