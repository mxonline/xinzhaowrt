# Arthur Unified Execution State, Gate Evidence & Staleness Design

Status: USER-APPROVED DESIGN / AWAITING SPEC REVIEW
Date: 2026-09-08
Scope: JDCloud RE-SS-01 / Arthur production control plane

## 1. Problem

Arthur already has durable pieces that must be preserved:

- `production/resume-state.json` is the canonical current execution snapshot used for progress/resume/next-action decisions.
- `production/firmware-events.jsonl` is the append-only execution ledger.
- Feature Handoff persists accepted HOT/LIVE work across process or Windows restarts.
- `ci-controller-v3.ps1` owns Candidate build/repair behavior.
- `production-agent.ps1` owns artifact retrieval, flash safety, at-most-once standard sysupgrade, real-device verification and release.
- `PRODUCTION_RELEASED` remains the only successful terminal state.

The current gap is not lack of persistence. The gap is lack of one common contract tying together:

1. what the product requires;
2. what the current execution state claims;
3. which concrete evidence proves each claim;
4. whether that evidence is still valid for the current source, artifact and device identity.

Today, several verified fields in `resume-state.json` are emitted as fixed status strings such as `VERIFIED_FROZEN` or `LIVE_BROWSER_VERIFIED`. They are not all represented as first-class Gate records with explicit evidence references and subject identity. This makes stale PASS reuse possible and makes it harder to distinguish a valid inherited verification from an old verification that must be rerun.

A second problem is identity fragmentation. GitHub `run_id`, Feature Handoff identity, current repository HEAD, accepted preview source SHA, Candidate SHA256 and real-device build identity are all meaningful, but no single execution identifier spans the full user task from accepted implementation to production release.

## 2. Goal

Upgrade the existing Arthur Control Plane into the only state arbiter and add a unified execution contract that binds:

`Source of Truth -> Execution -> Gates -> Evidence -> PASS/FAIL/STALE/BLOCKED -> next_action`

The implementation must preserve the existing RELEASE-FIRST architecture and production executors. It must not introduce a second orchestrator.

After this change, any progress/resume/continue request must be answerable from the reconciled machine state and evidence instead of historical chat or a best-effort interpretation of several independent files.

## 3. Non-goals

- Do not create a parallel `.runtime/current.json` controller.
- Do not replace Feature Handoff.
- Do not replace `ci-controller-v3.ps1`.
- Do not replace `production-agent.ps1`.
- Do not change the verified Arthur sysupgrade command or flash safety semantics.
- Do not add raw MTD, U-Boot, `dd`, partition-write or bootloader automation.
- Do not automatically rerun frozen Wi-Fi verification when change impact proves Wi-Fi is unaffected.
- Do not make normal state/ledger commits trigger firmware builds.
- Do not migrate the WeChat content-production system in this change.

## 4. Architectural rule

The Arthur Control Plane becomes the only component allowed to arbitrate a Gate status.

Executors may produce observations and evidence, but they do not independently establish global truth.

Examples:

- GitHub Actions may report a successful build and artifact metadata.
- Feature Handoff may report accepted preview evidence.
- Production Agent may report successful SHA checks or a real-device verifier result.
- Codex may produce a repair commit and tests.

The Control Plane consumes those inputs and decides whether the corresponding Gate is `PASS`, `FAIL`, `BLOCKED`, `STALE`, `PENDING`, `RUNNING` or `SKIPPED`.

The terminal rule remains:

`NO EVIDENCE -> NO PASS`

`NO PASS -> NO RELEASE`

`PRODUCTION_RELEASED` is the only successful terminal state.

## 5. Source of Truth responsibilities

The existing project files continue to define requirements rather than transient status:

- `production/release-policy.md` defines production flow, Candidate/Stable rules and flash safety.
- `production/ARTHUR_PRODUCT_TARGETS.md` defines product acceptance targets.
- `knowledge/V013-DEVELOPMENT-LOOP.md` defines Reuse Gate, HOT/LIVE development and durable handoff behavior.
- `AGENTS.md` defines execution policy and operator-scope constraints.
- `production/known-good.json`, `production/arthur-known-good-v1.json` and `production/real-device-baseline.json` define frozen rollback/baseline identity.

These documents do not directly say that the current run passed a Gate. They define what evidence a current execution must satisfy.

## 6. Execution identity

Add a stable string `execution_id` that spans one end-to-end Arthur task.

Format:

`arthur-<task-slug>-<accepted-source-prefix>-<yyyymmdd>`

Example:

`arthur-adh-cn-e27bafa-20260908`

