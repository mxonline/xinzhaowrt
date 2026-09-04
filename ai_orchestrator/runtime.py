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
            state = self.pipeline.initial_state(request_id or self.pipeline.default_request_id)
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
            state.next_codex_prompt = decision.next_codex_prompt
            state.pending_human_gate = None
            if state.phase != previous_phase:
                self.store.append_event(
                    "stage_change",
                    {"from": previous_phase, "to": state.phase, "source": "controller", "turn_count": state.turn_count},
                )
        elif outcome.route == PolicyRoute.RECOVERABLE:
            state.next_codex_prompt = decision.next_codex_prompt
            state.pending_human_gate = None
        elif outcome.route == PolicyRoute.HUMAN_GATE:
            state.pending_human_gate = outcome.human_gate.value
            state.next_codex_prompt = None
        elif outcome.route == PolicyRoute.TERMINAL:
            state.terminal_state = decision.terminal_state.value
            if state.terminal_state == TerminalState.PRODUCTION_RELEASED.value:
                state.phase = "PRODUCTION_RELEASED"
                state.next_codex_prompt = None

    def _approval_exists(self, gate):
        return getattr(self.store, "approval_path", self.store.root / ("approval-%s.json" % gate)).exists()

    def _consume_approval(self, state):
        path = getattr(self.store, "approval_path", self.store.root / ("approval-%s.json" % state.pending_human_gate))
        try:
            payload = path.read_text(encoding="utf-8")
            self.store.append_event("human_gate_approved", {"gate": state.pending_human_gate, "approval": payload})
            path.unlink()
        except OSError:
            return
        state.pending_human_gate = None
        state.next_codex_prompt = self.pipeline.prompt_for(state.phase)
        self.store.save(state)

    def _set_observation(self, state, **values):
        state.observability.update(values)
        state.observability["heartbeat_at"] = utc_now()
        state.observability["pid"] = os.getpid()
        publish_runtime_status(state, self.status_path, self.handoff_path)

    def _mark_progress(self, state, action):
        now = utc_now()
        state.observability["last_progress_at"] = now
        state.observability["heartbeat_at"] = now
        state.observability["action"] = action
        state.observability["pid"] = os.getpid()
        publish_runtime_status(state, self.status_path, self.handoff_path)

    def _start_observability(self, state):
        now = utc_now()
        state.observability.update(
            {
                "runtime": "LIVE",
                "stage": state.phase,
                "action": "startup",
                "heartbeat_at": now,
                "last_progress_at": state.observability.get("last_progress_at") or now,
                "pid": os.getpid(),
                "active_process": process_cpu_snapshot(os.getpid()),
            }
        )
        publish_runtime_status(state, self.status_path, self.handoff_path)
        self.store.save(state)

    async def _watchdog_loop(self, state):
        last_health = 0.0
        while True:
            await asyncio.sleep(self.heartbeat_interval)
            now = utc_now()
            state.observability["heartbeat_at"] = now
            state.observability["pid"] = os.getpid()
            active_pid = (state.observability.get("active_process") or {}).get("pid")
            if active_pid:
                state.observability["active_process"] = process_cpu_snapshot(active_pid)
            progress_age = age_seconds(state.observability.get("last_progress_at"))
            if progress_age is not None and progress_age >= self.stall_timeout:
                state.observability["runtime"] = "STALLED"
                state.observability["action"] = "diagnose_stall"
                diagnostic = {
                    "stage": state.phase,
                    "action": state.observability.get("action"),
                    "pid": os.getpid(),
                    "process": process_cpu_snapshot(os.getpid()),
                    "active_process": state.observability.get("active_process"),
                    "output": output_snapshot(self.project_root),
                    "progress_age_seconds": progress_age,
                }
                self.store.append_event("HEALTH_DIAGNOSIS", diagnostic)
                recovery = state.observability.setdefault("recovery", {})
                recovery["last_health_diagnosis"] = diagnostic
                recovery["stall_count"] = int(recovery.get("stall_count", 0)) + 1
                state.observability["runtime"] = "LIVE"
                state.observability["action"] = "retry_after_stall"
                state.observability["last_progress_at"] = now
            if age_seconds(state.observability.get("health_at")) is None or age_seconds(state.observability.get("health_at")) >= self.health_interval:
                state.observability["health_at"] = now
            self.store.save(state)
            publish_runtime_status(state, self.status_path, self.handoff_path)


async def _maybe_await(value):
    if hasattr(value, "__await__"):
        return await value
    return value


async def _with_timeout(value, timeout):
    if timeout is None:
        return await value
    return await asyncio.wait_for(value, timeout=timeout)


async def _close_with_timeout(close):
    try:
        await asyncio.wait_for(close(), timeout=5.0)
    except Exception:
        return


async def _reset_adapter_after_error(adapter, state, role):
    reset = getattr(adapter, "reset_after_error", None)
    if not reset:
        return
    try:
        await _maybe_await(reset(state, role))
    except Exception:
        return


def _exception_text(exc):
    return "%s: %s" % (exc.__class__.__name__, exc)
