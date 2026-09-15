# Arthur Unattended Release-Only Design

## Goal

Make Arthur firmware production safely unattended through GitHub Release while keeping router flashing and whole-device acceptance outside the release-critical path.

The successful production terminal remains `PRODUCTION_RELEASED`. A separate `POST_RELEASE_DEVICE_TEST` may run after publication, but it must never trigger a rebuild, block a GitHub Release, or mutate the accepted release artifact.

## Design decision

The machine-readable release mode is `production/release-mode.json`; the default production mode is `RELEASE_ONLY`.

`RELEASE_ONLY` production order:

`recover state -> CHANGE_IMPACT_GATE -> BASELINE_INHERITANCE_GATE -> EXPECTED_DIFF_GATE -> static/FAST gates -> fastest valid build lane -> BUILD -> ARTIFACT -> RELEASE_GATE -> GitHub Release -> PRODUCTION_RELEASED`

After `PRODUCTION_RELEASED`:

`POST_RELEASE_DEVICE_TEST` is independent and non-blocking for Release. It gates only promotion of the exact released hash to the next real-device-confirmed Known-Good baseline.

Legacy flash phases remain recognized for historical state compatibility. They are not deleted from parsers or historical ledgers. A `RELEASE_ONLY` execution skips them by policy instead of pretending they never existed.

## Cloud ownership — approved approach A

The existing cloud topology is reused rather than duplicated:

- `arthur-update-v3-auto.yml` remains the sole Candidate dispatcher and keeps fingerprint dedup/at-most-once semantics.
- `arthur-update-v3.yml` remains the Candidate build/acceptance workflow and publishes the immutable Candidate prerelease/assets.
- `arthur-production-state-sync.yml` is the sole cloud durable-state reconciliation/finalization entry.
- In `RELEASE_ONLY`, State Sync routes a verified Candidate from `ARTIFACT` directly to `RELEASE_GATE`; it must never persist an intermediate PRE_FLASH checkpoint.
- State Sync downloads/reuses the existing Candidate release assets, verifies checksums, 22-plugin evidence and source metadata, creates or reuses the final versioned GitHub Release, re-downloads the published sysupgrade asset and verifies its SHA256, then uses `Complete-ArthurReleaseOnlyState` to close the durable execution.
- State Sync writes release evidence and an append-only `PRODUCTION_RELEASED` event, sets `POST_RELEASE_DEVICE_TEST=PENDING_INDEPENDENT`, and closes firmware execution authorization.
- State Sync never updates `production/known-good.json` in RELEASE_ONLY.
- `promote-stable-v3.yml` remains the separate real-device/Known-Good promotion lane and compatibility path after independent device acceptance. It is not a GitHub Release prerequisite for RELEASE_ONLY.

There is no second Candidate dispatcher and no parallel State Sync writer.

## Machine policy

`production/release-mode.json` carries these durable fields:

- `schema_version`: `1.0`
- `mode`: `RELEASE_ONLY`
- `unattended_release`: `true`
- `automatic_flash`: `false`
- `post_release_device_test`: `INDEPENDENT`
- `known_good_promotion_requires_post_release_device_test_pass`: `true`
- `fail_closed_on_unknown`: `true`

No controller may infer auto-flash permission from a successful Candidate when this policy says `automatic_flash=false`.

## Compatibility model

The canonical phase registry continues to recognize `PRE_FLASH`, `AUTO_FLASH_SAFETY_GATE`, `FLASH`, `WAIT_DEVICE` and runtime device-verification phases so old `resume-state` and event-ledger entries remain readable.

New executions use a route selector derived from `production/release-mode.json`. For `RELEASE_ONLY`, the next production phase after `ARTIFACT` is `RELEASE_GATE`. For compatibility `FLASH_AND_VERIFY`, the legacy phase sequence remains available only when explicit policy/intent authorizes device writes.

This is a fail-closed migration: an unknown or missing release mode does not authorize Release or router writes.

## Candidate and Release Gate semantics

A production Candidate must prove:

