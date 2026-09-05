# Arthur Windows Repair Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Windows-owned outer repair controller that can restore the Arthur Codex execution runtime after Supervisor/Codex infrastructure failures without modifying firmware state, then hand the existing BUILD task back to Codex only after a 120-second health gate.

**Architecture:** Keep the current persistent Supervisor as the normal runtime owner. Add a separate PowerShell Repair Controller plus an isolated Python Runtime Probe. The Repair Controller classifies only approved infrastructure failures, applies one white-listed repair at a time, preserves `runtime-state.json`, and exposes `repair-status.json` / `repair-events.jsonl` for GitHub observation. GitHub remains a short-lived trigger and observer; Windows Task Scheduler owns long-running repair verification.

**Tech Stack:** Windows PowerShell 5.1, Python 3.12 standard library, existing `openai_codex` runtime only inside the isolated probe, Git, Windows Task Scheduler, GitHub Actions, existing Arthur Supervisor/state files.

**Spec:** `docs/superpowers/specs/2026-09-06-arthur-windows-repair-controller-design.md`

## Global Constraints

- The controller must never invoke firmware Build, create/replace a Candidate, call sysupgrade/Flash, modify Known-Good, or advance `ARTIFACT`, `PRE_FLASH`, `FLASH`, `RELEASE`, or `PRODUCTION_RELEASED`.
- The controller must never clear a human safety gate.
- The controller must never delete, rewrite, reconstruct, reset, clean, stash, or discard `runtime-state.json` or the mutable `workspace`.
- `control-runtime` may only be updated by clean fast-forward from its current HEAD to `origin/main`; dirty or diverged control code fails closed.
- The same release-task identity must be preserved across every repair mutation.
- One unchanged failure fingerprint may receive at most 3 automatic repair attempts in 30 minutes.
- `CODEX_RUNTIME_RECOVERED` requires a matching Supervisor process, a matching Codex runtime process, at least two advancing runtime heartbeats, and at least 120 continuous seconds between first and last healthy observations.
- Windows Scheduled Task behavior and quoting must be tested under Windows PowerShell 5.1.
- GitHub-only green CI is not sufficient production evidence; final acceptance requires a real Windows run.

---

### Task 1: Add the isolated Codex Runtime Probe

**Files:**
- Create: `scripts/arthur-codex-runtime-probe.py`
- Create: `tests/test_arthur_codex_runtime_probe.py`
- Modify: `.github/workflows/arthur-fast-preflight.yml`

**Interfaces:**
- Consumes: `ARTHUR_CONTROL_PLANE_CODE_ROOT`, `HEADLESS_CODEX_MODEL`, existing `ai_orchestrator.codex_compat.configured_headless_codex_model()` and compatibility initialization.
- Produces: one JSON object on stdout with keys `timestamp`, `python_executable`, `cwd`, `sys_path`, `ai_orchestrator_file`, `codex_compat_file`, `configured_model`, `effective_model`, `openai_codex_version`, `account_preflight_ok`, `model_catalog_skipped`, `exit_class`.
- Exit codes: `0=PROBE_OK`, `10=MODULE_ROOT_DRIFT`, `11=MODEL_BINDING_DRIFT`, `12=CODEX_IMPORT_FAILED`, `13=ACCOUNT_PREFLIGHT_FAILED`, `14=PROBE_INTERNAL_ERROR`.

- [ ] **Step 1: Write the failing Python probe contract tests**

Create `tests/test_arthur_codex_runtime_probe.py` using `unittest` and subprocess execution. The first tests must prove the script does not start the Arthur pipeline and that module/model evidence is explicit.

```python
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts" / "arthur-codex-runtime-probe.py"


class ArthurCodexRuntimeProbeTests(unittest.TestCase):
    def test_probe_source_never_invokes_firmware_runtime(self):
        text = PROBE.read_text(encoding="utf-8")
        self.assertNotIn("run-production", text)
        self.assertNotIn("ai_orchestrator resume", text)
        self.assertNotIn("sysupgrade", text)

    def test_probe_reports_expected_code_root_and_explicit_model(self):
        env = os.environ.copy()
        env["ARTHUR_CONTROL_PLANE_CODE_ROOT"] = str(ROOT)
        env["HEADLESS_CODEX_MODEL"] = "gpt-5.6-terra"
        env["ARTHUR_PROBE_SKIP_ACCOUNT"] = "1"
        completed = subprocess.run(
            [sys.executable, str(PROBE)],
            cwd=str(ROOT),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        payload = json.loads(completed.stdout)
        self.assertEqual(completed.returncode, 0)
        self.assertTrue(Path(payload["ai_orchestrator_file"]).resolve().is_relative_to(ROOT.resolve()))
        self.assertEqual(payload["configured_model"], "gpt-5.6-terra")
        self.assertEqual(payload["effective_model"], "gpt-5.6-terra")
        self.assertTrue(payload["model_catalog_skipped"])
        self.assertEqual(payload["exit_class"], "PROBE_OK")
```

