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
4. whether that evidence is still valid for the current source, artifact, requirement and device identity.

Today, several verified fields in `resume-state.json` are emitted as fixed status strings such as `VERIFIED_FROZEN` or `LIVE_BROWSER_VERIFIED`. They are not all represented as first-class Gate records with explicit evidence references and subject identity. This makes stale PASS reuse possible and makes it harder to distinguish a valid inherited verification from an old verification that must be rerun.

A second problem is identity fragmentation. GitHub `run_id`, Feature Handoff identity, current repository HEAD, accepted preview source SHA, Candidate SHA256 and real-device build identity are all meaningful, but no single execution identifier spans the full user task from accepted implementation to production release.

## 2. Goal

Upgrade the existing Arthur Control Plane into the only canonical Gate arbiter and add a unified execution contract that binds:

`Source of Truth -> Execution -> Gates -> Evidence -> PASS/FAIL/STALE/BLOCKED -> next_action`

The implementation must preserve the existing RELEASE-FIRST architecture and production executors. It must not introduce a second orchestrator.

After this change, any progress/resume/continue request must be answerable from reconciled machine state and durable evidence instead of historical chat or best-effort interpretation of several independent files.

## 3. Non-goals

- Do not create a parallel `.runtime/current.json` controller.
- Do not replace Feature Handoff.
- Do not replace `ci-controller-v3.ps1`.
- Do not replace `production-agent.ps1`.
- Do not change the verified Arthur sysupgrade command or flash safety semantics.
- Do not add raw MTD, U-Boot, `dd`, partition-write or bootloader automation.
- Do not automatically rerun frozen Wi-Fi verification when change impact proves Wi-Fi is unaffected.
- Do not make normal state/ledger/evidence-index commits trigger firmware builds.
- Do not migrate the WeChat content-production system in this change.

## 4. Architectural rule

The Arthur Control Plane becomes the only component allowed to arbitrate the canonical status of a production Gate.

Executors may keep local operational stages and statuses, but those are observations, not the canonical cross-system Gate truth.

Examples:

- GitHub Actions may report a successful build and artifact metadata.
- Feature Handoff may report accepted preview evidence.
- Production Agent may report successful SHA checks or a real-device verifier result.
- Codex may produce a repair commit and test results.

The Control Plane consumes those inputs and decides whether the corresponding canonical Gate is `PASS`, `FAIL`, `BLOCKED`, `STALE`, `PENDING`, `RUNNING` or `SKIPPED`.

The terminal rules are:

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

These files define what a Gate must prove. They do not directly establish that the current execution passed that Gate.

Every Gate stores both a `requirement_ref` and a `requirement_digest`. The digest is SHA256 over the normalized machine-readable acceptance contract for that Gate. A requirement change therefore invalidates historical evidence even if firmware bytes are unchanged.

## 6. Execution identity

Add one persisted string `execution_id` that spans an end-to-end Arthur user task.

It is generated once when the execution is created and is never recomputed from later repository state.

Format:

`arthur-<task-slug>-<accepted-source-prefix>-<utc-yyyymmddhhmmss>`

Example:

`arthur-adh-cn-e27bafa-20260908121731`

The timestamp prevents collisions between distinct executions created from the same accepted source on the same day.

`execution_id` is not a replacement for GitHub Actions `run_id`.

The existing numeric GitHub `run_id` remains unchanged because current controller and Production Agent code uses it as a numeric workflow identity.

The execution record contains concrete identities as they become available:

```json
{
  "execution_id": "arthur-adh-cn-e27bafa-20260908121731",
  "accepted_source_sha": "e27bafac2d4a3ecf0f7a0e4cf2f7b34cf77571c9",
  "github_run_id": 34056525562,
  "artifact_id": 9998837025,
  "candidate_sha256": "2f6f...",
  "device_build_id": "33462873812"
}
```

`execution_id + accepted_source_sha` identifies the user task and accepted starting source. `github_run_id + artifact_id + candidate_sha256` identifies one concrete Candidate.

