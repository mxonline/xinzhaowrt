# Arthur Build Routing Policy

## Goal

Avoid paying for a full OpenWrt firmware build when a change can be proven safely through a shorter path, while preserving a fail-closed route for anything uncertain.

The routing authority is `scripts/classify-build-scope.sh`. The CI implementation is `.github/workflows/arthur-fast-preflight.yml`.

`LIVE_PREVIEW` is orthogonal to build scope. It can accelerate pre-Candidate UI/static validation, but it never changes the formal build scope selected for the eventual firmware Candidate.

## Scope levels

### DOC_ONLY

Use for documentation and knowledge-only changes such as `README.md`, `docs/**` and `knowledge/**`.

Required action:

- no firmware compile;
- no Candidate dispatch;
- no Stable mutation.

### FAST_GATE

Use for CI, verifier, test and control-plane-only changes that do not alter firmware content. Typical examples include `.github/**`, `tests/**`, `scripts/verify-project.sh`, `scripts/analyze-error.sh`, verifier scripts, LIVE_PREVIEW control files and build request/control files.

Required action:

- run `Arthur Fast Preflight`;
- run classifier tests;
- run static project verification;
- do not start a firmware build solely to validate the verifier/control-plane change.

`scripts/live-preview.ps1` and `production/live-preview-policy.json` are FAST_GATE control-plane files. Modifying the executor or its safety policy does not by itself change firmware bytes.

If a FAST_GATE change reveals a separate firmware defect, fix that defect in a new scoped change and let the classifier route that change independently.

### IMAGEBUILDER

Use only for explicitly migrated Arthur overlay/image-assembly changes that can be produced from ABI-compatible Known-Good inputs. Current examples include approved `files/etc/uci-defaults/**`, `files/etc/init.d/**`, `files/etc/config/**` and explicit v4 ImageBuilder request/build paths.

Required action:

- Fast Preflight first;
- preserve target/profile/source-lock compatibility;
- use the project ImageBuilder lane;
- apply normal Candidate artifact/hash/flash and real-device gates before release.

### SDK_BUILD

Use for explicitly routed user-space package rebuilds that require the Known-Good-matched SDK but not a kernel/toolchain rebuild. Current examples include explicit v4 SDK paths and QuickStart package-source changes.

Required action:

- Fast Preflight first;
- use the pinned/matched SDK and compatible package inputs;
- assemble the resulting package output into the Candidate through the approved image path;
- retain normal post-build and real-device release gates.

### FULL_BUILD

Use for kernel/ABI-affecting or unknown changes and any path explicitly routed to FULL_BUILD. This includes core firmware config, mandatory plugin list, source lock, patches, build/source preparation logic, package/feed source logic that cannot use the SDK lane, version changes and any unclassified path.

Required action:

1. Fast Preflight must pass first.
2. Run the full Candidate build path selected by the current production controller.
3. Apply the existing Candidate acceptance gates.
4. Keep the result as Candidate until required real-device verification passes.
5. Promote Stable only through the existing Stable promotion path.

## LIVE_PREVIEW before source freeze

For a change that has deployable runtime files inside `production/live-preview-policy.json`, the preferred development loop is:

`edit -> static test -> LIVE_PREVIEW -> authenticated live check -> fix -> LIVE_PREVIEW`

Read `knowledge/LIVE-PREVIEW.md` before using the executor.

Key rule:

`LIVE_PREVIEW_PASS != REAL_DEVICE_VERIFY_PASS`

A preview can deploy only allowlisted LuCI static resources, ACLs and menu/static QuickStart files. It must not touch Wi-Fi, LAN/WAN, system binaries, package databases, kernel/storage or flash state. The current Arthur Wi-Fi result remains `WIFI=VERIFIED_FROZEN`.

After preview acceptance, freeze the source and continue with the build lane selected from the actual firmware-affecting changed paths. Do not classify a firmware content change as FAST_GATE merely because the same files were temporarily previewed on a running router.

## Fail-closed rule

Unknown paths are `FULL_BUILD`.

The classifier must never guess that an unfamiliar path is harmless. When a mixed change contains multiple scopes, the highest-risk scope wins:

`DOC_ONLY < FAST_GATE < IMAGEBUILDER < SDK_BUILD < FULL_BUILD`

LIVE_PREVIEW does not participate in this ordering because it is not a build scope or release gate.

## Active-build isolation

A preflight, documentation, LIVE_PREVIEW-control or CI-control change must not cancel, restart, rebase or mutate an already-running Candidate build. GitHub Actions runs against its original commit SHA, so improvement work should be done on an isolated branch/PR while the active Candidate completes.

A preview against the physical Arthur may be used only when it does not interfere with a currently flashing/rebooting/verification-critical production Candidate. Device-state reconciliation takes priority if a flash may already be in progress.

## Failure loop

For a failure:

1. preserve the first causal error;
2. classify the failure;
3. run the smallest relevant test or gate;
4. change one variable;
5. rerun only the failed gate and affected downstream gates;
6. perform a full OpenWrt rebuild only when firmware output can actually change or when the classifier requires `FULL_BUILD`.

For preview-safe UI defects, use LIVE_PREVIEW for the fast edit/test loop. A preview failure must rollback and must not be converted into release evidence.

Do not use a multi-hour build as a syntax checker, verifier test or UI preview mechanism.

## Relationship to existing workflows

- `Arthur Fast Preflight`: quick routing and static validation; never compiles firmware.
- `scripts/live-preview.ps1`: pre-Candidate real-router preview for allowlisted runtime files; never releases firmware.
- v4 ImageBuilder lane: assembles compatible image changes without a full kernel/toolchain rebuild.
- v4 SDK lane: rebuilds selected user-space packages with the Known-Good-matched SDK.
- Full Candidate lane: fallback for kernel/ABI/unknown changes.
- Stable promotion workflow: release only after required post-flash real-device evidence.

The routing and preview layers do not weaken the 22-plugin gate, checksum verification, source lock, AUTO_FLASH_SAFETY_GATE, post-flash real-device verification or Stable promotion requirements.