- [ ] **Step 2: Run the probe tests and verify RED**

Run:

```bash
python -m unittest tests.test_arthur_codex_runtime_probe -v
```

Expected: FAIL because `scripts/arthur-codex-runtime-probe.py` does not exist.

- [ ] **Step 3: Implement the minimal probe**

Create `scripts/arthur-codex-runtime-probe.py`. It must insert the expected `control-runtime` root at `sys.path[0]`, import `ai_orchestrator` and `ai_orchestrator.codex_compat`, call only account preflight when not in test-skip mode, and never call `.models()`.

Core structure:

```python
import asyncio
import importlib.metadata
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

EXIT = {
    "PROBE_OK": 0,
    "MODULE_ROOT_DRIFT": 10,
    "MODEL_BINDING_DRIFT": 11,
    "CODEX_IMPORT_FAILED": 12,
    "ACCOUNT_PREFLIGHT_FAILED": 13,
    "PROBE_INTERNAL_ERROR": 14,
}


def _under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


async def _account_probe():
    from ai_orchestrator import adapters
    module = adapters._import_sdk()
    codex = adapters.AsyncCodexExecutor(Path.cwd())._new_codex(module)
    await codex.account()


def main() -> int:
    expected_root = Path(os.environ["ARTHUR_CONTROL_PLANE_CODE_ROOT"]).resolve()
    sys.path.insert(0, str(expected_root))
    payload = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "python_executable": sys.executable,
        "cwd": str(Path.cwd().resolve()),
        "sys_path": list(sys.path),
        "account_preflight_ok": False,
        "model_catalog_skipped": True,
    }
    try:
        import ai_orchestrator
        from ai_orchestrator import codex_compat
        module_file = Path(ai_orchestrator.__file__).resolve()
        compat_file = Path(codex_compat.__file__).resolve()
        payload["ai_orchestrator_file"] = str(module_file)
        payload["codex_compat_file"] = str(compat_file)
        payload["configured_model"] = os.environ.get("HEADLESS_CODEX_MODEL", "")
        payload["effective_model"] = codex_compat.configured_headless_codex_model()
        try:
            payload["openai_codex_version"] = importlib.metadata.version("openai-codex")
        except importlib.metadata.PackageNotFoundError:
            payload["openai_codex_version"] = None
        if not _under(module_file, expected_root) or not _under(compat_file, expected_root):
            payload["exit_class"] = "MODULE_ROOT_DRIFT"
            print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
            return EXIT[payload["exit_class"]]
        if payload["effective_model"] != codex_compat.configured_headless_codex_model():
            payload["exit_class"] = "MODEL_BINDING_DRIFT"
            print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
            return EXIT[payload["exit_class"]]
        if os.environ.get("ARTHUR_PROBE_SKIP_ACCOUNT") == "1":
            payload["account_preflight_ok"] = True
        else:
            asyncio.run(_account_probe())
            payload["account_preflight_ok"] = True
        payload["exit_class"] = "PROBE_OK"
        print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
        return 0
    except Exception as exc:
        payload["error_type"] = type(exc).__name__
        payload["error"] = str(exc)
        payload["exit_class"] = "PROBE_INTERNAL_ERROR"
        print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
        return EXIT[payload["exit_class"]]


if __name__ == "__main__":
    raise SystemExit(main())
```

During implementation, refine exception mapping so import/account errors return their dedicated exit classes.

- [ ] **Step 4: Run probe tests and verify GREEN**

Run:

```bash
python -m unittest tests.test_arthur_codex_runtime_probe -v
```

Expected: PASS.

- [ ] **Step 5: Add the Python probe test to Fast Preflight**

Modify `.github/workflows/arthur-fast-preflight.yml` immediately after existing Python recovery tests:

```yaml
      - name: Test Arthur Codex runtime probe
        shell: pwsh
        run: python -m unittest tests.test_arthur_codex_runtime_probe -v
```

- [ ] **Step 6: Run Fast Preflight locally where available and commit**

Run the same existing local preflight command used by this repo plus the new unittest. Commit:

```bash
git add scripts/arthur-codex-runtime-probe.py tests/test_arthur_codex_runtime_probe.py .github/workflows/arthur-fast-preflight.yml
git commit -m "test: add isolated Arthur Codex runtime probe"
```

---

### Task 2: Build diagnostic-only Repair Controller and durable repair evidence

**Files:**
- Create: `scripts/arthur-windows-repair-controller.ps1`
- Create: `tests/arthur-windows-repair-controller.tests.ps1`
- Modify: `.github/workflows/arthur-fast-preflight.yml`