A replacement Candidate created after a valid repair remains inside the same `execution_id`, but receives a new GitHub `run_id`, artifact identity and Candidate SHA256. The event ledger records the supersession relationship.

## 7. Canonical current snapshot

Keep the filename `production/resume-state.json` to avoid breaking existing callers, but migrate its schema to version 2.

Schema v2 contains:

```json
{
  "schema_version": 2,
  "execution_id": "arthur-adh-cn-e27bafa-20260908121731",
  "status": "RESUME_SAFE",
  "instruction_allowed": true,
  "source": {
    "repository_head": "19ee34f...",
    "accepted_source_sha": "e27bafa..."
  },
  "production": {
    "github_run_id": 34056525562,
    "artifact_id": 9998837025,
    "candidate_sha256": "2f6f..."
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
  "evidence_timestamp": "2026-09-08T12:17:31Z"
}
```

Backward-compatible summary fields remain only while existing callers require them. All new decision logic reads the Gate model.

## 8. Gate model

Every Gate is a first-class state object.

Allowed statuses:

- `PENDING`: requirement exists and has not started.
- `RUNNING`: an executor is actively producing evidence.
- `PASS`: current evidence satisfies the current requirement for the current subject identity.
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
  "requirement_digest": "9c77...",
  "subject": {
    "source_sha": "19ee34f...",
    "candidate_sha256": "2f6f...",
    "device_build_id": "33462873812"
  },
  "evidence_refs": [
    "repo:production/evidence/arthur-adh-cn-e27bafa-20260908121731/index.json#ADGUARD_FULL_MANAGER"
  ],
  "inherited": false,
  "verified_at": "2026-09-08T12:17:31Z"
}
```

A `PASS` Gate contains at least one durable evidence reference unless the Gate is explicitly inherited from an immutable accepted baseline and the inheritance record itself contains durable evidence provenance.

## 9. Evidence model

Create:

`production/evidence/<execution_id>/index.json`

The index is small, durable and committed as control-plane state. It does not duplicate firmware binaries, large screenshots or workflow artifact payloads into Git.

Local `output/` files are producer inputs only. A local path by itself is not durable evidence.

Before evidence can support `PASS`, the evidence index must point to one of these durable forms:

- an immutable repository object committed under `production/evidence/<execution_id>/objects/`;
- a GitHub workflow run plus immutable run ID and source SHA;
- a GitHub Actions artifact plus artifact ID and content SHA256;
- a GitHub Release/tag plus release/tag identity and asset SHA256;
- an immutable accepted baseline record with its stored provenance.

Small machine-readable reports required for future arbitration, such as normalized real-device result summaries, may be copied into `production/evidence/<execution_id>/objects/<evidence_id>.json`. Large payloads remain external and are referenced by immutable GitHub identity plus hash.

Evidence entry:

```json
{
  "evidence_id": "real-device-verify-001",
  "gate_id": "REAL_DEVICE_VERIFY",
  "type": "REAL_DEVICE_REPORT",
  "producer": "scripts/real-device-verify-v3.ps1",
  "source_sha": "19ee34f...",
  "github_run_id": 34056525562,
  "artifact_id": 9998837025,
  "candidate_sha256": "2f6f...",
  "device_build_id": "33462873812",
  "durable_ref": "repo:production/evidence/arthur-adh-cn-e27bafa-20260908121731/objects/real-device-verify-001.json",
  "sha256": "71b2...",
  "observed_at": "2026-09-08T12:17:31Z",
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

An evidence reference is valid only when its requirement and subject identities match the Gate rules.

## 10. Evidence subject matching

Gate-specific subject matching prevents old PASS evidence from being reused against new bytes or new acceptance criteria.

### BUILD

Must match accepted source SHA, requirement digest and GitHub run identity.

### ARTIFACT

Must match GitHub run ID, artifact ID, source SHA, requirement digest and Candidate SHA256.

### PRE_FLASH / AUTO_FLASH_SAFETY_GATE

Must match Candidate SHA256, expected target/profile, rollback identity, requirement digest and current device identity.

### REAL_DEVICE_VERIFY

Must match Candidate SHA256, post-flash device build identity and current real-device acceptance requirement digest.

### RELEASE

Must match the Candidate SHA256 already accepted by REAL_DEVICE_VERIFY and the current release-policy requirement digest.

### Inherited frozen Gates

May remain PASS across a new execution only when Change Impact proves the relevant subject is unaffected, the current requirement digest matches the accepted baseline requirement digest, and the inherited baseline has durable evidence provenance.

## 11. STALE invalidation

`STALE` is mandatory when previously valid evidence no longer proves the current subject or requirement.

The Control Plane computes invalidation using Change Impact plus subject and requirement identity.

Examples:

- A Candidate-producing source change after BUILD makes BUILD and Candidate-dependent downstream Gates stale.
- A Candidate SHA change makes ARTIFACT, PRE_FLASH, flash-safety, flash, real-device verification and release evidence stale.
- A post-flash device build ID mismatch makes REAL_DEVICE_VERIFY and RELEASE stale or failed depending on observed evidence.
- A change limited to LuCI Chinese resources does not invalidate unrelated frozen Wi-Fi evidence when Change Impact proves Wi-Fi is unaffected.
- A Wi-Fi source/config change invalidates inherited Wi-Fi evidence.
- A requirement digest change invalidates historical PASS for that Gate even if firmware bytes are unchanged.

STALE Gates are never treated as PASS by next-action selection.

## 12. State freshness gate

Add `STATE_FRESHNESS_GATE` before any instruction generation or automatic continuation.

It compares the canonical snapshot against live authoritative identity sources.

At minimum it validates:

- current non-state repository HEAD;
- current execution identity;
- accepted source SHA;
- active runtime/controller phase;
- current Production Agent run identity when attached;
- live device build-info when the current phase requires real-device identity.

State-only paths are excluded from firmware source identity. At minimum these include:

- `production/resume-state.json`
- `production/firmware-events.jsonl`
- `production/evidence/**`

The existing build-scope classifier remains responsible for excluding other established control-only files. The migration must not broaden build triggers accidentally.

If the snapshot is older than the current non-state repository/runtime state, the Control Plane reconciles and republishes before returning `next_action`.

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

Each event records `execution_id`, Gate where applicable, requirement digest, relevant subject identity and previous event hash.

`resume-state.json` answers "where are we now?".

`firmware-events.jsonl` answers "how did we get here?".

`production/evidence/<execution_id>/index.json` answers "what proves it?".

## 14. Executor responsibilities

### Feature Handoff

- preserves accepted preview bytes and evidence;
- creates or adopts one persisted `execution_id` before entering production;
- submits observations to the Control Plane;
- preserves existing idempotent production-dispatch rules.

### GitHub Actions / v3 Controller

- emits workflow/run/artifact observations;
- preserves numeric GitHub `run_id` semantics;
- does not mark real-device canonical Gates PASS.

### Production Agent

- keeps at-most-once sysupgrade semantics;
- emits artifact/hash/flash/device observations and durable evidence identity;
- does not reuse a Candidate when subject identity no longer matches the active execution;
- retains local operational stages, but canonical Gate status is reconciled by the Control Plane.

### Codex

- begins from reconciled `resume-state.json`;
- performs only `next_action` or the minimum repair necessary to unblock it;
- never claims a canonical Gate is PASS without evidence accepted by the Control Plane;
- does not restart a completed upstream Gate merely because the Codex session restarted.

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

Existing build-dedup and Change Impact behavior is preserved and strengthened.

State/control-only file changes do not request a Candidate.

A source-changing repair invalidates only the Gates dependent on the changed subject.

If a repair changes Candidate-producing source, the active execution remains the same, the previous Candidate is recorded as superseded, and Candidate-dependent downstream Gates become `STALE`.

The replacement Candidate receives a new numeric GitHub `run_id`, artifact identity and SHA256.

## 17. Migration strategy

Migration is additive and fail closed.

### Phase 1: schema and arbitration foundation

- add Gate, evidence, requirement-digest and execution-identity helpers with tests;
- allow schema v1 snapshots to be read during migration;
- publish schema v2 while retaining compatibility summary fields needed by existing callers;
- add State Freshness reconciliation without changing firmware execution authorization.

### Phase 2: explicit evidence for existing accepted features

- make Control Plane decisions use Gate records;
- create evidence indexes for new executions;
- map existing accepted Wi-Fi, LuCI Chinese, ADH and QuickStart states to explicit inherited or live evidence records only when durable provenance can be established;
- if durable provenance cannot be established for an old fixed VERIFIED string, represent it as `STALE`/`PENDING` according to impact and require valid verification before it can support a release.

### Phase 3: executor adapters

- update Feature Handoff and Production Agent adapters to submit execution/evidence identity to the Control Plane;
- remove decision dependence on fixed `verified` strings once all callers are migrated.

No phase requires a firmware rebuild merely to deploy the state-contract implementation.

## 18. Safety and authorization

Existing operator intent remains authoritative for whether firmware execution is authorized.

A state statement is not execution authorization.

The new state model does not broaden authorization scope.

`STATE_FRESHNESS_GATE`, evidence reconciliation and read-only diagnostics are allowed under read-only/status scope. Build, upload, flash or release actions remain gated by the existing `production/operator-intent.json` authorization contract.

Any ambiguity involving device identity, rollback identity, Candidate bytes, post-flash state or irreversible-write state fails closed.

## 19. Required tests

Implementation uses TDD. At minimum tests prove:

1. schema v1 remains readable during migration;
2. schema v2 contains one persisted `execution_id` and canonical Gate map;
3. two executions created for the same source cannot collide;
4. a Gate cannot become PASS with no durable evidence unless it is valid explicit inheritance;
5. a requirement-digest mismatch invalidates historical evidence;
6. evidence with a different source SHA cannot satisfy BUILD;
7. evidence with a different Candidate SHA256 cannot satisfy Candidate-dependent Gates;
8. Candidate-producing source change marks dependent downstream Gates STALE;
9. unrelated frozen Wi-Fi remains PASS when Change Impact proves it is unaffected and requirement digest still matches;
10. changed Wi-Fi source/config or requirement digest invalidates inherited Wi-Fi evidence;
11. snapshot repository identity behind current non-state HEAD triggers reconciliation before instruction generation;
12. state-only commits do not trigger false firmware invalidation or build requests;
13. local `output/` path alone is rejected as durable PASS evidence;
14. immutable GitHub run/artifact identity plus matching hashes can satisfy configured evidence rules;
15. an existing RUNNING GitHub/Production Agent identity is resumed instead of duplicate-dispatched;
16. `FLASH_STARTED` recovery cannot execute a second sysupgrade before device reconciliation;
17. replacement Candidate remains in the same `execution_id` but receives new GitHub/artifact identity;
18. old Candidate-dependent PASS records become STALE after replacement;
19. REAL_DEVICE_VERIFY PASS binds Candidate SHA256, post-flash build identity and current requirement digest;
20. RELEASE cannot pass without valid REAL_DEVICE_VERIFY evidence for the same Candidate;
21. `PRODUCTION_RELEASED` remains the only success terminal and yields `next_action = NONE`;
22. event-ledger hash chaining remains valid with new event types.

## 20. Success criteria

The change is successful when all of the following are true:

- progress/continue/next-action decisions come from one reconciled Control Plane snapshot;
- every non-inherited PASS has durable evidence provenance;
- inherited PASS states have explicit accepted-baseline provenance, matching requirement digest and impact justification;
- stale evidence is mechanically invalidated rather than trusted by narrative;
- a stopped Codex session or restarted Windows host resumes the same execution identity and first incomplete valid Gate;
- completed valid Gates do not repeat without an invalidation reason;
- old Candidate evidence cannot prove a replacement Candidate;
- no new controller duplicates Feature Handoff, v3 Controller or Production Agent;
- existing flash safety and at-most-once write semantics remain intact;
- no control-plane/state-only change causes an unnecessary firmware rebuild;
- terminal success remains `PRODUCTION_RELEASED`.
