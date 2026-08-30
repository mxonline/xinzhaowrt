# GPT-Codex Bridge Headless Production Runtime v2

## Goal

Move Arthur production control out of the interactive Codex task into an independently runnable Python daemon. One business request must continue through executor turns, controller decisions, policy gates, recovery, real-device validation, and release until `PRODUCTION_RELEASED`, pausing only at the explicit high-risk whitelist.

## Architecture

`ai_orchestrator` is a durable process with three isolated boundaries:

1. `CodexExecutor` owns one persisted `EXECUTOR_THREAD_ID`, uses the official `openai_codex.AsyncCodex` API, and starts/resumes the thread with `ApprovalMode.auto_review` and `Sandbox.workspace_write`.
2. `ControllerAdapter` owns a separate controller identity. It prefers the Responses API when `OPENAI_API_KEY` is discoverable, otherwise it uses a separate read-only Codex controller thread selected from the SDK's actual `models()` response. The controller receives serialized results and returns schema-validated decisions; it cannot execute commands or write files.
3. `ProductionRuntime` is the durable loop. It persists every result and decision before continuing, routes ordinary failures to automatic recovery, and only enters a human gate for the exact safety/credential/device whitelist.

The state store is append-only for events plus atomically replaced snapshots. `executor_thread_id`, controller identity, next action, terminal state, candidate evidence, known-good reference, and pending gate are all recoverable after process exit. A PID/stop marker controls the daemon without requiring a Codex UI page.

## Arthur pipeline

The initial action is the ordered handoff:

`FORENSICS → CHANGE_IMPACT → BASELINE_INHERITANCE → EXPECTED_DIFF → CONFIG → PACKAGE → PLUGIN_BASELINE → ARGON_KUCAT → LAN → FAST_GATE → BUILD → ARTIFACT → PRE_FLASH → AUTO_FLASH_SAFETY_GATE → FLASH → WAIT_DEVICE → IDENTIFY → LAN → DHCP → WAN → DNS → SSH → LUCI → PLUGIN_RUNTIME → ARGON_KUCAT → SYSTEM_HEALTH → RELEASE_GATE → RELEASE → PRODUCTION_RELEASED`.

Each phase is a controller-generated prompt sent to the same executor thread. Standard sysupgrade is automatic after a complete candidate manifest, device identity, storage, three-way SHA256, SSH, plugin/theme, known-good, rollback, and LAN recovery safety gate. Raw MTD, U-Boot/bootloader, raw-partition, raw eMMC/SPI/NAND, and calibration writes remain hard safety boundaries.

## Policy

The only human gates are:

`NEW_CREDENTIAL_PROVISIONING`, `UNKNOWN_DEVICE_IDENTITY`, `NO_SAFE_ROLLBACK`, and `UNRECOVERABLE_IRREVERSIBLE_OPERATION`.

Design/spec/plan/merge/PR choices, SDK/runtime installation, build/dependency/source/config errors, and LAN/plugin/theme regressions are automatic recovery states. `AUTH_REQUIRED` is valid only when `auth_resource`, `provider`, `verification_error`, and evidence proving automatic credential discovery failure are all present.

## Controller decision contract

```json
{
  "action": "SAFE_AUTO | RECOVERABLE | HUMAN_GATE | TERMINAL",
  "reason_code": "BUILD_ERROR",
  "summary": "short evidence-backed explanation",
  "next_codex_prompt": "the complete next executor instruction",
  "human_gate": null,
  "evidence": ["relative evidence path or fact"],
  "terminal_state": null
}
```

`HUMAN_GATE` requires a whitelisted gate and complete evidence. `TERMINAL` requires `PRODUCTION_RELEASED` or an explicitly irrecoverable safety/credential blocker. Malformed or unsafe controller output is persisted and automatically sent back to the controller as a recoverable protocol error; it is never silently interpreted as success.

## Startup and recovery

Preflight runs before the first executor turn and persists all checks: Python version, SDK import, Codex account, available models, controller backend, source tree, state store, known-good metadata, target/profile, and required artifacts. Recoverable setup problems are repaired by an executor action; missing credentials or SDK support produce one structured blocker with evidence. `status`, `resume`, and `stop` operate on the same state directory. `run-production arthur` can detach on Windows and the child process continues after the interactive task exits.

## Verification

Unit tests cover the gate whitelist, strict `AUTH_REQUIRED` validation, atomic recovery, schema validation, and adapter configuration. Integration tests run a real runtime loop with durable state and independent executor/controller adapters. The LIVE E2E command launches the daemon as a separate process and proves three automatic executor/controller pairs, required provenance fields, and phase advancement without a follow-up message. External SDK and physical flash remain environment-gated; the test does not claim a router flash occurred.