`execution_id` is not a replacement for GitHub Actions `run_id`.

The existing numeric GitHub `run_id` remains unchanged because current controller and Production Agent code uses it as a numeric workflow identity.

The execution record may contain:

```json
{
  "execution_id": "arthur-adh-cn-e27bafa-20260908",
  "accepted_source_sha": "e27bafac2d4a3ecf0f7a0e4cf2f7b34cf77571c9",
  "github_run_id": 34056525562,
  "artifact_id": 9998837025,
  "candidate_sha256": "...",
  "device_build_id": "33462873812"
}
```

The tuple `execution_id + accepted_source_sha` is the user-task identity. `github_run_id + artifact_id + candidate_sha256` is the concrete Candidate identity.

A replacement Candidate created after a valid repair remains in the same `execution_id` but receives a new GitHub `run_id`, artifact identity and Candidate SHA256. The event ledger records the replacement relationship.

## 7. Canonical current snapshot

Keep the filename `production/resume-state.json` to avoid breaking existing callers, but migrate its schema to version 2.

Schema v2 must include:

```json
{
  "schema_version": 2,
  "execution_id": "arthur-adh-cn-e27bafa-20260908",
  "status": "RESUME_SAFE",
  "instruction_allowed": true,
  "source": {
    "repository_head": "...",
    "accepted_source_sha": "..."
  },
  "production": {
    "github_run_id": 34056525562,
    "artifact_id": 9998837025,
    "candidate_sha256": "..."
  },
  "device": {
    "version": "0.1.3",
    "build_id": "33462873812",
    "git_commit": "e27bafa"
  },
  "gates": {},
  "current_gate": "PRE_FLASH",
  "next_action": "PRE_FLASH",
  "conflicts": [],
  "semantic_sha256": "...",
  "evidence_timestamp": "..."
}
```

Backward-compatible summary fields may remain during migration only when existing scripts require them. All new decision logic reads the Gate model.

## 8. Gate model

Every Gate is a first-class state object.

Allowed statuses:

- `PENDING`: requirement exists and has not started.
- `RUNNING`: an executor is actively producing evidence.
- `PASS`: current evidence satisfies the requirement for the current subject identity.
- `FAIL`: evidence proves the requirement is not met; automatic repair may continue.
- `BLOCKED`: no safe automatic continuation exists under current policy.
- `STALE`: the Gate previously passed, but source/artifact/device/requirement identity changed in a way that invalidates the evidence.
- `SKIPPED`: the Gate is not applicable for this execution and the reason is explicit.

Gate record:

```json
{
  "gate_id": "ADGUARD_FULL_MANAGER",
  "status": "PASS",
  "requirement_ref": "production/ARTHUR_PRODUCT_TARGETS.md#ADGUARD_HOME",
  "subject": {
    "source_sha": "...",
    "candidate_sha256": "...",
    "device_build_id": "..."
  },
  "evidence_refs": [
    "production/evidence/arthur-adh-cn-e27bafa-20260908/index.json#ADGUARD_FULL_MANAGER"
  ],
  "inherited": false,
  "verified_at": "2026-09-08T12:00:00Z"
}
```

A `PASS` Gate must contain at least one evidence reference unless the Gate is explicitly inherited from an immutable accepted baseline and the inheritance record itself contains evidence provenance.

## 9. Evidence model

Create:

`production/evidence/<execution_id>/index.json`

Do not commit firmware binaries, large screenshots or duplicate workflow artifacts into Git.

The evidence index stores references and hashes for externally stored or already-existing evidence.

Evidence entry fields:

```json
{
  "evidence_id": "real-device-verify-001",
  "gate_id": "REAL_DEVICE_VERIFY",
  "type": "REAL_DEVICE_REPORT",
  "producer": "scripts/real-device-verify-v3.ps1",
  "source_sha": "...",
  "github_run_id": 34056525562,
  "artifact_id": 9998837025,
  "candidate_sha256": "...",
  "device_build_id": "...",
  "ref": "output/real-device/real-device-verification.json",
  "sha256": "...",
  "observed_at": "...",
  "result": "PASS"
}
```

Valid evidence types include at minimum:

- `LIVE_PREVIEW_REPORT`
- `GITHUB_WORKFLOW_RUN`
- `ARTIFACT_MANIFEST`
- `HASH_VERIFICATION`
- `FLASH_SAFETY_REPORT`
- `FLASH_EVENT`
- `LIVE_DEVICE_BUILD_INFO`
- `REAL_DEVICE_REPORT`
- `GITHUB_RELEASE`
- `INHERITED_BASELINE`

