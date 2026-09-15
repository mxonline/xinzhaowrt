# Arthur Unattended Release-Only Design

## Goal

Make Arthur firmware production safely unattended through GitHub Release while keeping router flashing and whole-device acceptance outside the release-critical path.

The successful production terminal remains `PRODUCTION_RELEASED`. A separate `POST_RELEASE_DEVICE_TEST` may run after publication, but it must never trigger a rebuild, block a GitHub Release, or mutate the accepted release artifact.

## Current conflict

The repository already records v0.1.4 as `PRODUCTION_RELEASED` with `POST_RELEASE_DEVICE_TEST=PENDING_INDEPENDENT`, but older durable policy and machine phase descriptions still encode the legacy chain:

`ARTIFACT -> PRE_FLASH -> AUTO_FLASH_SAFETY_GATE -> FLASH -> WAIT_DEVICE -> REAL_DEVICE_VERIFY -> RELEASE_GATE -> RELEASE`

That conflict is unsafe for a new unattended execution because a controller can follow the old path and write to the router even when the intended production task is release-only.

## Design decision

Introduce an explicit machine-readable release mode and make the new default production mode `RELEASE_ONLY`.

`RELEASE_ONLY` production order:

`recover state -> CHANGE_IMPACT_GATE -> BASELINE_INHERITANCE_GATE -> EXPECTED_DIFF_GATE -> static/FAST gates -> fastest valid build lane -> BUILD -> ARTIFACT -> RELEASE_GATE -> RELEASE -> PRODUCTION_RELEASED`

After `PRODUCTION_RELEASED`:

`POST_RELEASE_DEVICE_TEST` is independent and non-blocking.

Legacy flash phases remain recognized for historical state compatibility. They are not deleted from parsers or historical ledgers. A new `RELEASE_ONLY` execution skips them by policy instead of pretending they never existed.

## Machine policy

Create `production/release-mode.json` with these durable fields:

- `schema_version`: `1.0`
- `mode`: `RELEASE_ONLY`
- `unattended_release`: `true`
- `automatic_flash`: `false`
- `post_release_device_test`: `INDEPENDENT`
- `known_good_promotion_requires_post_release_device_test_pass`: `true`
- `fail_closed_on_unknown`: `true`

No controller may infer auto-flash permission from a successful Candidate when this policy says `automatic_flash=false`.

## Compatibility model

The canonical phase registry may continue to recognize `PRE_FLASH`, `AUTO_FLASH_SAFETY_GATE`, `FLASH`, `WAIT_DEVICE` and runtime device-verification phases so old `resume-state` and event-ledger entries remain readable.

New executions must use a route selector derived from `production/release-mode.json`. For `RELEASE_ONLY`, the next production phase after `ARTIFACT` is `RELEASE_GATE`. For historical `FLASH_AND_VERIFY` executions, the existing phase sequence remains available only when an explicit policy/intent authorizes it.

This is a fail-closed migration: an unknown or missing release mode does not authorize router writes.

## Candidate semantics

A production Candidate remains required to prove:

- target/subtarget/profile are Arthur `qualcommax/ipq60xx/jdcloud_re-ss-01`;
- firmware exists and is non-empty;
- SHA256 and manifest evidence are complete;
- required configuration, all 22 mandatory plugins, themes and first-boot defaults pass;
- source/build provenance is complete;
- `CHANGE_IMPACT_GATE`, `BASELINE_INHERITANCE_GATE` and `EXPECTED_DIFF_GATE` pass.

In `RELEASE_ONLY`, a valid Candidate has:

- `release_allowed=true` after Release Gate passes;
- `flash_allowed=false` regardless of Candidate validity.

A route mismatch, missing evidence, unexpected diff, baseline drift, target/profile change, hash mismatch, source-lock incompatibility or UNKNOWN safety state fails closed.

## Known-Good semantics

Publishing a GitHub Release does not automatically replace the rollback baseline.

`production/known-good.json` may advance only after the independently executed `POST_RELEASE_DEVICE_TEST` passes for the exact released firmware/hash. Until then the previous real-device-confirmed known-good remains the rollback authority.

A post-release test failure must mark the new release as not eligible for known-good promotion. It must not rewrite release history or silently trigger a new build. A later repair starts a new execution with a new source/artifact identity.

## Authorization

The current completed v0.1.4 execution must not be resumed as a new build. Starting a new firmware production requires a new execution identity plus explicit durable intent:

- `intent_type=EXECUTE_FIRMWARE`
- `authorization_scope=FIRMWARE_RELEASE`
- `firmware_execution_authorized=true`
- release mode resolves to `RELEASE_ONLY`

Authorization is execution-scoped and does not grant auto-flash permission.

## Unattended behavior

Once a new release execution is authorized, routine safe phases continue without human confirmation. The controller may automatically diagnose and apply minimal reversible repairs when evidence is sufficient.

Human intervention remains mandatory for genuinely unsafe or ambiguous conditions, including unknown device/storage identity when device writes are requested, bootloader/raw partition operations, unverifiable source provenance, no safe rollback, credential provisioning that cannot be recovered safely, or contradictory Source of Truth that changes product intent.

In `RELEASE_ONLY`, device-write-specific blockers cannot be used as a reason to flash; the correct action is to keep `automatic_flash=false` and continue only if the release artifact itself is safely provable.

## Files and responsibilities

- `production/release-mode.json`: machine-readable release/flash separation policy.
- `production/release-policy.md`: human-readable Source of Truth aligned to release-only production.
- `production/GPT-FIRMWARE-EXECUTION-RULES.md`: authorization and resume contract for the new mode.
- `AGENTS.md`: Codex project rule preventing release authorization from becoming flash authorization.
- `ai_orchestrator/arthur.py`: compatibility-aware production route selector and Candidate permissions.
- `scripts/arthur-resume-state.ps1`: release-mode-aware next-phase resolution while retaining legacy phase recognition.
- tests: prove ARTIFACT routes to RELEASE_GATE in `RELEASE_ONLY`, valid Candidates cannot flash, unknown modes fail closed, legacy history remains parseable, and known-good promotion stays post-release-test-gated.

## Safety invariants

1. No automatic `sysupgrade` in `RELEASE_ONLY`.
2. No raw MTD/U-Boot/dd/partition writes are added.
3. No new execution reuses the completed v0.1.4 execution ID.
4. No unexpected diff or missing provenance can be promoted.
5. No post-release device test can block or undo an already published GitHub Release.
6. No untested release can overwrite the previous real-device-confirmed known-good.
7. Existing historical flash evidence remains readable and auditable.
8. `PRODUCTION_RELEASED` remains the production success terminal.

## Verification

Implementation is accepted only when:

- tests first demonstrate failure against the current legacy route;
- implementation makes the release-mode contract tests pass;
- existing resume-state and production-agent CI remain green;
- PR diff shows no firmware payload/config/plugin change unrelated to the release-control migration;
- no workflow is dispatched for a real firmware build until governance changes are merged and the new execution authorization is explicitly established.
