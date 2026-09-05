# 新肇网络Wrt-京东云亚瑟固件 — Codex project rules

## Project identity

- Official Chinese name: 新肇网络Wrt-京东云亚瑟固件
- Internal firmware ID: XinZhaoWrt
- Device: JDCloud RE-SS-01 / Arthur
- SoC: Qualcomm IPQ6000
- OpenWrt target: qualcommax/ipq60xx
- Device profile: jdcloud_re-ss-01
- 64G means eMMC capacity only. Never create a fake `jdcloud_re-ss-01-64g` target.
- Upstream: VIKINGYFY/immortalwrt
- Default branch: main

Read `build.env` before changing build logic.

## Agent Knowledge Layer

For every non-trivial firmware task, do not begin by re-deriving the project from old chat context or loading every repository document.

Required startup sequence:

1. read `production/operator-intent.json` first and classify the current operator scope. A **state statement is not execution authorization**. **Authorization is scope-bound**: `GOVERNANCE_RULES_ONLY`, status/read-only work, diagnostics, or state correction must never unlock firmware mutation. Firmware execution requires the durable combination `intent_type=EXECUTE_FIRMWARE`, `authorization_scope=FIRMWARE_RELEASE`, and `firmware_execution_authorized=true`; ambiguity fails closed;
2. read `production/resume-state.json`. It is the only repository snapshot allowed to name the **current execution checkpoint and next action**. If `status != RESUME_SAFE` or `instruction_allowed != true`, do not invent or emit a Codex next-action instruction; preserve the conflict evidence and reconcile state, but do not turn reconciliation into firmware execution unless the operator-intent file explicitly authorizes firmware execution;
3. validate and read `production/firmware-events.jsonl`. It is the append-only historical event ledger. Use it to establish what actually happened and in what absolute-time order; never reconstruct completed stages from chat when the ledger exists;
4. run the equivalent of `scripts/arthur-firmware-resume.ps1` before asserting a concrete current firmware stage, proposing a next firmware action, or mutating the release task. A `RESUME_GATE_CONFLICT` result fails closed;
5. verify live Git branch/effective HEAD and relevant GitHub workflow/release state, and confirm they are compatible with the resume snapshot and event ledger;
6. read `knowledge/PROJECT-STATE.md` only as project/routing context; its historical version/Candidate sections are auxiliary and may not override the reconciled machine state;
7. read `knowledge/INDEX.md` and route the task to only the relevant knowledge/documents;
8. for device/target work, read `knowledge/DEVICE-PROFILE.md`;
9. for baseline/update work, read `production/real-device-baseline.json`, `knowledge/KNOWN-GOOD.md` and `knowledge/SOURCE-LOCK.md`;
10. on a failure, classify the first causal error and consult `knowledge/KNOWN-FAILURES.md` before inventing a repair;
11. before changing an upstream/feed/package source, adopting a fork, or creating a new compatibility patch/build component, execute `knowledge/REUSE-GATE.md` and record `USE / REUSE / FORK / BUILD`.

The durable intent/recovery contract is `production/GPT-FIRMWARE-EXECUTION-RULES.md`. When a user says where the firmware currently is, treat that as state correction unless the same instruction explicitly authorizes firmware execution. A short follow-up such as “开始 / 执行 / 继续” inherits only the unambiguous current task scope; it must not leak authorization from governance work into firmware repair, Build, Flash, or Release. Relative words such as “今天/昨天/刚才” are presentation only; machine ordering uses ISO 8601 timestamps from the event ledger and external evidence.

Current-state precedence is fixed: **explicit current operator state correction → live device/build evidence → `production/resume-state.json` structured reconciliation → validated `production/firmware-events.jsonl` history → AI Orchestrator runtime checkpoint → current GitHub HEAD/workflow evidence → HANDOFF/project docs → chat/model narrative**. `production/v4-state.json`, old Candidate text, historical `knowledge/PROJECT-STATE.md` sections and prior chat messages must never downgrade the accepted physical development baseline or roll a verified checkpoint backward.

`production/known-good.json` remains the machine-readable authority for the last promoted real-device-confirmed Stable/rollback reference. `config/arthur-known-good.lock` remains the authority for pinned source/feed/plugin refs. These Stable/lock authorities do not replace the current execution pointer in `production/resume-state.json` or the historical evidence in `production/firmware-events.jsonl`.

After a new failure is genuinely fixed and verified, update `knowledge/KNOWN-FAILURES.md`. After a Candidate is promoted, update the project state/known-good knowledge to match the new machine-readable Stable record.

## Reuse Gate hard rule

