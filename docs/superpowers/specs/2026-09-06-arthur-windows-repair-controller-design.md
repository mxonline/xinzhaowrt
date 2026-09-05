# Arthur Windows Repair Controller Design

## Status

Approved design for implementation planning. This document defines a new outer recovery layer for the Arthur production firmware pipeline. It exists only to restore the GPT-Codex execution runtime when that runtime cannot recover itself.

## Problem

The current Arthur unattended chain can detect a dead or stale Codex runtime and restart it, but repeated startup failures eventually enter `CRASH_LOOP_BLOCKED`. At that point the component expected to repair the firmware task, Codex itself, is unavailable.

The production host has several independently persistent layers:

- GitHub `main`
- clean `control-runtime`
- mutable `workspace`
- Windows Scheduled Task
- long-lived Supervisor
- `runtime-state.json`
- `supervisor-state.json`
- managed Python and `openai_codex`
- Codex child process

Past failures showed that a green GitHub change or a healthy Supervisor process does not prove that the actual Codex child is loading the intended code, model configuration, working directory, or state. The result was repeated local retries, `CRASH_LOOP_BLOCKED`, and manual screenshot-driven diagnosis.

## Goal

Introduce an independent Windows Repair Controller that can diagnose and repair known Codex runtime infrastructure failures without depending on Codex itself, while preserving the current Arthur BUILD handoff and never performing firmware actions.

The only successful terminal for this controller is:

`CODEX_RUNTIME_RECOVERED`

That terminal requires all of the following to be true for at least 120 continuous seconds:

- the persistent Supervisor process is alive
- the Codex runtime process is alive
- the runtime heartbeat advances at least twice
- the runtime module path is the expected current `control-runtime` code
- the repair probe confirms the configured explicit headless Codex model
- the immutable release-task identity is unchanged

After `CODEX_RUNTIME_RECOVERED`, the Repair Controller stops mutating recovery infrastructure. The Codex runtime may already be continuing the existing BUILD handoff during the 120-second health window; any firmware progress during that window must come only from the pre-existing Arthur runtime and its normal gates, never from the Repair Controller.

## Non-Goals and Safety Boundary

The Repair Controller must never:

- invoke firmware Build
- create or replace a Candidate
- call sysupgrade or any flash operation
- modify Known-Good
- change device acceptance evidence
- directly advance `ARTIFACT`, `PRE_FLASH`, `FLASH`, `RELEASE`, or `PRODUCTION_RELEASED`
- clear a human safety gate
- replace `runtime-state.json`
- reset, clean, stash, or discard the mutable task workspace
- force-push Git history

It may stop and restart only the Windows Supervisor and Codex runtime processes associated with the existing Arthur control-plane state directory.

## Architecture

The new component runs outside the Codex process tree and outside the existing Supervisor retry loop.

Production topology:

`GitHub schedule -> Windows Repair Controller Scheduled Task -> persistent Supervisor -> Codex runtime -> existing Arthur BUILD handoff`

The existing Supervisor remains responsible for normal heartbeat monitoring and bounded restart attempts. The Repair Controller activates only when the Supervisor cannot restore the Codex runtime or when the runtime probe proves that the child is executing the wrong code/configuration.

The Repair Controller is deliberately implemented with PowerShell plus Python standard-library probes only. Its core detection and repair path must not import or require `openai_codex` except inside the isolated Codex runtime probe process.

## Components

### 1. Repair Controller

New script:

`scripts/arthur-windows-repair-controller.ps1`

Responsibilities:

- acquire a repair lock so only one controller instance can run
- read current Supervisor, runtime, Scheduled Task, Git, Python, and process evidence
- classify the failure into a known repair class or `UNKNOWN_FAILURE`
- persist a structured repair record
- apply at most one approved repair action per cycle
- run the isolated Runtime Probe
- restart the existing persistent Supervisor only after the probe passes
- verify the 120-second recovery gate

The controller must be idempotent. A second invocation while another repair owns the lock exits successfully with `REPAIR_CONTROLLER_ALREADY_RUNNING=PASS` and performs no mutation.

### 2. Runtime Probe

New script:

`scripts/arthur-codex-runtime-probe.py`

The probe runs in a separate process using the managed headless Python interpreter. It is not allowed to execute the Arthur firmware pipeline.

It reports JSON containing:

- probe timestamp
- Python executable
- current working directory
- `sys.path`
- resolved `ai_orchestrator.__file__`
- resolved `ai_orchestrator.codex_compat.__file__`
- configured `HEADLESS_CODEX_MODEL`
- effective default headless model
- `openai_codex` package version when importable
- whether account preflight succeeds
- whether model catalog access was skipped
- probe exit class

The probe must use the same compatibility initialization path as production, but it must stop before creating or resuming an Arthur runtime.

### 3. Repair State

New durable file under the existing canonical Windows state directory:

`repair-status.json`

It records:

