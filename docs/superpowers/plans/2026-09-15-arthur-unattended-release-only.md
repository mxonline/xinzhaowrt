# Arthur Unattended Release-Only Implementation Plan

**Goal:** Make new Arthur production executions automatically build, verify and publish a GitHub Release without automatically flashing the router, while preserving legacy flash history and keeping Known-Good promotion gated by an independent post-release device test.

**Architecture:** `production/release-mode.json` selects the effective route. `RELEASE_ONLY` is the default. The existing Arthur Candidate workflow remains the sole Candidate builder/dispatcher. `Arthur Production State Sync` is the sole cloud state reconciliation/finalization entry: after a verified Candidate it routes directly from `ARTIFACT` to `RELEASE_GATE`, creates or reuses the final GitHub Release, verifies the published firmware hash, and closes the durable execution at `PRODUCTION_RELEASED`. `promote-stable-v3.yml` remains the separate real-device/Known-Good promotion lane and legacy compatibility lane; it is not a prerequisite for the preceding RELEASE_ONLY GitHub Release.

**Spec:** `docs/superpowers/specs/2026-09-15-arthur-unattended-release-only-design.md`

## Global Constraints

- `PRODUCTION_RELEASED` remains the production success terminal.
- New default mode is exactly `RELEASE_ONLY`.
- `automatic_flash=false` in `RELEASE_ONLY`.
- `POST_RELEASE_DEVICE_TEST` remains independent and non-blocking for Release.
- `production/known-good.json` may advance only after the exact released firmware/hash passes the independent post-release device test.
- Preserve historical flash phases for state/event compatibility.
- Unknown/missing release mode fails closed and never authorizes router writes.
- Never add MTD/U-Boot/dd/raw partition automation.
- Do not reuse the completed v0.1.4 execution ID for a new production task.
- Candidate dispatch remains at-most-once by existing build fingerprint/dedup logic.
- State Sync must not commit an intermediate PRE_FLASH checkpoint for RELEASE_ONLY.

## Completed control-plane migration

- [x] Added failing Python/PowerShell `RELEASE_ONLY` route tests before implementation.
- [x] Added `production/release-mode.json` with `RELEASE_ONLY`, unattended release enabled, automatic flash disabled, independent post-release device test, and fail-closed unknown mode.
- [x] Made Python orchestrator and PowerShell Resume Gate route `ARTIFACT -> RELEASE_GATE` in RELEASE_ONLY while retaining explicit `FLASH_AND_VERIFY` compatibility.
- [x] Split default Production Agent routing from the preserved legacy flash implementation.
- [x] Added terminal state helper `scripts/arthur-release-only-state.ps1`.
- [x] Aligned `production/release-policy.md`, `production/GPT-FIRMWARE-EXECUTION-RULES.md`, `AGENTS.md`, `knowledge/LIVE-PREVIEW.md`, and `production/ARTHUR_PRODUCT_TARGETS.md` with RELEASE_ONLY semantics.
- [x] Added cloud State Sync contract test using RED -> GREEN verification.
- [x] Made `arthur-production-state-sync.yml` read `production/release-mode.json` and route verified RELEASE_ONLY artifacts to `RELEASE_GATE`, not PRE_FLASH.
- [x] State Sync reuses the existing Candidate prerelease assets, verifies checksums/22-plugin evidence/source metadata, creates or reuses the final GitHub Release, re-downloads the published sysupgrade asset and verifies SHA256, then calls `Complete-ArthurReleaseOnlyState`.
- [x] State Sync records release evidence plus append-only `PRODUCTION_RELEASED` event evidence and leaves `POST_RELEASE_DEVICE_TEST=PENDING_INDEPENDENT`.
- [x] State Sync never writes `production/known-good.json`; Known-Good promotion remains separate.
- [x] Idempotent terminal replay is a no-op; a partially completed Release can be reused on retry rather than rebuilt.
- [x] Design spec updated to record the approved State Sync ownership model and retry invariants.

## Merge gate

Before integration:

- [x] Relevant control-plane CI passed on implementation head before the final design-doc-only synchronization commit.
- [x] PR diff contains no `config/arthur.config`, required-plugin list, firmware overlay, source lock, target/profile or firmware payload change.
- [x] RELEASE_ONLY cloud State Sync contains no `/sbin/sysupgrade`, `mtd write`, raw storage write or router access path.
- [x] `production/known-good.json` is unchanged by this migration.
- [ ] Re-run the same CI set on the final documentation-synchronized head and require all checks green.
- [ ] Integrate PR #126 only by explicit operator integration choice.

## Fresh unattended execution after merge

After integration, do not resume the closed v0.1.4 execution.

- [ ] Re-read live `main`, latest GitHub Release, current `production/known-good.json`, `production/operator-intent.json`, `production/resume-state.json`, and validated event ledger.
- [ ] Reconcile the version metadata conflict: repository `VERSION`/build metadata must not silently claim 0.1.3 while the published release is v0.1.4. Resolve the next release identity from explicit durable execution data; do not guess a tag in State Sync.
- [ ] Create a fresh execution ID with `intent_type=EXECUTE_FIRMWARE`, `authorization_scope=FIRMWARE_RELEASE`, `firmware_execution_authorized=true`, `release_mode=RELEASE_ONLY`, and no device-write authorization.
- [ ] Generate execution-specific expected diff and preserve protected device/target/storage/LAN/credential/plugin/theme/web-stack domains.
- [ ] Run Resume Gate and all pre-build gates; require release-only traversal and no flash phase selection.
- [ ] Dispatch/reuse the existing Candidate workflow only once by existing fingerprint dedup rules.
- [ ] Continue unattended through Build -> Artifact -> Release Gate -> GitHub Release -> `PRODUCTION_RELEASED`.
- [ ] Record `POST_RELEASE_DEVICE_TEST=PENDING_INDEPENDENT`; do not update Known-Good until the exact released hash later passes independent device testing.
