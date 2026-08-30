# Agent Skill Framework v0.1 + Arthur Pilot Design

## Goal

Build a reusable development Skill Framework that can serve OpenWrt, Z-Blog, website, PHP/IIS, automation, video-system and future projects without replacing their existing proven execution pipelines. Arthur is the first pilot because it already has Known-Good, build routing, GitHub Actions, artifact gates, real-device verification and release state.

## Non-goals

- Do not rewrite the existing Arthur build pipeline.
- Do not invent a second Known-Good or release-state system.
- Do not make Arthur-specific rules part of the reusable Core layer.
- Do not allow a third-party Skill to bypass project policies, verification or release gates.
- Do not guess flash parameters or introduce raw MTD/U-Boot/dd/eMMC/NAND write paths.

## Architecture

User goal -> GPT Orchestrator -> Resume/Context Gate -> Skill Router -> Skill Contract -> Policy Gate -> GPT-Codex Bridge/runtime -> existing project executor -> Evidence -> Verification Gate -> Release Gate -> HANDOFF.

The framework is layered:

1. Core Skills: reusable across projects.
2. Domain Skills: OpenWrt, Z-Blog/PHP, website/UI, video, etc.
3. Project Skills: Arthur and future project-specific constraints.
4. Vendor Skills: audited third-party capabilities; never trusted implicitly.

## Three reusable third-party capabilities

### 1. Superpowers

Decision: REUSE.

Use the already available Superpowers development skills instead of reimplementing mature methods. Initial reusable capabilities include brainstorming, writing-plans, test-driven-development, systematic-debugging, verification-before-completion, using-git-worktrees, requesting-code-review, receiving-code-review and finishing-a-development-branch.

Superpowers supplies methods. It does not own project state, release policy, device safety, HANDOFF or project-specific routing.

### 2. Skill Creator / writing-skills

Decision: REUSE.

Use the existing `writing-skills` capability to create, edit and test local Skills. New reusable Skills must be developed with skill-level RED/GREEN/REFACTOR pressure tests before promotion to the approved registry.

It does not auto-promote a Skill to production. Registry approval still requires the framework's Reuse Gate, security checks, evals and versioning.

### 3. Skill Finder

Decision: REUSE CONCEPT / CONTROLLED DISCOVERY ADAPTER.

The current environment has no trusted installed Skill Finder plugin, so v0.1 implements a discovery-only adapter rather than pretending one is installed. It can search approved public ecosystems such as GitHub and documented Skill catalogs for candidate capabilities.

Hard rule: Skill Finder may discover and rank candidates, but it may not install, execute, grant permissions, edit the registry or replace an approved Skill automatically.

Discovery result -> Reuse Gate -> source/license/maintenance/security/permission review -> sandbox/eval -> APPROVED or REJECTED -> registry.

## Core framework components

### Skill Registry

Machine-readable catalog containing skill id, version, source, layer, trigger metadata, risk, permissions, implementation binding, eval status and approval status.

### Skill Contract

Every Skill declares:

- id and version
- trigger and non-trigger conditions
- required inputs
- preconditions
- allowed tools/permissions
- risk level
- procedure reference
- expected outputs
- evidence requirements
- verification contract
- failure behavior
- fallback/rollback behavior
- HANDOFF fields

### Skill Router

Use deterministic routing for known states and GPT semantic routing only where ambiguity remains. Unknown/high-risk states fail closed.

### Policy Gate

Policy is external to the Skill. A Skill cannot grant itself permissions. Project policy overrides vendor Skill behavior.

### Evidence Store

Every execution returns structured evidence, including commands/actions invoked, artifacts, hashes, test results, device checks, failures and affected stages.

### HANDOFF / Resume

State records current stage, status, verified stages, failed/blocked stage, immutable completed stages, evidence pointers, next skill, rollback target and last update. Resume must continue from the earliest affected stage rather than restarting the whole lifecycle.

### Release Gate

No completion claim or release solely from a green build. Release requires the project-specific verification contract.

## Arthur Pilot bindings

