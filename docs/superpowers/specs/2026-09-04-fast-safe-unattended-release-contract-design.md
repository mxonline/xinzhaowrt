# Fast Safe Unattended Release Contract Design

## Goal

Make every Arthur and future XinZhaoWrt firmware release optimize for one permanent objective: reach `PRODUCTION_RELEASED` as quickly as possible while preserving device identity, artifact integrity, rollback safety, required acceptance, and fail-closed behavior for genuinely ambiguous write operations.

The release system must treat verified evidence as a reusable asset. It must never repeat preview, build, flash, or verification work merely because Codex stopped, a response stream disconnected, a HANDOFF/document changed, a control-plane wrapper changed, or a PR head moved for non-firmware reasons.

## Non-goals

- Do not add a new firmware release stage, Gate, Agent, Controller, Supervisor workflow, or parallel orchestration platform.
- Do not replace the existing `RELEASE-FIRST AUTOMATION MODE`, v3 controller, Production Agent, Feature Handoff, Candidate, flash, or `REAL_DEVICE_VERIFY` stages.
- Do not weaken any required device identity, candidate hash, rollback, mandatory-plugin, configuration, theme, or post-flash acceptance rule.
- Do not optimize by silently dropping requested packages or bypassing safety checks.
- Do not make Codex thread/session/response identity part of durable release identity.

## Permanent policy

All current and future firmware work is governed by one machine-enforced policy:

```text
minimize(time_to_PRODUCTION_RELEASED)
subject to:
  device_identity_verified
  artifact_integrity_verified
  rollback_path_verified
  required_acceptance_preserved
  no_ambiguous_write_action
```

Every proposed action must answer both questions:

1. Does this action remove a currently proven blocker or advance the current release to the next permitted production stage?
2. Is the safety evidence gained by this action not already valid and reusable?

If both answers are not true, the action is not allowed in the active release path.

## Existing production order remains unchanged

The frozen production sequence remains:

```text
recover current release state
→ determine minimum change scope
→ CHANGE_IMPACT_GATE
→ BASELINE_INHERITANCE_GATE
→ EXPECTED_DIFF_GATE
→ fastest reliable build path (ImageBuilder / SDK / Full Build)
→ Build
→ artifact / SHA256 / flash-manifest / config / plugin / theme checks
→ AUTO_FLASH_SAFETY_GATE
→ Windows PowerShell
→ OpenSSH upload
→ remote SHA256
→ verified Arthur sysupgrade
→ WAIT_DEVICE
→ REAL_DEVICE_VERIFY
→ Release Gate
→ GitHub Release
→ PRODUCTION_RELEASED
```

This design changes how existing controllers decide whether prior evidence must be reused, reconciled, repaired, or invalidated. It does not add a production stage.

## Core execution law: REUSE → RECONCILE → REPAIR → CONTINUE

Every recovery or failure handler must use this order:

1. **REUSE** — reuse verified evidence whose inputs are still valid.
2. **RECONCILE** — compare durable state with live GitHub/artifact/device evidence where execution outcome may be uncertain.
3. **REPAIR** — make the smallest change that resolves the first causal error.
4. **CONTINUE** — return immediately to the next permitted release stage.

`RESTART_FROM_EARLIER_STAGE` is forbidden unless explicit invalidation evidence proves that the earlier checkpoint is no longer valid.

## Monotonic release state

A verified checkpoint is monotonic. Once a stage is `VERIFIED`, it remains reusable until an explicit invalidation record names:

- the checkpoint being invalidated;
- the changed input or contradictory evidence;
- the old fingerprint;
- the new fingerprint or live contradiction;
- the minimum downstream stage that must be repeated.

A Codex crash, 404, stream disconnect, context compaction, Windows restart, HANDOFF update, documentation commit, PR description update, controller-only edit, verifier-only edit, or other control-plane-only change is never by itself invalidation evidence for firmware preview/build bytes.

## Durable release identity

The release task is identified by `release_task_id`, not by Codex execution identity.

The durable state extends the existing Feature Handoff/runtime state with:

```json
{
  "schema_version": 2,
  "release_task_id": "arthur:<feature-or-release-id>:<immutable-source-id>",
  "device_id": "jdcloud_re-ss-01",
  "current_stage": "...",
  "last_verified_stage": "...",
  "terminal_state": "ACTIVE",
  "accepted_preview_fingerprint": "<sha256-or-empty>",
  "build_fingerprint": "<sha256-or-empty>",
  "active_run_id": 0,
  "artifact_sha256": "",
  "artifact_identity": "",
  "flash_state": "NOT_STARTED",
  "next_action": "...",
  "invalidations": [],
  "last_progress_at": "<UTC ISO8601>",
  "last_progress_marker": "..."
}
```

Existing Feature Handoff state fields remain supported during migration. Schema v1 state is upgraded in memory and persisted as schema v2 only after validation.

## Fingerprints and evidence reuse

### Accepted preview fingerprint

The preview fingerprint represents the accepted preview bytes and policy-relevant preview inputs, not the current Git HEAD. It is computed from normalized, sorted tuples containing:

