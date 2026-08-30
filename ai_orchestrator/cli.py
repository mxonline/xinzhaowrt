import argparse
import asyncio
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from .adapters import (
    AsyncCodexExecutor,
    CodexThreadController,
    PreflightStatus,
    ResponsesController,
    SDKUnavailable,
    choose_controller_backend,
)
from .arthur import ArthurPipeline
from .live import LoopbackLiveController, LoopbackLiveExecutor
from .preflight import inspect_project
from .runtime import ProductionRuntime
from .state_store import StateStore
from .observability import age_seconds, process_is_alive, publish_runtime_status
from .windows_process import hidden_creation_flags, hidden_startupinfo


SDK_REQUIREMENT = "openai-codex>=0.147.0"


def main(argv=None):
    parser = argparse.ArgumentParser(prog="python -m ai_orchestrator")
    subparsers = parser.add_subparsers(dest="command")

    run_parser = subparsers.add_parser("run-production")
    run_parser.add_argument("device", choices=["arthur"])
    _common_options(run_parser)
    run_parser.add_argument("--adapter", choices=["auto", "loopback-live"], default="auto")
    run_parser.add_argument("--detach", action="store_true")
    run_parser.add_argument("--foreground", action="store_true", help=argparse.SUPPRESS)
    run_parser.add_argument("--max-turns", type=int, default=None, help=argparse.SUPPRESS)

    resume_parser = subparsers.add_parser("resume")
    _common_options(resume_parser)
    resume_parser.add_argument("--adapter", choices=["auto", "loopback-live"], default="auto")
    resume_parser.add_argument("--max-turns", type=int, default=None, help=argparse.SUPPRESS)

    status_parser = subparsers.add_parser("status")
    _common_options(status_parser)
    status_parser.add_argument("--watch", action="store_true")
    status_parser.add_argument("--interval", type=float, default=5.0)
    status_parser.add_argument("--iterations", type=int, default=None, help=argparse.SUPPRESS)
    stop_parser = subparsers.add_parser("stop")
    _common_options(stop_parser)
    publisher_parser = subparsers.add_parser("status-publisher", help=argparse.SUPPRESS)
    _common_options(publisher_parser)
    publisher_parser.add_argument("--interval", type=float, default=5.0)
    publisher_parser.add_argument("--once", action="store_true")

    args = parser.parse_args(argv)
    if args.command == "status":
        return _status(args.state_dir, args.watch, args.interval, args.iterations)
    if args.command == "stop":
        StateStore(args.state_dir).request_stop()
        return 0
    if args.command == "status-publisher":
        return _status_publisher(args.state_dir, args.interval, args.once)
    if args.command == "run-production":
        if args.detach and not args.foreground:
            return _detach(args)
        return asyncio.run(_run(args.state_dir, args.adapter, args.max_turns, "arthur-production"))
    if args.command == "resume":
        StateStore(args.state_dir).clear_stop()
        _recover_automatic_terminal_state(StateStore(args.state_dir))
        return asyncio.run(_run(args.state_dir, args.adapter, args.max_turns, None))
    parser.print_help()
    return 2


def _common_options(parser):
    parser.add_argument("--state-dir", default="output/headless-production")


