"""Independent watchdog for the headless GPT-Codex bridge runtime.

The supervisor only starts/resumes the persisted runtime.  It never advances a
pipeline phase, clears a safety gate, or performs a device operation itself.
"""

import contextlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from .observability import age_seconds, atomic_json_write, process_is_alive, utc_now
from .windows_process import hidden_creation_flags, hidden_startupinfo, pythonw_path, runtime_python_path


PROTECTED_PHASES = {"FLASH", "WAIT_DEVICE", "AUTO_FLASH_SAFETY_GATE", "RELEASE_GATE", "RELEASE"}
HUMAN_GATES = {
    "NEW_CREDENTIAL_PROVISIONING",
    "UNKNOWN_DEVICE_IDENTITY",
    "NO_SAFE_ROLLBACK",
    "UNRECOVERABLE_IRREVERSIBLE_OPERATION",
}


def ensure_windows_startup(project_root, state_dir):
    """Install an idempotent per-user startup entry for the hidden supervisor."""
    if os.name != "nt":
        return {"status": "SKIPPED", "reason": "non_windows"}
    project_root = Path(project_root).resolve()
    state_dir = Path(state_dir).resolve()
    launcher = project_root / "scripts" / "run-supervisor.py"
    value = '"%s" "%s" --state-dir "%s" --interval 30' % (
        Path(runtime_python_path()).with_name("pythonw.exe") if os.name == "nt" else runtime_python_path(),
        launcher,
        state_dir,
    )
    completed = subprocess.run(
        [
            "reg.exe",
            "ADD",
            r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
            "/v",
            "XinZhaoWrtGPTCodexBridgeSupervisor",
            "/t",
            "REG_SZ",
            "/d",
            value,
            "/f",
        ],
        capture_output=True,
        text=True,
        creationflags=hidden_creation_flags(),
        startupinfo=hidden_startupinfo(),
    )
    if completed.returncode != 0:
        return {"status": "DEFERRED", "reason": "STARTUP_REGISTRATION_FAILED"}
    return {"status": "PASS", "entry": "XinZhaoWrtGPTCodexBridgeSupervisor"}


