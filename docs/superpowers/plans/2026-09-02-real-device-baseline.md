# Arthur Real-Device Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. Follow test-driven development for every behavior change.

**Goal:** Make the currently running physical JDCloud RE-SS-01 with XinZhaoWrt 0.1.3 the authoritative development baseline for all future Arthur changes, while preserving the historical v0.1.0 rollback until 0.1.3 provenance is formally reconciled.

**Architecture:** Add a machine-readable `production/real-device-baseline.json`, a read-only snapshot path, and reusable baseline/version/access-classification helpers. The existing `CHANGE_IMPACT_GATE`, `BASELINE_INHERITANCE_GATE`, `EXPECTED_DIFF_GATE`, Production Agent, and AUTO_FLASH_SAFETY_GATE consume that authority. No new release controller is introduced. Normal forward Candidates older than the active physical baseline are blocked before upload/flash; explicit rollback assets remain separately allowed.

**Tech Stack:** PowerShell 7/Windows OpenSSH for the physical device path, JSON state files, existing GitHub Actions Windows contract CI, existing shell/static project gates.

**Spec:** `docs/superpowers/specs/2026-09-02-real-device-baseline-design.md`

## Global constraints

- Work only on `design/real-device-baseline` until verification is green.
- Do not flash or otherwise write the physical router during implementation.
- Preserve `production/known-good.json` and its `v0.1.0` rollback until Phase B promotion evidence exists.
- Do not weaken target/profile/storage/SHA256 checks or raw-write prohibitions.
- Physical 0.1.3 is the bootstrap development reference; user-observed uptime >24h is evidence for choosing it, not a substitute for machine snapshot/provenance.
- Current v0.1.2 Candidate run 33570985102 must never auto-flash over physical 0.1.3 as a normal forward Candidate.

### Task 1: Add failing real-device baseline contract tests

**Files:** Create `tests/real-device-baseline.tests.ps1`; modify `.github/workflows/production-agent-ci.yml` only after RED is observed if needed to execute the test.

- [ ] Assert `production/real-device-baseline.json` exists and names physical version 0.1.3, JDCloud RE-SS-01, qualcommax/ipq60xx, and bootstrap machine-verification state.
- [ ] Assert reusable helpers classify `DEVICE_UNREACHABLE`, `SSH_AUTH_FAILED`, and `DEVICE_IDENTITY_MISMATCH` separately.
- [ ] Assert normal 0.1.2 < baseline 0.1.3 is rejected while 0.1.3/0.1.4 are allowed and explicit rollback is exempt from forward ordering.
- [ ] Assert Production Agent consumes the real-device baseline and does not use `UNKNOWN_DEVICE_IDENTITY` as the generic access failure.
- [ ] Assert safety gate verifies the rollback file against `known-good.rollback.sha256`, not the unrelated top-level known-good digest.
- [ ] Observe the test failing for the missing implementation.

### Task 2: Implement baseline model and pure helper functions

**Files:** Create `production/real-device-baseline.json`, `production/expected-diff.json`, `scripts/real-device-baseline-lib.ps1`.

- [ ] Record physical 0.1.3 bootstrap identity and operator evidence without fabricating firmware SHA256/provenance.
- [ ] Keep `machine_verified=false`/bootstrap-pending status until a read-only snapshot succeeds.
- [ ] Implement semantic-version parsing/comparison and forward-candidate ordering.
- [ ] Implement SSH probe classification and exact Arthur board identity predicate.
- [ ] Run focused contract test to GREEN.

### Task 3: Implement the read-only physical snapshot

**Files:** Create `scripts/real-device-snapshot.ps1`; extend `tests/real-device-baseline.tests.ps1`.

- [ ] RED: require the snapshot script to contain only read-only remote commands and to write runtime evidence under `output/real-device/`.
- [ ] Implement network reachability probe, non-interactive SSH auth probe, board identity verification, system/build metadata, LAN, Wi-Fi state without plaintext keys, installed packages, themes/LuCI, iStore/QuickStart, AdGuard Home state, storage/overlay health, and uptime/health evidence.
- [ ] Produce deterministic JSON evidence without modifying the router or committed baseline automatically.
- [ ] GREEN: syntax and contract tests pass.

### Task 4: Enforce expected-diff and version/baseline inheritance before flash

**Files:** Create `scripts/real-device-baseline-gate.ps1`; modify `scripts/production-agent.ps1`, `scripts/auto-flash-safety-gate.ps1`, `production/production-agent.json`, `tests/production-agent.tests.ps1`, `tests/verified-baseline-inheritance.tests.ps1`.

- [ ] RED: test current v0.1.2 Candidate is blocked before upload/flash and access failures are retryable.
- [ ] Add baseline path/expected-diff path to Production Agent config.
- [ ] Make access classification retry `DEVICE_UNREACHABLE` and `SSH_AUTH_FAILED`; hard-block only true `DEVICE_IDENTITY_MISMATCH` plus existing irreversible/rollback safety classes.
- [ ] Invoke read-only snapshot/baseline gate before candidate upload.
- [ ] Gate target/profile/LAN, product version ordering, required plugin/theme/static defaults, AdGuard Home default state, iStore/QuickStart expectations, and declared expected changes.
- [ ] Correct rollback hash validation to `known-good.rollback.sha256`.
- [ ] GREEN: Windows contract CI passes.

### Task 5: Align future version source with physical 0.1.3

**Files:** Modify `VERSION`, `build.env`, `config/arthur.config`; extend baseline tests.

- [ ] RED: require all three version sources to resolve to 0.1.3.
- [ ] Update version sources to 0.1.3 so the next normal Candidate cannot be generated as an accidental downgrade.
- [ ] Do not start a build as part of this migration.
- [ ] GREEN: version consistency tests pass.

### Task 6: Reconcile policy and knowledge sources

**Files:** Modify `AGENTS.md`, `production/release-policy.md`, `knowledge/DEVICE-PROFILE.md`, `knowledge/PROJECT-STATE.md`, `knowledge/KNOWN-GOOD.md`.

- [ ] Declare live verified physical evidence and `production/real-device-baseline.json` as development-baseline authority.
- [ ] Clearly distinguish active physical development baseline 0.1.3 from formally promoted historical Known-Good/rollback.
- [ ] Reconcile stale no-auto-flash text: standard Arthur sysupgrade is automatic only after the full safety gate; raw/boot-critical writes remain prohibited.
- [ ] Record normal version downgrade prohibition and explicit rollback exception.

### Task 7: Wire CI and verify the migration

**Files:** Modify `.github/workflows/production-agent-ci.yml`, `.github/workflows/production-agent-deploy.yml`, `scripts/verify-project.sh` if appropriate.

- [ ] Parse new PowerShell scripts in CI and execute new contract tests.
- [ ] Ensure deployment watches baseline/gate/test paths when changes later reach main.
- [ ] Run/fetch PR CI and require all focused tests green.
- [ ] Inspect PR diff for unintended production writes, raw flash commands, plaintext secrets, or rollback deletion.
- [ ] Keep PR draft until verification is complete; do not merge automatically without explicit completion review.