`knowledge/REUSE-GATE.md` is a prospective source/implementation decision gate. It does not create a new firmware workflow and does not supersede the current Known-Good/Candidate/Stable gates.

- Do not move `config/arthur-known-good.lock`, invalidate `production/known-good.json`, restart an active Candidate, or revert current `main` progress merely because this rule was introduced.
- Rebuilding the exact current locked baseline does not require a new Reuse Gate.
- Apply the gate when a task changes upstream, feeds, third-party package sources, forks, patch strategy or build-system components.
- Search official OpenWrt/ImmortalWrt sources first, then same-device/same-target recent successful GitHub Actions baselines, then maintained package upstreams/forks.
- Evaluate actual target/kernel/branch compatibility, recent CI/build status, license, maintenance, dependency health, security, source provenance, 22-plugin compatibility and long-term maintenance cost.
- Star count is supporting evidence only.
- No explicit `USE / REUSE / FORK / BUILD` decision means no new source/fork/custom compatibility implementation should be adopted.
- The gate never authorizes dropping a mandatory plugin or weakening acceptance criteria to get a green build.

## Frozen RELEASE-FIRST automation baseline

This section is a frozen project-level development rule. Do not rename, replace, bypass or redesign this control model unless the user explicitly requests a change to the development standard.

- The only primary workflow is `RELEASE-FIRST AUTOMATION MODE`.
- The only successful terminal state is `PRODUCTION_RELEASED`.
- The frozen production order is: recover current release state → determine minimum change scope → `CHANGE_IMPACT_GATE` → `BASELINE_INHERITANCE_GATE` → `EXPECTED_DIFF_GATE` → choose the fastest reliable build path (`ImageBuilder` / `SDK` / `Full Build`) → Build → artifact/SHA256/flash-manifest/config/plugin/theme checks → `AUTO_FLASH_SAFETY_GATE` → Windows PowerShell → OpenSSH `ssh.exe` upload → remote SHA256 → previously verified Arthur `/sbin/sysupgrade` → `WAIT_DEVICE` → `REAL_DEVICE_VERIFY` → Release Gate → GitHub Release → `PRODUCTION_RELEASED`.
- Do not invent, insert, rename, reorder or promote a new Gate, Agent, Controller, Runtime stage or workflow stage inside that frozen production order unless the user explicitly changes the development standard. The unified resume/event reconciliation is a pre-action state integrity check, not a new production stage. Ideas for future improvement must remain non-blocking suggestions and must not alter an active release.
- Before proposing or executing a next action, `production/operator-intent.json` must authorize that exact scope, `production/resume-state.json` must be `RESUME_SAFE` with `instruction_allowed=true`, `production/firmware-events.jsonl` must validate, and `scripts/arthur-firmware-resume.ps1` (or its exact equivalent) must return `RESUME_GATE_SAFE`; then reconcile the live current stage, the next stage permitted by this frozen order, and the proposed action. If they do not match, do not execute the action.
- If repository documents or defaults conflict with current machine-readable/product targets, do not guess. Reconcile the conflicting source of truth before starting a new Candidate build; live verified device/build evidence and explicit current product requirements override stale text.
- The automation control plane must keep one Arthur release task as a single, continuous and recoverable execution chain. It must not spend extended time recovering or optimizing Codex, Bridge, Runtime, Supervisor or Skill while the real firmware release is stalled.
- GPT, Codex, Bridge, Runtime, Supervisor and Skill are supporting components only. None of them may become the release workflow owner.
- Skill may provide local auxiliary capabilities only; it must not take over firmware pipeline orchestration.
- Bridge is limited to GPT ↔ Codex dispatch. Runtime and Supervisor are limited to execution, guarding and recovery.
- When a supporting component fails, apply the smallest repair needed to restore the real firmware task, then immediately return to the release pipeline. Do not turn a component failure into a new automation-platform project.
- The recovery target is the Arthur release task itself, not a specific Codex process or thread. After a computer restart, Codex crash, network interruption or controller failure, recover from durable `HANDOFF`/state plus live GitHub, artifact and device evidence, and continue from the last valid checkpoint.
- Completed or `VERIFIED` stages must not be repeated without evidence that their result is invalid. Reuse an existing GitHub build if it is still valid. Reuse an already verified artifact. If sysupgrade may already have started, reconcile the real device state before taking any further write action; never blindly flash again.
- After any Build that successfully produces an Arthur firmware image plus its local SHA256/manifest evidence, persist that exact output immediately as an immutable quarantine Candidate artifact before later Acceptance checks can discard it. A failure caused only by Acceptance logic, validation text, controller logic or another non-firmware check must reuse and revalidate the same quarantine Candidate instead of rebuilding. Rebuild is permitted only when evidence shows that the Candidate bytes, SHA256, target/profile, source/build provenance, required config/plugins/themes, or another firmware-affecting property is invalid or no longer compatible.
- `CHANGE_IMPACT_GATE` must choose the shortest reliable build path for future releases. For same-device/same-target work with compatible source lock and toolchain, prefer ImageBuilder, SDK/package-only rebuilds, source reuse and valid compiler/download caches when those paths can prove the required output. Full Build is a fallback when the change impact or verification evidence requires it; do not mechanically hard-code `REUSE_SOURCE=0`, `JOBS=2`, or a fresh Full Build for every incremental change. Build concurrency must be selected from runner CPU/RAM constraints, and caches must be compatibility-keyed to target/subtarget, source lock, feeds/toolchain and relevant package/config manifests so incompatible state is never reused.
- The two build-efficiency rules above are adopted for subsequent release work only. They must not modify, cancel, restart, replace or delay an Arthur Candidate/Run that was already active when the rules were introduced. Implement any workflow/script changes needed to realize them only after the current active Arthur release has reached `PRODUCTION_RELEASED`.
- Do not create probe workflows, Bridge E2E tests, recovery experiments, parallel writers or new orchestration architectures inside an active Arthur production release unless a new, concrete release blocker cannot be removed by a minimal repair.
- If the same failure is retried with the same fingerprint and `last_progress` does not advance, trigger a circuit breaker. Stop repeating the same `resume`/`relaunch` method and switch to a clean execution or another minimal release-unblocking repair.
- Every proposed action must pass one fixed test: does it move the current Arthur firmware more quickly and safely toward `PRODUCTION_RELEASED`? If not, do not perform it during the active release.
- Live firmware progress has priority over platform cleanup. Automation-platform improvements are lower priority and must never block the current production release.

