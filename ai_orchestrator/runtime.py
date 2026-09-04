import asyncio
import os
from pathlib import Path

from .models import ActionKind, CodexResult, GPTDecision, PipelineState, TerminalState
from .policy import DecisionValidationError, PolicyRoute, policy_gate
from .observability import (
    age_seconds,
    output_snapshot,
    process_cpu_snapshot,
    process_is_alive,
    publish_runtime_status,
    utc_now,
)


class ProductionRuntime:
    """Durable executor -> controller -> policy loop independent of Codex UI."""

    def __init__(self, store, executor, controller, pipeline, preflight=None, wait_seconds=2.0, turn_timeout=300.0,
                 heartbeat_interval=30.0, health_interval=120.0, stall_timeout=300.0, project_root=None):
        self.store = store
        self.executor = executor
        self.controller = controller
        self.pipeline = pipeline
        self.preflight = preflight
        self.wait_seconds = wait_seconds
        self.turn_timeout = turn_timeout
        self.heartbeat_interval = heartbeat_interval
        self.health_interval = health_interval
        self.stall_timeout = stall_timeout
        self.project_root = Path(project_root or Path.cwd())
        self.status_path = self.store.root / "runtime-status.json"
        self.handoff_path = self.store.root / "handoff.json"

    async def run(self, request_id=None, max_turns=None):
        state = self.store.load()
        if state is None:
            state = self.pipeline.initial_state(request_id or "arthur-production")
            self.store.save(state)
            self.store.append_event("runtime_started", {"request_id": state.request_id})
        elif request_id and state.request_id != request_id:
            raise ValueError("existing state belongs to request %s" % state.request_id)
        if state.stop_requested and not self.store.stop_requested():
            state.stop_requested = False
            self.store.save(state)
        self._start_observability(state)

        if self.preflight and not state.preflight:
            preflight_value = self.preflight(state) if callable(self.preflight) else self.preflight
            preflight = await _maybe_await(preflight_value)
            state.preflight = preflight
            self.store.append_event("startup_preflight", preflight)
            self.store.save(state)
            if preflight.get("status") not in (None, "READY"):
                state.terminal_state = preflight.get("terminal_state") or preflight.get("status")
                state.phase = "PREFLIGHT"
                state.next_codex_prompt = None
                self.store.save(state)
                self.store.append_event("preflight_blocked", preflight)
                return state

        turns_this_run = 0
        watchdog_task = asyncio.create_task(self._watchdog_loop(state))
        try:
            while state.terminal_state is None:
                if self.store.stop_requested():
                    state.stop_requested = True
                    self._set_observation(state, runtime="STOPPED", action="stop_requested")
                    self.store.save(state)
                    self.store.append_event("runtime_stopped", {"phase": state.phase})
                    return state
                if state.pending_human_gate:
                    self._set_observation(state, runtime="WAITING_HUMAN", action="human_gate_wait", human_input_required=state.pending_human_gate)
                    if self._approval_exists(state.pending_human_gate):
                        self._consume_approval(state)
                    elif max_turns is not None:
                        self.store.save(state)
                        return state
                    else:
                        await asyncio.sleep(self.wait_seconds)
                        continue

                prompt = state.next_codex_prompt or self.pipeline.prompt_for(state.phase)
                prepare = getattr(self.executor, "prepare", None)
                prepare_error = None
                if prepare:
                    self._set_observation(state, runtime="LIVE", stage=state.phase, action="executor.prepare")
                    try:
                        await _with_timeout(prepare(state), self.turn_timeout)
                    except Exception as exc:
                        prepare_error = exc
                    self.store.save(state)
                    self.store.append_event(
                        "executor_thread_ready",
                        {
                            "executor_thread_id": state.executor_thread_id,
                            "ready": prepare_error is None,
                            "error": _exception_text(prepare_error) if prepare_error else None,
                        },
                    )
                if prepare_error is not None:
                    await _reset_adapter_after_error(self.executor, state, "executor")
                    error_text = _exception_text(prepare_error)
                    result = CodexResult(
                        turn_id="executor-error-%d" % (state.turn_count + 1),
                        final_response="executor error: %s" % error_text,
                        status="error",
                        executor_thread_id=state.executor_thread_id,
                        evidence=["executor exception: %s" % error_text],
                    )
                else:
                    self._set_observation(state, runtime="LIVE", stage=state.phase, action="executor.run")
                    try:
                        result = await _with_timeout(self.executor.run(prompt, state), self.turn_timeout)
                    except Exception as exc:
                        await _reset_adapter_after_error(self.executor, state, "executor")
                        error_text = _exception_text(exc)
                        result = CodexResult(
                            turn_id="executor-error-%d" % (state.turn_count + 1),
                            final_response="executor error: %s" % error_text,
                            status="error",
                            executor_thread_id=state.executor_thread_id,
                            evidence=["executor exception: %s" % error_text],
                        )
                state.turn_count += 1
                state.last_result = result.to_dict()
                self.store.append_event(
                    "executor_result",
                    dict(result.to_dict(), source="executor", turn_number=state.turn_count),
                )
                self.store.save(state)
                self._mark_progress(state, "executor_result")

                try:
                    prepare_controller = getattr(self.controller, "prepare", None)
                    if prepare_controller:
                        self._set_observation(state, runtime="LIVE", stage=state.phase, action="controller.prepare")
                        await _with_timeout(prepare_controller(state), self.turn_timeout)
                        self.store.save(state)
                        self.store.append_event(
                            "controller_thread_ready",
                            {"controller_thread_id": state.controller_thread_id},
                        )
                    raw_decision = await _with_timeout(self.controller.review(result, state), self.turn_timeout)
                    conversation_id = getattr(self.controller, "last_conversation_id", None)
                    if conversation_id:
                        state.responses_conversation_id = conversation_id
                    decision = policy_gate(raw_decision).decision
                except (DecisionValidationError, ValueError, TypeError, Exception) as exc:
                    await _reset_adapter_after_error(self.controller, state, "controller")
                    error_text = _exception_text(exc)
                    decision = GPTDecision(
                        action=ActionKind.RECOVERABLE,
                        reason_code="CONTROLLER_PROTOCOL_ERROR",
                        summary="Controller response failed validation or transport; retry automatically.",
                        next_codex_prompt=(
                            "Recover the controller protocol error, preserve all evidence, and rerun phase %s. Error: %s"
                            % (state.phase, error_text)
                        ),
                        evidence=["runtime/controller-error.log"],
                    )
                state.last_decision = decision.to_dict()
                self.store.append_event(
                    "controller_decision",
                    dict(decision.to_dict(), reviewed_by="controller", turn_number=state.turn_count),
                )
                outcome = policy_gate(decision)
                self._apply_outcome(state, outcome)
                self.store.save(state)
                self._mark_progress(state, "controller_decision")
                if outcome.route == PolicyRoute.HUMAN_GATE:
                    self._set_observation(state, runtime="WAITING_HUMAN", stage=state.phase, action="human_gate_wait", human_input_required=state.pending_human_gate)
                elif outcome.route == PolicyRoute.TERMINAL:
                    self._set_observation(state, runtime="TERMINAL", stage=state.phase, action="terminal")
                else:
                    self._set_observation(state, runtime="LIVE", stage=state.phase, action="next_turn", human_input_required=None)
                turns_this_run += 1

                if outcome.route in (PolicyRoute.SAFE_AUTO, PolicyRoute.RECOVERABLE):
                    self.store.append_event(
                        "next_turn",
                        {
                            "source": "executor",
                            "reviewed_by": "controller",
                            "next_action_generated_by": "controller",
                            "next_turn_started_automatically": True,
                            "phase": state.phase,
                        },
                    )
                if max_turns is not None and turns_this_run >= max_turns:
                    self.store.save(state)
                    return state
        finally:
            watchdog_task.cancel()
            try:
                await watchdog_task
            except asyncio.CancelledError:
                pass
            close = getattr(self.executor, "close", None)
            if close:
                await _close_with_timeout(close)
            close = getattr(self.controller, "close", None)
            if close:
                await _close_with_timeout(close)
        return state

    def _apply_outcome(self, state, outcome):
        decision = outcome.decision
        if outcome.route == PolicyRoute.SAFE_AUTO:
            previous_phase = state.phase
            state.phase = decision.metadata.get("next_phase") or self.pipeline.next_phase(state.phase, decision.action)
            state.current_stage = state.phase
            state.next_action = state.phase
            state.next_codex_prompt = decision.next_codex_prompt
            state.pending_human_gate = None
            if state.phase != previous_phase:
                self.store.append_event(
                    "stage_change",
                    {"from": previous_phase, "to": state.phase, "source": "controller", "turn_count": state.turn_count},
                )
        elif outcome.route == PolicyRoute.RECOVERABLE:
            state.current_stage = state.phase
            state.next_action = state.phase
            state.next_codex_prompt = decision.next_codex_prompt
            state.pending_human_gate = None
        elif outcome.route == PolicyRoute.HUMAN_GATE:
            state.current_stage = state.phase
            state.next_action = state.phase
            state.pending_human_gate = outcome.human_gate.value
            state.next_codex_prompt = None
        elif outcome.route == PolicyRoute.TERMINAL:
            state.terminal_state = decision.terminal_state.value
            state.current_stage = state.phase
            state.next_action = state.phase
            state.next_codex_prompt = None
            if state.terminal_state == TerminalState.PRODUCTION_RELEASED.value:
                state.phase = "PRODUCTION_RELEASED"
                state.current_stage = "PRODUCTION_RELEASED"
                state.next_action = "PRODUCTION_RELEASED"

    def _approval_exists(self, gate):
        return getattr(self.store, "approval_path", self.store.root / ("approval-%s.json" % gate)).exists()

    def _consume_approval(self, state):
        path = getattr(self.store, "approval_path", self.store.root / ("approval-%s.json" % state.pending_human_gate))
        try:
            payload = path.read_text(encoding="utf-8")
            self.store.append_event("human_gate_approved", {"gate": state.pending_human_gate, "approval": payload})
            path.unlink()
        except FileNotFoundError:
            return
        state.pending_human_gate = None
        state.current_stage = state.phase
        state.next_action = state.phase
        state.next_codex_prompt = self.pipeline.prompt_for(state.phase)
        self.store.save(state)

    def _start_observability(self, state):
        now = utc_now()
        observations = state.observability
        previous_runtime = observations.get("runtime")
        previous_pid = observations.get("pid")
        process_recovery = previous_pid and not process_is_alive(previous_pid)
        observations.setdefault("started_at", now)
        observations.setdefault("last_progress_at", now)
        observations.update(
            {
                "runtime": "LIVE" if state.terminal_state is None else "TERMINAL",
                "pid": os.getpid(),
                "stage": state.phase,
                "action": "startup",
                "heartbeat_at": now,
                "human_input_required": state.pending_human_gate,
                "observed_turn_count": state.turn_count,
            }
        )
        if (previous_runtime in ("STOPPED", "STALLED") or process_recovery) and state.terminal_state is None:
            observations["action"] = "watchdog_auto_recovery"
            self.store.append_event(
                "watchdog_auto_recovery",
                {
                    "previous_runtime": previous_runtime,
                    "previous_pid": previous_pid,
                    "stage": state.phase,
                    "pid": os.getpid(),
                },
            )
        self.store.save(state)
        self._publish_runtime_status(state)

    def _set_observation(self, state, **values):
        observations = state.observability
        observations.update(values)
        observations["pid"] = os.getpid()
        observations["stage"] = state.phase
        observations["heartbeat_at"] = utc_now()
        observations["active_process"] = self._active_process_info()
        observations["human_input_required"] = state.pending_human_gate
        self._publish_runtime_status(state)

    def _mark_progress(self, state, reason):
        observations = state.observability
        now = utc_now()
        observations["last_progress_at"] = now
        observations["last_progress_reason"] = reason
        observations["observed_turn_count"] = state.turn_count
        observations["active_process"] = self._active_process_info()
        observations["heartbeat_at"] = now
        self.store.save(state)
        self._publish_runtime_status(state)

    def _publish_runtime_status(self, state):
        publish_runtime_status(state, self.status_path, self.handoff_path)

    def _active_process_info(self):
        getter = getattr(self.executor, "active_process_info", None)
        if getter:
            try:
                return getter()
            except Exception as exc:
                return {"pid": None, "alive": False, "error": _exception_text(exc)}
        return {"pid": None, "alive": False}

    def _progress_root(self):
        output_root = self.project_root / "output"
        return output_root if output_root.exists() else self.store.root

    def _health_payload(self, state, active_process, output_before, output_after, cpu_before, cpu_after):
        output_delta = output_after.get("bytes", 0) - output_before.get("bytes", 0)
        output_file_delta = output_after.get("files", 0) - output_before.get("files", 0)
        cpu_delta = None if cpu_before is None or cpu_after is None else cpu_after - cpu_before
        last_progress_at = state.observability.get("last_progress_at")
        return {
            "pid": os.getpid(),
            "daemon_alive": process_is_alive(os.getpid()),
            "stage": state.phase,
            "runtime": state.observability.get("runtime"),
            "action": state.observability.get("action"),
            "heartbeat_at": state.observability.get("heartbeat_at"),
            "last_progress_at": last_progress_at,
            "last_progress_age_seconds": age_seconds(last_progress_at),
            "active_process": active_process,
            "active_process_alive": bool(active_process.get("alive")),
            "output_delta_bytes": output_delta,
            "output_delta_files": output_file_delta,
            "cpu_delta_seconds": cpu_delta,
            "long_running_work": state.phase in ("BUILD", "WAIT_DEVICE", "FLASH"),
            "human_input_required": state.pending_human_gate,
        }

    async def _watchdog_loop(self, state):
        output_before = output_snapshot(self._progress_root(), excluded_roots=(self.store.root,))
        cpu_before = None
        last_health_monotonic = asyncio.get_event_loop().time()
        stall_reported = False
        first_sample = True
        while True:
            if first_sample:
                first_sample = False
                await asyncio.sleep(0)
            else:
                await asyncio.sleep(max(0.01, min(self.heartbeat_interval, self.health_interval)))
            active_process = self._active_process_info()
            output_after = output_snapshot(self._progress_root(), excluded_roots=(self.store.root,))
            cpu_after = process_cpu_snapshot(active_process.get("pid"))
            output_delta = output_after.get("bytes", 0) - output_before.get("bytes", 0)
            cpu_delta = None if cpu_before is None or cpu_after is None else cpu_after - cpu_before
            turn_progressed = state.turn_count != state.observability.get("observed_turn_count", state.turn_count)
            if turn_progressed or output_delta > 0 or (cpu_delta is not None and cpu_delta > 0):
                self._mark_progress(state, "watchdog_activity")
                stall_reported = False
            now = utc_now()
            state.observability.update(
                {
                    "runtime": state.observability.get("runtime") or "LIVE",
                    "pid": os.getpid(),
                    "heartbeat_at": now,
                    "stage": state.phase,
                    "active_process": active_process,
                    "output_snapshot": output_after,
                }
            )
            self.store.append_event(
                "heartbeat",
                {
                    "pid": os.getpid(),
                    "stage": state.phase,
                    "action": state.observability.get("action"),
                    "active_process": active_process,
                    "last_progress_at": state.observability.get("last_progress_at"),
                },
            )
            monotonic = asyncio.get_event_loop().time()
            if monotonic - last_health_monotonic >= self.health_interval:
                health = self._health_payload(state, active_process, output_before, output_after, cpu_before, cpu_after)
                state.observability["last_health_at"] = now
                state.observability["health"] = health
                self.store.append_event("runtime_health", health)
                last_health_monotonic = monotonic
            progress_age = age_seconds(state.observability.get("last_progress_at"))
            if progress_age is not None and progress_age >= self.stall_timeout and not stall_reported:
                diagnosis = self._health_payload(state, active_process, output_before, output_after, cpu_before, cpu_after)
                diagnosis.update({"reason": "no_actual_progress", "threshold_seconds": self.stall_timeout})
                state.observability.update(
                    {"runtime": "STALLED", "action": "STALL_DIAGNOSIS", "stall_diagnosis_at": now}
                )
                self.store.append_event("STALL_DIAGNOSIS", diagnosis)
                self.store.save(state)
                reset = getattr(self.executor, "reset_after_error", None)
                if reset:
                    try:
                        await _with_timeout(reset(), 5.0)
                        state.observability.update({"runtime": "RECOVERING", "action": "watchdog_auto_recovery"})
                        self.store.append_event(
                            "watchdog_auto_recovery",
                            {"reason": "STALL_DIAGNOSIS", "stage": state.phase, "pid": os.getpid()},
                        )
                        self.store.save(state)
                    except Exception as exc:
                        self.store.append_event(
                            "watchdog_recovery_error", {"stage": state.phase, "error": _exception_text(exc)}
                        )
                stall_reported = True
            else:
                self.store.save(state)
            self._publish_runtime_status(state)
            output_before = output_after
            cpu_before = cpu_after


async def _maybe_await(value):
    if hasattr(value, "__await__"):
        return await value
    return value


async def _with_timeout(value, timeout):
    awaitable = _maybe_await(value)
    if timeout is None:
        return await awaitable
    return await asyncio.wait_for(awaitable, timeout=timeout)


def _exception_text(exc):
    text = str(exc).strip()
    if text:
        return "%s: %s" % (type(exc).__name__, text)
    return type(exc).__name__


def _reset_thread_after_error(adapter, state, role):
    """Make the next automatic iteration start from a fresh SDK thread."""
    if role == "executor":
        state.executor_thread_id = None
    else:
        state.controller_thread_id = None
    if hasattr(adapter, "thread"):
        adapter.thread = None


async def _reset_adapter_after_error(adapter, state, role):
    _reset_thread_after_error(adapter, state, role)
    reset = getattr(adapter, "reset_after_error", None)
    if reset:
        try:
            await _with_timeout(reset(), 5.0)
        except Exception:
            return None


async def _close_with_timeout(close, timeout=5.0):
    try:
        await _with_timeout(close(), timeout)
    except Exception:
        return None