async def _run(state_dir, adapter_name, max_turns, request_id):
    root = Path.cwd()
    store = StateStore(state_dir)
    pipeline = ArthurPipeline()
    if adapter_name == "loopback-live":
        runtime = ProductionRuntime(store, LoopbackLiveExecutor(), LoopbackLiveController(), pipeline)
    else:
        executor, controller, preflight = await _build_sdk_runtime(root)
        runtime = ProductionRuntime(
            store,
            executor,
            controller,
            pipeline,
            preflight=preflight,
            turn_timeout=float(os.environ.get("HEADLESS_TURN_TIMEOUT", "300")),
        )
    state = await runtime.run(request_id=request_id, max_turns=max_turns)
    print(json.dumps(state.to_dict(), ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if state.terminal_state in (None, "PRODUCTION_RELEASED") else 2


async def _build_sdk_runtime(root):
    executor = AsyncCodexExecutor(root)
    try:
        probe = await executor.preflight()
        model_ids = _model_ids(probe.get("models"))
    except SDKUnavailable as exc:
        if _auto_install_sdk():
            executor = AsyncCodexExecutor(root)
            try:
                probe = await executor.preflight()
                model_ids = _model_ids(probe.get("models"))
            except SDKUnavailable as retry_exc:
                status = "RUNTIME_REQUIRED" if sys.version_info < (3, 10) else "SDK_REQUIRED"
                return executor, _UnavailableController(), _environment_preflight(root, status, str(retry_exc))
        else:
            status = "RUNTIME_REQUIRED" if sys.version_info < (3, 10) else "SDK_REQUIRED"
            return executor, _UnavailableController(), _environment_preflight(root, status, str(exc))
    selection = choose_controller_backend(os.environ.get("OPENAI_API_KEY"), model_ids)
    if selection.kind == "responses":
        controller = ResponsesController(os.environ["OPENAI_API_KEY"], selection.model)
        controller_probe = {"backend": "responses", "model": selection.model}
    elif selection.kind == "codex_thread":
        controller = CodexThreadController(root, selection.model)
        try:
            controller_probe = await controller.preflight()
        except SDKUnavailable as exc:
            return executor, _UnavailableController(), _environment_preflight(root, "SDK_REQUIRED", str(exc))
    else:
        controller = _UnavailableController()
        controller_probe = {}
    report = _environment_preflight(root, selection.status.value, "; ".join(selection.evidence))
    report["executor_probe"] = probe
    report["controller_probe"] = controller_probe
    return executor, controller, report


def _auto_install_sdk():
    if sys.version_info < (3, 10):
        return False
    try:
        completed = subprocess.run(
            [sys.executable, "-m", "pip", "install", "--user", SDK_REQUIREMENT],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=300,
        )
        return completed.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


class _UnavailableController:
    async def review(self, result, state):
        raise RuntimeError("controller backend unavailable")


def _environment_preflight(root, status, detail=""):
    report = inspect_project(root)
    report["python"] = sys.version.split()[0]
    if detail:
        report["detail"] = detail
    if status not in ("READY", None):
        report["status"] = status
        report["terminal_state"] = status
    elif report["status"] != "READY":
        report["terminal_state"] = report["status"]
    return report


def _model_ids(payload):
    if isinstance(payload, dict):
        payload = payload.get("models", payload.get("data", []))
    ids = []
    for model in payload or []:
        if isinstance(model, str):
            ids.append(model)
        elif isinstance(model, dict):
            value = model.get("id") or model.get("name")
            if isinstance(value, dict):
                value = value.get("value")
            if value:
                ids.append(value)
    return ids


def _status(state_dir, watch=False, interval=5.0, iterations=None):
    store = StateStore(state_dir)
    if not watch:
        status_path = store.root / "runtime-status.json"
        if status_path.exists():
            print(status_path.read_text(encoding="utf-8"), end="")
            return 0
        state = store.load()
        print(json.dumps(state.to_dict() if state else {"status": "NOT_STARTED"}, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    count = 0
    while iterations is None or count < iterations:
        state = store.load()
        status_path = store.root / "runtime-status.json"
        if status_path.exists():
            try:
                current_status = json.loads(status_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                current_status = None
        else:
            current_status = None
        observations = state.observability if state else {}
        pid = observations.get("pid")
        daemon_alive = process_is_alive(pid)
        if current_status:
            runtime = current_status.get("runtime", "UNKNOWN")
        elif state is None:
            runtime = "NOT_STARTED"
        elif state.pending_human_gate:
            runtime = "WAITING_HUMAN"
        elif state.terminal_state:
            runtime = "TERMINAL"
        elif observations.get("runtime") == "STALLED":
            runtime = "STALLED"
        elif daemon_alive:
            runtime = "LIVE"
        else:
            runtime = "STOPPED"
        active = observations.get("active_process") or {"pid": None, "alive": False}
        print("Runtime: %s" % runtime, flush=True)
        print("PID: %s" % ((current_status or {}).get("daemon_pid", pid if pid is not None else "-")), flush=True)
        print("Stage: %s" % ((current_status or {}).get("stage") or ((observations.get("stage") or state.phase) if state else "-")), flush=True)
        print("Action: %s" % ((current_status or {}).get("action") or observations.get("action") or "-"), flush=True)
        print("Heartbeat: %s" % ((current_status or {}).get("heartbeat_at") or observations.get("heartbeat_at") or "-"), flush=True)
        print("Last Progress: %s" % ((current_status or {}).get("last_progress_at") or observations.get("last_progress_at") or "-"), flush=True)
        active = (current_status or {}).get("active_process") or active
        print("Active Process: pid=%s alive=%s" % (active.get("pid", "-"), active.get("alive", False)), flush=True)
        print("Console Visible: %s" % ("YES" if active.get("console_visible") else "NO"), flush=True)
        print("Human Input Required: %s" % ((current_status or {}).get("human_gate") or (state.pending_human_gate if state and state.pending_human_gate else "NO")), flush=True)
        print(flush=True)
        count += 1
        if iterations is not None and count >= iterations:
            break
        time.sleep(max(0.1, interval))
    return 0


def _status_publisher(state_dir, interval=5.0, once=False):
    store = StateStore(state_dir)
    diagnosed_heartbeat = None
    while True:
        state = store.load()
        if state is not None:
            payload = publish_runtime_status(state, store.root / "runtime-status.json", store.root / "handoff.json")
            heartbeat = payload.get("heartbeat_at")
            heartbeat_age = age_seconds(heartbeat)
            if heartbeat_age is not None and heartbeat_age > 120 and heartbeat != diagnosed_heartbeat:
                store.append_event(
                    "HEALTH_DIAGNOSIS",
                    {
                        "daemon_pid": payload.get("daemon_pid"),
                        "stage": payload.get("stage"),
                        "heartbeat_at": heartbeat,
                        "heartbeat_age_seconds": heartbeat_age,
                        "runtime": payload.get("runtime"),
                    },
                )
                diagnosed_heartbeat = heartbeat
        if once:
            return 0
        time.sleep(max(1.0, interval))


def _detach(args):
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    store = StateStore(state_dir)
    store.clear_stop()
    _recover_automatic_terminal_state(store)
    log_path = state_dir / "runtime.log"
    command = [
        sys.executable,
        "-m",
        "ai_orchestrator",
        "run-production",
        args.device,
        "--state-dir",
        str(state_dir),
        "--adapter",
        args.adapter,
        "--foreground",
    ]
    with log_path.open("a", encoding="utf-8") as log:
        creationflags = hidden_creation_flags() | getattr(subprocess, "DETACHED_PROCESS", 0)
        subprocess.Popen(
            command,
            stdout=log,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            creationflags=creationflags,
            startupinfo=hidden_startupinfo(),
            cwd=str(Path.cwd()),
        )
    return 0


def _recover_automatic_terminal_state(store):
    """Reopen only watchdog/retry exhaustion; never reopen a safety gate."""
    state = store.load()
    if not state or state.terminal_state != "SAFETY_BLOCKED":
        return False
    reason = (state.last_decision or {}).get("reason_code")
    legacy_runtime_block = (
        reason == "TERMINAL_STATE_ALREADY_REACHED"
        and state.phase not in ("AUTO_FLASH_SAFETY_GATE", "FLASH", "WAIT_DEVICE", "RELEASE_GATE", "RELEASE")
        and state.pending_human_gate is None
        and (state.last_result or {}).get("status") == "error"
    )
    if reason not in {"AUTOMATIC_RECOVERY_EXHAUSTED", "SAFETY_BLOCKED_PERSISTENT_EXECUTOR_TIMEOUT"} and not legacy_runtime_block:
        return False
    state.terminal_state = None
    state.pending_human_gate = None
    state.next_codex_prompt = (
        "Resume the current Arthur production handoff from the persisted state. "
        "Preserve every VERIFIED phase and evidence; diagnose the previous automatic runtime failure, "
        "recover it without asking the user, and continue the next safe production action."
    )
    state.observability.update({"runtime": "STOPPED", "action": "automatic_terminal_recovery"})
    store.save(state)
    store.append_event(
        "automatic_terminal_recovery",
        {"reason_code": reason, "phase": state.phase, "legacy_runtime_block": legacy_runtime_block},
    )
    return True
