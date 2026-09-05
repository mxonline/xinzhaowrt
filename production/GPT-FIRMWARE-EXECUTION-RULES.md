# Arthur GPT Firmware Execution Rules

This file is the durable operator/GPT contract for deciding whether a firmware action may be proposed or executed. It does not replace the frozen RELEASE-FIRST production workflow; it governs intent, state recovery, historical evidence, and authorization before that workflow is allowed to move.

## Hard rules

1. **A state statement is not execution authorization.** Messages such as “当前应该从 ADH 完整管理和中文开始”, “现在状态是…”, “记住这里”, “进度到这里” correct or describe state only. They must not trigger Codex, CI, Build, Flash, Release, repository mutation, or firmware repair.
2. **Authorization is scope-bound.** “开始”, “执行”, “继续” authorizes only the task that is unambiguously being discussed. Authorization for governance/rule work must never leak into firmware execution. Authorization for a diagnostic read must never leak into a repair. If scope is ambiguous, fail closed.
3. Read `production/operator-intent.json` before deciding whether any firmware execution is allowed.
4. Read `production/resume-state.json` for the current reconciled checkpoint and `production/firmware-events.jsonl` for historical event evidence. Historical chat, old project-state sections, and stale controller state are auxiliary only.
5. For any firmware status/next-step/execution prompt, run the equivalent of `scripts/arthur-firmware-resume.ps1` before naming a concrete stage or action. A concrete answer without a completed Resume Gate is not allowed.
6. No Codex firmware instruction may be emitted while `firmware_execution_authorized != true`, `authorization_scope != FIRMWARE_RELEASE`, or `intent_type != EXECUTE_FIRMWARE`.
7. Completed/verified work is never repeated without invalidating evidence. `WIFI=VERIFIED_FROZEN` stays frozen. Accepted iStore/QuickStart state is preserved unless new evidence proves it invalid.
8. On conflict, do not guess. Report the conflicting sources and require state reconciliation before firmware execution.
9. **Machine time is absolute.** State/event evidence must use ISO 8601 timestamps with `Z` or an explicit UTC offset. Words such as `today`, `yesterday`, “今天”, “昨天”, “刚才”, and “前几天” are presentation language only and must never be used as machine truth or to order firmware events.
10. **The event ledger is append-only.** `production/firmware-events.jsonl` records what actually happened. Existing event lines must never be edited, reordered, or deleted to make a later narrative look consistent; corrections are new events.

## Required GPT/Codex startup sequence

For firmware prompts such as “进度”, “下一步”, “继续”, “现在做什么”, “编译了吗”, “昨天做到哪里”, “修 ADH”, or “让 Codex 继续”, perform this sequence before proposing an executable action or asserting a concrete current stage:

1. **Intent Gate** — read `production/operator-intent.json`; classify the user message as state correction, status/read-only request, governance/process work, or explicit firmware execution.
2. **Workflow Recovery** — read the canonical Arthur phase order from `scripts/arthur-resume-state.ps1` and the frozen RELEASE-FIRST policy.
3. **Current-State Recovery** — read `production/resume-state.json`.
4. **Historical Recovery** — validate and read `production/firmware-events.jsonl`; use the latest relevant events to explain how the current checkpoint was reached. Never reconstruct this from chat when the ledger exists.
5. **External Evidence** — verify current effective Git HEAD and relevant GitHub workflow/release evidence; use live-device evidence already reconciled into the resume snapshot or fresh read-only device evidence when the action requires it.
6. **State Reconciliation** — compare operator-corrected work start, machine checkpoint, verified-frozen items, current source SHA, candidate/build identity, event chronology, and live device state.
7. **Authorization Check** — only explicit `EXECUTE_FIRMWARE + FIRMWARE_RELEASE + firmware_execution_authorized=true` can unlock a firmware action.
8. **Action Check** — the proposed action must match the reconciled current stage and the next permitted stage. Otherwise stop and reconcile.

The canonical local implementation of steps 1–6 is `scripts/arthur-firmware-resume.ps1`. It is read-only: it may inspect state and external evidence, but it must not itself Build, Flash, Release, mutate Stable/Known-Good, or advance a checkpoint.

## Event ledger contract

`production/firmware-events.jsonl` is a JSON Lines append-only history. Each event contains an absolute ISO 8601 time, monotonic sequence number, event name, stage, source, data, previous hash, and current hash. The hash chain makes accidental edits/reordering detectable by the Resume Gate.

Typical events include `LEDGER_INITIALIZED`, `CONTROL_PLANE_RECONCILED`, `CHECKPOINT_ADVANCED`, `STAGE_VERIFIED`, `BUILD_STARTED`, `CANDIDATE_ACCEPTED`, `FLASH_STARTED`, `REAL_DEVICE_VERIFIED`, and `OPERATOR_STATE_CORRECTION`. Event names are evidence labels, not new workflow stages.

If a past state was wrong, append a correction event with the old/new stage and evidence. Do not rewrite history.

## Current operator-corrected firmware work start

The user-corrected work start is durable state in `production/operator-intent.json`; the live executable checkpoint must still be reconciled through `production/resume-state.json` and the event ledger before action. At the time this contract was introduced, the correction was:

- current stage: `ADH_MANAGEMENT`
- next stage: `ADH_CHINESE`
- `WIFI=VERIFIED_FROZEN`
- preserve accepted iStore/QuickStart state

Do not assume those values are still current merely because they appear in this prose. Current machine files and evidence win.

## Canonical Arthur phase order

The machine phase registry in `scripts/arthur-resume-state.ps1` is authoritative. At the time this contract was introduced its order is:

`FORENSICS -> ADH_MANAGEMENT -> ADH_CHINESE -> CHANGE_IMPACT -> BASELINE_INHERITANCE -> EXPECTED_DIFF -> CONFIG -> PACKAGE -> PLUGIN_BASELINE_22 -> ARGON_KUCAT -> LAN -> FAST_GATE -> BUILD -> ARTIFACT -> PRE_FLASH -> AUTO_FLASH_SAFETY_GATE -> FLASH -> WAIT_DEVICE -> IDENTIFY -> LAN_RUNTIME -> DHCP -> WAN -> DNS -> SSH -> LUCI -> PLUGIN_RUNTIME_22 -> ARGON_KUCAT_RUNTIME -> SYSTEM_HEALTH -> RELEASE_GATE -> RELEASE -> PRODUCTION_RELEASED`

Do not use this prose copy to override the machine registry if the registry is intentionally changed under an explicit user-approved workflow change.

## Authorization examples

- “当前应该从修 ADH 完整管理和中文开始” -> `STATE_CORRECTION`, firmware execution remains false unless the same instruction explicitly authorizes execution.
- “把这套防跑偏规则建立起来” -> `PROCESS_GOVERNANCE / GOVERNANCE_RULES_ONLY`, firmware execution remains false.
- “那就开始啊” immediately after governance design -> authorizes governance implementation only, not firmware repair.
- “按当前状态开始修 ADH，并继续固件发布流程” -> may be recorded as `EXECUTE_FIRMWARE / FIRMWARE_RELEASE / firmware_execution_authorized=true` after state reconciliation.

The only successful firmware terminal state remains `PRODUCTION_RELEASED`.
