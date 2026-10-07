"""Provider-backed live proof for the headless executor/controller contract."""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ai_orchestrator.adapters import AsyncCodexExecutor, CodexThreadController
from ai_orchestrator.arthur import ArthurPipeline
from ai_orchestrator.models import CodexResult, PipelineState
from ai_orchestrator.policy import policy_gate


async def run_live_sdk_e2e():
    root = Path.cwd()
    executor = AsyncCodexExecutor(root, model="gpt-5.6-sol")
    controller = CodexThreadController(root, model="gpt-5.6-sol")
    state: PipelineState = ArthurPipeline().initial_state("live-sdk-e2e")
    pairs = []
    try:
        await executor.preflight()
        await controller.preflight()
        for index in range(1, 4):
            await executor.prepare(state)
            result = await asyncio.wait_for(
                executor.run(
                    "Headless provider E2E turn %d. Do not modify files, execute commands, or ask questions. "
                    "Return exactly: LIVE_EXECUTOR_%d" % (index, index),
                    state,
                ),
                120,
            )
            state.last_result = result.to_dict()
            await controller.prepare(state)
            raw_decision = await asyncio.wait_for(controller.review(result, state), 120)
            decision = policy_gate(raw_decision).decision
            state.last_decision = decision.to_dict()
            pairs.append((result, decision))
        assert len(pairs) == 3
        assert all(result.executor_thread_id == state.executor_thread_id for result, _ in pairs)
        assert state.executor_thread_id
        assert state.controller_thread_id
        print("LIVE_SDK_E2E=PASS")
        print("EXECUTOR_TURNS=%d" % len(pairs))
        print("CONTROLLER_DECISIONS=%d" % len(pairs))
        print("EXECUTOR_THREAD_ID=%s" % state.executor_thread_id)
        print("CONTROLLER_THREAD_ID=%s" % state.controller_thread_id)
        return 0
    finally:
        await executor.close()
        await controller.close()


if __name__ == "__main__":
    raise SystemExit(asyncio.run(run_live_sdk_e2e()))