An evidence reference is valid only when its identity fields match the Gate subject rules.

## 10. Evidence subject matching

Gate-specific subject matching prevents old PASS evidence from being reused against new bytes.

Examples:

### BUILD

Must match accepted source SHA and GitHub run identity.

### ARTIFACT

Must match GitHub run ID, artifact ID, source SHA and Candidate SHA256.

### PRE_FLASH / AUTO_FLASH_SAFETY_GATE

Must match Candidate SHA256, expected target/profile, rollback identity and current device identity.

### REAL_DEVICE_VERIFY

Must match Candidate SHA256 and the post-flash device build identity.

### RELEASE

Must match the Candidate SHA256 already accepted by REAL_DEVICE_VERIFY.

### Inherited frozen Gates

May remain PASS across a new execution only when change impact proves that the relevant subject is unaffected and the inherited baseline has explicit evidence provenance.

## 11. STALE invalidation

`STALE` is mandatory when previously valid evidence no longer proves the current subject.

The Control Plane computes invalidation using change impact and subject identity.

Examples:

- A source change after BUILD makes BUILD and all Candidate-dependent downstream Gates stale.
- A Candidate SHA change makes ARTIFACT, PRE_FLASH, flash-safety, flash, real-device verification and release evidence stale.
- A post-flash device build ID mismatch makes REAL_DEVICE_VERIFY and RELEASE stale or failed depending on evidence.
- A change limited to LuCI Chinese resources must not automatically invalidate unrelated frozen Wi-Fi evidence when Change Impact says Wi-Fi is unaffected.
- A requirement change in `ARTHUR_PRODUCT_TARGETS.md` invalidates historical PASS for that requirement even if source bytes did not change.

Stale Gates are never treated as PASS by next-action selection.

## 12. State freshness gate

Add `STATE_FRESHNESS_GATE` before any instruction generation or automatic continuation.

It compares the canonical snapshot against live authoritative identity sources.

At minimum it validates:

- current non-state repository HEAD;
- current execution identity;
- accepted source SHA;
- active runtime/controller phase;
- current Production Agent run identity when attached;
- live device build-info when the phase requires real-device identity.

State-only commits such as updates to `production/resume-state.json`, `production/firmware-events.jsonl` and evidence indexes must not create a false source change or trigger a firmware build.

If the snapshot is older than the current non-state state of the repository or runtime, the Control Plane must reconcile and republish before returning `next_action`.

If reconciliation cannot establish one unambiguous current state, set:

`status = STATE_RECONCILIATION_REQUIRED`

`instruction_allowed = false`

## 13. Event ledger

Keep `production/firmware-events.jsonl` as the append-only historical ledger and preserve its existing hash-chain behavior.

Add event types required by the new model:

- `EXECUTION_CREATED`
- `EXECUTION_ATTACHED_GITHUB_RUN`
- `GATE_STARTED`
- `EVIDENCE_RECORDED`
- `GATE_PASSED`
- `GATE_FAILED`
- `GATE_BLOCKED`
- `GATE_STALE`
- `GATE_INHERITED`
- `CANDIDATE_REPLACED`
- `FLASH_STARTED`
- `DEVICE_RECONCILED`
- `RELEASED`

Each event records `execution_id`, Gate where applicable, relevant subject identity and the previous event hash.

`resume-state.json` answers "where are we now?".

`firmware-events.jsonl` answers "how did we get here?".

`production/evidence/<execution_id>/index.json` answers "what proves it?".

## 14. Executor responsibilities

### Feature Handoff

- preserves accepted preview bytes and evidence;
- ensures one `execution_id` is present before entering production;
- does not arbitrate production Gate PASS beyond its own submitted observations;
- preserves existing idempotent dispatch rules.

### GitHub Actions / v3 Controller

- emits workflow/run/artifact observations;
- preserves numeric GitHub `run_id` semantics;
- does not mark real-device Gates PASS.

### Production Agent

- keeps at-most-once sysupgrade semantics;
- emits artifact/hash/flash/device evidence;
- does not reuse a Candidate when subject identity no longer matches the active execution;
- reports verification evidence to the Control Plane.

### Codex

- begins from reconciled `resume-state.json`;
- performs only `next_action` or the minimum repair necessary to unblock it;
- never claims a Gate is PASS without evidence accepted by the Control Plane;
- does not restart a completed upstream stage merely because a session restarted.

## 15. Next-action selection

The Control Plane selects the first required Gate that is not validly `PASS` or `SKIPPED`.

Priority rules:

1. hard safety conflicts produce `BLOCKED` or `STATE_RECONCILIATION_REQUIRED`;
2. `STALE` is treated as incomplete;
3. `FAIL` with a safe repair path returns the repair action for that Gate;
4. `RUNNING` returns resume/observe for the same executor and identity rather than dispatching a duplicate;
5. previously completed valid Gates are never rerun without invalidation evidence;
6. after `FLASH_STARTED`, recovery always reconciles device state before any new write;
7. `PRODUCTION_RELEASED` returns `next_action = NONE`.

## 16. Build dedup and impact behavior

Existing build-dedup and change-impact behavior must be preserved and strengthened.

State/control-only file changes must not request a Candidate.

A source-changing repair invalidates only the Gates dependent on the changed subject.

If a repair changes Candidate-producing source, the active execution remains the same but the previous Candidate is recorded as superseded and downstream Candidate-dependent Gates become `STALE`.

The new Candidate receives a new numeric GitHub `run_id`, artifact identity and SHA256.

## 17. Migration strategy

Migration must be additive and fail closed.

Phase 1:

- add schema helpers, Gate/Evidence types and tests;
- allow reading existing schema v1 snapshot;
- publish schema v2 while retaining compatibility summary fields needed by existing callers.

Phase 2:

- make Control Plane decisions use Gate records;
- record evidence indexes for new executions;
- map existing frozen Wi-Fi, LuCI Chinese, ADH and QuickStart acceptance to explicit inherited or live evidence records.

Phase 3:

- update Feature Handoff and Production Agent adapters to submit evidence identity to the Control Plane;
- remove decision dependence on fixed `verified` strings once all callers are migrated.

No phase may require a firmware rebuild merely to deploy the state-contract implementation.

## 18. Safety and authorization

Existing operator intent remains authoritative for whether firmware execution is authorized.

A state statement is not execution authorization.

The new state model must not broaden authorization scope.

`STATE_FRESHNESS_GATE`, evidence reconciliation and read-only diagnostics are allowed under read-only/status scope. Build, upload, flash or release actions remain gated by the existing `production/operator-intent.json` authorization contract.

Any ambiguity involving device identity, rollback identity, Candidate bytes, post-flash state or irreversible-write state fails closed.

## 19. Required tests

Implementation uses TDD. At minimum tests must prove:

1. schema v1 is readable during migration;
2. schema v2 contains one `execution_id` and canonical Gate map;
3. a Gate cannot become PASS with no evidence unless it is valid explicit inheritance;
4. evidence with a different source SHA cannot satisfy BUILD;
5. evidence with a different Candidate SHA256 cannot satisfy Candidate-dependent Gates;
6. source change marks dependent downstream Gates STALE;
7. unrelated frozen Wi-Fi remains PASS when Change Impact proves it is unaffected;
8. changed Wi-Fi source or requirement invalidates inherited Wi-Fi evidence;
9. snapshot repository identity behind the current non-state HEAD triggers reconciliation before instruction generation;
10. state-only commits do not trigger false firmware invalidation or build requests;
11. an existing RUNNING GitHub/Production Agent identity is resumed instead of duplicate-dispatched;
12. `FLASH_STARTED` recovery cannot execute a second sysupgrade before device reconciliation;
13. replacement Candidate remains in the same `execution_id` but receives new GitHub/artifact identity;
14. old Candidate-dependent PASS records become STALE after replacement;
15. REAL_DEVICE_VERIFY PASS must bind Candidate SHA256 and post-flash build identity;
16. RELEASE cannot pass without valid REAL_DEVICE_VERIFY evidence for the same Candidate;
17. `PRODUCTION_RELEASED` remains the only success terminal and yields `next_action = NONE`;
18. event-ledger hash chaining remains valid with new event types.

## 20. Success criteria

The change is successful when all of the following are true:

- progress/continue/next-action decisions come from one reconciled Control Plane snapshot;
- every non-inherited PASS has explicit evidence provenance;
- inherited PASS states have explicit baseline provenance and impact justification;
- stale evidence is mechanically invalidated rather than trusted by narrative;
- a stopped Codex session or restarted Windows host resumes the same execution identity and the first incomplete valid Gate;
- completed valid Gates do not repeat without an invalidation reason;
- old Candidate evidence cannot prove a replacement Candidate;
- no new controller duplicates Feature Handoff, v3 Controller or Production Agent;
- existing flash safety and at-most-once write semantics remain intact;
- no control-plane/state-only change causes an unnecessary firmware rebuild;
- terminal success remains `PRODUCTION_RELEASED`.
