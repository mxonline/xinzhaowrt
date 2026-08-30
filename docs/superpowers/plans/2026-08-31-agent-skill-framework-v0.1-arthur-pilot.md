# Agent Skill Framework v0.1 + Arthur Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a project-agnostic Skill Framework that reuses Superpowers, writing-skills and a controlled Skill Finder capability, then prove it against the existing Arthur OpenWrt production pipeline including gated automatic standard sysupgrade and automatic real-device verification.

**Architecture:** The framework sits above existing project pipelines. A registry and contract model route a TaskPacket through policy, execution, evidence, verification, HANDOFF/resume and release gates. Arthur adapters call the existing v4 build/control-plane assets rather than replacing them. The automatic flash adapter is fail-closed and can only execute the verified `PowerShell -> ssh.exe -> upload -> remote SHA256 -> /sbin/sysupgrade -> WAIT_DEVICE` path after the project has synchronized the historically verified Arthur sysupgrade invocation and all safety predicates pass.

**Tech Stack:** Python 3 standard library for JSON contracts/router/state/evidence, POSIX shell for existing OpenWrt control-plane adapters/tests, Windows PowerShell + Windows OpenSSH `ssh.exe` for the Arthur standard sysupgrade executor, existing GitHub Actions workflows and repository shell test style.

**Spec:** `docs/superpowers/specs/2026-08-31-agent-skill-framework-v0.1-arthur-pilot-design.md`

## Global Constraints

- Existing `production/known-good.json` and the frozen Arthur Known-Good remain authoritative and must not be rewritten by framework setup.
- Existing v4 build routing remains authoritative for DOC_ONLY / FAST_GATE / IMAGEBUILDER / SDK_BUILD / FULL_BUILD.
- Exactly 22 mandatory LuCI applications remain required.
- Arthur standard automatic flashing requires AUTO_FLASH_SAFETY_GATE PASS and uses only the verified PowerShell -> `ssh.exe` -> `/sbin/sysupgrade` route.
- No human confirmation stop is permitted once AUTO_FLASH_SAFETY_GATE passes for the verified standard sysupgrade path.
- Never guess sysupgrade flags. Missing verified invocation metadata is a BLOCKED state, not permission to improvise.
- MTD, U-Boot, bootloader, `dd`, raw eMMC/SPI/NAND writes are outside the automatic path.
- Real-device failure blocks release and enters the repair loop.
- Superpowers and writing-skills are reused; do not duplicate their methodology in local Core Skills.
- Skill Finder is discovery-only and cannot install, execute, grant permissions or mutate the approved registry.
- The framework must be disableable without breaking the existing Arthur production pipeline.

---

### Task 1: Freeze current state and expose stale flash-policy conflict

**Files:**
- Create: `tests/test-skill-framework-preflight.sh`
- Create: `scripts/skill-framework-preflight.sh`
- Create: `production/skill-framework-state.json`
- Do not modify Known-Good files in this task.

**Interfaces:**
- Consumes: `AGENTS.md`, `knowledge/OPENWRT-PRODUCTION-V4.md`, `production/v4-state.json`, `production/known-good.json`.
- Produces: machine-readable preflight result with `baseline_integrity`, `flash_policy_sync`, `verified_flash_method`, and `framework_mode`.

- [ ] **Step 1: Write the failing preflight test**

