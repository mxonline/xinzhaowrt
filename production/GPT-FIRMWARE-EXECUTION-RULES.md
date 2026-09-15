# Arthur GPT Firmware Execution Rules

This file is the durable operator/GPT contract for deciding whether a firmware action may be proposed or executed. It governs intent, release mode, state recovery, historical evidence, and authorization before the RELEASE-FIRST workflow is allowed to move.

## Hard rules

1. **A state statement is not execution authorization.** Messages such as “当前应该从 ADH 完整管理和中文开始”, “现在状态是…”, “记住这里”, “进度到这里” correct or describe state only. They must not trigger Codex, CI, Build, router writes, Release, repository mutation, or firmware repair.
2. **Authorization is scope-bound.** “开始”, “执行”, “继续” authorizes only the task that is unambiguously being discussed. Authorization for governance/rule work must never leak into firmware execution. Authorization for a diagnostic read must never leak into a repair. If scope is ambiguous, fail closed.
3. Read `production/operator-intent.json` before deciding whether any firmware execution is allowed.
4. Read `production/release-mode.json` before choosing a production route. New executions default to `RELEASE_ONLY`; unknown or missing mode fails closed.
5. `FIRMWARE_RELEASE` authorization authorizes the release task only. It never implies permission to upload to, flash, reboot, or otherwise write the router. In `RELEASE_ONLY`, `automatic_flash=false` is absolute.
6. Read `production/resume-state.json` for the current reconciled checkpoint and `production/firmware-events.jsonl` for historical event evidence. Historical chat, old project-state sections, and stale controller state are auxiliary only.
7. For any firmware status/next-step/execution prompt, run the equivalent of `scripts/arthur-firmware-resume.ps1` before naming a concrete stage or action. A concrete answer without a completed Resume Gate is not allowed.
8. No Codex firmware instruction may be emitted while `firmware_execution_authorized != true`, `authorization_scope != FIRMWARE_RELEASE`, or `intent_type != EXECUTE_FIRMWARE`.
9. A completed execution must never be reopened as the identity of a new release. After `PRODUCTION_RELEASED`, the next firmware production requires a fresh execution id and fresh execution-specific expected diff.
10. Completed/verified work is never repeated without invalidating evidence. `WIFI=VERIFIED_FROZEN` and other accepted capabilities stay frozen unless current requirements or evidence invalidate them.
11. On conflict, do not guess. Report/reconcile the conflicting sources before firmware execution. Version metadata conflict, source identity conflict, non-matching artifact/hash, and unknown release mode all fail closed.
12. **Machine time is absolute.** State/event evidence uses ISO 8601 timestamps with `Z` or explicit UTC offset. Relative date words such as `today` and “今天” are presentation only.
13. **The event ledger is append-only.** Existing `production/firmware-events.jsonl` lines must never be edited, reordered, or deleted; corrections are appended as new events.
14. **Windows Schannel credential-handle failures are transport failures, not operator credential gates.** `schannel: AcquireCredentialsHandle failed` and `SEC_E_NO_CREDENTIALS` are transport-recovery signatures. Use `scripts/arthur-git-remote.ps1`: Git read with OpenSSL fallback, then authenticated `gh api` read-only fallback. A successful fallback is degraded transport and must not create `NEW_CREDENTIAL_PROVISIONING`; only a real non-Schannel authentication/authorization failure may become a credential problem.

## Release mode contract

`production/release-mode.json` is the machine-readable route selector.

For `RELEASE_ONLY`:

- `unattended_release=true` permits routine safe phases to continue without human confirmation once a fresh execution is explicitly authorized;
- `automatic_flash=false` forbids automatic router writes and `sysupgrade`;
- `post_release_device_test=INDEPENDENT` means whole-device testing occurs after GitHub Release and cannot block Build/Release;
- `known_good_promotion_requires_post_release_device_test_pass=true` means a published Release cannot replace the previous real-device-confirmed rollback baseline until its exact firmware/hash passes the independent device test;
- `fail_closed_on_unknown=true` applies to release-mode, provenance, expected diff, target/profile and hash ambiguity.

`FLASH_AND_VERIFY` exists only to keep historical state and an explicitly authorized legacy device-write route parseable. It must never be selected implicitly from `FIRMWARE_RELEASE` authorization.

## Unified Gate and Evidence rule

For schema-v2 state, read `execution_id`, `gates`, `current_gate`, and `next_action` before compatibility summary fields. The Arthur Control Plane alone decides Gate status. `NO EVIDENCE -> NO PASS`; `NO PASS -> NO RELEASE`.

Accepted Gate evidence refs must be durable evidence-index references using the `evidence:<id>` form where the project Global Runtime Contract requires it. Historical human-readable ref strings may remain inside indexed evidence objects, but must not masquerade as valid gate evidence ids.

`STALE` means earlier evidence no longer proves the current source, artifact, product requirement or other subject identity. Only the affected dependency chain may be rerun. Evidence/state-only commits are control-plane changes and never justify a firmware rebuild.

## Required GPT/Codex startup sequence

For prompts such as “进度”, “下一步”, “继续”, “现在做什么”, “编译了吗”, “修 ADH”, “发布固件”, or “让 Codex 继续”, perform this sequence before executable action selection:

