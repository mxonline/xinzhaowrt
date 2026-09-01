from .models import ActionKind, CodexResult


class LoopbackLiveExecutor:
    """A process-test adapter that exercises the production runtime boundary."""

    def __init__(self):
        self.turn = 0

    async def run(self, prompt, state):
        self.turn += 1
        return CodexResult(
            turn_id="live-executor-turn-%d" % self.turn,
            final_response="LIVE executor completed phase %s" % state.phase,
            executor_thread_id="live-executor-thread",
            evidence=["live/turn-%d.json" % self.turn],
        )


class LoopbackLiveController:
    """A separate controller adapter used only by the live daemon contract test."""

    def __init__(self):
        self.review_count = 0

    async def review(self, result, state):
        self.review_count += 1
        if self.review_count < 3:
            return {
                "action": ActionKind.SAFE_AUTO.value,
                "reason_code": "LIVE_PHASE_COMPLETE",
                "summary": "Live controller accepted the executor evidence.",
                "next_codex_prompt": "Continue the next production phase automatically.",
                "evidence": list(result.evidence),
            }
        return {
            "action": ActionKind.TERMINAL.value,
            "reason_code": "LIVE_E2E_COMPLETE",
            "summary": "Live controller verified the chained production path.",
            "terminal_state": "PRODUCTION_RELEASED",
            "evidence": list(result.evidence),
        }