Arthur consumes generic Core Skills plus OpenWrt Domain Skills and Arthur Project Skills.

Initial pilot skills:

- core.research-reuse-gate
- core.systematic-debugging
- core.verification
- core.handoff-resume
- openwrt.change-impact
- openwrt.build
- arthur.auto-flash
- arthur.real-device-verify
- arthur.release

Existing `production/known-good.json`, `production/v4-state.json`, current classifiers, build scripts, tests and GitHub workflows remain authoritative where already proven.

## Arthur automatic flash policy

The current repository documentation still contains obsolete human-review flash language. The pilot must not inherit that stale policy. Before a real-device E2E test, repository policy/state must be synchronized to the currently approved automatic standard sysupgrade path.

When AUTO_FLASH_SAFETY_GATE passes, no human confirmation stop is permitted for the standard Arthur sysupgrade path.

Approved flow:

Candidate verified -> AUTO_FLASH_SAFETY_GATE -> PowerShell -> Windows OpenSSH `ssh.exe` -> upload candidate -> local/cloud/remote SHA256 equality -> execute the historically verified Arthur `/sbin/sysupgrade` invocation -> expected SSH disconnect -> WAIT_DEVICE -> reconnect -> automatic real-device verification -> PASS to Release Gate, FAIL to systematic-debugging and affected-stage retry.

The implementation must retrieve/reuse the previously verified Arthur sysupgrade invocation/parameters from real project evidence. It must never guess flags.

AUTO_FLASH_SAFETY_GATE must fail closed unless device identity, MAC/model, target/profile, storage layout, candidate integrity, hashes, required plugin/theme gates, LAN defaults, Known-Good rollback artifact, device health and safe rollback prerequisites are verified.

Raw MTD, bootloader, U-Boot, dd, raw eMMC/SPI/NAND writes remain outside this automatic path.

## Arthur verification contract

A candidate cannot release until real-device verification includes at minimum:

- correct JDCloud RE-SS-01 identity and target/profile
- LAN 192.168.6.1
- SSH
- LuCI reachable on default HTTP port 80
- simplified Chinese availability/default policy as required by project target
- Argon installed and actually rendered as default theme
- Kucat installed and renderable as secondary theme
- exact 22 mandatory baseline LuCI applications
- DHCP
- WAN
- DNS
- required system services
- storage/overlay health
- boot log checks
- firmware SHA256/provenance consistency

A failure blocks Release and routes to debugging; it must not be waived merely to produce a green release.

## State conflict rule

Live GitHub/build/device evidence outranks stale docs. Before v0.1 can perform a real flash, obsolete `HUMAN_REVIEW_GATE` and `AGENTS.md` wording must be reconciled with the approved automatic standard sysupgrade policy. Until that synchronization is verified, v0.1 may run routing/eval/dry-run tests but must not claim the automatic flash path is repository-enforced.

## Rollout

1. Build Core framework contracts/registry/router/policy/evidence/handoff in an isolated branch/worktree.
2. Reuse Superpowers and writing-skills; add controlled Skill Finder discovery adapter.
3. Add Arthur adapters without changing existing build semantics.
4. Run synthetic failure/resume/release-blocking tests.
5. Synchronize current Arthur automatic-flash policy and verified executor evidence.
6. Run one minimal safe Arthur E2E candidate through automatic flash and real-device verification.
7. Only after the pilot passes, generalize the framework to Z-Blog, website and video domains.

## Success criteria

- Core framework is project-agnostic.
- Existing Arthur Known-Good remains intact.
- Existing Arthur pipeline has zero regression.
- Superpowers and writing-skills are reused rather than duplicated.
- Skill Finder cannot auto-install or execute candidates.
- Router resumes from affected state instead of restarting completed verified stages.
- Policy Gate blocks unsafe/unknown execution.
- Automatic Arthur standard sysupgrade runs without human confirmation when all gates pass.
- Failed real-device verification blocks release and automatically enters the repair loop.
- Framework can be disabled without breaking the pre-existing Arthur production pipeline.