**Interfaces:**
- Consumes: canonical state directory, clean `control-runtime`, persistent Supervisor Scheduled Task, managed headless Python, `runtime-state.json`, `supervisor-status.json`, `runtime-status.json`, Runtime Probe JSON.
- Produces: `repair-status.json`, append-only `repair-events.jsonl`, machine markers `WINDOWS_REPAIR_DIAGNOSIS=PASS`, `WINDOWS_REPAIR_CLASS=<class>`, blocked terminal markers.
- Public parameters:

```powershell
param(
    [Parameter(Mandatory=$true)][string]$StateDir,
    [Parameter(Mandatory=$true)][string]$ControlRoot,
    [Parameter(Mandatory=$true)][string]$HeadlessPythonExe,
    [ValidateSet('DiagnosticOnly','WhitelistRepair','FullRecovery')]
    [string]$Mode = 'DiagnosticOnly',
    [string]$SupervisorTaskName = 'XinZhaoWrt-Arthur-Persistent-Supervisor',
    [string]$RepairTaskName = 'XinZhaoWrt-Arthur-Repair-Controller'
)
```

- [ ] **Step 1: Write RED PowerShell tests for diagnostic classification and safety boundary**

`tests/arthur-windows-repair-controller.tests.ps1` must dot-source the controller with a test-only guard such as `$env:ARTHUR_REPAIR_CONTROLLER_IMPORT_ONLY='1'` and test pure functions using temporary fixtures.

Required assertions:

```powershell
Assert-Equal (Get-ArthurRepairFailureClass $evidenceStale) 'CONTROL_RUNTIME_STALE' 'clean behind control-runtime must classify as stale'
Assert-Equal (Get-ArthurRepairFailureClass $evidenceDirty) 'REPAIR_BLOCKED_DIRTY_CONTROL_RUNTIME' 'dirty control-runtime must fail closed'
Assert-Equal (Get-ArthurRepairFailureClass $evidenceModuleDrift) 'MODULE_ROOT_DRIFT' 'probe module root outside control-runtime must be explicit'
Assert-Equal (Get-ArthurRepairFailureClass $evidenceModelDrift) 'MODEL_BINDING_DRIFT' 'probe model mismatch must be explicit'
Assert-Equal (Get-ArthurRepairFailureClass $evidenceRetryExhausted) 'SUPERVISOR_RETRY_EXHAUSTED' 'healthy probe plus crash-loop block may reset only retry state'
Assert-Equal (Get-ArthurRepairFailureClass $evidenceUnknown) 'UNKNOWN_FAILURE' 'unknown conditions must not mutate'
Assert-True (Test-ArthurRepairProtectedState $flashState) 'FLASH must always be repair-protected'
Assert-True (Test-ArthurRepairProtectedState $humanGateState) 'human safety gate must always be repair-protected'
```

The test must scan the controller source and fail if it contains `sysupgrade`, firmware build workflow dispatch, `git reset --hard`, `git clean`, `git stash`, or deletion of `runtime-state.json`.

- [ ] **Step 2: Run RED contract**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\arthur-windows-repair-controller.tests.ps1
```

Expected: FAIL because controller functions do not exist.

- [ ] **Step 3: Implement diagnostic-only controller primitives**

Implement these focused functions in `scripts/arthur-windows-repair-controller.ps1`:

```powershell
function Read-JsonFile([string]$Path) { ... }
function Save-JsonAtomic([string]$Path,[object]$Value) { ... }
function Add-ArthurRepairEvent([string]$Path,[string]$Event,[object]$Data) { ... }
function Get-ArthurRuntimeStateIdentity([object]$State) { ... }
function Test-ArthurRuntimeStateIdentity([object]$Before,[object]$After) { ... }
function Test-ArthurRepairProtectedState([object]$State) { ... }
function Get-ArthurScheduledTaskEvidence([string]$TaskName) { ... }
function Get-ArthurProcessEvidence([string]$StateDir) { ... }
function Get-ArthurGitEvidence([string]$ControlRoot) { ... }
function Invoke-ArthurRuntimeProbe([string]$ControlRoot,[string]$HeadlessPythonExe) { ... }
function Get-ArthurRepairEvidence(...) { ... }
function Get-ArthurRepairFailureClass([object]$Evidence) { ... }
function Get-ArthurFailureFingerprint([object]$Evidence) { ... }
function Write-ArthurRepairStatus(...) { ... }
```

Protected phases are exactly:

```powershell
@('ARTIFACT','PRE_FLASH','AUTO_FLASH_SAFETY_GATE','FLASH','WAIT_DEVICE','IDENTIFY','LAN_RUNTIME','DHCP','WAN','DNS','SSH','LUCI','PLUGIN_RUNTIME_22','ARGON_KUCAT_RUNTIME','SYSTEM_HEALTH','RELEASE_GATE','RELEASE','PRODUCTION_RELEASED')
```

In `DiagnosticOnly`, any detected class is recorded but no process, task, Git, or retry-state mutation occurs.

- [ ] **Step 4: Implement repair lock and event/status schema**

Use an exclusive file lock on `<StateDir>\repair-controller.lock`. On lock contention print and return success:

```text
REPAIR_CONTROLLER_ALREADY_RUNNING=PASS
```

Write `repair-status.json` schema version 1 with at least:

```json
{
  "schema_version": 1,
  "status": "DIAGNOSING",
  "mode": "DiagnosticOnly",
  "failure_class": "MODULE_ROOT_DRIFT",
  "evidence_timestamp": "...",
  "repair_attempt_count": 0,
  "selected_repair_action": null,
  "source_sha": "...",
  "control_runtime_sha": "...",
  "expected_module_root": "...\\control-runtime",
  "actual_module_root": "...",
  "expected_model": "gpt-5.6-terra",
  "actual_model": "...",
  "supervisor_pid": null,
  "codex_pid": null,
  "runtime_state_identity": {},
  "failure_fingerprint": "...",
  "final_result": null
}
```

Append `repair_cycle_started` and diagnostic terminal events to `repair-events.jsonl`.

- [ ] **Step 5: Run controller tests GREEN and add Fast Preflight step**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\arthur-windows-repair-controller.tests.ps1
```

