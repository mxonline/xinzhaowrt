# Arthur Unattended Production Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Arthur firmware pipeline continue from a single user request through GitHub build, automatic failure remediation, artifact retrieval, safe sysupgrade, real-device verification, and release without manual PowerShell/Codex copy-paste between ordinary stages.

**Architecture:** GitHub Actions is the authoritative build plane. Existing `ci-controller-v3.ps1` remains the reusable repair engine for GitHub build failures; a new Windows Production Agent is the persistent local execution plane for artifact retrieval, release-state resumption, AUTO_FLASH_SAFETY_GATE, verified `ssh.exe` transfer/sysupgrade, WAIT_DEVICE, and real-device verification. State is durable and idempotent so process restarts resume the first incomplete gate instead of rebuilding successful work.

**Tech Stack:** PowerShell 7/Windows PowerShell, GitHub CLI, GitHub Actions, existing Codex CLI repair controller, OpenSSH `ssh.exe`, JSON state files.

**Spec:** `docs/superpowers/specs/2026-08-31-openwrt-pipeline-v4.3-design.md`

## Global Constraints

- `PRODUCTION_RELEASED` is the only final success state.
- GitHub Actions remains authoritative for normal compilation and artifact availability.
- A successful existing build/artifact must be reused; local bridge/runtime failure must never trigger a rebuild by itself.
- Build lane selection remains IMAGEBUILDER / SDK_BUILD+IMAGEBUILDER / FULL_BUILD according to impact.
- Standard Arthur automatic flashing is only the historically verified PowerShell -> `ssh.exe` -> remote SHA256 -> `/sbin/sysupgrade` path.
- Raw MTD, U-Boot/bootloader, `dd`, raw eMMC/SPI/NAND, ART/EEPROM writes remain prohibited.
- Device is JDCloud RE-SS-01, target/profile `qualcommax/ipq60xx` / `jdcloud_re-ss-01`.
- Expected LAN is `192.168.6.1`, LuCI HTTP port is `80`, default language is `zh_cn`, Argon is default theme, Kucat is second theme, AdGuardHome is installed but disabled by default, and the 22-plugin baseline is preserved.
- GitHub credential provisioning, unknown device identity, no safe rollback, and unrecoverable irreversible operations are the only human-stop classes.

---

### Task 1: Production Agent contract tests

**Files:**
- Create: `tests/production-agent.tests.ps1`
- Create: `.github/workflows/production-agent-ci.yml`

**Interfaces:**
- Consumes: `scripts/production-agent.ps1`, `scripts/install-production-agent.ps1`, `production/production-agent.json`.
- Produces: static/behavior contract that fails until the unattended agent exists.

- [ ] Assert the agent files/config exist.
- [ ] Assert the agent exposes `Resume`, `Status`, and `RunOnce` modes.
- [ ] Assert source contains explicit states `ARTIFACT_METADATA_VERIFIED`, `ARTIFACT_BYTES_VERIFIED`, `CANDIDATE_VERIFIED`, `AUTO_FLASH_SAFETY_GATE`, `WAIT_DEVICE`, `REAL_DEVICE_VERIFY`, `PRODUCTION_RELEASED`.
- [ ] Assert auth failure maps to `NEW_CREDENTIAL_PROVISIONING` and does not contain a rebuild action.
- [ ] Assert raw flash commands (`mtd`, `dd`, bootloader raw writes) are absent from the automatic path.
- [ ] Run on GitHub Actions and observe RED before implementation.

### Task 2: Durable artifact fetch/resume layer

**Files:**
- Create: `scripts/fetch-production-artifact.ps1`
- Create: `production/production-agent.json`
- Modify/Test: `tests/production-agent.tests.ps1`

**Interfaces:**
- Consumes: repository, run ID/artifact identity, destination, existing state.
- Produces: `output/production-agent/artifact-metadata.json`, `candidate-manifest.json`, and durable stage state.

- [ ] Use authenticated `gh` credential store; classify failed auth as `NEW_CREDENTIAL_PROVISIONING`.
- [ ] Download by immutable run/artifact identity with bounded transient retry.
- [ ] Reuse already verified bytes rather than redownload/rebuild.
- [ ] Discover one Arthur `*sysupgrade.bin`, record size/SHA256, and reject ambiguity/empty files.
- [ ] Preserve Run ID, artifact ID/name/digest, source SHA, and local candidate SHA256.

### Task 3: Windows Production Agent state machine

**Files:**
- Create: `scripts/production-agent.ps1`
- Create: `scripts/production-agent-status.ps1`
- Modify/Test: `tests/production-agent.tests.ps1`

