"""Unattended Arthur supervisor with durable executor recovery.

This wraps the existing watchdog. Before a stale runtime is restarted it
reconciles HANDOFF plus persisted GitHub Actions/artifact/device observations.
A lost transport/session never authorizes replaying an irreversible action.
"""

import argparse
import os
import time
from pathlib import Path

from .recovery import ExecutorLease, RecoveryEvidence, RecoverySupervisor
from .state_store import StateStore
from .supervisor import RuntimeSupervisor, ensure_windows_startup


class RecoveryRuntimeSupervisor(RuntimeSupervisor):
    def _load_pipeline_state(self):
        return StateStore(self.root).load()

    def _save_pipeline_state(self, state):
        StateStore(self.root).save(state)

    def _heartbeat_executor_lease(self, state):
        if not state:
            return
        recovery = RecoverySupervisor(state)
        if recovery.lease and recovery.lease.status == "ACTIVE":
            recovery.lease.heartbeat()
            recovery._persist_lease()
            self._save_pipeline_state(recovery.state)

    def _prepare_unattended_recovery(self, status, raw_state, supervisor_state):
        state = self._load_pipeline_state()
        if state is None or state.terminal_state:
            return state

        recovery = RecoverySupervisor(state)
        reason = str(
            status.get("transport_error")
            or status.get("error")
            or status.get("reason")
            or "runtime heartbeat lost"
        )
        if recovery.lease and recovery.lease.status == "ACTIVE":
            recovery.mark_executor_lost(reason)

        evidence = RecoveryEvidence.from_handoff(state)
        state = recovery.reconcile(evidence)
        state.observability["supervisor_recovery"] = {
            "release_task_id": state.release_task_id,
            "repo": state.repo,
            "branch": state.branch,
            "source_sha": state.source_sha,
            "active_run_id": state.active_run_id,
            "next_action": state.next_action,
            "old_executor_status": recovery.lease.status if recovery.lease else None,
        }
        self._save_pipeline_state(state)
        return state

    def run_once(self):
        status, raw_state = self._load_runtime()
        supervisor_state = self._load_supervisor_state()
        health = self._runtime_healthy(status, raw_state, supervisor_state)

        if health["healthy"]:
            self._heartbeat_executor_lease(self._load_pipeline_state())
            return super().run_once()

        state = self._prepare_unattended_recovery(status, raw_state, supervisor_state)
        result = super().run_once()

        # A successful relaunch receives a new lease. The old response/thread/
        # session identifiers remain diagnostics and never become task identity.
        if state and result.get("action") == "resume_persisted_handoff":
            refreshed = self._load_pipeline_state() or state
            recovery = RecoverySupervisor(refreshed)
            if recovery.lease and recovery.lease.status == "ACTIVE":
                recovery.mark_executor_lost("superseded by supervisor relaunch")
            child_pid = result.get("child_pid")
            executor_id = "runtime-pid:%s" % (child_pid if child_pid else "pending")
            recovery.acquire_executor(executor_id)
            recovery.state.observability["executor_relaunch"] = {
                "executor_id": executor_id,
                "release_task_id": recovery.state.release_task_id,
                "next_action": recovery.state.next_action,
            }
            self._save_pipeline_state(recovery.state)
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(prog="python -m ai_orchestrator.recovery_runtime")
    parser.add_argument("--state-dir", default="output/headless-production")
    parser.add_argument("--interval", type=float, default=30.0)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args(argv)
    supervisor = RecoveryRuntimeSupervisor(args.state_dir, interval=args.interval)
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