Expected: PASS and markers:

```text
ARTHUR_WINDOWS_REPAIR_CONTROLLER_DIAGNOSTIC_CONTRACT=PASS
ARTHUR_WINDOWS_REPAIR_CONTROLLER_SAFETY_CONTRACT=PASS
```

Add to `.github/workflows/arthur-fast-preflight.yml`:

```yaml
      - name: Test Arthur Windows repair controller
        shell: powershell
        run: ./tests/arthur-windows-repair-controller.tests.ps1
```

Use `shell: powershell`, not `pwsh`, so this contract executes in Windows PowerShell 5.1 on Windows CI where available.

- [ ] **Step 6: Commit diagnostic-only Stage A**

```bash
git add scripts/arthur-windows-repair-controller.ps1 tests/arthur-windows-repair-controller.tests.ps1 .github/workflows/arthur-fast-preflight.yml
git commit -m "feat: add diagnostic Arthur Windows repair controller"
```

---

### Task 3: Add white-listed repair actions with fail-closed identity checks

**Files:**
- Modify: `scripts/arthur-windows-repair-controller.ps1`
- Modify: `tests/arthur-windows-repair-controller.tests.ps1`
- Modify: `scripts/ensure-arthur-persistent-supervisor.ps1`
- Modify: `tests/arthur-recovery-supervisor-wiring.tests.ps1`

**Interfaces:**
- Consumes: failure class from Task 2 and passing Runtime Probe from Task 1.
- Produces: exactly one action per cycle from `FAST_FORWARD_CONTROL_RUNTIME`, `REREGISTER_SUPERVISOR_TASK`, `REGENERATE_CANONICAL_LAUNCHER`, `BIND_EXPLICIT_MODEL`, `RESET_SUPERVISOR_RETRY_STATE`.

- [ ] **Step 1: Write RED tests for each approved repair and forbidden mutation**

Extend PowerShell tests with temp Git repos and mock task/process evidence. Required behavior:

```powershell
Assert-Equal (Get-ArthurApprovedRepairAction 'CONTROL_RUNTIME_STALE') 'FAST_FORWARD_CONTROL_RUNTIME' 'stale clean control code has one repair'
Assert-Equal (Get-ArthurApprovedRepairAction 'TASK_LAUNCHER_DRIFT') 'REREGISTER_SUPERVISOR_TASK' 'task drift reuses canonical task name'
Assert-Equal (Get-ArthurApprovedRepairAction 'MODULE_ROOT_DRIFT') 'REGENERATE_CANONICAL_LAUNCHER' 'module drift repairs launcher only'
Assert-Equal (Get-ArthurApprovedRepairAction 'MODEL_BINDING_DRIFT') 'BIND_EXPLICIT_MODEL' 'model drift binds approved model only'
Assert-Equal (Get-ArthurApprovedRepairAction 'SUPERVISOR_RETRY_EXHAUSTED') 'RESET_SUPERVISOR_RETRY_STATE' 'retry reset is allowed only after probe pass'
Assert-Equal (Get-ArthurApprovedRepairAction 'UNKNOWN_FAILURE') $null 'unknown failure has no repair action'
```

Add tests that `Invoke-ArthurApprovedRepair` refuses mutation when:

- runtime-state identity changed since diagnosis
- `pending_human_gate` is non-null
- phase is protected
- control-runtime is dirty/diverged
- identical fingerprint already has 3 attempts inside 30 minutes

- [ ] **Step 2: Fix the existing Supervisor helper so REUSE validates and updates task action**

