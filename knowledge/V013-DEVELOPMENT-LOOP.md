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

`durable Feature Handoff -> freeze accepted source -> Git/CI integration -> immutable accepted-source ref -> durable v3 request -> existing v3 Controller -> existing Production Agent -> AUTO_FLASH_SAFETY_GATE -> sysupgrade -> REAL_DEVICE_VERIFY -> Release -> PRODUCTION_RELEASED`

Human visual confirmation is a pause condition only when the user explicitly asks to inspect before continuation, or when an acceptance criterion is inherently subjective and has no reliable automated equivalent.

## Executable Feature Handoff

The permanent bridge between HOT/LIVE development and the existing production chain is implemented by:

- `scripts/feature-handoff.ps1` — durable stage machine, accepted-source integration, durable v3 request and production attachment;
- `scripts/feature-handoff-lib.ps1` — state, accepted-source identity, path safety and idempotency helpers;
- `scripts/install-feature-handoff.ps1` — current-user Windows Scheduled Task recovery;
- `scripts/feature-handoff-status.ps1` — compact durable state inspection;
- `%LOCALAPPDATA%\XinZhaoWrt\FeatureHandoff\handoff.json` — durable runtime checkpoint.

After `LIVE_PREVIEW=PASS`, the preview executor first runs `feature-handoff.ps1 -Mode AcceptPreview` synchronously so accepted HEAD, worktree diff, preview manifest and evidence are durable before the preview process can exit. It then installs/starts the current-user Scheduled Task `XinZhaoWrt-Arthur-Feature-Handoff`. The task owns immediate continuation and also resumes after process exit, user logon or Windows restart.

The handoff does not replace `ci-controller-v3.ps1`, `start-ci-controller-v3.ps1` or `production-agent.ps1`; it connects accepted development state to those mature production components.

The handoff preserves the exact accepted preview bytes by freezing approved manifest entries into the repository `files/` overlay and writing source/hashes to `production/accepted-preview/<feature-id>.json`. A Candidate must not be dispatched if accepted preview identity cannot be proven in integrated source.

## Durable production dispatch rule

Feature Handoff must not directly call `gh workflow run arthur-update-v3.yml` for an accepted feature.

After the accepted source PR passes CI and is merged, Handoff reads the PR's actual GitHub `mergeCommit.oid`, verifies the frozen file blobs at that exact commit, and creates one immutable lightweight tag for that commit. It then atomically updates the existing `production/v3-request.json` control-plane record with a deterministic `request_id`, `source_ref`, `source_sha`, accepted diff/manifest identity and the selected existing v3 mode.

`.github/workflows/arthur-update-v3-auto.yml` is the sole normal dispatcher for that durable request. For Handoff requests it resolves the immutable `source_ref`, verifies `source_sha`, checks existing `arthur-update-v3.yml` runs for the same tag before dispatching, and becomes a no-op with `V3_AUTO_TRIGGER_ALREADY_DISPATCHED=YES` if that production request already has a run. This makes auto-trigger reruns safe after network/API ambiguity.

Handoff discovers the concrete v3 Run ID by immutable `headBranch=source_ref` plus `headSha=source_sha`; it never guesses by "latest main". After discovery it returns the worktree to a clean, fast-forwarded `main` and invokes the existing `start-ci-controller-v3.ps1 -Mode Resume -RunId <id>` path. The persistent Feature Handoff task restarts the same Run-ID Resume path after a Windows/process restart if necessary. The v3 Controller remains responsible for Candidate verification/repair and then hands the same run to the existing Production Agent through `PRODUCTION_RELEASED`.

Any earlier design/implementation-plan example that directly workflow-dispatches v3 from Feature Handoff is superseded by this durable-request rule.

## No-stop-after-preview rule

`LIVE_PREVIEW=PASS` is a checkpoint, not a terminal state.

After all automatically verifiable feature-specific preview acceptance items pass, the normal unattended behavior is to create/update durable Feature Handoff state, freeze the accepted source and continue into the existing production sequence. Do not stop merely because `REAL_DEVICE_VERIFY=NOT_RUN` or `RELEASE_ALLOWED=false`; those values are expected during preview and indicate that the next production stages still need to run.

Do not emit or follow instructions such as `wait for the user to refresh the router`, `wait for visual confirmation`, `do not build yet`, or `keep the PR draft until the user looks at the page` unless the user explicitly requested such a pause in the current task.

For a feature with both safe previewable and unsafe runtime acceptance items, safe preview acceptance may pass while unsafe items are marked `DEFERRED_TO_REAL_DEVICE_VERIFY`. That is not a blocker. Continue automatically to Candidate and formal post-flash verification, where the deferred items must be exercised.

The unattended terminal state for a complete firmware task remains `PRODUCTION_RELEASED`, not `LIVE_PREVIEW=PASS`, not handoff creation, not PR creation, not Candidate creation, and not build success.

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
5. after safe preview acceptance, continue automatically through Feature Handoff into Candidate/flash/formal verification so the deferred item can be tested there;
6. ask the user only when no safe continuation exists.

Example: an upstream init script that can mutate dnsmasq/firewall may be deployed for UI integration while its network-mutating start/stop behavior is deferred to formal `REAL_DEVICE_VERIFY`. The defer marker must advance the workflow, not stop it.

## Frozen baseline inheritance

Features already verified and outside the requested change remain frozen/inherited. Do not edit or repeatedly re-prove them during ordinary feature development unless the new change can affect them.

Current Arthur Wi-Fi is `WIFI=VERIFIED_FROZEN`; ordinary new-feature development must not change or reload it.

## Status semantics

HOT/LIVE development success means the requested feature is working on the currently running development router. It is intentionally fast and may use runtime overlays.

It must not be misreported as a new firmware release:

- `LIVE_PREVIEW=PASS` is allowed for development preview;
- `FEATURE_HANDOFF_STAGE=*` records the durable continuation state after acceptance;
- `REAL_DEVICE_VERIFY=NOT_RUN` remains true until a newly built Candidate is flashed;
- `RELEASE_ALLOWED=false` remains true during development preview;
- these preview-state values must trigger continuation, not completion;
- only post-Candidate `REAL_DEVICE_VERIFY=PASS` may unlock release.

## When a full build is required immediately

Skip HOT/LIVE implementation only when the requested change inherently requires firmware bytes that cannot be safely represented on the running system, such as kernel/modules/drivers, boot-critical components, ABI-dependent package binaries that cannot be safely hot-installed, partition/storage layout, bootloader, or another explicitly non-previewable change.

Even then, the mandatory Reuse Gate still runs first, and the shortest safe build lane is selected by change impact. Do not default to a full source rebuild or custom implementation without evidence.

## Unattended execution rule

Once the user has asked to implement/continue a feature, the executor owns one continuous chain until `PRODUCTION_RELEASED` or a genuine blocker with no safe continuation.

A normal recoverable failure must trigger root-cause diagnosis, rollback/repair and retry. A passed HOT/LIVE preview must trigger durable Feature Handoff automatically. PR creation, CI success, preview success, handoff creation, durable request creation, build success and flash success are checkpoints only.

Only a genuine blocker with no safe continuation may stop the chain, for example: wrong/unknown device identity, lost control path, unavailable required credentials with no authorized recovery path, device unreachable with no recovery path, accepted-source identity cannot be proven, rollback evidence missing for a required mutation, immutable source-ref conflict, or a formal flashing safety gate failure.