## Approved LIVE_PREVIEW development lane

The user has explicitly approved `LIVE_PREVIEW` as a permanent pre-Candidate development aid for Arthur and future OpenWrt devices that define their own device policy. This lane restores the useful 0.1.3-style fast real-router preview without changing the frozen production order after source freeze.

- Read `knowledge/LIVE-PREVIEW.md` and `production/live-preview-policy.json` before using the lane.
- Preferred loop for preview-safe changes: `edit -> static tests -> LIVE_PREVIEW -> authenticated live check -> fix -> LIVE_PREVIEW`.
- `LIVE_PREVIEW` is not a Gate, Candidate, flash stage, formal real-device verification stage or release stage.
- `LIVE_PREVIEW=PASS` must always coexist with `REAL_DEVICE_VERIFY=NOT_RUN` and `RELEASE_ALLOWED=false`.
- Only allowlisted LuCI static resources, rpcd ACL files, LuCI menu files and explicitly approved QuickStart static mappings may be hot-deployed.
- Unknown or unmapped paths fail closed. A firmware-affecting path keeps its normal `ImageBuilder` / `SDK` / `Full Build` classification for the eventual Candidate even when a safe runtime subset is previewed.
- Current Arthur Wi-Fi is frozen as `WIFI=VERIFIED_FROZEN`. LIVE_PREVIEW must never mutate or reload wireless UCI, SSIDs, credentials, radios or Wi-Fi runtime.
- LIVE_PREVIEW must never mutate LAN/WAN, DHCP, firewall core configuration, system binaries, package databases, kernel/modules/drivers, bootloader, partitions, raw storage, Known-Good, Stable or Latest pointers.
- Before runtime mutation, back up every remote target to `/root/xinzhaowrt-live-preview/<timestamp>/`. Any failure after mutation begins must restore or remove the affected files, refresh LuCI/rpcd state as required, and emit `LIVE_PREVIEW=FAIL_ROLLED_BACK`.
- AdGuard/QuickStart preview checks must use authenticated LuCI access. AdGuard preview must finish with AdGuard Home stopped and disabled. QuickStart preview must prove the complete official homepage markers, not only package/socket presence.
- After preview acceptance, freeze source and return to the frozen RELEASE-FIRST production sequence. Only a newly built/flashed Candidate followed by formal `REAL_DEVICE_VERIFY=PASS` may enter Release Gate.

## Mandatory plugins

`config/required-plugins.txt` is the authoritative list. It contains exactly 22 required LuCI applications. Every one must remain `=y` after `make defconfig`.

Never fix a build by silently deleting, disabling, renaming or commenting out a requested plugin. If a plugin fails:

1. identify the first real compiler/package error;
2. verify source layout and dependencies;
3. check current ImmortalWrt/kernel API compatibility;
4. run the Reuse Gate when the repair would change package source/fork/patch strategy;
5. patch or update the package source only after that decision;
6. rerun `make defconfig` and `scripts/check-config.sh`;
7. rebuild.