Current `ensure-arthur-persistent-supervisor.ps1` rewrites the launcher but reuses an existing Scheduled Task without proving that its Action/WorkingDirectory still match. Add pure canonical comparison functions:

```powershell
function Get-CanonicalSupervisorTaskAction(...) { ... }
function Test-SupervisorTaskActionMatches([object]$ExistingAction,[object]$Canonical) { ... }
function Register-CanonicalSupervisorTask(...) { ... }
```

Behavior:

- matching existing task: print `PERSISTENT_SUPERVISOR_TASK_REGISTERED=REUSE`
- drifted existing task: preserve approved `Principal.UserId`, stop the task, re-register the same task name with canonical action/settings, print `PERSISTENT_SUPERVISOR_TASK_REREGISTERED=PASS`
- never create a second Supervisor task name

Update `tests/arthur-recovery-supervisor-wiring.tests.ps1` to require the drift comparison and re-registration marker.

- [ ] **Step 3: Implement clean fast-forward repair**

`FAST_FORWARD_CONTROL_RUNTIME` must run only:

```powershell
git -c "safe.directory=$ControlRoot" -C $ControlRoot fetch --prune origin main
git -c "safe.directory=$ControlRoot" -C $ControlRoot merge-base --is-ancestor HEAD origin/main
git -c "safe.directory=$ControlRoot" -C $ControlRoot merge --ff-only origin/main
```

Before and after, verify `status --porcelain` is empty. If dirty return `REPAIR_BLOCKED_DIRTY_CONTROL_RUNTIME`. If not ancestor return `REPAIR_BLOCKED_DIVERGED_CONTROL_RUNTIME`.

- [ ] **Step 4: Implement launcher/module/model repairs**

For `MODULE_ROOT_DRIFT` / `MODEL_BINDING_DRIFT`:

- stop only the known Supervisor Scheduled Task
- stop only processes whose command line contains the exact canonical `StateDir` and either `run-supervisor.py` or `ai_orchestrator ... resume`
- regenerate the existing canonical Supervisor launcher through `ensure-arthur-persistent-supervisor.ps1`
- launcher must set:

```powershell
$env:PYTHONDONTWRITEBYTECODE = '1'
$env:HEADLESS_PYTHON_EXE = '<managed python>'
$env:ARTHUR_CONTROL_PLANE_CODE_ROOT = '<control-runtime>'
$env:ARTHUR_CONTROL_PLANE_STATE_DIR = '<state dir>'
$env:HEADLESS_CODEX_MODEL = 'gpt-5.6-terra'
Set-Location -LiteralPath '<control-runtime>'
```

Do not start the Supervisor yet in `WhitelistRepair` mode; the isolated probe must pass first.

- [ ] **Step 5: Implement retry-state reset guard**

`RESET_SUPERVISOR_RETRY_STATE` must require:

```text
probe.exit_class = PROBE_OK
probe.module root = control-runtime
probe.model_catalog_skipped = true
runtime-state identity unchanged
phase not protected
human gate absent
```

Then:

- copy `supervisor-state.json` to timestamped backup
- remove only `supervisor-state.json`
- assert `runtime-state.json` still exists and hash/identity tuple matches the pre-repair snapshot

- [ ] **Step 6: Run all RED/GREEN contracts and commit Stage B implementation**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\arthur-windows-repair-controller.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\arthur-recovery-supervisor-wiring.tests.ps1
python -m unittest tests.test_arthur_codex_runtime_probe -v
```

Expected: PASS. Commit:

```bash
git add scripts/arthur-windows-repair-controller.ps1 scripts/ensure-arthur-persistent-supervisor.ps1 tests/arthur-windows-repair-controller.tests.ps1 tests/arthur-recovery-supervisor-wiring.tests.ps1
git commit -m "feat: add safe Arthur runtime repair actions"
```

---

### Task 4: Add independent Repair Controller Scheduled Task

**Files:**
- Create: `scripts/ensure-arthur-windows-repair-controller.ps1`
- Create: `tests/arthur-windows-repair-task.tests.ps1`
- Modify: `.github/workflows/arthur-fast-preflight.yml`

**Interfaces:**
- Consumes: same approved interactive user principal as `XinZhaoWrt-Arthur-Persistent-Supervisor`.
- Produces: task `XinZhaoWrt-Arthur-Repair-Controller` and launcher `C:\ProgramData\XinZhaoWrt\RepairController\run-arthur-repair-controller.ps1`.
- Scheduled Task settings: `LogonType Interactive`, `RunLevel Highest`, `MultipleInstances IgnoreNew`, no more frequent than 1 minute, on-demand start supported.

- [ ] **Step 1: Write RED Windows PowerShell 5.1 task contract**

Create `tests/arthur-windows-repair-task.tests.ps1`. Source inspection plus mocked ScheduledTask cmdlets must require:

```powershell
Assert-Contains $installer 'XinZhaoWrt-Arthur-Repair-Controller' 'repair task name must be stable'
Assert-Contains $installer 'XinZhaoWrt-Arthur-Persistent-Supervisor' 'repair task principal must be inherited from supervisor task'
Assert-Contains $installer 'LogonType Interactive' 'repair task must use Codex credential-bearing interactive context'
Assert-Contains $installer 'MultipleInstances IgnoreNew' 'repair task must be single-instance'
Assert-Contains $installer 'arthur-windows-repair-controller.ps1' 'task must invoke the independent repair controller'
Assert-NotContains $installer 'sysupgrade' 'task installer must not gain firmware authority'
```

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\arthur-windows-repair-task.tests.ps1
```

