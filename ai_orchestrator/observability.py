"""Small, dependency-free runtime and process observability helpers."""

import os
import time
import json
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def process_is_alive(pid):
    if not pid:
        return False
    if os.name == "nt":
        try:
            import ctypes

            kernel32 = ctypes.windll.kernel32
            handle = kernel32.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
            if not handle:
                return False
            try:
                code = ctypes.c_ulong()
                if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
                    return False
                return code.value == 259  # STILL_ACTIVE
            finally:
                kernel32.CloseHandle(handle)
        except (AttributeError, ImportError, OSError, TypeError, ValueError, SystemError):
            # Some bundled pythonw environments cannot load ``_ctypes`` when
            # detached.  Use the native task list as a read-only fallback so a
            # missing optional module cannot kill the bridge watchdog.
            try:
                result = subprocess.run(
                    ["tasklist.exe", "/FI", "PID eq %d" % int(pid), "/NH"],
                    capture_output=True,
                    text=True,
                    timeout=3,
                )
                return result.returncode == 0 and str(pid) in result.stdout
            except (OSError, ValueError, subprocess.SubprocessError):
                return False
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, ProcessLookupError, SystemError):
        return False


def process_snapshot(pid):
    if not pid:
        return {"pid": None, "alive": False}
    return {"pid": int(pid), "alive": process_is_alive(pid)}


def output_snapshot(root, excluded_roots=()):
    root = Path(root)
    excluded = [Path(item).resolve() for item in excluded_roots]
    total_bytes = 0
    latest_mtime = 0.0
    file_count = 0
    if not root.exists():
        return {"bytes": 0, "files": 0, "latest_mtime": None}
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        try:
            resolved = path.resolve()
            if any(resolved == excluded_root or excluded_root in resolved.parents for excluded_root in excluded):
                continue
            stat = path.stat()
        except OSError:
            continue
        total_bytes += stat.st_size
        latest_mtime = max(latest_mtime, stat.st_mtime)
        file_count += 1
    return {
        "bytes": total_bytes,
        "files": file_count,
        "latest_mtime": datetime.fromtimestamp(latest_mtime, timezone.utc).isoformat() if latest_mtime else None,
    }


def process_cpu_snapshot(pid):
    """Return a monotonic CPU-time sample when the platform exposes it."""
    if not pid or not process_is_alive(pid):
        return None
    if os.name == "nt":
        try:
            import ctypes
            from ctypes import wintypes

            kernel32 = ctypes.windll.kernel32
            handle = kernel32.OpenProcess(0x1000, False, int(pid))  # QUERY_LIMITED_INFORMATION
            if not handle:
                return None
            creation = wintypes.FILETIME()
            exit_time = wintypes.FILETIME()
            kernel = wintypes.FILETIME()
            user = wintypes.FILETIME()
            try:
                if not kernel32.GetProcessTimes(handle, ctypes.byref(creation), ctypes.byref(exit_time), ctypes.byref(kernel), ctypes.byref(user)):
                    return None
                to_int = lambda value: (value.dwHighDateTime << 32) | value.dwLowDateTime
                return (to_int(kernel) + to_int(user)) / 10_000_000.0
            finally:
                kernel32.CloseHandle(handle)
        except (AttributeError, ImportError, OSError, TypeError):
            return None
    proc_stat = Path("/proc") / str(pid) / "stat"
    try:
        fields = proc_stat.read_text(encoding="utf-8").split()
        return (int(fields[13]) + int(fields[14])) / max(1, os.sysconf("SC_CLK_TCK"))
    except (OSError, ValueError, IndexError):
        return None


def process_io_snapshot(pid):
    """Return cumulative process I/O counters where the platform exposes them."""
    if not pid or not process_is_alive(pid):
        return None
    if os.name == "nt":
        try:
            import ctypes
            from ctypes import wintypes

            class IoCounters(ctypes.Structure):
                _fields_ = [
                    ("ReadOperationCount", ctypes.c_ulonglong),
                    ("WriteOperationCount", ctypes.c_ulonglong),
                    ("OtherOperationCount", ctypes.c_ulonglong),
                    ("ReadTransferCount", ctypes.c_ulonglong),
                    ("WriteTransferCount", ctypes.c_ulonglong),
                    ("OtherTransferCount", ctypes.c_ulonglong),
                ]

            kernel32 = ctypes.windll.kernel32
            handle = kernel32.OpenProcess(0x1000, False, int(pid))
            if not handle:
                return None
            counters = IoCounters()
            try:
                if not kernel32.GetProcessIoCounters(handle, ctypes.byref(counters)):
                    return None
                return {
                    "read_operations": counters.ReadOperationCount,
                    "write_operations": counters.WriteOperationCount,
                    "read_bytes": counters.ReadTransferCount,
                    "write_bytes": counters.WriteTransferCount,
                }
            finally:
                kernel32.CloseHandle(handle)
        except (AttributeError, OSError, TypeError, ValueError, SystemError):
            return None
    proc_io = Path("/proc") / str(pid) / "io"
    try:
        values = {}
        for line in proc_io.read_text(encoding="utf-8").splitlines():
            name, value = line.split(":", 1)
            values[name.strip().lower()] = int(value.strip())
        return {
            "read_bytes": values.get("read_bytes", 0),
            "write_bytes": values.get("write_bytes", 0),
            "read_operations": values.get("syscr", 0),
            "write_operations": values.get("syscw", 0),
        }
    except (OSError, ValueError):
        return None