## Required first-boot defaults

- LAN IP: 192.168.6.1
- administrator: root
- initial password: password

These defaults are implemented in `files/etc/uci-defaults/99-xinzhao-defaults` and checked by `scripts/check-defaults.sh`.
Do not change them unless the user explicitly requests a change.

The password is intentionally a known initial password. Documentation must tell users to change it immediately after first login.

## Source rules

Use standard ImmortalWrt feeds where the requested package exists. External packages are added by `scripts/add-custom-packages.sh`.
Avoid adding broad duplicate feeds just to make one package appear.

Current external source families:

- iStoreX / Store / QuickStart / QuickFile / Lucky: selected kenzok8 packages
- DiskMan: sbwml/luci-app-diskman
- EasyTier: EasyTier/luci-app-easytier
- MosDNS: sbwml/luci-app-mosdns v5 plus geodata dependency
- OpenClash: vernesong/OpenClash
- OAF: destan19/OpenAppFilter

Before replacing any of these source families, use `knowledge/REUSE-GATE.md`. Existing pinned refs remain authoritative until the normal update/fix acceptance path justifies a lock change.

## Build procedure

Before a long build:

```bash
./scripts/verify-project.sh
```

Before `make defconfig`, external sources must pass:

```bash
./scripts/check-package-sources.sh work/immortalwrt
```

Cloud build entrypoint:

```bash
./scripts/codex-cloud-build.sh
```

Do not stream a full OpenWrt build log into the conversation. The cloud build writes `output/logs/build.log`. On failure, use:

```bash
./scripts/extract-build-error.sh output/logs/build.log
```

Read only the relevant error area before deciding on a fix.

## Build success criteria

A build is not successful merely because `make` exits zero. Verify all of these:

- target remains `qualcommax/ipq60xx/jdcloud_re-ss-01`;
- all 22 mandatory plugin symbols remain enabled in `output/full.config`;
- at least one Arthur firmware image is present in `output/firmware/`;
- `output/build-info.txt` exists;
- `output/firmware/SHA256SUMS.local` exists;
- first-boot defaults file is included in the source `files/` overlay.

## Web server stack

QuickFile requires `luci-nginx`. This project therefore uses LuCI on Nginx as the primary web stack. Do not add the `luci` or `luci-ssl` meta collections unless there is a verified reason, because those select the default uhttpd stack and may create port conflicts with Nginx.

## Runtime coexistence notes

AdGuard Home, MosDNS, SmartDNS and OpenClash may all be compiled, but do not configure multiple services to bind the same DNS port 53 by default.
OpenClash and PBR may coexist as packages, but should not both be configured to own the same policy-routing flows.
OAF is kernel-facing and should be one of the first packages investigated after a major upstream kernel change.

## Safety and flashing boundary

Standard Arthur sysupgrade is part of the automated release path only when `AUTO_FLASH_SAFETY_GATE` is fully satisfied.

The verified automatic flashing method is:

`GitHub Actions build → candidate integrity/SHA256 verification → AUTO_FLASH_SAFETY_GATE → Windows PowerShell → OpenSSH ssh.exe upload → remote SHA256 verification → remote /sbin/sysupgrade using previously verified Arthur parameters → WAIT_DEVICE → real-device verification → Release Gate`.

Automatic standard sysupgrade is allowed only when all required safety evidence is positive, including exact device identity/model/target/profile/storage-layout match, candidate integrity, cloud/local/remote SHA256 consistency, required plugin/theme/config gates, healthy current device state, expected LAN configuration, and a verified Known-Good rollback artifact/path.

Never guess sysupgrade arguments. Reuse the project's previously verified Arthur upgrade parameters.

Raw or boot-critical write paths are outside automated flashing. Never automatically perform MTD, U-Boot, bootloader, `dd`, raw eMMC/SPI/NAND writes, partition-table changes, ART/EEPROM/calibration writes, or any equivalent raw-storage operation. These require explicit human authorization or remain prohibited according to the project safety policy.

If device identity, storage layout, rollback safety, candidate hash or flash state is unknown, stop automatic write actions and preserve evidence. If a previous sysupgrade may already have occurred, reconcile the real device before considering another flash.

## Git discipline

Before editing: `git status`.
After editing: `git diff`.
Never commit `work/`, `output/`, `build_dir/`, `staging_dir/`, `dl/`, `tmp/` or full build logs.
Use focused commit messages such as `fix: resolve OAF build compatibility` or `feat: add Arthur first-boot defaults`.