- schema version
- controller status
- failure class
- evidence timestamp
- repair attempt count
- selected repair action
- source and control-runtime SHA
- expected and actual module roots
- expected and actual model
- Scheduled Task action summary
- Supervisor PID
- Codex PID
- heartbeat observations
- runtime-state immutable identity
- runtime progress snapshot
- final result

A second append-only file is used for forensic history:

`repair-events.jsonl`

Each repair cycle appends one start record, one action record when a mutation occurs, and one terminal record.

## Failure Classification

The controller supports only these automatic repair classes in the first version.

### CONTROL_RUNTIME_STALE

Detection:

- `control-runtime` is clean
- local HEAD is an ancestor of `origin/main`
- local HEAD differs from `origin/main`

Repair:

- `git fetch origin main`
- `git merge --ff-only origin/main`

Hard stop if the tree is dirty, diverged, or cannot fast-forward.

### TASK_LAUNCHER_DRIFT

Detection:

- Scheduled Task exists
- task principal is the approved interactive user
- task action, launcher path, state directory, Python path, or `control-runtime` binding differs from the generated canonical launcher

Repair:

- re-register only the existing `XinZhaoWrt-Arthur-Persistent-Supervisor` task using the canonical action
- preserve the existing approved interactive user principal
- do not create a second Supervisor task name

### MODULE_ROOT_DRIFT

Detection:

- Runtime Probe resolves `ai_orchestrator` outside the clean `control-runtime` tree

Repair:

- stop only the existing Supervisor and matching Codex runtime processes
- regenerate the canonical launcher
- ensure the launcher changes directory to `control-runtime`
- ensure Python starts the shim from `control-runtime`
- rerun the Runtime Probe before restarting the Supervisor

The controller must not delete or modify `workspace` to solve module drift.

### MODEL_BINDING_DRIFT

Detection:

- Runtime Probe effective model differs from the configured explicit headless model
- or production compatibility initialization does not report model-catalog skipping

Repair:

- regenerate the canonical launcher with an explicit `HEADLESS_CODEX_MODEL`
- rerun the Runtime Probe

No model change is allowed outside the project-approved headless model constant/configuration.

### SUPERVISOR_RETRY_EXHAUSTED

Detection:

- Supervisor status is `CRASH_LOOP_BLOCKED`
- runtime-state has no protected phase or human safety gate
- Runtime Probe is otherwise healthy

Repair:

- back up `supervisor-state.json`
- clear only the Supervisor retry state
- preserve `runtime-state.json`
- restart the existing Scheduled Task

### UNKNOWN_FAILURE

Any condition not matching the approved classes is terminal for the Repair Controller.

Result:

`REPAIR_BLOCKED_UNKNOWN_FAILURE`

The controller records full evidence and performs no mutation beyond diagnostic reads.

## Runtime-State Preservation

Before any repair mutation, the controller stores two snapshots from `runtime-state.json`.

Immutable release-task identity:

- `release_task_id`
- `repo`
- `branch`
- `source_sha`
- `request_id`

Progress snapshot:

- `phase`
- `candidate_sha256`
- `active_run_id`
- `next_action`
- `terminal_state`
- `pending_human_gate`

During diagnosis, repair, and isolated probing, both snapshots must remain byte-for-byte equivalent at the field level. Any change before the production Supervisor is restarted is `REPAIR_BLOCKED_RUNTIME_STATE_CHANGED`.

After the production Supervisor is restarted, the immutable release-task identity must continue to match exactly. Progress fields may change only because the existing Arthur Codex runtime resumes its already-authorized handoff. The Repair Controller must never write those fields itself. It records before/after values in `repair-events.jsonl` for attribution and audit.

The controller never deletes, rewrites, or reconstructs `runtime-state.json`.

## Recovery State Machine

States:

`IDLE -> DIAGNOSING -> REPAIRING -> PROBING -> RESTARTING -> VERIFYING -> CODEX_RUNTIME_RECOVERED`

Failure terminals:

- `REPAIR_BLOCKED_UNKNOWN_FAILURE`
- `REPAIR_BLOCKED_DIRTY_CONTROL_RUNTIME`
- `REPAIR_BLOCKED_DIVERGED_CONTROL_RUNTIME`
- `REPAIR_BLOCKED_RUNTIME_STATE_CHANGED`
- `REPAIR_BLOCKED_SAFETY_PHASE`
- `REPAIR_BLOCKED_HUMAN_GATE`
- `REPAIR_EXHAUSTED`

Maximum automatic repair attempts for one unchanged failure fingerprint: 3 within 30 minutes. A fourth identical fingerprint is `REPAIR_EXHAUSTED` and receives no additional automatic mutation.

## Recovery Verification Gate

Recovery is not considered successful merely because a process starts.

The controller must observe all of the following:

1. Scheduled Task state is `Running`.
2. A matching `run-supervisor.py --interval 30` process exists.
3. A matching `ai_orchestrator resume` runtime process exists.
4. Runtime Probe before restart passes the code-root and model checks.
5. Runtime heartbeat timestamp advances at least twice.
6. The first and last healthy observations are at least 120 seconds apart.
7. Supervisor status is `HEALTHY`, or a documented active runtime state whose heartbeat is fresh and whose process is alive.
8. No protected firmware phase or human safety gate was altered by the Repair Controller.
9. The immutable release-task identity is preserved.