class _FileLock:
    def __init__(self, path):
        self.path = Path(path)
        self.fd = None

    def acquire(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        for attempt in range(2):
            try:
                self.fd = os.open(str(self.path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(self.fd, str(os.getpid()).encode("ascii"))
                return
            except FileExistsError:
                if attempt == 0:
                    try:
                        owner = int(self.path.read_text(encoding="ascii").strip())
                    except (OSError, ValueError):
                        owner = None
                    if owner and not process_is_alive(owner):
                        try:
                            self.path.unlink()
                            continue
                        except OSError:
                            pass
                raise RuntimeError("SUPERVISOR_ALREADY_RUNNING")

    def release(self):
        if self.fd is None:
            return
        try:
            os.close(self.fd)
        finally:
            self.fd = None
            try:
                self.path.unlink()
            except FileNotFoundError:
                pass

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, exc_type, exc, tb):
        self.release()


class RuntimeSupervisor:
    """Watch and restart a stopped/stalled runtime with bounded retries."""

    def __init__(
        self,
        state_dir="output/headless-production",
        project_root=None,
        interval=30.0,
        heartbeat_timeout=120.0,
        max_restarts=5,
        restart_window=600.0,
        backoff_base=5.0,
        backoff_max=300.0,
        launcher=None,
        now=None,
    ):
        self.root = Path(state_dir)
        self.project_root = Path(project_root or Path.cwd())
        self.interval = max(1.0, float(interval))
        self.heartbeat_timeout = float(heartbeat_timeout)
        self.max_restarts = max(1, int(max_restarts))
        self.restart_window = max(1.0, float(restart_window))
        self.backoff_base = max(0.0, float(backoff_base))
        self.backoff_max = max(self.backoff_base, float(backoff_max))
        self.launcher = launcher or self._launch_runtime
        self.now = now or time.time
        self.lock_path = self.root / "supervisor.lock"
        self.state_path = self.root / "supervisor-state.json"
        self.status_path = self.root / "supervisor-status.json"
        self.log_path = self.root / "supervisor.log"
        self._process = None

    def locked(self):
        return _FileLock(self.lock_path)

    def _load_json(self, path, default):
        try:
            return json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return default

    def _load_runtime(self):
        status = self._load_json(self.root / "runtime-status.json", {})
        state = self._load_json(self.root / "runtime-state.json", {})
        return status, state

    def _load_supervisor_state(self):
        payload = self._load_json(self.state_path, {})
        if not isinstance(payload, dict):
            payload = {}
        payload.setdefault("restart_times", [])
        payload.setdefault("restart_count", 0)
        payload.setdefault("child_pid", None)
        payload.setdefault("last_start_at", None)
        payload.setdefault("next_retry_at", 0.0)
        return payload

    def _save_supervisor_state(self, payload):
        atomic_json_write(self.state_path, payload)

    def _append_log(self, event, **values):
        self.root.mkdir(parents=True, exist_ok=True)
        record = {"timestamp": utc_now(), "event": event, **values}
        with self.log_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")

    def _write_status(self, payload):
        atomic_json_write(self.status_path, payload)
        return payload

    def _runtime_healthy(self, status, state, supervisor_state):
        child_pid = supervisor_state.get("child_pid")
        child_alive = bool(child_pid and process_is_alive(child_pid))
        runtime = status.get("runtime") or state.get("observability", {}).get("runtime")
        heartbeat = status.get("heartbeat_at") or state.get("observability", {}).get("heartbeat_at")
        heartbeat_age = age_seconds(heartbeat)
        fresh = heartbeat_age is not None and heartbeat_age <= self.heartbeat_timeout
        progress = status.get("last_progress_at") or state.get("observability", {}).get("last_progress_at")
        progress_age = age_seconds(progress)
        stalled = runtime == "STALLED" or status.get("action") == "STALL_DIAGNOSIS"
        daemon_pid = status.get("daemon_pid")
        daemon_alive = bool(daemon_pid and process_is_alive(daemon_pid))
        return {
            "runtime": runtime,
            "heartbeat_age_seconds": heartbeat_age,
            "heartbeat_fresh": fresh,
            "progress_age_seconds": progress_age,
            "stalled": stalled,
            "child_pid": child_pid,
            "child_alive": child_alive,
            "daemon_pid": daemon_pid,
            "daemon_alive": daemon_alive,
            # A live PID is not sufficient: a wedged bridge can remain alive
            # while its persisted heartbeat is stale.  Require a fresh
            # heartbeat for every automatic-health decision.
            "healthy": fresh and not stalled and (
                (runtime in ("LIVE", "RECOVERING") and daemon_alive) or child_alive
            ),
        }

    def _restart_allowed(self, state):
        phase = state.get("phase")
        pending = state.get("pending_human_gate")
        if pending in HUMAN_GATES:
            return False, "WAITING_HUMAN"
        if phase in PROTECTED_PHASES:
            return False, "DEFERRED_SAFETY_PHASE"
        return True, None

    def _prune_restart_times(self, supervisor_state):
        cutoff = self.now() - self.restart_window
        supervisor_state["restart_times"] = [item for item in supervisor_state.get("restart_times", []) if item >= cutoff]

    def _terminate_pid(self, pid):
        if not pid:
            return
        try:
            if os.name == "nt":
                subprocess.run(
                    ["taskkill.exe", "/PID", str(int(pid)), "/T", "/F"],
                    capture_output=True,
                    timeout=5,
                )
            else:
                os.kill(int(pid), 15)
        except (OSError, ValueError, subprocess.SubprocessError):
            return

    def _runtime_command(self):
        runtime_python = runtime_python_path()
        return [
            str(Path(runtime_python).with_name("pythonw.exe") if os.name == "nt" else runtime_python),
            "-m",
            "ai_orchestrator",
            "resume",
            "--state-dir",
            str(self.root.resolve()),
            "--adapter",
            "auto",
        ]

    def _launch_runtime(self, command=None):
        command = command or self._runtime_command()
        self.root.mkdir(parents=True, exist_ok=True)
        log = self.log_path.open("a", encoding="utf-8")
        flags = hidden_creation_flags()
        if os.name == "nt":
            flags |= getattr(subprocess, "DETACHED_PROCESS", 0)
        try:
            return subprocess.Popen(
                command,
                cwd=str(self.project_root),
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                creationflags=flags,
                startupinfo=hidden_startupinfo(),
            )
        except Exception:
            log.close()
            raise

    def run_once(self):
        status, state = self._load_runtime()
        supervisor_state = self._load_supervisor_state()
        self._prune_restart_times(supervisor_state)
        health = self._runtime_healthy(status, state, supervisor_state)
        now = self.now()
        base = {
            "supervisor_pid": os.getpid(),
            "runtime": health["runtime"],
            "runtime_heartbeat_age_seconds": health["heartbeat_age_seconds"],
            "runtime_progress_age_seconds": health["progress_age_seconds"],
            "daemon_pid": health["daemon_pid"],
            "daemon_alive": health["daemon_alive"],
            "child_pid": health["child_pid"],
            "child_alive": health["child_alive"],
            "restart_count": supervisor_state.get("restart_count", 0),
            "heartbeat_timeout_seconds": self.heartbeat_timeout,
            "updated_at": utc_now(),
        }
        if state.get("terminal_state"):
            supervisor_state["child_pid"] = None
            self._save_supervisor_state(supervisor_state)
            return self._write_status({**base, "status": "TERMINAL", "action": "no_restart_terminal_state"})
        allowed, reason = self._restart_allowed(state)
        if not allowed:
            supervisor_state["child_pid"] = health["child_pid"]
            self._save_supervisor_state(supervisor_state)
            return self._write_status({**base, "status": reason, "action": "no_bypass"})
        if health["healthy"]:
            if health["daemon_alive"] and not health["child_alive"]:
                # Adopt a runtime started by the previous supervisor/launcher so
                # the watchdog can continue monitoring it after its own restart.
                supervisor_state["child_pid"] = health["daemon_pid"]
            self._save_supervisor_state(supervisor_state)
            return self._write_status({**base, "status": "HEALTHY", "action": "monitor", "child_pid": supervisor_state.get("child_pid")})
        if now < float(supervisor_state.get("next_retry_at") or 0):
            return self._write_status({**base, "status": "BACKOFF", "action": "bounded_backoff", "next_retry_at": supervisor_state["next_retry_at"]})
        if len(supervisor_state["restart_times"]) >= self.max_restarts:
            self._save_supervisor_state(supervisor_state)
            self._append_log("crash_loop_blocked", restart_count=len(supervisor_state["restart_times"]))
            return self._write_status({**base, "status": "CRASH_LOOP_BLOCKED", "action": "bounded_restart_limit"})
        if health["child_alive"]:
            if self._process is not None:
                try:
                    self._process.terminate()
                except OSError:
                    pass
            else:
                self._terminate_pid(health["child_pid"])
        try:
            process = self.launcher(self._runtime_command())
        except Exception as exc:
            supervisor_state["restart_times"].append(now)
            supervisor_state["restart_count"] += 1
            delay = min(self.backoff_max, self.backoff_base * (2 ** max(0, len(supervisor_state["restart_times"]) - 1)))
            supervisor_state["next_retry_at"] = now + delay
            self._save_supervisor_state(supervisor_state)
            self._append_log("runtime_launch_failed", error=type(exc).__name__, backoff_seconds=delay)
            return self._write_status({**base, "status": "RECOVERING", "action": "launch_failed", "error": type(exc).__name__, "next_retry_at": supervisor_state["next_retry_at"]})
        self._process = process
        supervisor_state["child_pid"] = getattr(process, "pid", None)
        supervisor_state["last_start_at"] = utc_now()
        supervisor_state["restart_times"].append(now)
        supervisor_state["restart_count"] += 1
        delay = min(self.backoff_max, self.backoff_base * (2 ** max(0, len(supervisor_state["restart_times"]) - 1)))
        supervisor_state["next_retry_at"] = now + delay
        self._save_supervisor_state(supervisor_state)
        self._append_log("runtime_started", child_pid=supervisor_state["child_pid"], backoff_seconds=delay)
        return self._write_status({**base, "status": "RECOVERING", "action": "resume_persisted_handoff", "child_pid": supervisor_state["child_pid"], "next_retry_at": supervisor_state["next_retry_at"]})

    def run_forever(self):
        startup = ensure_windows_startup(self.project_root, self.root)
        self._append_log("startup_registration", **startup)
        with self.locked():
            while True:
                self.run_once()
                time.sleep(self.interval)


def main(argv=None):
    import argparse

    parser = argparse.ArgumentParser(prog="python -m ai_orchestrator.supervisor")
    parser.add_argument("--state-dir", default="output/headless-production")
    parser.add_argument("--interval", type=float, default=30.0)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args(argv)
    supervisor = RuntimeSupervisor(args.state_dir, interval=args.interval)
    startup = ensure_windows_startup(Path.cwd(), args.state_dir)
    supervisor._append_log("startup_registration", **startup)
    with supervisor.locked():
        supervisor.run_once()
        if not args.once:
            while True:
                time.sleep(supervisor.interval)
                supervisor.run_once()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