**Interfaces:**
- Consumes: production-agent config, artifact fetch helper, known-good/rollback files, current GitHub run state.
- Produces: `output/production-agent/state.json`, `handoff.json`, `agent.log` and automatic continuation.

- [ ] Implement idempotent stages from artifact discovery through candidate gate.
- [ ] On build failure invoke/reuse the existing `ci-controller-v3.ps1` repair path rather than duplicating repair logic.
- [ ] On successful build resume artifact handling without requiring a local bridge PID.
- [ ] Persist state before/after each external action and recover after restart.
- [ ] Never interpret a dead Bridge/Supervisor as a reason to rebuild a successful GitHub run.

### Task 4: Flash profile and safety gate

**Files:**
- Create: `production/arthur-flash-profile.json`
- Create: `scripts/auto-flash-safety-gate.ps1`
- Modify: `scripts/production-agent.ps1`
- Test: `tests/production-agent.tests.ps1`

**Interfaces:**
- Consumes: candidate manifest, known-good rollback metadata, device identity evidence, machine-readable verified flash profile.
- Produces: `AUTO_FLASH_SAFETY_GATE=PASS` or a fail-closed machine-readable block.

- [ ] Validate model/target/profile, candidate completeness/SHA256, known-good rollback presence/SHA256, expected LAN, SSH reachability, and baseline gates.
- [ ] Flash profile may encode only a historically verified standard sysupgrade invocation; no guessed parameters are allowed.
- [ ] If no verified flash profile is present, remain fail-closed and emit evidence for remediation; do not substitute raw writes.
- [ ] On PASS, upload via Windows `ssh.exe`/`scp.exe`, verify remote SHA256, then execute only the verified `/sbin/sysupgrade` template.

### Task 5: WAIT_DEVICE, real-device verify, and repair loop

**Files:**
- Modify: `scripts/production-agent.ps1`
- Reuse: `scripts/real-device-verify.ps1`, `scripts/real-device-verify-v3.ps1`
- Test: `tests/production-agent.tests.ps1`

**Interfaces:**
- Consumes: flashed candidate SHA256 and router recovery.
- Produces: real-device report and either release or a batched repair request.

- [ ] Detect expected SSH disconnect after sysupgrade and enter WAIT_DEVICE.
- [ ] Wait for `192.168.6.1` and validate device identity before accepting recovery.
- [ ] Run existing real-device verifier and require LAN/SSH/LuCI/80/zh_cn/Argon/Kucat/DHCP/WAN/DNS/WiFi/22 plugins/QuickStart/ADG disabled/storage/boot log checks.
- [ ] Batch ordinary verification failures into one repair cycle through Codex controller, then rebuild/reflash/reverify.
- [ ] Keep safety/credential blocks distinct from repairable firmware failures.

### Task 6: One-time Windows installation bootstrap

**Files:**
- Create: `scripts/install-production-agent.ps1`
- Create: `scripts/uninstall-production-agent.ps1`
- Create: `scripts/start-production-agent.ps1`
- Test: `tests/production-agent.tests.ps1`

**Interfaces:**
- Consumes: repo path and current Windows user GitHub CLI credential store.
- Produces: a Scheduled Task running in the current user context with hidden/no-console execution and restart-on-failure behavior.

- [ ] Scheduled Task starts on logon and periodically ensures the agent is running.
- [ ] Use current user context so `gh auth` and SSH credentials are readable; never use LocalSystem for authenticated artifact fetch.
- [ ] Start/resume from durable state after Windows restart.
- [ ] Provide status/uninstall scripts, but routine operation requires no manual PowerShell.

### Task 7: CI verification and unattended E2E gate

**Files:**
- Modify: `.github/workflows/production-agent-ci.yml`
- Create/Modify: test fixtures under `tests/fixtures/production-agent/` only as needed.

**Interfaces:**
- Produces explicit gate markers.

- [ ] Verify unauthenticated simulation -> `NEW_CREDENTIAL_PROVISIONING`, no rebuild.
- [ ] Verify transient artifact failure -> retry/resume same run.
- [ ] Verify preverified candidate -> skip download/build and continue candidate gate.
- [ ] Verify failed build route references existing Codex repair controller.
- [ ] Verify raw flash paths are absent.
- [ ] Require CI markers: `AUTO_ARTIFACT_FETCH_CONTRACT=PASS`, `AUTO_REMEDIATION_CONTRACT=PASS`, `AUTO_FLASH_POLICY_CONTRACT=PASS`, `PRODUCTION_AGENT_RESUME_CONTRACT=PASS`.
- [ ] Only after these pass may the branch be considered ready for live unattended E2E on Arthur.