- target/subtarget/profile are Arthur `qualcommax/ipq60xx/jdcloud_re-ss-01`;
- firmware exists and is non-empty;
- SHA256 and manifest evidence are complete;
- required configuration, all 22 mandatory plugins, themes and first-boot defaults pass;
- source/build provenance is complete;
- `CHANGE_IMPACT_GATE`, `BASELINE_INHERITANCE_GATE` and `EXPECTED_DIFF_GATE` pass.

In `RELEASE_ONLY`, a valid Candidate has `release_allowed=true` after Release Gate passes and `flash_allowed=false` regardless of Candidate validity.

Before final publication, State Sync additionally binds the GitHub Release to the exact execution run, artifact, source SHA, versioned release tag and firmware SHA256. If a final Release already exists on retry, the existing published firmware must hash-match the Candidate before the terminal state can be reused.

A route mismatch, missing evidence, unexpected diff, baseline drift, target/profile change, hash mismatch, source-lock incompatibility or UNKNOWN safety state fails closed.

## Known-Good semantics

Publishing a GitHub Release does not automatically replace the rollback baseline.

`production/known-good.json` may advance only after the independently executed `POST_RELEASE_DEVICE_TEST` passes for the exact released firmware/hash. Until then the previous real-device-confirmed Known-Good remains rollback authority.

A post-release test failure marks the new release as not eligible for Known-Good promotion. It does not rewrite release history or silently trigger a new build. A repair starts a new execution with a new source/artifact identity.

## Authorization

The completed v0.1.4 execution must not be resumed as a new build. Starting a new firmware production requires a new execution identity plus explicit durable intent:

- `intent_type=EXECUTE_FIRMWARE`
- `authorization_scope=FIRMWARE_RELEASE`
- `firmware_execution_authorized=true`
- release mode resolves to `RELEASE_ONLY`
- no device-write authorization is implied

Authorization is execution-scoped. State Sync verifies the authorization again immediately before the GitHub Release mutation and closes it after `PRODUCTION_RELEASED`.

## Failure and retry behavior

Routine safe phases continue without human confirmation once a new execution is authorized.

- Candidate dispatch is deduplicated by the existing source/build fingerprint gate.
- Build/Artifact failure persists the failing stage and never advances to Release Gate.
- If GitHub Release creation succeeds but durable state persistence fails, a retry reuses the existing Release only after target/hash verification; it does not rebuild or blindly create a second Release.
- Once the exact run is durably `PRODUCTION_RELEASED`, State Sync replay is a no-op and cannot reopen PRE_FLASH.
- In `RELEASE_ONLY`, device-write-specific blockers cannot be used as a reason to flash; device testing is deferred to the independent post-release lane.

Human intervention remains mandatory for genuinely unsafe or ambiguous conditions such as unverifiable source provenance, contradictory product intent, unknown release mode, missing rollback authority for a later device-write task, bootloader/raw partition operations, or unrecoverable credential provisioning.

## Safety invariants

1. No automatic `sysupgrade` in `RELEASE_ONLY`.
2. No raw MTD/U-Boot/dd/partition writes are added.
3. No new execution reuses the completed v0.1.4 execution ID.
4. No unexpected diff or missing provenance can be promoted.
5. No post-release device test can block or undo an already published GitHub Release.
6. No untested release can overwrite the previous real-device-confirmed Known-Good.
7. Existing historical flash evidence remains readable and auditable.
8. `PRODUCTION_RELEASED` remains the production success terminal.
9. RELEASE_ONLY State Sync never commits PRE_FLASH as an intermediate durable checkpoint.
10. No second Candidate dispatcher or second cloud state writer is introduced.

## Verification

Implementation is accepted only when:

- release-mode tests first demonstrate failure against the old route;
- implementation makes Python, PowerShell, Production Agent and cloud State Sync release-only contracts pass;
- existing Resume State, Durable State, Unified State, Runtime, Control Plane, Auto-Recovery, Production Agent and Fast Preflight CI remain green;
- PR diff shows no firmware payload/config/plugin/source-lock/target-profile change unrelated to the release-control migration;
- `production/known-good.json` is not modified by RELEASE_ONLY publication;
- no workflow is dispatched for a real firmware build until the control-plane migration is integrated and a fresh execution authorization is explicitly established.