- `feature_id`;
- accepted preview source SHA;
- accepted diff SHA256;
- preview manifest SHA256;
- each frozen target path + file SHA256 + mode;
- live-preview policy version relevant to those paths.

It excludes:

- HANDOFF text;
- documentation;
- controller scripts that do not change previewed firmware bytes;
- PR metadata;
- logs and status files.

If the accepted preview fingerprint is unchanged, source discovery, Reuse Gate for the already accepted source, bundle reconstruction, and complete preview deployment are forbidden.

Recovery may only perform a **real-device reconcile** of target file hashes. If hashes match, emit `REUSE_PREVIEW_ACCEPTED`. If only some files are missing or drifted, restore only those files from the frozen accepted bundle and run only the minimum acceptance checks affected by those files.

### Build fingerprint

The build fingerprint represents all firmware-affecting inputs required to reproduce Candidate bytes. It is computed from normalized, sorted values including:

- target/subtarget/profile;
- immutable upstream/source lock;
- feed/package source locks;
- toolchain/ImageBuilder/SDK identity;
- `config/arthur.config` and required-plugin manifest identities;
- `files/` overlay content identity;
- firmware-affecting build scripts/patches;
- package/config/theme inputs that affect the image.

It excludes control-plane-only material such as:

- HANDOFF and ordinary Markdown documentation;
- Feature Handoff runtime state;
- Codex/Supervisor heartbeat state;
- PR metadata;
- verifier/report formatting changes;
- controller-only changes that do not alter image inputs.

Build decisions are deterministic:

```text
same fingerprint + matching run queued/in_progress
  -> WATCH_EXISTING_RUN

same fingerprint + successful immutable Candidate artifact
  -> REUSE_ARTIFACT

same fingerprint + Candidate bytes exist in quarantine but acceptance/control-plane check failed
  -> REVALIDATE_QUARANTINE_CANDIDATE

fingerprint changed for firmware-affecting reason
  -> START_NEW_CANDIDATE using fastest reliable build path
```

No control-plane-only commit may cause a new SDK/Full Build.

## Candidate quarantine and acceptance separation

Immediately after a build produces an Arthur image and local SHA256/manifest, persist the exact Candidate as immutable quarantine evidence before later acceptance logic can discard it.

A later failure is classified as either:

- **FIRMWARE_INVALIDATING** — Candidate bytes/provenance/required config/plugins/theme/target are wrong or incompatible; rebuild may be required.
- **CONTROL_OR_ACCEPTANCE_ONLY** — report parsing, acceptance text, controller path, verifier invocation, workflow glue, or another non-byte defect; Candidate must be reused and revalidated after the control-plane repair.

The failure classifier must record this class in durable state and HANDOFF evidence.

## Invalidation matrix

The machine contract enforces the minimum downstream invalidation scope:

| Change/evidence | Preview invalidated | Build invalidated | Pre-flash safety invalidated | Post-flash verify invalidated |
|---|---:|---:|---:|---:|
| HANDOFF/docs/PR metadata only | no | no | no | no |
| Controller/verifier formatting/path fix only | no | no | only if its exact safety evidence was malformed | only affected verifier evidence |
| Accepted preview source bytes change | yes | yes if frozen into image | yes downstream | yes downstream |
| `files/` overlay/config/package/feed/toolchain changes | only affected preview if applicable | yes | yes | yes |
| Candidate artifact bytes/SHA mismatch | no | yes | yes | yes |
| Device identity/control path changes | no | no | yes | yes |
| Sysupgrade outcome unknown | no | no | do not repeat write; reconcile device | yes |
| Device runtime drift after flash | no | no | no | only affected runtime acceptance |

No broader invalidation is allowed without explicit evidence.

## Impact classification

Extend the existing build-scope classifier rather than adding a Gate. Every changed path receives one of:

- `DOC_ONLY`
- `CONTROL_PLANE_ONLY`
- `PREVIEW_BYTES`
- `FIRMWARE_INPUT`
- `DEVICE_WRITE_POLICY`

The release controller aggregates classifications and invalidates only the required fingerprints/evidence.

A commit containing only `DOC_ONLY` or `CONTROL_PLANE_ONLY` changes must not dispatch a firmware build.

## Executable next_action is not a terminal state

A release executor may stop only at:

- `PRODUCTION_RELEASED`; or
- `SAFETY_BLOCKED` / `BLOCKED` where evidence proves no safe automatic recovery path exists.

If `next_action` is deterministic and machine-executable, returning to the user is an illegal terminal condition. The durable handoff loop must execute it automatically.

Examples that must auto-continue:

- read failed workflow diagnostics;
- identify the first causal error;
- repair a controller path or report parser;
- retry a bounded read-only verifier;
- restore a missing accepted-preview file from frozen accepted bytes;
- watch an already running Candidate;
- revalidate a quarantined artifact after an acceptance-only repair.

Examples that may become `SAFETY_BLOCKED`:

- management route cannot be proven to reach the intended device;
- MAC/device/target/profile identity conflicts;
- authentication cannot be recovered through already approved credentials;
- rollback artifact/path cannot be proven before flash;
- Candidate/local/remote SHA256 conflict cannot be reconciled;
- sysupgrade state is ambiguous and real-device reconciliation cannot establish a safe next state;
- required acceptance fails and no bounded safe repair is known.

## Codex/session independence

Codex is an executor, not the owner of the release.

The existing persistent Feature Handoff + Scheduled Task/runtime is extended so that:

- executor identity and heartbeat are stored separately from release identity;
- a Codex 404, response loss, stream disconnect, context compact failure, process exit, or Windows restart marks the executor `LOST` but leaves the release `ACTIVE`;
- the persistent runtime performs `Resume Gate` from durable state plus live GitHub/artifact/device evidence;
- the next safe executable action is resumed without operator input;
- a running build is watched, not redispatched;
- a successful artifact is reused, not rebuilt;
- `FLASH_STARTED`, `WAIT_DEVICE`, and `REAL_DEVICE_VERIFY` always reconcile the existing write chain and never start a second flash chain.

No new Supervisor workflow is introduced. Existing Feature Handoff/runtime and scheduled recovery infrastructure remain the durable owner of continuation.

## Circuit breaker

The system records a `failure_fingerprint` from:

- current stage;
- first causal error class/message;
- relevant input fingerprint;
- proposed recovery action.

If the same failure fingerprint repeats without `last_progress_marker` changing, the same recovery action may not be executed indefinitely. After the configured bounded retry count, the controller must switch to the next known minimal repair/reconciliation path. If no distinct safe path exists, it becomes `BLOCKED` with evidence.

The circuit breaker prevents repeated `resume`, repeated full preview, repeated build dispatch, and repeated flash attempts from consuming time or quota without progress.

## Anti-expansion contract

The release pipeline structure is protected by tests.

By default a change fails CI if it:

- introduces a new production Gate/stage name;
- inserts a new production workflow owner;
- duplicates existing Feature Handoff/v3 Controller/Production Agent responsibilities;
- causes `DOC_ONLY`/`CONTROL_PLANE_ONLY` changes to trigger firmware builds;
- permits a verified checkpoint to regress without an invalidation record.

Changing the production stage model requires an explicit policy-version change recorded in the repository and explicit user authorization. Normal bug fixes must work within the existing stage model.

## Required machine contract tests

The implementation must prove at least these cases:

1. Pure HANDOFF/docs changes do not invalidate preview/build and do not dispatch SDK/Full Build.
2. Control-plane-only fixes do not invalidate Candidate bytes.
3. Same accepted preview fingerprint + matching device hashes emits `REUSE_PREVIEW_ACCEPTED` and skips full preview deployment.
4. Same accepted preview fingerprint + one drifted file restores only that file and does not redo source discovery.
5. Same build fingerprint + running Candidate emits `WATCH_EXISTING_RUN`.
6. Same build fingerprint + successful Candidate emits `REUSE_ARTIFACT`.
7. Acceptance-only failure after Candidate creation reuses the quarantine artifact after repair.
8. Firmware input change invalidates build and creates exactly one new Candidate.
9. Verified checkpoint cannot regress without an explicit invalidation record.
10. Executable `next_action` cannot terminate the release task.
11. `FLASH_STARTED`/`WAIT_DEVICE` recovery cannot dispatch another build/flash chain.
12. Same failure fingerprint without progress trips the circuit breaker instead of repeating the same action.
13. Controlled executor/session loss automatically resumes from durable state without operator `继续`.
14. Adding an unapproved production Gate/stage fails the anti-expansion contract test.

## Migration

Migration is additive and must not disturb an active firmware release.

- Existing Feature Handoff state remains readable.
- New fields are initially optional for schema v1 recovery and are populated from existing accepted-preview records, active GitHub run/artifact evidence, and current project state.
- Existing production workflow names and stage order stay unchanged.
- Control-plane implementation is developed and tested on an isolated branch.
- Activation for a live release is allowed only at a checkpoint where it can attach without invalidating or redispatching existing preview/build/flash state.
- If a production run or flash is already active at activation time, the new contract must adopt that run ID and reconcile it; it must not replace it.

## Source of Truth updates

After implementation and verification:

- `AGENTS.md` retains the human-readable permanent goal and points to the machine contract.
- `knowledge/PROJECT-STATE.md` records the active contract version only, not transient execution history.
- The machine-readable contract lives in `production/fast-safe-release-policy.json`.
- Existing Feature Handoff/runtime state remains the durable per-release state store.

## Success criteria

The architecture is complete only when all of the following are demonstrated:

- One user release instruction can continue through process/session interruption to `PRODUCTION_RELEASED` without routine operator intervention.
- Repeated Codex 404/stream loss cannot cause duplicate preview, duplicate build, or duplicate flash actions.
- A control-plane-only repair after Candidate creation reuses the same Candidate bytes.
- A valid accepted preview is reused by fingerprint and is not reconstructed or fully redeployed.
- A real firmware-affecting input change still causes the minimum necessary rebuild and all mandatory safety gates remain enforced.
- The existing production stage order is unchanged.
- No new workflow owner or redundant release layer is introduced.
