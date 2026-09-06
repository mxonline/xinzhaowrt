import asyncio
import tempfile
import unittest
from unittest.mock import patch

from ai_orchestrator import cli


class _FakeState:
    def __init__(self, terminal_state):
        self.terminal_state = terminal_state

    def to_dict(self):
        return {"terminal_state": self.terminal_state}


class _FakeRuntime:
    def __init__(self, *args, **kwargs):
        self.state = kwargs.pop("test_state")

    async def run(self, **kwargs):
        return self.state


class CliExitCodeTests(unittest.TestCase):
    def test_terminal_state_exit_code_semantics(self):
        cases = (
            (None, 0),
            ("", 0),
            ("PRODUCTION_RELEASED", 0),
            ("SAFETY_BLOCKED", 2),
        )

        with tempfile.TemporaryDirectory() as tmp:
            for terminal_state, expected in cases:
                with self.subTest(terminal_state=terminal_state):
                    fake_state = _FakeState(terminal_state)

                    def runtime_factory(*args, **kwargs):
                        kwargs["test_state"] = fake_state
                        return _FakeRuntime(*args, **kwargs)

                    with patch.object(cli, "ProductionRuntime", side_effect=runtime_factory):
                        actual = asyncio.run(cli._run(tmp, "loopback-live", None, None))

                    self.assertEqual(expected, actual)


if __name__ == "__main__":
    unittest.main()