Expected: FAIL because installer is missing.

- [ ] **Step 3: Implement canonical Repair Controller task installer**

The installer must:

1. read `Principal.UserId` from the already-approved Supervisor task
2. fail closed if Supervisor task/principal is absent
3. generate launcher under ProgramData
4. set `ARTHUR_CONTROL_PLANE_CODE_ROOT`, `ARTHUR_CONTROL_PLANE_STATE_DIR`, `HEADLESS_PYTHON_EXE`, `HEADLESS_CODEX_MODEL`
5. invoke controller in configured mode
6. compare existing Repair Task action to canonical action and re-register the same name on drift
7. never require the GitHub runner service account to guess the interactive user

- [ ] **Step 4: Run GREEN and add Fast Preflight**

Run the PowerShell test and add:

```yaml
      - name: Test Arthur Windows repair Scheduled Task
        shell: powershell
        run: ./tests/arthur-windows-repair-task.tests.ps1
```

- [ ] **Step 5: Commit**

```bash
git add scripts/ensure-arthur-windows-repair-controller.ps1 tests/arthur-windows-repair-task.tests.ps1 .github/workflows/arthur-fast-preflight.yml
git commit -m "feat: add Windows-owned Arthur repair task"
```

---

### Task 5: Add full recovery verification gate and bounded repair exhaustion

**Files:**
- Modify: `scripts/arthur-windows-repair-controller.ps1`
- Modify: `tests/arthur-windows-repair-controller.tests.ps1`

**Interfaces:**
- Consumes: passing pre-restart Runtime Probe, repaired Supervisor launcher/task, preserved runtime-state identity.
- Produces: `CODEX_RUNTIME_RECOVERED=PASS` only after 120 seconds and two advancing heartbeats.

- [ ] **Step 1: Write RED tests for 120-second recovery gate**

Make the health evaluator pure by passing observations:

```powershell
$observations = @(
    [pscustomobject]@{ at = [datetimeoffset]'2026-09-06T00:00:00Z'; task_running=$true; supervisor_alive=$true; codex_alive=$true; heartbeat='2026-09-06T00:00:00Z' },
    [pscustomobject]@{ at = [datetimeoffset]'2026-09-06T00:01:00Z'; task_running=$true; supervisor_alive=$true; codex_alive=$true; heartbeat='2026-09-06T00:00:55Z' },
    [pscustomobject]@{ at = [datetimeoffset]'2026-09-06T00:02:01Z'; task_running=$true; supervisor_alive=$true; codex_alive=$true; heartbeat='2026-09-06T00:01:55Z' }
)
$result = Test-ArthurRepairRecoveryWindow -Observations $observations
Assert-Equal $result.passed $true 'two advancing heartbeats over >=120 seconds must pass'
```

Negative tests:

- process dies at 90 seconds => fail
- heartbeat does not advance twice => fail
- runtime identity changes before Codex is healthy => `REPAIR_BLOCKED_RUNTIME_STATE_CHANGED`
- protected phase/human gate appears during repair-owned probe/restart period => fail closed
- same fingerprint reaches 4th attempt within 30 minutes => `REPAIR_EXHAUSTED`, no mutation

- [ ] **Step 2: Implement attempt ledger/fingerprint counting**

Use `repair-events.jsonl`, not a mutable hidden counter, as the source of attempt history. Fingerprint input is stable JSON of:

```text
failure_class
control_runtime_sha
actual_module_root
actual_model
supervisor task action digest
latest runtime error class
```

Hash with SHA-256. Count `repair_action_started` events for the same fingerprint within `[UtcNow-30m, UtcNow]`. If count >= 3, write `REPAIR_EXHAUSTED` and return without mutation.

- [ ] **Step 3: Implement FullRecovery restart and health window**

In `FullRecovery` only:

1. require Runtime Probe `PROBE_OK`
2. verify original runtime-state identity unchanged
3. reset retry state only when needed
4. start the existing Supervisor Scheduled Task
5. sample every 30 seconds
6. require Scheduled Task Running, matching Supervisor PID, matching `ai_orchestrator ... resume` PID, fresh heartbeat, no safety gate
7. require at least two distinct heartbeat timestamps and >=120 seconds between first and last healthy samples
8. write `CODEX_RUNTIME_RECOVERED=PASS`