Only then write:

`status = CODEX_RUNTIME_RECOVERED`

## GitHub Integration

The existing scheduled wakeup remains the outer recurring trigger.

Before it asks the Arthur Control Plane to resume Codex, it checks `repair-status.json` when available.

Behavior:

- if repair is actively running, GitHub logs `WINDOWS_REPAIR_CONTROLLER=ACTIVE` and does not create a competing repair
- if status is `CODEX_RUNTIME_RECOVERED`, the normal Control Plane wakeup continues
- if a repair-blocked terminal exists, GitHub publishes the evidence and fails without attempting a duplicate Supervisor restart
- if Supervisor/Codex health is normal, the Repair Controller is not invoked
- if Codex is absent, heartbeat is stale, or Supervisor is crash-loop blocked in a non-protected phase, GitHub starts the Repair Controller Scheduled Task once and exits; the Windows-owned task carries the long recovery verification independently of the Actions job lifetime

GitHub is an observer and trigger. It does not own the long-lived repair process.

## Windows Ownership and Provisioning

The Repair Controller uses a dedicated Scheduled Task and runs under the same approved interactive Windows user principal as the persistent Supervisor.

Required task name:

`XinZhaoWrt-Arthur-Repair-Controller`

Provisioning rules:

- the existing Supervisor task principal is the authoritative user identity
- the Repair Controller task is created or updated from that principal; no second user-discovery mechanism is introduced
- `LogonType` is `Interactive`
- `RunLevel` is `Highest`
- `MultipleInstances` is `IgnoreNew`
- `ExecutionTimeLimit` is unlimited so the 120-second verification window is not owned by GitHub Actions
- the task has no firmware command or pipeline argument
- GitHub may call `Start-ScheduledTask` for this existing task, but it does not launch the repair script as its own child process

The Repair Controller task is on-demand only in version 1. The existing GitHub five-minute wakeup is the recurring trigger; no second periodic repair schedule is added.

## Observability

Every cycle emits concise machine-readable markers suitable for GitHub Actions logs:

- `WINDOWS_REPAIR_DIAGNOSIS=PASS`
- `WINDOWS_REPAIR_CLASS=<class>`
- `WINDOWS_REPAIR_ACTION=<action>`
- `WINDOWS_REPAIR_PROBE=PASS`
- `WINDOWS_REPAIR_RUNTIME_STATE_PRESERVED=PASS`
- `WINDOWS_REPAIR_HEALTH_WINDOW=PASS seconds=<n>`
- `CODEX_RUNTIME_RECOVERED=PASS`

Failure markers include the exact blocked reason and evidence file path.

No success marker may be emitted before the 120-second verification gate completes.

## Testing Strategy

All implementation follows TDD.

Automated tests must cover:

- clean fast-forward control-runtime recovery
- dirty and diverged control-runtime fail-closed behavior
- task launcher drift detection and canonical re-registration
- module-root drift detection without modifying workspace
- explicit model binding and model-catalog skip verification
- Supervisor retry-state reset only after a passing Runtime Probe
- no mutation when runtime-state changes during repair
- no mutation in protected firmware phases
- no mutation when a human safety gate exists
- identical failure fingerprint exhaustion after three repair attempts
- idempotent concurrent invocation behavior
- 120-second two-heartbeat recovery gate
- Repair Controller Scheduled Task provisioning from the existing Supervisor principal
- GitHub wakeup behavior for ACTIVE, RECOVERED, BLOCKED, and healthy/no-repair states

Windows-specific tests must execute under Windows PowerShell 5.1 in CI for Scheduled Task and quoting behavior. Python probe tests may run under the managed Python version used by the production headless runtime.

## Rollout

The feature is introduced in three safe stages.

Stage A: diagnostic-only mode. The controller classifies failures and writes evidence but performs no mutation.

Stage B: enable the approved white-list repairs while keeping automatic Supervisor restart disabled after repair. CI plus a real Windows dry run must prove task/action/module/model alignment.

Stage C: enable restart and the 120-second recovery gate. Only after a real Windows run reaches `CODEX_RUNTIME_RECOVERED` may this become the default unattended path.

The current Arthur firmware release remains on the existing BUILD handoff throughout rollout. No rollout stage may authorize firmware progress independently of Codex.

## Acceptance Criteria

The implementation is accepted only when a real Windows test demonstrates this complete sequence without manual intervention after the trigger:

`Codex runtime failure -> automatic diagnosis -> known repair -> isolated probe -> Supervisor restart -> Codex runtime alive -> two advancing heartbeats over at least 120 seconds -> CODEX_RUNTIME_RECOVERED -> existing BUILD handoff continues`

A GitHub-only green CI result is insufficient evidence of production recovery.