def atomic_json_write(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, str(path))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def runtime_status_payload(state):
    observations = state.observability or {}
    active = observations.get("active_process") or {"pid": None, "alive": False, "console_visible": False}
    executor_process = observations.get("executor_process") or active
    controller_process = observations.get("controller_process") or {"pid": None, "alive": False, "console_visible": False}
    last_decision = state.last_decision or {}
    candidate = state.candidate or {}
    candidate_id = (
        candidate.get("id")
        or candidate.get("candidate_id")
        or candidate.get("github_run_id")
        or candidate.get("run_id")
        or candidate.get("sha256")
        or candidate.get("filename")
    )
    current_stage = observations.get("current_stage") or observations.get("stage") or state.phase
    github_run_id = observations.get("github_run_id") or candidate.get("github_run_id") or candidate.get("run_id")
    next_action = observations.get("next_action") or state.next_codex_prompt or last_decision.get("next_codex_prompt")
    daemon_pid = observations.get("pid")
    started_at = observations.get("started_at")
    last_progress_at = observations.get("last_progress_at")
    runtime = observations.get("runtime") or ("TERMINAL" if state.terminal_state else "LIVE")
    if state.pending_human_gate:
        runtime = "WAITING_HUMAN"
    elif state.terminal_state:
        runtime = "TERMINAL"
    elif daemon_pid and not process_is_alive(daemon_pid) and runtime == "LIVE":
        runtime = "STOPPED"
    return {
        "runtime": runtime,
        "daemon_pid": daemon_pid,
        "daemon_uptime": age_seconds(started_at),
        "stage": state.phase,
        "current_stage": current_stage,
        "action": observations.get("action"),
        "candidate_id": candidate_id,
        "github_run_id": github_run_id,
        "codex_child_pid": active.get("pid"),
        "codex_thread_id": state.executor_thread_id,
        "executor_process": executor_process,
        "controller_process": controller_process,
        "controller_thread_id": state.controller_thread_id,
        "controller_stream_recovery": observations.get("controller_stream_recovery"),
        "controller_state": last_decision.get("action") or "IDLE",
        "active_process": active,
        "heartbeat_at": observations.get("heartbeat_at"),
        "last_progress_at": last_progress_at,
        "progress_age_seconds": age_seconds(last_progress_at),
        "retry_count": observations.get("retry_count", 0),
        "human_input_required": bool(state.pending_human_gate),
        "human_gate": state.pending_human_gate,
        "next_action": next_action,
        "terminal_state": state.terminal_state,
        "updated_at": utc_now(),
    }


def publish_runtime_status(state, status_path, handoff_path):
    payload = runtime_status_payload(state)
    atomic_json_write(status_path, payload)
    atomic_json_write(
        handoff_path,
        {
            "request_id": state.request_id,
            "device": state.device,
            "phase": state.phase,
            "runtime": payload["runtime"],
            "current_stage": payload["current_stage"],
            "next_action": payload["next_action"],
            "github_run_id": payload["github_run_id"],
            "candidate_id": payload["candidate_id"],
            "executor_thread_id": state.executor_thread_id,
            "controller_thread_id": state.controller_thread_id,
            "pending_human_gate": state.pending_human_gate,
            "candidate": state.candidate,
            "known_good": state.known_good,
            "updated_at": payload["updated_at"],
        },
    )
    return payload


def age_seconds(timestamp):
    if not timestamp:
        return None
    try:
        value = datetime.fromisoformat(timestamp)
        return max(0.0, (datetime.now(timezone.utc) - value).total_seconds())
    except ValueError:
        return None


def is_long_running_progressing(active_process, output_delta, cpu_delta):
    return bool(active_process and active_process.get("alive") and (output_delta > 0 or (cpu_delta is not None and cpu_delta > 0)))