Do not declare success if only the Supervisor process exists.

- [ ] **Step 4: Run tests GREEN and commit**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\arthur-windows-repair-controller.tests.ps1
```

Expected markers:

```text
ARTHUR_WINDOWS_REPAIR_CONTROLLER_EXHAUSTION_CONTRACT=PASS
ARTHUR_WINDOWS_REPAIR_CONTROLLER_RECOVERY_GATE_CONTRACT=PASS
```

Commit:

```bash
git add scripts/arthur-windows-repair-controller.ps1 tests/arthur-windows-repair-controller.tests.ps1
git commit -m "feat: verify Arthur Codex recovery before handoff"
```

---

### Task 6: Integrate the Repair Controller into GitHub wakeup without making Actions the runtime owner

**Files:**
- Modify: `.github/workflows/production-agent-deploy.yml`
- Modify: `tests/arthur-recovery-supervisor-wiring.tests.ps1`
- Modify: `tests/production-agent.tests.ps1`

**Interfaces:**
- Consumes: `repair-status.json`, Repair Controller Scheduled Task, existing Supervisor/Control Plane state.
- Produces: GitHub markers `WINDOWS_REPAIR_CONTROLLER=ACTIVE|RECOVERED|BLOCKED|TRIGGERED|NOT_REQUIRED`.

- [ ] **Step 1: Write RED workflow contract tests**

Extend PowerShell contract tests to require the wakeup workflow to:

- read `repair-status.json` before ordinary Supervisor recovery
- skip duplicate repair when status is active
- continue ordinary Control Plane only after recovered/healthy
- fail closed and publish evidence on repair-blocked terminal
- start the Repair Controller Scheduled Task when Codex is absent/stale or Supervisor is crash-loop blocked in a non-protected phase
- never wait 120 seconds inside GitHub Actions
- never directly delete `supervisor-state.json`

Required source assertions:

```powershell
Assert-Contains $wakeup 'repair-status.json' 'wakeup must observe durable Windows repair state'
Assert-Contains $wakeup 'XinZhaoWrt-Arthur-Repair-Controller' 'wakeup must trigger the Windows-owned repair task'
Assert-Contains $wakeup 'WINDOWS_REPAIR_CONTROLLER=ACTIVE' 'active repair must suppress duplicate recovery'
Assert-Contains $wakeup 'WINDOWS_REPAIR_CONTROLLER=BLOCKED' 'blocked repair evidence must surface in Actions'
Assert-NotContains $wakeup 'Start-Sleep -Seconds 120' 'Actions must not own the long recovery verification window'
```

- [ ] **Step 2: Implement observer/trigger step before ordinary Control Plane resume**

Add a workflow step after persistent Python preparation and before `Reconcile and resume Arthur Control Plane`:

```powershell
$repairStatusPath = Join-Path $env:LOCALAPPDATA 'XinZhaoWrt\ControlPlane\state\repair-status.json'
$repair = $null
if (Test-Path $repairStatusPath) {
    try { $repair = Get-Content -Raw $repairStatusPath | ConvertFrom-Json } catch { $repair = $null }
}
```

Routing:

- `DIAGNOSING|REPAIRING|PROBING|RESTARTING|VERIFYING` => print ACTIVE and exit this wakeup path successfully without starting a second recovery
- `CODEX_RUNTIME_RECOVERED` => print RECOVERED and continue normal Control Plane
- any `REPAIR_BLOCKED_*|REPAIR_EXHAUSTED` => print BLOCKED plus evidence path and fail the job
- normal healthy Supervisor/Codex => NOT_REQUIRED and continue
- broken non-protected runtime => ensure/start Repair Controller Scheduled Task, print TRIGGERED, skip ordinary duplicate Supervisor restart in this wakeup

- [ ] **Step 3: Publish repair summary in GitHub Actions**

Add to the existing wakeup summary:

```text
- Windows repair status
- failure class
- repair action
- repair attempt count
- control-runtime SHA
- expected/actual module root
- expected/actual model
- final result
```

Do not publish secrets/account payloads.

- [ ] **Step 4: Run contract suites and commit**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\arthur-recovery-supervisor-wiring.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\production-agent.tests.ps1
```

Commit:

```bash
git add .github/workflows/production-agent-deploy.yml tests/arthur-recovery-supervisor-wiring.tests.ps1 tests/production-agent.tests.ps1
git commit -m "feat: route Arthur runtime failures through Windows repair controller"
```

---

### Task 7: Execute staged rollout A -> B -> C on the real Windows controller