1. **Intent Gate** — read `production/operator-intent.json`; classify the message as state correction, status/read-only, governance/process, or explicit firmware execution.
2. **Release Mode Gate** — read and validate `production/release-mode.json`; determine `RELEASE_ONLY` or an explicitly authorized compatibility mode.
3. **Workflow Recovery** — read the effective Arthur phase order from `scripts/arthur-resume-state.ps1` / state-contract helpers and `production/release-policy.md`.
4. **Current-State Recovery** — read `production/resume-state.json`.
5. **Historical Recovery** — validate/read `production/firmware-events.jsonl`; never reconstruct completed stages from chat when the ledger exists.
6. **External Evidence** — verify effective Git HEAD and relevant GitHub workflow/artifact/release evidence. Remote-main verification must use the resilient `scripts/arthur-git-remote.ps1` path. Preserve returned remote SHA, verification method and degraded flag.
7. **State Reconciliation** — compare operator intent, execution id, machine checkpoint, verified-frozen items, source SHA, candidate/build identity, event chronology, Release evidence and current known-good authority.
8. **Authorization Check** — only explicit `EXECUTE_FIRMWARE + FIRMWARE_RELEASE + firmware_execution_authorized=true` can unlock a firmware release action. Router writes require separate explicit device-write authorization and can never be inferred in `RELEASE_ONLY`.
9. **Action Check** — the proposed action must match the effective phase order for the selected release mode. Otherwise stop and reconcile.

The canonical local implementation is `scripts/arthur-firmware-resume.ps1` plus the release-mode-aware state-contract helper. Resume inspection is read-only: it may inspect state/evidence but must not itself Build, flash, Release, mutate Stable/Known-Good, or advance a checkpoint.

## Event ledger contract

`production/firmware-events.jsonl` is append-only JSON Lines history. Each event contains an absolute ISO 8601 time, monotonic sequence, event name, stage, source, data, previous hash and current hash.

Typical historical events may include `BUILD_STARTED`, `CANDIDATE_ACCEPTED`, `FLASH_STARTED`, `REAL_DEVICE_VERIFIED`, `PRODUCTION_RELEASED`, and reconciliation events. Event names are evidence labels, not authorization.

If a past state was wrong, append a correction/reconciliation event. Do not rewrite history.

## Current terminal state rule

The v0.1.4 durable execution is already `PRODUCTION_RELEASED` and `firmware_execution_authorized=false`. Its `execution_id` is historical/audit identity only; it cannot be resumed into PRE_FLASH, Build, or a new Release.

Before a new release starts, reconcile live `main`, latest GitHub Release, `production/known-good.json`, root `VERSION`, source lock, and current product targets. If root `VERSION` is behind the published Release, that is a version-metadata conflict and must be corrected before dispatch; do not guess a next version.

## Canonical Arthur phase order

The legacy machine registry remains parseable for historical state:

`FORENSICS -> ADH_MANAGEMENT -> ADH_CHINESE -> CHANGE_IMPACT -> BASELINE_INHERITANCE -> EXPECTED_DIFF -> CONFIG -> PACKAGE -> PLUGIN_BASELINE_22 -> ARGON_KUCAT -> LAN -> FAST_GATE -> BUILD -> ARTIFACT -> PRE_FLASH -> AUTO_FLASH_SAFETY_GATE -> FLASH -> WAIT_DEVICE -> IDENTIFY -> LAN_RUNTIME -> DHCP -> WAN -> DNS -> SSH -> LUCI -> PLUGIN_RUNTIME_22 -> ARGON_KUCAT_RUNTIME -> SYSTEM_HEALTH -> RELEASE_GATE -> RELEASE -> PRODUCTION_RELEASED`

The effective default `RELEASE_ONLY` order removes the device-write and post-flash runtime stages:

`FORENSICS -> ADH_MANAGEMENT -> ADH_CHINESE -> CHANGE_IMPACT -> BASELINE_INHERITANCE -> EXPECTED_DIFF -> CONFIG -> PACKAGE -> PLUGIN_BASELINE_22 -> ARGON_KUCAT -> LAN -> FAST_GATE -> BUILD -> ARTIFACT -> RELEASE_GATE -> RELEASE -> PRODUCTION_RELEASED`

The machine release-mode selector, not this prose copy, decides the effective order.

## Unattended execution behavior

Once a fresh execution is reconciled and explicitly authorized for `FIRMWARE_RELEASE`, routine safe work continues without asking the operator for repeated confirmations. The system may diagnose and apply minimal reversible repairs when evidence is sufficient.

It must still stop on genuine unsafe ambiguity: unverifiable source provenance, contradictory product intent, unsafe/unknown target/profile, no valid rollback authority where rollback is required, unexpected Diff that changes protected product domains, or any request involving raw storage/bootloader operations.

A stopped safety condition is not permission to weaken a Gate or broaden the expected-diff allowlist.

## Post-release device test and Known-Good

`POST_RELEASE_DEVICE_TEST` is outside Build/Release. It must not trigger a rebuild, create a second Release for the same bytes, block an already valid Release, or silently perform a device write.

Only an exact released firmware/hash that passes this independent test may advance `production/known-good.json`. On failure, preserve the Release and evidence, keep the previous known-good rollback baseline, and open a new repair execution if needed.

## Authorization examples

- “当前应该从修 ADH 完整管理和中文开始” -> state correction only.
- “把这套防跑偏规则建立起来” -> `PROCESS_GOVERNANCE / GOVERNANCE_RULES_ONLY`, no firmware mutation.
- “按当前状态开始发布固件，并继续无人值守流程” -> may become a fresh `EXECUTE_FIRMWARE / FIRMWARE_RELEASE / firmware_execution_authorized=true` after reconciliation; under `RELEASE_ONLY` this still does not authorize a router write.
- “刷到真实 Arthur 并验证” -> is a separate device-write request; it requires explicit compatible policy/authorization and must not be inferred from a release request.

The only successful firmware production terminal remains `PRODUCTION_RELEASED`.