Create a shell test that asserts current repository evidence is detected accurately: Known-Good exists, `production/v4-state.json` parses, and stale `HUMAN_REVIEW_GATE`/manual-flash language causes `flash_policy_sync=BLOCKED` rather than being silently accepted.

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
bash tests/test-skill-framework-preflight.sh
```

Expected: FAIL because `scripts/skill-framework-preflight.sh` and state output do not yet exist.

- [ ] **Step 3: Implement fail-closed preflight**

Implement a shell wrapper using Python 3 standard-library JSON parsing. It must run `scripts/baseline-integrity-gate.sh`, inspect the three policy/state sources above, and write `production/skill-framework-state.json` with `framework_mode=DRY_RUN_ONLY` while stale manual-flash policy is present.

- [ ] **Step 4: Verify GREEN**

Run the focused test and JSON parse check. Expected: PASS with the conflict explicitly represented as BLOCKED, no build and no flash.

- [ ] **Step 5: Commit**

Commit only the preflight script, test and framework-state file.

---

### Task 2: Add Skill Contract and TaskPacket contracts

**Files:**
- Create: `agent/contracts/skill.schema.json`
- Create: `agent/contracts/task-packet.schema.json`
- Create: `agent/contracts/handoff.schema.json`
- Create: `agent/contracts/evidence.schema.json`
- Create: `agent/contracts/validate.py`
- Create: `tests/agent/test_contracts.py`

**Interfaces:**
- Produces: `validate_document(kind: str, data: dict) -> list[str]` where an empty list means valid and any error makes routing fail closed.

- [ ] **Step 1: Write contract tests**

Cover required Skill fields: `id`, `version`, `layer`, triggers, non-triggers, inputs, preconditions, permissions, risk, implementation binding, evidence requirements, verification, failure handling and fallback. Cover TaskPacket fields: `task_id`, `goal`, `project`, `domain`, `current_state`, `requested_action`, `constraints`, `risk`, `resume_state`.

- [ ] **Step 2: Run RED**

Run:

```bash
python3 -m unittest tests.agent.test_contracts -v
```

Expected: FAIL because contracts/validator do not exist.

- [ ] **Step 3: Implement standard-library validation**

Do not add a PyPI dependency. The JSON schema files document the contract; `validate.py` performs the runtime checks needed by v0.1 with explicit field/type/enumeration validation.

- [ ] **Step 4: Run GREEN and malformed-input tests**

Malformed/unknown risk, layer, status or missing permission fields must fail validation.

- [ ] **Step 5: Commit**

Commit contracts, validator and tests.

---

### Task 3: Create approved Skill Registry with the three reusable capabilities

**Files:**
- Create: `agent/registry/skills.json`
- Create: `agent/registry/load_registry.py`
- Create: `tests/agent/test_registry.py`
- Create: `skills/core/finding-skills/SKILL.md`

**Interfaces:**
- Produces: `load_registry(path) -> dict[str, SkillRecord]` semantics using plain dictionaries in v0.1.

- [ ] **Step 1: Write registry tests**

Require three reusable entries:

1. `vendor.superpowers` with `decision=REUSE`, current-runtime binding, no ownership of project release policy.
2. `vendor.writing-skills` with `decision=REUSE`, allowed to create/test candidate Skills but not approve them.
3. `core.finding-skills` with `decision=CONTROLLED_DISCOVERY`, `install=false`, `execute_candidate=false`, `registry_write=false`.

- [ ] **Step 2: Run RED**

Expected: missing registry/loader.

- [ ] **Step 3: Implement registry loader and discovery Skill**

`finding-skills/SKILL.md` must direct the agent to search official ecosystems/GitHub, return candidate metadata, and hand every candidate to Reuse Gate. It must explicitly prohibit automatic installation or execution.

- [ ] **Step 4: Verify registry rejects duplicate ids, invalid versions and unapproved executable vendor entries**

- [ ] **Step 5: Commit**

Commit registry, Skill and tests.

---

### Task 4: Implement deterministic Skill Router and Policy Gate

**Files:**
- Create: `agent/router/router.py`
- Create: `agent/policy/policy.py`
- Create: `agent/policy/default-policy.json`
- Create: `tests/agent/test_router.py`
- Create: `tests/agent/test_policy.py`

**Interfaces:**
- `route(task_packet: dict, handoff: dict, registry: dict) -> dict`
- `authorize(route_result: dict, task_packet: dict, policy: dict) -> dict`

- [ ] **Step 1: Write router tests for known states**

Required cases:

- new source/fork/package-source change -> `core.research-reuse-gate`
- build failure -> `core.systematic-debugging`
- VERIFIED build + FAILED real-device -> `core.systematic-debugging`, never restart requirements/architecture
- VERIFIED candidate requiring device update -> `arthur.auto-flash`
- real-device PASS -> `arthur.release`
- unknown/high-risk transition -> BLOCKED

- [ ] **Step 2: Write policy tests**

A Skill cannot grant itself network, Git, device or write privileges. Project policy must be able to deny an otherwise valid route. Unknown permission/risk is denied.

- [ ] **Step 3: Run RED, implement minimal router/policy, run GREEN**

Use deterministic state transitions first. Keep GPT semantic classification outside the v0.1 unit-test core; TaskPacket arrives normalized from the orchestrator.

- [ ] **Step 4: Commit**

Commit router/policy and tests.

---

### Task 5: Implement Evidence Store and HANDOFF/Resume

**Files:**
- Create: `agent/evidence/store.py`
- Create: `agent/state/handoff.py`
- Create: `agent/state/status.py`
- Create: `tests/agent/test_evidence.py`
- Create: `tests/agent/test_handoff.py`
- Create: `production/agent-handoff.json`

**Interfaces:**
- `append_evidence(record: dict, root: Path) -> Path`
- `load_handoff(path: Path) -> dict`
- `transition(handoff: dict, event: dict) -> dict`

- [ ] **Step 1: Write resume tests**

Simulate `Build=VERIFIED`, `Candidate=VERIFIED`, `Flash=DONE`, `RealDevice=FAILED`. Expected next route is debugging of the failed/affected stage, preserving prior VERIFIED stages.

- [ ] **Step 2: Add interruption/restart test**

Persist HANDOFF, instantiate a new process, reload it, and prove `current_stage`, immutable verified stages, evidence pointers and rollback target survive restart.

- [ ] **Step 3: Implement append-only evidence and atomic HANDOFF writes**

Use temporary-file + replace semantics so interruption cannot leave partial JSON.

- [ ] **Step 4: Run GREEN and commit**

---

### Task 6: Add Arthur adapters without duplicating v4 build logic

**Files:**
- Create: `agent/adapters/arthur.py`
- Create: `agent/adapters/commands.json`
- Create: `tests/agent/test_arthur_adapter.py`
- Modify: `scripts/classify-build-scope.sh` only if needed to classify new `agent/`, `skills/` and framework state as FAST_GATE.
- Modify: `tests/test-classify-build-scope.sh` correspondingly.

**Interfaces:**
- `classify_change(paths: list[str]) -> str`
- `build_command(scope: str) -> list[str]`
- `baseline_gate_command() -> list[str]`
- `real_device_verify_command() -> list[str]`

- [ ] **Step 1: Write adapter tests against existing command names**

The adapter must point to existing baseline/routing/build assets and never inline-copy their logic.

- [ ] **Step 2: Run RED and implement adapter**

Fail closed if an expected existing script/workflow binding is missing.

- [ ] **Step 3: Update classifier only for framework-control-plane paths**

`agent/**`, `skills/**`, relevant framework tests/docs should be FAST_GATE unless a project config/firmware file also changes.

- [ ] **Step 4: Run existing classifier and v4 dry-run regression suites**

Existing routing semantics must stay unchanged.

- [ ] **Step 5: Commit**

---

### Task 7: Synchronize the repository to the approved Arthur automatic-flash policy

**Files:**
- Modify: `AGENTS.md`
- Modify: `knowledge/OPENWRT-PRODUCTION-V4.md`
- Modify: `production/v4-state.json`
- Create: `production/arthur-flash-method.schema.json`
- Create at implementation time only after evidence is found: `production/arthur-flash-method.json`
- Create: `tests/test-arthur-flash-policy.sh`

**Interfaces:**
- Produces verified machine-readable flash-method metadata containing device/profile, transport=`windows-openssh`, uploader=`ssh.exe`, remote upgrader=`/sbin/sysupgrade`, verified invocation/argument representation, evidence source, rollback method and verification timestamp.

- [ ] **Step 1: Write policy test**

Test must reject `HUMAN_REVIEW_GATE`, reject statements that standard sysupgrade requires manual confirmation, and require automatic standard sysupgrade after safety PASS while keeping raw-write methods forbidden.

- [ ] **Step 2: Locate historical verified invocation evidence before writing metadata**

Search repository history and the local production runner/worktree evidence for the successful Arthur PowerShell/`ssh.exe`/`sysupgrade` run. Use repository search plus local PowerShell text/history/log search. Record exact verified invocation semantics; do not infer flags from generic OpenWrt documentation.

- [ ] **Step 3: If exact verified invocation evidence is absent, mark `verified_flash_method=BLOCKED` and keep real-flash E2E disabled**

This is an automated evidence gate, not a human confirmation gate. Framework implementation and dry-run tests continue; real flash does not.

- [ ] **Step 4: If evidence exists, create `production/arthur-flash-method.json` and synchronize the three stale policy/state files**

Set the REAL_DEVICE lane to automatic standard sysupgrade subject to AUTO_FLASH_SAFETY_GATE. Preserve prohibitions on MTD/U-Boot/bootloader/dd/raw storage writes.

- [ ] **Step 5: Run policy test and commit**

---

### Task 8: Implement AUTO_FLASH_SAFETY_GATE

**Files:**
- Create: `scripts/arthur-auto-flash-safety.ps1`
- Create: `tests/arthur-auto-flash-safety.Tests.ps1`
- Create: `agent/skills/projects/arthur-auto-flash.json`

**Interfaces:**
- `arthur-auto-flash-safety.ps1` outputs JSON with `status=PASS|BLOCKED`, predicate evidence, selected candidate and flash-method id.

- [ ] **Step 1: Write Pester-compatible or standalone PowerShell tests**

Cover PASS and fail-closed cases for: device identity, model/MAC, target/profile, storage layout, candidate existence, cloud/local hash, rollback artifact/hash, Known-Good status, required plugins/themes/LAN metadata, device health and verified flash-method metadata.

- [ ] **Step 2: Implement safety gate without performing a write**

Safety script is pure validation. It never calls sysupgrade.

- [ ] **Step 3: Verify hash mismatch and unknown identity both BLOCK**

- [ ] **Step 4: Commit**

---

### Task 9: Implement Arthur automatic standard sysupgrade executor

**Files:**
- Create: `scripts/arthur-auto-flash.ps1`
- Create: `tests/arthur-auto-flash.Tests.ps1`
- Create: `agent/adapters/arthur_flash.py`

**Interfaces:**
- PowerShell parameters consume candidate path, safety-gate JSON and verified flash-method metadata.
- Executor returns phase records: `UPLOAD`, `REMOTE_HASH`, `SYSUPGRADE_STARTED`, `WAIT_DEVICE`, `RECOVERED` or fail-closed status.

- [ ] **Step 1: Write tests with mocked `ssh.exe`**

Tests must prove: no upload/sysupgrade on safety BLOCKED; upload occurs before remote hash; hash mismatch blocks sysupgrade; sysupgrade invocation is loaded from verified metadata; expected SSH disconnect transitions to WAIT_DEVICE rather than generic failure.

- [ ] **Step 2: Implement executor**

Use Windows OpenSSH `ssh.exe`/supported copy transport as recorded by the verified method. Never synthesize sysupgrade flags. No confirmation prompt after safety PASS.

- [ ] **Step 3: Implement WAIT_DEVICE bounded reconnect loop**

On recovery, verify device identity again before reporting RECOVERED.

- [ ] **Step 4: Run mocked tests and commit**

---

### Task 10: Bind automatic real-device verification and release blocking

**Files:**
- Create: `agent/skills/projects/arthur-real-device-verify.json`
- Create: `agent/skills/projects/arthur-release.json`
- Create: `tests/agent/test_arthur_release_gate.py`
- Modify existing real-device verification script only if necessary to emit structured JSON; preserve its checks.

**Interfaces:**
- Real-device result includes identity, LAN, SSH, LuCI port 80, language, Argon rendered default, Kucat renderable, 22/22 plugins, DHCP, WAN, DNS, services, storage/overlay, boot log and hash/provenance.

- [ ] **Step 1: Write release-blocking tests**

Cases: GitHub build PASS + Argon FAIL -> RELEASE BLOCKED; all PASS -> release eligible; unknown check -> BLOCKED.

- [ ] **Step 2: Adapt verifier output to structured evidence**

Do not weaken existing checks to make the test pass.

- [ ] **Step 3: Route FAIL to debugging/HANDOFF and PASS to release**

- [ ] **Step 4: Commit**

---

### Task 11: Add controlled Skill Finder evaluation path

**Files:**
- Create: `agent/discovery/finder.py`
- Create: `agent/discovery/reuse_gate.py`
- Create: `tests/agent/test_skill_finder.py`
- Create: `agent/discovery/candidate.schema.json`

**Interfaces:**
- `normalize_candidates(raw_results) -> list[dict]`
- `assess_candidate(candidate: dict) -> dict` producing `USE|REUSE|FORK|BUILD|REJECT` recommendation plus license/maintenance/security/permissions evidence.

- [ ] **Step 1: Write tests proving discovery cannot install or execute**

No discovery result may set registry approval directly. Missing license/source/permission metadata prevents approval.

- [ ] **Step 2: Implement provider-neutral normalization**

Network search is performed by the host agent/tooling; this module stores and evaluates structured candidate metadata without embedding credentials or a new crawler.

- [ ] **Step 3: Connect approved result to writing-skills workflow**

If a candidate is FORK/BUILD or needs a local wrapper, route to `vendor.writing-skills` for skill-level RED/GREEN/REFACTOR creation/evaluation; approval remains a separate registry action.

- [ ] **Step 4: Commit**

---

### Task 12: Run framework regression and synthetic end-to-end tests

**Files:**
- Create: `tests/test-agent-framework-e2e.sh`
- Create: `tests/fixtures/agent/*.json`

**Interfaces:**
- End-to-end dry runner consumes TaskPacket + fixture state and prints selected Skills/transitions without touching router/build/device unless explicitly enabled.

- [ ] **Step 1: Add required synthetic scenarios**

1. RealDevice FAILED resumes at debugging and preserves earlier VERIFIED stages.
2. Restart reloads HANDOFF.
3. CI/build PASS but theme verify FAIL blocks release.
4. SHA mismatch blocks automatic flash.
5. Unknown device blocks automatic flash.
6. Fully verified fixture routes automatically from candidate -> flash -> WAIT_DEVICE -> verify -> release.

- [ ] **Step 2: Run all new Python/shell/PowerShell mocked tests**

- [ ] **Step 3: Run existing v4 baseline, classifier and dry-run tests**

No existing regression is allowed.

- [ ] **Step 4: Run secret scan and diff review**

No credentials, private keys or device secrets may be committed.

- [ ] **Step 5: Commit**

---

### Task 13: Run one minimal real Arthur Pilot E2E

**Files:**
- Update only runtime/evidence/HANDOFF state generated by the pilot; do not mutate frozen Known-Good until release promotion rules pass.

**Interfaces:**
- Consumes a minimal safe candidate and verified flash-method metadata.
- Produces real evidence from build/artifact checks, safety gate, automatic sysupgrade, recovery, real-device verification and release decision.

- [ ] **Step 1: Select a minimal safe Candidate change and run Baseline Integrity + Change Impact**

The change must not exist solely to test destructive behavior; use a legitimate low-risk configuration/package/UI correction already needed by the project if available.

- [ ] **Step 2: Build through the smallest validated v4 lane**

Artifact, SHA256 and required package/theme/config gates must pass.

- [ ] **Step 3: Run AUTO_FLASH_SAFETY_GATE**

PASS continues automatically. BLOCKED stops with evidence and routes to the responsible failed prerequisite, without requesting a manual flash confirmation.

- [ ] **Step 4: Automatically execute the verified Arthur standard sysupgrade path**

PowerShell -> `ssh.exe` -> upload -> remote SHA256 -> `/sbin/sysupgrade` -> WAIT_DEVICE.

- [ ] **Step 5: Automatically run real-device verification**

Any failed acceptance check blocks release and enters the repair loop.

- [ ] **Step 6: Promote only after Release Gate PASS**

Update Stable/Known-Good only using existing promotion semantics.

- [ ] **Step 7: Commit durable framework state/docs only after verification**

Do not commit transient logs, credentials or firmware build directories.

---

### Task 14: Final verification and merge readiness

**Files:**
- Modify: `docs/` framework/operator documentation only as required by actual implementation.
- Update: `production/skill-framework-state.json` to VERIFIED only after all required tests and Arthur Pilot criteria pass.

**Interfaces:**
- Final state must expose framework version, approved Skills, vendor capability versions/bindings, pilot result, last evidence pointers, rollback target and disable switch.

- [ ] **Step 1: Run complete test matrix**

All framework tests plus existing Arthur control-plane tests must pass.

- [ ] **Step 2: Verify frozen Known-Good and rollback integrity**

No unintended tag, hash, plugin or baseline mutation.

- [ ] **Step 3: Verify disable path**

With Skill Framework disabled, the pre-existing Arthur production pipeline still runs its original control-plane path.

- [ ] **Step 4: Review commits and open PR**

PR must clearly separate framework core, Arthur adapter/policy synchronization and real-device E2E evidence.

- [ ] **Step 5: Merge only after review and verification evidence are complete**
