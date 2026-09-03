# Arthur v0.1.3-style default development loop

## User-approved default

For Arthur and future OpenWrt devices derived from this project, new feature development defaults to the proven v0.1.3-style real-router loop.

The development objective is to make the requested feature appear and work on the currently running real router as quickly as safely possible, then iterate there until the feature is accepted. Do not make a full firmware build, Candidate or sysupgrade the default first step for a new feature.

This rule applies to new LuCI pages, themes, plugin management UIs, package-facing configuration, QuickStart/iStore UI, service-management integration and other changes that can be safely exercised on the running device.

## Default order

`requirement -> Reuse Gate when needed -> implement smallest change -> static sanity check -> backup current router targets -> HOT/LIVE deploy to running Arthur -> clear/reload only required runtime state -> authenticated real-router check -> inspect/fix -> repeat HOT/LIVE deploy`

Only after the requested feature is visibly and functionally correct on Arthur:

`freeze accepted source -> CHANGE_IMPACT_GATE -> BASELINE_INHERITANCE_GATE -> EXPECTED_DIFF_GATE -> fastest valid Candidate build lane -> artifact/hash checks -> AUTO_FLASH_SAFETY_GATE -> sysupgrade -> reboot -> REAL_DEVICE_VERIFY -> Release -> PRODUCTION_RELEASED`

## Fast real-router implementation principle

The running Arthur is the primary development preview target. Prefer direct SSH/SCP/UCI/runtime deployment when the changed component can be safely backed up and restored.

Examples include:

- LuCI JavaScript/Lua/ucode/templates/static assets;
- LuCI menu and rpcd ACL files;
- theme resources;
- approved application configuration files;
- approved service-specific runtime files;
- QuickStart/iStore homepage assets and controllers;
- other explicitly mapped files whose effect can be reliably rolled back.

After deployment, clear only the caches or restart/reload only the service required for the feature. Do not reboot or flash merely to see a UI/configuration change.

## Safety fallback must continue automatically

A safety check must not turn a normal development iteration into a human approval stop when a safer continuation exists.

If one requested preview action has side effects that cannot be reliably rolled back:

1. do not execute that unsafe action;
2. automatically use the safest preview subset that still lets the user see/test the feature;
3. mark only the unsafe acceptance item as deferred to formal post-flash `REAL_DEVICE_VERIFY`;
4. continue all other preview work unattended;
5. ask the user only when no safe continuation exists.

Examples: an upstream init script that can mutate dnsmasq/firewall may be deployed for UI integration but its network-mutating start/stop behavior can be deferred to formal `REAL_DEVICE_VERIFY`.

## Frozen baseline inheritance

Features already verified and outside the requested change remain frozen/inherited. Do not edit or repeatedly re-prove them during ordinary feature development unless the new change can affect them.

Current Arthur Wi-Fi is `WIFI=VERIFIED_FROZEN`; ordinary new-feature development must not change or reload it.

## Status semantics

HOT/LIVE development success means the requested feature is working on the currently running development router. It is intentionally fast and may use runtime overlays.

It must not be misreported as a new firmware release:

- `LIVE_PREVIEW=PASS` is allowed for development preview;
- `REAL_DEVICE_VERIFY=NOT_RUN` remains true until a newly built Candidate is flashed;
- `RELEASE_ALLOWED=false` remains true during development preview;
- only post-Candidate `REAL_DEVICE_VERIFY=PASS` may unlock release.

## When a full build is required immediately

Skip HOT/LIVE implementation only when the requested change inherently requires firmware bytes that cannot be safely represented on the running system, such as kernel/modules/drivers, boot-critical components, ABI-dependent package binaries that cannot be safely hot-installed, partition/storage layout, bootloader, or another explicitly non-previewable change.

Even then, use the shortest safe build lane selected by change impact; do not default to a full source rebuild without evidence.

## Unattended execution rule

Once the user has asked to implement/continue a feature, the executor should keep iterating through the safe v0.1.3-style loop without asking for routine confirmation. A normal recoverable failure should trigger root-cause diagnosis, rollback/repair and retry.

Only a genuine blocker with no safe continuation may stop the chain, for example: wrong/unknown device identity, lost control path, unavailable required credentials with no authorized recovery path, device unreachable, rollback evidence missing for a required mutation, or a formal flashing safety gate failure.