**Files:**
- Modify only after evidence gates: `.github/workflows/production-agent-deploy.yml` and/or Repair Task installer default mode.
- Evidence only: canonical Windows `state\repair-status.json`, `state\repair-events.jsonl`, Supervisor/runtime status files, GitHub Actions logs.

**Interfaces:**
- Consumes: all implementation tasks complete and CI green.
- Produces: real-Windows evidence for `CODEX_RUNTIME_RECOVERED`, then existing BUILD handoff continues.

- [ ] **Step 1: Stage A diagnostic-only deployment**

Set mode to `DiagnosticOnly`. On the real Windows controller, trigger the existing known failure state and require:

```text
WINDOWS_REPAIR_DIAGNOSIS=PASS
WINDOWS_REPAIR_CLASS=<known class>
```

Verify by direct file/process evidence that no Git HEAD, Scheduled Task, Supervisor process, retry state, `runtime-state.json`, Candidate, or firmware state changed.

- [ ] **Step 2: Stage A verification gate**

Require all CI green plus real Windows `repair-status.json` matching the known current failure. If classification is `UNKNOWN_FAILURE`, stop rollout and return to root-cause investigation. Do not enable repair mode.

- [ ] **Step 3: Stage B white-list repair deployment**

Set mode to `WhitelistRepair`. Trigger exactly one repair cycle. Require:

```text
WINDOWS_REPAIR_ACTION=<expected whitelist action>
WINDOWS_REPAIR_PROBE=PASS
WINDOWS_REPAIR_RUNTIME_STATE_PRESERVED=PASS
```

Verify the Supervisor is not automatically restarted by Stage B after the repair probe. Confirm `runtime-state.json` identity tuple is byte-for-byte/field-for-field preserved for repair-owned fields.

- [ ] **Step 4: Stage B real Windows dry-run review**

Inspect:

```text
Scheduled Task action/principal
control-runtime HEAD
probe module path
probe effective model
model_catalog_skipped
runtime-state identity
```

Only if all match the spec, enable Stage C.

- [ ] **Step 5: Stage C FullRecovery deployment**

Set mode to `FullRecovery`. Trigger the same repair controller once. No manual PowerShell commands are allowed after the trigger.

Required sequence:

```text
WINDOWS_REPAIR_DIAGNOSIS=PASS
WINDOWS_REPAIR_CLASS=<known class>
WINDOWS_REPAIR_ACTION=<approved action>
WINDOWS_REPAIR_PROBE=PASS
WINDOWS_REPAIR_RUNTIME_STATE_PRESERVED=PASS
WINDOWS_REPAIR_HEALTH_WINDOW=PASS seconds>=120
CODEX_RUNTIME_RECOVERED=PASS
```

- [ ] **Step 6: Verify the existing BUILD handoff continues**

After `CODEX_RUNTIME_RECOVERED`, verify that the existing Arthur task, not a new request, advances from current BUILD state. Evidence must show:

- same `release_task_id`
- same `request_id`
- same accepted/frozen ADH/LuCI/Wi-Fi/QuickStart evidence
- Codex runtime heartbeat continues
- a real BUILD progress marker appears after recovery
- no duplicate Candidate or Flash was created during repair

- [ ] **Step 7: Final verification before claiming completion**

Run all CI and repository contracts, then invoke `superpowers:verification-before-completion`. The only acceptable infrastructure completion statement is backed by real Windows evidence of `CODEX_RUNTIME_RECOVERED` and post-recovery BUILD progress. Do not call the firmware task complete until the existing production pipeline later reaches `PRODUCTION_RELEASED`.

- [ ] **Step 8: Commit rollout-mode change only after successful real-Windows evidence**

If Stage C succeeds, commit the mode default/integration change that makes this the unattended default:

```bash
git add .github/workflows/production-agent-deploy.yml scripts/ensure-arthur-windows-repair-controller.ps1
git commit -m "feat: enable unattended Arthur Windows runtime recovery"
```

If Stage C does not succeed, do not enable default FullRecovery; retain the last proven rollout stage and preserve evidence for the next root-cause cycle.

---

## Plan Self-Review

- Spec coverage: all white-listed failure classes, fail-closed terminals, runtime-state preservation, 3-attempt/30-minute exhaustion, independent Windows ownership, GitHub observer role, 120-second/two-heartbeat gate, and staged rollout are assigned to concrete tasks.
- Placeholder scan: no implementation step relies on TBD/TODO or undefined later work.
- Type/interface consistency: the controller consumes Runtime Probe JSON from Task 1; Tasks 3 and 5 reuse the same runtime identity/fingerprint/status contracts established in Task 2; GitHub integration consumes `repair-status.json` produced by the controller; rollout consumes those same markers without inventing new state.
- Scope check: this plan remains confined to restoring Codex runtime infrastructure. Firmware Build/Candidate/Flash behavior remains outside the Repair Controller.
