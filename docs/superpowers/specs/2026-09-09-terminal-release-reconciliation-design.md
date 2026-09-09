# Arthur terminal release reconciliation

## Purpose

When an Arthur production release has completed, durable production evidence must close every state source for that execution.  Stale local runtime checkpoints, operator intent, and resume state must never restart a completed release at `PRE_FLASH` or any earlier action.

## Trusted terminal evidence

`TerminalReleaseReconciler` accepts a release only when all four sources agree on one execution:

1. GitHub Actions-verified production-release evidence, obtained in the existing production workflow with `GITHUB_TOKEN`.
2. `production/status.json` with `status=PRODUCTION_RELEASED` and `known_good=true`.
3. `production/known-good.json` with `verified=true` and `verification=real-device-confirmed`.
4. Durable real-device verification evidence for the same source commit, firmware filename, firmware SHA256, run ID, and stable tag.

The reconciler fails closed on missing or mismatched identity.  Local Codex does not call GitHub REST and has no token or credential-manager fallback.

## Reconciliation

For validated evidence, produce one canonical terminal snapshot:

- Resume state: `PRODUCTION_RELEASED`, `instruction_allowed=false`, `current_gate=PRODUCTION_RELEASED`, `next_action=NONE`, no pending work or conflicts, and terminal checkpoint fields.
- Operator intent: close the completed execution with `firmware_execution_authorized=false`, stage `PRODUCTION_RELEASED`, next stage `NONE`, and the validated run/source identity.
- Local runtime: supersede matching stale local state with `phase`, `current_stage`, and `terminal_state` set to `PRODUCTION_RELEASED`; clear pending human gates and set `next_action=NONE`.
- Events: append exactly one semantic `PRODUCTION_RELEASED` event keyed by stable tag and run ID.  Repeated reconciliation is a no-op.

New operator intents with a distinct execution ID remain eligible for a new firmware task; a previous terminal release never authorizes or blocks it.

## Integration

Expose the reconciler as a single library path used by:

1. The existing resolver/runtime on load, before stale checkpoint migrations.
2. `Complete-Release` and the server-side production promotion success path in GitHub Actions.
3. A one-shot reconciliation command for a completed release.

GitHub Actions obtains and persists release evidence using `GITHUB_TOKEN`; it then invokes the same reconciler.  No second orchestrator, candidate, build, release, firmware update, or device action is introduced.

## Tests

The test suite covers: stale `PRE_FLASH` forward reconciliation; idempotent repeated reconciliation with one event; fail-closed missing/mismatched release evidence; superseding a matching stale local runtime; and a new execution ID remaining eligible after a prior terminal release.
