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


def _emit_failure_diagnostics(state_dir):
    state_dir = Path(state_dir)
    status_path = state_dir / "supervisor-status.json"
    log_path = state_dir / "supervisor.log"

    if status_path.exists():
        try:
            payload = json.loads(status_path.read_text(encoding="utf-8"))
            print(
                "RECOVERY_SUPERVISOR_STATUS="
                + json.dumps(payload, ensure_ascii=False, sort_keys=True),
                file=sys.stderr,
                flush=True,
            )
        except (OSError, ValueError) as exc:
            print(
                "RECOVERY_SUPERVISOR_STATUS_READ_FAILED=%s: %s"
                % (type(exc).__name__, exc),
                file=sys.stderr,
                flush=True,
            )
    else:
        print("RECOVERY_SUPERVISOR_STATUS=MISSING", file=sys.stderr, flush=True)

    print("RECOVERY_SUPERVISOR_LOG_TAIL_BEGIN", file=sys.stderr, flush=True)
    if log_path.exists():
        try:
            lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
            for line in lines[-80:]:
                print(line, file=sys.stderr, flush=True)
        except OSError as exc:
            print(
                "RECOVERY_SUPERVISOR_LOG_READ_FAILED=%s: %s"
                % (type(exc).__name__, exc),
                file=sys.stderr,
                flush=True,
            )
    else:
        print("RECOVERY_SUPERVISOR_LOG=MISSING", file=sys.stderr, flush=True)
    print("RECOVERY_SUPERVISOR_LOG_TAIL_END", file=sys.stderr, flush=True)


def _run(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    state_dir = _state_dir(argv)
    try:
        code = main(argv)
    except BaseException as exc:
        print(
            "RECOVERY_SUPERVISOR_EXCEPTION=%s: %s" % (type(exc).__name__, exc),
            file=sys.stderr,
            flush=True,
        )
        traceback.print_exc(file=sys.stderr)
        _emit_failure_diagnostics(state_dir)
        raise
    if code:
        print("RECOVERY_SUPERVISOR_EXIT_CODE=%s" % code, file=sys.stderr, flush=True)
        _emit_failure_diagnostics(state_dir)
    return code


raise SystemExit(_run())
