# Arthur v0.1.3-style default development loop

## User-approved default

For Arthur and future OpenWrt devices derived from this project, new feature development defaults to the proven v0.1.3-style real-router loop.

The development objective is to make the requested feature appear and work on the currently running real router as quickly as safely possible, then iterate there until the feature is accepted. Do not make a full firmware build, Candidate or sysupgrade the default first step for a new feature.

This rule applies to new LuCI pages, themes, plugin management UIs, package-facing configuration, QuickStart/iStore UI, service-management integration and other changes that can be safely exercised on the running device.

## Mature-reuse-first rule

Every new feature begins with the mandatory `knowledge/REUSE-GATE.md` decision before implementation code is written.

Default preference order:

`official OpenWrt/ImmortalWrt -> official package/application upstream -> maintained same-device/same-target implementation -> maintained community implementation -> thin compatibility layer -> project-specific BUILD only as last resort`

Do not recreate an existing mature feature by progressively adding local LuCI pages, buttons, scripts, RPC calls or partial backend logic. If a mature implementation already provides the requested management experience, reuse that implementation and adapt only what Arthur requires.

`BUILD` is allowed only when the Reuse Gate records concrete evidence that suitable mature solutions are unavailable, incompatible, unsafe, abandoned or materially incomplete. Even then, selectively reuse mature components wherever possible.

The HOT/LIVE development loop is for rapidly integrating and validating the selected solution on the real router; it is not permission to bypass Reuse Gate or hand-build a substitute for a mature upstream solution.

## Default order

`requirement -> mandatory Reuse Gate -> USE/REUSE/FORK/BUILD decision -> implement smallest integration/change -> static sanity check -> backup current router targets -> HOT/LIVE deploy to running Arthur -> clear/reload only required runtime state -> authenticated real-router check -> inspect/fix -> repeat HOT/LIVE deploy`

When automated HOT/LIVE acceptance proves the requested feature according to its objective acceptance contract, the executor must continue automatically without waiting for routine human visual confirmation:

`freeze accepted source -> CHANGE_IMPACT_GATE -> BASELINE_INHERITANCE_GATE -> EXPECTED_DIFF_GATE -> fastest valid Candidate build lane -> artifact/hash checks -> AUTO_FLASH_SAFETY_GATE -> sysupgrade -> reboot -> REAL_DEVICE_VERIFY -> Release -> PRODUCTION_RELEASED`

Human visual confirmation is a pause condition only when the user explicitly asks to inspect before continuation, or when an acceptance criterion is inherently subjective and has no reliable automated equivalent.

## No-stop-after-preview rule

`LIVE_PREVIEW=PASS` is a checkpoint, not a terminal state.

After all automatically verifiable feature-specific preview acceptance items pass, the normal unattended behavior is to freeze the accepted source and continue into the existing production sequence. Do not stop merely because `REAL_DEVICE_VERIFY=NOT_RUN` or `RELEASE_ALLOWED=false`; those values are expected during preview and indicate that the next production stages still need to run.

Do not emit or follow instructions such as `wait for the user to refresh the router`, `wait for visual confirmation`, `do not build yet`, or `keep the PR draft until the user looks at the page` unless the user explicitly requested such a pause in the current task.

For a feature with both safe previewable and unsafe runtime acceptance items, safe preview acceptance may pass while unsafe items are marked `DEFERRED_TO_REAL_DEVICE_VERIFY`. That is not a blocker. Continue automatically to Candidate and formal post-flash verification, where the deferred items must be exercised.

The unattended terminal state for a complete firmware task remains `PRODUCTION_RELEASED`, not `LIVE_PREVIEW=PASS`, not PR creation, not Candidate creation, and not build success.

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
2. automatically use the safest preview subset that still lets the feature be validated;
3. mark only the unsafe acceptance item as deferred to formal post-flash `REAL_DEVICE_VERIFY`;
4. continue all other preview work unattended;
5. after safe preview acceptance, continue automatically into Candidate/flash/formal verification so the deferred item can be tested there;
6. ask the user only when no safe continuation exists.

Example: an upstream init script that can mutate dnsmasq/firewall may be deployed for UI integration while its network-mutating start/stop behavior is deferred to formal `REAL_DEVICE_VERIFY`. The defer marker must advance the workflow, not stop it.

## Frozen baseline inheritance

Features already verified and outside the requested change remain frozen/inherited. Do not edit or repeatedly re-prove them during ordinary feature development unless the new change can affect them.

Current Arthur Wi-Fi is `WIFI=VERIFIED_FROZEN`; ordinary new-feature development must not change or reload it.

## Status semantics

HOT/LIVE development success means the requested feature is working on the currently running development router. It is intentionally fast and may use runtime overlays.

It must not be misreported as a new firmware release:

- `LIVE_PREVIEW=PASS` is allowed for development preview;
- `REAL_DEVICE_VERIFY=NOT_RUN` remains true until a newly built Candidate is flashed;
- `RELEASE_ALLOWED=false` remains true during development preview;
- these preview-state values must trigger continuation, not completion;
- only post-Candidate `REAL_DEVICE_VERIFY=PASS` may unlock release.

## When a full build is required immediately

Skip HOT/LIVE implementation only when the requested change inherently requires firmware bytes that cannot be safely represented on the running system, such as kernel/modules/drivers, boot-critical components, ABI-dependent package binaries that cannot be safely hot-installed, partition/storage layout, bootloader, or another explicitly non-previewable change.

Even then, the mandatory Reuse Gate still runs first, and the shortest safe build lane is selected by change impact. Do not default to a full source rebuild or custom implementation without evidence.

## Unattended execution rule

Once the user has asked to implement/continue a feature, the executor owns one continuous chain until `PRODUCTION_RELEASED` or a genuine blocker with no safe continuation.

A normal recoverable failure must trigger root-cause diagnosis, rollback/repair and retry. A passed HOT/LIVE preview must trigger the next production stage automatically. PR creation, CI success, preview success, build success and flash success are checkpoints only.

Only a genuine blocker with no safe continuation may stop the chain, for example: wrong/unknown device identity, lost control path, unavailable required credentials with no authorized recovery path, device unreachable, rollback evidence missing for a required mutation, or a formal flashing safety gate failure.
