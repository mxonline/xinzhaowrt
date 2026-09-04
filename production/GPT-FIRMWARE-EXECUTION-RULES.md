# Arthur GPT Firmware Execution Rules

This file is the durable operator/GPT contract for deciding whether a firmware action may be proposed or executed. It does not replace the frozen RELEASE-FIRST production workflow; it governs intent, state recovery, and authorization before that workflow is allowed to move.

## Hard rules

1. **A state statement is not execution authorization.** Messages such as “当前应该从 ADH 完整管理和中文开始”, “现在状态是…”, “记住这里”, “进度到这里” correct or describe state only. They must not trigger Codex, CI, Build, Flash, Release, repository mutation, or firmware repair.
2. **Authorization is scope-bound.** “开始”, “执行”, “继续” authorizes only the task that is unambiguously being discussed. Authorization for governance/rule work must never leak into firmware execution. Authorization for a diagnostic read must never leak into a repair. If scope is ambiguous, fail closed.
3. Read `production/operator-intent.json` before deciding whether any firmware execution is allowed.
4. Read `production/resume-state.json` and live GitHub/device evidence before naming the current executable checkpoint. Historical chat, old project-state sections, and stale controller state are auxiliary only.
5. No Codex firmware instruction may be emitted while `firmware_execution_authorized != true`, `authorization_scope != FIRMWARE_RELEASE`, or `intent_type != EXECUTE_FIRMWARE`.
6. Completed/verified work is never repeated without invalidating evidence. `WIFI=VERIFIED_FROZEN` stays frozen. Accepted iStore/QuickStart state is preserved unless new evidence proves it invalid.
7. On conflict, do not guess. Report the conflicting sources and require state reconciliation before firmware execution.

## Required GPT startup sequence

For firmware prompts such as “进度”, “下一步”, “继续”, “编译”, “修 ADH”, or “让 Codex 继续”, perform this sequence before proposing an executable action:

1. **Intent Gate** — read `production/operator-intent.json`; classify the user message as state correction, status/read-only request, governance/process work, or explicit firmware execution.
2. **Workflow Recovery** — read the canonical Arthur phase order from `scripts/arthur-resume-state.ps1` and the frozen RELEASE-FIRST policy.
3. **Current-State Recovery** — read `production/resume-state.json`, current runtime/HANDOFF evidence, current GitHub HEAD/workflows/releases, and relevant live-device evidence.
4. **State Reconciliation** — compare operator-corrected work start, machine checkpoint, verified-frozen items, current source SHA, candidate/build identity, and live device state.
5. **Authorization Check** — only explicit `EXECUTE_FIRMWARE + FIRMWARE_RELEASE + firmware_execution_authorized=true` can unlock a firmware action.
6. **Action Check** — the proposed action must match the reconciled current stage and the next permitted stage. Otherwise stop and reconcile.

## Current operator-corrected firmware work start

The current user-corrected work start is stored in `production/operator-intent.json`:

- current stage: `ADH_MANAGEMENT`
- next stage: `ADH_CHINESE`
- `WIFI=VERIFIED_FROZEN`
- preserve accepted iStore/QuickStart state

This is state information only while firmware execution authorization is false.

## Canonical Arthur phase order

The machine phase registry in `scripts/arthur-resume-state.ps1` is authoritative. At the time this contract was introduced its order is:

`FORENSICS -> ADH_MANAGEMENT -> ADH_CHINESE -> CHANGE_IMPACT -> BASELINE_INHERITANCE -> EXPECTED_DIFF -> CONFIG -> PACKAGE -> PLUGIN_BASELINE_22 -> ARGON_KUCAT -> LAN -> FAST_GATE -> BUILD -> ARTIFACT -> PRE_FLASH -> AUTO_FLASH_SAFETY_GATE -> FLASH -> WAIT_DEVICE -> IDENTIFY -> LAN_RUNTIME -> DHCP -> WAN -> DNS -> SSH -> LUCI -> PLUGIN_RUNTIME_22 -> ARGON_KUCAT_RUNTIME -> SYSTEM_HEALTH -> RELEASE_GATE -> RELEASE -> PRODUCTION_RELEASED`

Do not use this prose copy to override the machine registry if the registry is intentionally changed under an explicit user-approved workflow change.

## Authorization examples

- “当前应该从修 ADH 完整管理和中文开始” -> `STATE_CORRECTION`, firmware execution remains false.
- “把这套防跑偏规则建立起来” -> `PROCESS_GOVERNANCE / GOVERNANCE_RULES_ONLY`, firmware execution remains false.
- “那就开始啊” immediately after governance design -> authorizes governance implementation only, not firmware repair.
- “按当前状态开始修 ADH，并继续固件发布流程” -> may be recorded as `EXECUTE_FIRMWARE / FIRMWARE_RELEASE / firmware_execution_authorized=true` after state reconciliation.

The only successful firmware terminal state remains `PRODUCTION_RELEASED`.
