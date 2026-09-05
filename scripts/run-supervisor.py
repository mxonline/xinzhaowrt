"""Windows startup shim for the hidden GPT-Codex bridge recovery supervisor."""

import json
import sys
import traceback
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

from ai_orchestrator.recovery_runtime import main  # noqa: E402


def _state_dir(argv):
    try:
        index = argv.index("--state-dir")
        return Path(argv[index + 1]).resolve()
    except (ValueError, IndexError):
        return (Path.cwd() / "output" / "headless-production").resolve()


def _emit_failure_evidence(root):
    status_path = root / "supervisor-status.json"
    if status_path.exists():
        try:
            payload = json.loads(status_path.read_text(encoding="utf-8"))
            print("RECOVERY_SUPERVISOR_STATUS=" + json.dumps(payload, ensure_ascii=False, sort_keys=True), flush=True)
        except (OSError, ValueError, TypeError) as exc:
            print("RECOVERY_SUPERVISOR_STATUS=INVALID:%s" % type(exc).__name__, flush=True)
    else:
        print("RECOVERY_SUPERVISOR_STATUS=MISSING", flush=True)

    log_path = root / "supervisor.log"
    print("RECOVERY_SUPERVISOR_LOG_TAIL_BEGIN", flush=True)
    if log_path.exists():
        try:
            lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
            for line in lines[-60:]:
                print(line, flush=True)
        except OSError as exc:
            print("SUPERVISOR_LOG_READ_FAILED:%s" % type(exc).__name__, flush=True)
    else:
        print("SUPERVISOR_LOG_MISSING", flush=True)
    print("RECOVERY_SUPERVISOR_LOG_TAIL_END", flush=True)


def _emit_already_running_evidence(root):
    status_path = root / "supervisor-status.json"
    status = "UNKNOWN"
    child_pid = None
    daemon_pid = None
    if status_path.exists():
        try:
            payload = json.loads(status_path.read_text(encoding="utf-8"))
            if isinstance(payload, dict):
                status = str(payload.get("status") or "UNKNOWN")
                child_pid = payload.get("child_pid")
                daemon_pid = payload.get("daemon_pid")
        except (OSError, ValueError, TypeError):
            status = "INVALID_STATUS_JSON"
    print(
        "RECOVERY_SUPERVISOR_ALREADY_RUNNING=PASS status=%s child_pid=%s daemon_pid=%s"
        % (status, child_pid, daemon_pid),
        flush=True,
    )


def _run():
    argv = sys.argv[1:]
    root = _state_dir(argv)
    try:
        code = main()
    except RuntimeError as exc:
        # The long-lived Windows Scheduled Task intentionally owns supervisor.lock.
        # A later GitHub Actions --once health tick seeing that live owner is an
        # idempotent handoff success, not a second-supervisor failure. Persistent
        # invocations without --once remain fail-closed on any lock conflict.
        if str(exc) == "SUPERVISOR_ALREADY_RUNNING" and "--once" in argv:
            _emit_already_running_evidence(root)
            return 0
        traceback.print_exc()
        _emit_failure_evidence(root)
        return 1
    except Exception:
        traceback.print_exc()
        _emit_failure_evidence(root)
        return 1
    if code:
        _emit_failure_evidence(root)
    return int(code or 0)


raise SystemExit(_run())
