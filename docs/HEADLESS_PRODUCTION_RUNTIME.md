# Headless Production Runtime v2

The production controller is now an independent Python process. The interactive Codex task only starts/diagnoses it; closing the UI does not end the process.

## Commands

```powershell
py -3 -m ai_orchestrator run-production arthur --detach
py -3 -m ai_orchestrator status
py -3 -m ai_orchestrator status --watch
py -3 -m ai_orchestrator resume
py -3 -m ai_orchestrator stop
```

The Windows wrapper is `scripts/start-headless-production.ps1`. State and append-only events are stored under `output/headless-production/` and include executor/controller provenance, persisted thread IDs, decisions, pending Gate, and preflight evidence.

`status --watch` continuously reports Runtime, PID, Stage, Action, Heartbeat, Last Progress, Active Process, Console Visible, and Human Input Required. The daemon writes a heartbeat every 30 seconds, a health diagnostic every 120 seconds, and emits `STALL_DIAGNOSIS` after 300 seconds without actual turn/output/CPU progress. A stalled executor is automatically reset and resumed; a restarted daemon restores the persisted state and SDK thread IDs.

The Chat UI response is a snapshot, not a live-updating terminal. `runtime-status.json` is the canonical atomic status surface, and `handoff.json` mirrors the current resumable handoff. A separate hidden `status-publisher` may be kept running when the daemon predates the status publisher, so status publication does not require restarting production.

## Runtime contract

The executor uses the official `openai_codex.AsyncCodex` API with `ApprovalMode.auto_review` and `Sandbox.workspace_write`. The controller is a separate read-only structured-output backend: GPT-5.6 Sol Responses when `OPENAI_API_KEY` is available, otherwise a separate Codex SDK thread using a model returned by `models()`.

The SDK's underlying `subprocess.Popen` does not expose Windows creation flags. The adapter therefore supplies a project-owned `CodexConfig.launch_args_override` to `pythonw.exe` and `ai_orchestrator/codex_hidden_launcher.py`. The launcher starts the bundled `codex_cli_bin` with `CREATE_NO_WINDOW`, `STARTF_USESHOWWINDOW`, `SW_HIDE`, inherited stdin/stdout/stderr, exit-code propagation, and a best-effort Windows Job Object for cancellation cleanup. It never requests `CREATE_NEW_CONSOLE` and does not modify site-packages.

Every completed executor turn is persisted before controller review. The controller decision is schema-validated and policy-gated before the controller-generated prompt is sent to the same executor thread. Ordinary build, dependency, source, configuration, LAN, plugin, and theme failures are recoverable; they never become interactive UI questions.

Standard sysupgrade has no human gate. A controller decision with `reason_code=AUTO_FLASH_SAFETY_GATE` is accepted only when the exact candidate, device identity, storage layout, cloud/local/remote SHA256, SSH control channel, 22-plugin baseline, Argon/Kucat, known-good, rollback, recovery-address classification, and expected LAN checks all pass. It then advances automatically through `FLASH` and `WAIT_DEVICE` to real-device verification and Release.

Human Gates are reserved for `NEW_CREDENTIAL_PROVISIONING`, `UNKNOWN_DEVICE_IDENTITY`, `NO_SAFE_ROLLBACK`, and `UNRECOVERABLE_IRREVERSIBLE_OPERATION`. Raw MTD, U-Boot/bootloader, `dd` raw-partition, raw eMMC/SPI/NAND, and ART/EEPROM/calibration writes remain blocked.

## LIVE E2E

```powershell
py -3 -m unittest tests.test_live_e2e_contract -v
py -3 tests/live_e2e.py
py -3 tests/live_sdk_e2e.py
```

The daemon LIVE E2E starts a separate process and verifies at least three executor/controller pairs plus `source=executor`, `reviewed_by=controller`, `next_action_generated_by=controller`, and `next_turn_started_automatically=true` using the loopback lifecycle adapter. `live_sdk_e2e.py` is the provider-backed proof: it uses the real `AsyncCodexExecutor` and read-only `CodexThreadController` on the same two SDK threads for three pairs. Tests use mocked device adapters for the automatic sysupgrade lifecycle; they never perform a physical router write.
